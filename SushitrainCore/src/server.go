// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"time"

	"github.com/gotd/contrib/http_range"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
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
	qs.Add(signatureQueryParameter, string(signature))
	u.RawQuery = qs.Encode()
}

func (srv *StreamingServer) verifyURL(u *url.URL) bool {
	qs := u.Query()
	signature := qs.Get(signatureQueryParameter)
	if len(signature) == 0 {
		return false
	}
	qs.Del(signatureQueryParameter)
	u.RawQuery = qs.Encode()
	partToVerify := u.RawPath + "/" + u.RawQuery
	return ed25519.Verify(srv.publicKey, []byte(partToVerify), []byte(signature))
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
	Logger.Infoln("HTTP service listening on port", srv.port())
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
			w.WriteHeader(403)
			return
		}

		folder := r.URL.Query().Get("folder")
		path := r.URL.Query().Get("path")

		Logger.Infoln("Request", r.Method, folder, path)
		stFolder := server.client.FolderWithID(folder)
		if stFolder == nil {
			w.WriteHeader(404)
			return
		}
		stEntry, err := stFolder.GetFileInformation(path)
		if err != nil {
			w.WriteHeader(500)
			w.Write([]byte(err.Error()))
			return
		}

		m := app.Internals
		info, ok, err := m.GlobalFileInfo(folder, path)
		if err != nil {
			w.WriteHeader(500)
			w.Write([]byte(err.Error()))
			return
		}
		if !ok {
			w.WriteHeader(404)
			return
		}

		// Set MIME type
		ext := filepath.Ext(path)
		mime := MIMETypeForExtension(ext)
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

type serveCallback func(bytesSent int64, bytesRequested int64)

func serveEntry(w http.ResponseWriter, r *http.Request, folderID string, entry *Entry, info protocol.FileInfo, m *syncthing.Internals, measurements *Measurements, callback serveCallback) {
	w.Header().Add("Accept-range", "bytes")

	// Disable caching
	w.Header().Add("Cache-Control", "no-cache, no-store, must-revalidate")
	w.Header().Add("Pragma", "no-cache")
	w.Header().Add("Expires", "0")

	// Is this a ranged request?
	requestedRange := r.Header.Get("Range")
	if len(requestedRange) > 0 {
		// Send just the blocks requested
		parsedRanges, err := http_range.ParseRange(requestedRange, info.Size)
		if err != nil {
			w.WriteHeader(500)
			w.Write([]byte(err.Error()))
			return
		}

		if len(parsedRanges) > 1 {
			Logger.Warnln("Multipart ranges not yet supported", requestedRange)
			w.WriteHeader(500)
			return
		}

		mp := newMiniPuller(r.Context(), measurements)

		blockSize := int64(info.BlockSize())
		for _, rng := range parsedRanges {
			// Range cannot be longer than actual file
			if rng.Start+rng.Length > info.Size {
				Logger.Warnln("Requested range ", rng, " is larger than file; shrinking range to length=", max(0, info.Size-rng.Start))
				rng.Length = max(0, info.Size-rng.Start)
			}

			// Do we have this file ourselves?
			// FIXME: this will lead to re-opening the file for each block, persist the file handle and 'ReadAt' from it directly.
			if buffer, err := entry.FetchLocal(rng.Start, rng.Length); err == nil {
				Logger.Debugln("We have this block locally; writing ", len(buffer), " bytes")
				w.Write(buffer)
				continue
			}

			startBlock := rng.Start / int64(blockSize)
			blockCount := ceilDiv(rng.Length, blockSize)

			// If we start halfway the first block, we need to fetch another one at the end to make up for it
			offsetInStartBlock := rng.Start % int64(blockSize)
			if offsetInStartBlock > 0 {
				blockCount += 1
			}
			rangeHeader := fmt.Sprintf("bytes %d-%d/%d", rng.Start, rng.Length+rng.Start-1, info.Size)
			lengthHeader := fmt.Sprintf("%d", rng.Length)
			Logger.Infoln("Range: ", rng, "start block=", startBlock, "block count=", blockCount, "block size=", blockSize, "range header=", rangeHeader, "length header=", lengthHeader)
			w.Header().Add("Content-Range", rangeHeader)
			w.Header().Add("Content-length", lengthHeader)
			w.WriteHeader(206) // partial content

			bytesSent := int64(0)

			for blockIndex := startBlock; blockIndex < startBlock+blockCount; blockIndex++ {
				if int(blockIndex) > len(info.Blocks)-1 {
					break
				}

				// Fetch block
				block := info.Blocks[blockIndex]
				buf, err := mp.downloadBock(m, folderID, int(blockIndex), info, block)
				if err != nil {
					Logger.Warnln("error downloading block #", blockIndex, " of ", len(info.Blocks), ": ", err)
					return
				}

				bufStart := int64(0)
				bufEnd := int64(len(buf))

				if block.Offset < rng.Start {
					bufStart = rng.Start - block.Offset
				}

				blockEnd := (block.Offset + int64(block.Size))
				rangeEnd := (rng.Length + rng.Start)
				if blockEnd > rangeEnd {
					bufEnd = rangeEnd - block.Offset
				}
				if bufEnd < 0 {
					break
				}

				// Write buffer
				Logger.Infoln("Sending block #", blockIndex, bufStart, bufEnd, len(buf), "bytes=", bufEnd-bufStart, "range=", rng)
				w.Write(buf[bufStart:bufEnd])
				bytesSent += (bufEnd - bufStart)
				if callback != nil {
					callback(bytesSent, rng.Length)
				}
			}

			if rng.Length != bytesSent {
				Logger.Warnln("Sent a different number of bytes than promised! range=", rng, "; promised ", lengthHeader, "sent", bytesSent)
			}
		}
	} else {
		// Send all blocks (unthrottled)
		w.Header().Add("Content-length", fmt.Sprintf("%d", info.Size))
		w.WriteHeader(200)

		// Do we have this file ourselves?
		if buffer, err := entry.FetchLocal(0, info.Size); err == nil {
			Logger.Debugln("We have this file completely locally; writing ", len(buffer), " bytes")
			w.Write(buffer)
		} else {
			fetchedBytes := int64(0)
			mp := newMiniPuller(r.Context(), measurements)

			for blockNo, block := range info.Blocks {
				buf, err := mp.downloadBock(m, folderID, blockNo, info, block)
				if err != nil {
					return
				}
				fetchedBytes += int64(block.Size)
				w.Write(buf)
			}
		}
	}
}
