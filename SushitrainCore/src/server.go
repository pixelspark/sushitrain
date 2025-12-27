// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
	"golang.org/x/exp/slog"
)

type StreamingServerDelegate interface {
	OnStreamChunk(folder string, path string, bytesSent int64, bytesTotal int64)
}

type StreamingServer struct {
	listener                    net.Listener
	client                      *Client
	publicKey                   ed25519.PublicKey
	privateKey                  ed25519.PrivateKey
	MaxMbitsPerSecondsStreaming int64
	mux                         *http.ServeMux
	Delegate                    StreamingServerDelegate
}

func ceilDiv(a int64, b int64) int64 {
	return (a + (b - 1)) / b
}

const (
	signatureQueryParameter string = "signature"
)

func (srv *StreamingServer) port() int {
	return srv.listener.Addr().(*net.TCPAddr).Port
}

func (srv *StreamingServer) urlFor(folder string, path string) string {
	url := url.URL{
		Scheme: "http",
		Host:   fmt.Sprintf("localhost:%d", srv.port()),
		Path:   "/file",
	}

	q := url.Query()
	q.Set("path", path)
	q.Set("folder", folder)
	url.RawQuery = q.Encode()
	srv.signURL(&url)
	return url.String()
}

func (srv *StreamingServer) signURL(u *url.URL) {
	// Remove any existing signature
	qs := u.Query()
	qs.Del(signatureQueryParameter)
	u.RawQuery = qs.Encode()

	// Sign full URL
	partToVerify := u.RawPath + "/" + u.RawQuery
	signature := ed25519.Sign(srv.privateKey, []byte(partToVerify))
	qs.Add(signatureQueryParameter, base64.StdEncoding.EncodeToString(signature))
	u.RawQuery = qs.Encode()
}

func (srv *StreamingServer) verifyURL(u *url.URL) bool {
	qs := u.Query()
	signatureBase64 := qs.Get(signatureQueryParameter)
	if len(signatureBase64) == 0 {
		return false
	}
	qs.Del(signatureQueryParameter)
	signature, err := base64.StdEncoding.DecodeString(signatureBase64)
	if err != nil {
		return false
	}

	u.RawQuery = qs.Encode()
	partToVerify := u.RawPath + "/" + u.RawQuery
	return ed25519.Verify(srv.publicKey, []byte(partToVerify), signature)
}

func (srv *StreamingServer) Listen() error {
	// Close existing listener
	if srv.listener != nil {
		srv.listener.Close()
	}

	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		return err
	}

	go http.Serve(listener, srv.mux)
	srv.listener = listener
	slog.Info("HTTP service listening", "port", srv.port())
	return nil
}

func NewServer(app *syncthing.App, measurements *Measurements, ctx context.Context) (*StreamingServer, error) {
	// Generate a private key to sign URLs with
	publicKey, privateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		return nil, err
	}

	mux := http.NewServeMux()

	server := StreamingServer{
		mux:                         mux,
		publicKey:                   publicKey,
		privateKey:                  privateKey,
		MaxMbitsPerSecondsStreaming: 0, // no limit
	}

	mux.Handle("/file", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !server.verifyURL(r.URL) {
			slog.Warn("request denied", "method", r.Method, r.URL.Path, r.URL.RawQuery)
			w.WriteHeader(403)
			return
		}

		folder := r.URL.Query().Get("folder")
		path := r.URL.Query().Get("path")

		slog.Info("request", "method", r.Method, "folder", folder, "path", path)
		stFolder := server.client.FolderWithID(folder)
		if stFolder == nil {
			slog.Warn("request not found", "method", r.Method, "folder", folder, "path", path)
			w.WriteHeader(404)
			return
		}
		stEntry, err := stFolder.GetFileInformation(path)
		if err != nil {
			slog.Warn("request file information failed", "cause", err, "method", r.Method, "folder", folder, "path", path)
			w.WriteHeader(500)
			w.Write([]byte(err.Error()))
			return
		}

		m := app.Internals
		info, ok, err := m.GlobalFileInfo(folder, path)
		if err != nil {
			slog.Warn("request global file information failed", "cause", err, "method", r.Method, "folder", folder, "path", path)
			w.WriteHeader(500)
			w.Write([]byte(err.Error()))
			return
		}
		if !ok {
			slog.Warn("request global file not found", "method", r.Method, "folder", folder, "path", path)
			w.WriteHeader(404)
			return
		}

		// Set MIME type
		ext := filepath.Ext(path)
		mime := MIMETypeForExtension(ext)
		if mime == "" {
			mime = "application/octet-stream"
		}
		w.Header().Add("Content-type", mime)

		startTime := time.Now()
		var totalBytesSent int64 = 0

		callback := func(bytesSent int64, bytesRequested int64) {
			if server.Delegate != nil {
				go server.Delegate.OnStreamChunk(folder, path, int64(bytesSent), bytesRequested)
			}
			totalBytesSent += bytesSent

			// Throttle the stream to a specific average Mbit/s to prevent streaming video from being donwloaded
			// too quickly, wasting precious mobile data
			if server.MaxMbitsPerSecondsStreaming > 0 {
				blockFetchDurationMs := time.Since(startTime).Milliseconds()
				blockFetchShouldHaveTakenMs := totalBytesSent * 8 / server.MaxMbitsPerSecondsStreaming / 1000

				if blockFetchDurationMs < blockFetchShouldHaveTakenMs {
					time.Sleep(time.Duration(blockFetchShouldHaveTakenMs-blockFetchDurationMs) * time.Millisecond)
				}
			}
		}

		// Send file contents to the client
		serveEntry(w, r, folder, stEntry, info, m, measurements, callback)
	}))

	if err := server.Listen(); err != nil {
		return nil, err
	}

	return &server, nil
}

type entryReadSeeker struct {
	info     protocol.FileInfo
	offset   int64
	puller   *miniPuller
	entry    *Entry
	context  context.Context
	callback serveCallback
}

func newEntryReadSeeker(info protocol.FileInfo, puller *miniPuller, entry *Entry, context context.Context, callback serveCallback) *entryReadSeeker {
	return &entryReadSeeker{
		info:     info,
		offset:   0,
		puller:   puller,
		entry:    entry,
		context:  context,
		callback: callback,
	}
}

// Seek implements io.Seeker.
func (e *entryReadSeeker) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekCurrent:
		e.offset += offset
		return e.offset, nil
	case io.SeekStart:
		e.offset = offset
		return e.offset, nil
	case io.SeekEnd:
		e.offset = offset + e.info.Size
		return e.offset, nil
	default:
		return e.offset, errors.New("unsuported whence value")
	}
}

// Read implements io.Reader.
func (e *entryReadSeeker) Read(p []byte) (n int, err error) {
	if len(p) == 0 {
		return 0, nil
	}

	size := int64(len(p))
	if e.offset+int64(size) > e.info.Size {
		if e.info.Size > e.offset {
			size = e.info.Size - e.offset
		} else {
			size = 0
		}
	}

	if size == 0 {
		return 0, io.EOF
	}

	// Try to fulfill request locally
	if bytes, err := e.entry.FetchLocal(e.offset, size); err == nil && bytes != nil {
		total := copy(p, bytes)
		e.offset += int64(total)
		return total, nil
	}

	// Start pulling those blocks
	blockSize := int64(e.info.BlockSize())
	startBlock := e.offset / int64(blockSize)
	blockCount := ceilDiv(int64(size), blockSize)

	// If we start halfway the first block, we need to fetch another one at the end to make up for it
	offsetInStartBlock := e.offset % int64(blockSize)
	if offsetInStartBlock > 0 {
		blockCount += 1
	}

	var bytesRead int64 = 0
	folderID := e.entry.Folder.FolderID

	for blockIndex := startBlock; blockIndex < startBlock+blockCount; blockIndex++ {
		if int(blockIndex) > len(e.info.Blocks)-1 {
			break
		}

		// Fetch block
		block := e.info.Blocks[blockIndex]
		buf, err := e.puller.downloadBlock(e.context, folderID, int(blockIndex), e.info, 1)
		if err != nil {
			slog.Warn("error downloading block", "blockIndex", blockIndex, "blockCount", len(e.info.Blocks), "cause", err)
			// We are now sending less content than we promised in the header. The client should reject our response
			// and try again later.
			return int(bytesRead), err
		}

		bufStart := int64(0)
		bufEnd := int64(len(buf))

		if block.Offset < e.offset {
			bufStart = e.offset - block.Offset
		}

		blockEnd := (block.Offset + int64(block.Size))
		rangeEnd := (e.offset + int64(size))
		if blockEnd > rangeEnd {
			bufEnd = rangeEnd - block.Offset
		}
		if bufEnd < 0 {
			break
		}

		// Write buffer
		slog.Info("sending block", "blockIndex", blockIndex, "bufStart", bufStart, "bufEnd", bufEnd, "bufLength", len(buf), "bytes", bufEnd-bufStart)
		copy(p[bytesRead:], buf[bufStart:bufEnd])
		bytesRead += (bufEnd - bufStart)
		if e.callback != nil {
			e.callback(bytesRead, size)
		}
	}

	e.offset += bytesRead
	return int(bytesRead), nil
}

var _ io.ReadSeeker = &entryReadSeeker{}

type serveCallback func(bytesSent int64, bytesRequested int64)

func serveEntry(w http.ResponseWriter, r *http.Request, folderID string, entry *Entry, info protocol.FileInfo, m *syncthing.Internals, measurements *Measurements, callback serveCallback) {
	// Disable caching
	w.Header().Add("Cache-Control", "no-cache, no-store, must-revalidate")
	w.Header().Add("Pragma", "no-cache")
	w.Header().Add("Expires", "0")

	mp := newMiniPuller(measurements, m)
	readSeeker := newEntryReadSeeker(info, mp, entry, r.Context(), callback)
	http.ServeContent(w, r, entry.info.Name, entry.info.ModTime(), readSeeker)
}
