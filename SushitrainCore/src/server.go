// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"crypto/ed25519"
	"errors"
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
	ctx                         context.Context
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

func (srv *StreamingServer) URLFor(folder string, path string) string {
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

type miniPuller struct {
	experiences map[protocol.DeviceID]bool
	context     context.Context
}

func (mp *miniPuller) downloadBock(m *syncthing.Internals, folderID string, blockIndex int, file protocol.FileInfo, block protocol.BlockInfo) ([]byte, error) {
	availables, err := m.BlockAvailability(folderID, file, block)
	if err != nil {
		return nil, err
	}
	if len(availables) < 1 {
		return nil, errors.New("no peer available")
	}

	Logger.Infoln("Download block", availables, mp.experiences)

	// Attempt to download the block from an available and 'known good' peers first
	for _, available := range availables {
		if exp, ok := mp.experiences[available.ID]; ok && exp {
			buf, err := m.DownloadBlock(mp.context, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
			// Remember our experience with this peer for next time
			mp.experiences[available.ID] = err == nil
			if err == nil {
				return buf, nil
			} else {
				Logger.Infoln("- good peer error:", available.ID, err, len(buf))
			}
		}
	}

	// Failed to download from a good peer, let's try the others
	for _, available := range availables {
		if _, ok := mp.experiences[available.ID]; !ok {
			buf, err := m.DownloadBlock(mp.context, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
			// Remember our experience with this peer for next time
			mp.experiences[available.ID] = err == nil
			if err == nil {
				return buf, nil
			} else {
				Logger.Infoln("- unknown peer error:", available.ID, err, len(buf))
			}
		}
	}

	// Failed to download from a good or unknown peer, let's try the 'bad' ones again
	for _, available := range availables {
		if exp, ok := mp.experiences[available.ID]; ok && !exp {
			buf, err := m.DownloadBlock(mp.context, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
			// Remember our experience with this peer for next time
			mp.experiences[available.ID] = err == nil
			if err == nil {
				return buf, nil
			} else {
				Logger.Infoln("- bad peer error:", available.ID, err, len(buf))
			}
		}
	}

	return nil, errors.New("no peer to download this block from")
}

func newMiniPuller(ctx context.Context) *miniPuller {
	return &miniPuller{
		experiences: map[protocol.DeviceID]bool{},
		context:     ctx,
	}
}

func NewServer(app *syncthing.App, ctx context.Context) (*StreamingServer, error) {
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

		w.Header().Add("Accept-range", "bytes")

		// Set MIME type
		ext := filepath.Ext(path)
		mime := MIMETypeForExtension(ext)
		w.Header().Add("Content-type", mime)

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

			mp := newMiniPuller(r.Context())

			blockSize := int64(info.BlockSize())
			for _, rng := range parsedRanges {
				startBlock := rng.Start / int64(blockSize)
				blockCount := ceilDiv(rng.Length, blockSize)
				Logger.Infoln("Range: ", rng, startBlock, blockCount, blockSize)
				w.Header().Add("Content-Range", fmt.Sprintf("bytes %d-%d/%d", rng.Start, rng.Length+rng.Start-1, info.Size))
				w.Header().Add("Content-length", fmt.Sprintf("%d", rng.Length))
				w.WriteHeader(206) // partial content

				bytesSent := int64(0)

				for blockIndex := startBlock; blockIndex < startBlock+blockCount; blockIndex++ {
					blockStartTime := time.Now()

					// Fetch block
					block := info.Blocks[blockIndex]
					buf, err := mp.downloadBock(m, folder, int(blockIndex), info, block)
					if err != nil {
						Logger.Warnln("error downloading block: ", err)
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

					// Write buffer
					Logger.Debugln("Sending chunk", blockIndex, bufStart, bufEnd, len(buf), bufEnd-bufStart)
					w.Write(buf[bufStart:bufEnd])
					bytesSent += (bufEnd - bufStart)
					if server.Delegate != nil {
						go server.Delegate.OnStreamChunk(folder, path, int64(bytesSent), rng.Length)
					}

					// Throttle the stream to a specific average Mbit/s to prevent streaming video from being donwloaded
					// too quickly, wasting precious mobile data
					if server.MaxMbitsPerSecondsStreaming > 0 {
						blockFetchDurationMs := time.Since(blockStartTime).Milliseconds()
						blockFetchShouldHaveTakenMs := int64(block.Size) * 8 / server.MaxMbitsPerSecondsStreaming / 1000

						if blockFetchDurationMs < blockFetchShouldHaveTakenMs {
							time.Sleep(time.Duration(blockFetchShouldHaveTakenMs-blockFetchDurationMs) * time.Millisecond)
						}
					}
				}
			}
		} else {
			// Send all blocks (unthrottled)
			w.Header().Add("Content-length", fmt.Sprintf("%d", info.Size))
			w.WriteHeader(200)

			fetchedBytes := int64(0)
			mp := newMiniPuller(r.Context())

			for blockNo, block := range info.Blocks {
				buf, err := mp.downloadBock(m, folder, blockNo, info, block)
				if err != nil {
					return
				}
				fetchedBytes += int64(block.Size)
				w.Write(buf)
			}
		}
	}))

	if err := server.Listen(); err != nil {
		return nil, err
	}

	return &server, nil
}
