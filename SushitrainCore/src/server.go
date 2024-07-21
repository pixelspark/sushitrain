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

func (self *StreamingServer) port() int {
	return self.listener.Addr().(*net.TCPAddr).Port
}

func (self *StreamingServer) URLFor(folder string, path string) string {
	url := url.URL{
		Scheme: "http",
		Host:   fmt.Sprintf("localhost:%d", self.port()),
		Path:   "/file",
	}

	q := url.Query()
	q.Set("path", path)
	q.Set("folder", folder)
	url.RawQuery = q.Encode()
	self.signURL(&url)
	return url.String()
}

func (self *StreamingServer) signURL(u *url.URL) {
	// Remove any existing signature
	qs := u.Query()
	qs.Del(signatureQueryParameter)
	u.RawQuery = qs.Encode()

	// Sign full URL
	partToVerify := u.RawPath + "/" + u.RawQuery
	signature := ed25519.Sign(self.privateKey, []byte(partToVerify))
	qs.Add(signatureQueryParameter, string(signature))
	u.RawQuery = qs.Encode()
}

func (self *StreamingServer) verifyURL(u *url.URL) bool {
	qs := u.Query()
	signature := qs.Get(signatureQueryParameter)
	if len(signature) == 0 {
		return false
	}
	qs.Del(signatureQueryParameter)
	u.RawQuery = qs.Encode()
	partToVerify := u.RawPath + "/" + u.RawQuery
	return ed25519.Verify(self.publicKey, []byte(partToVerify), []byte(signature))
}

func (self *StreamingServer) Listen() error {
	// Close existing listener
	if self.listener != nil {
		self.listener.Close()
	}

	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		return err
	}

	go http.Serve(listener, self.mux)
	self.listener = listener
	fmt.Println("HTTP service listening on port", self.port())
	return nil
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
		fmt.Println("Request", folder, path)
		fmt.Printf("Headers %v\n", r.Header)
		fmt.Println("Method", r.Method)

		m := app.M
		info, ok, err := m.CurrentGlobalFile(folder, path)
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
				fmt.Println("Multipart ranges not yet supported")
				w.WriteHeader(500)
				return
			}

			blockSize := int64(info.BlockSize())
			for _, rng := range parsedRanges {
				startBlock := rng.Start / int64(blockSize)
				blockCount := ceilDiv(rng.Length, blockSize)
				w.Header().Add("Content-Range", fmt.Sprintf("bytes %d-%d/%d", rng.Start, rng.Length+rng.Start-1, info.Size))
				w.Header().Add("Content-length", fmt.Sprintf("%d", rng.Length))
				w.WriteHeader(206) // partial content

				bytesSent := int64(0)

				for blockIndex := startBlock; blockIndex < startBlock+blockCount; blockIndex++ {
					blockStartTime := time.Now()

					// Fetch block
					block := info.Blocks[blockIndex]
					av, err := m.Availability(folder, info, block)
					if err != nil {
						return
					}
					if len(av) < 1 {
						return
					}

					buf, err := m.RequestGlobal(r.Context(), av[0].ID, folder, info.Name, int(blockIndex), block.Offset, block.Size, block.Hash, block.WeakHash, false)
					if err != nil {
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
					fmt.Println("Sending chunk", blockIndex, bufStart, bufEnd, len(buf), bufEnd-bufStart)
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
						// fmt.Println("Throttle: took", blockFetchDurationMs, "size", block.Size, "should have taken", blockFetchShouldHaveTakenMs, "delay", blockFetchShouldHaveTakenMs-blockFetchDurationMs)
						if blockFetchDurationMs < blockFetchShouldHaveTakenMs {
							time.Sleep(time.Duration(blockFetchShouldHaveTakenMs-blockFetchDurationMs) * time.Millisecond)
						}
					}
				}
			}
		} else {
			// Send all blocks
			w.Header().Add("Content-length", fmt.Sprintf("%d", info.Size))
			w.WriteHeader(200)

			fetchedBytes := int64(0)
			for blockNo, block := range info.Blocks {
				av, err := m.Availability(folder, info, block)
				if err != nil {
					return
				}
				if len(av) < 1 {
					return
				}

				buf, err := m.RequestGlobal(ctx, av[0].ID, folder, info.Name, blockNo, block.Offset, block.Size, block.Hash, block.WeakHash, false)
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
