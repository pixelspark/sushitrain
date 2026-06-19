// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"bytes"
	"io"
	"testing"

	"github.com/syncthing/syncthing/lib/fs"
)

// fakeEntry is a minimal in-memory CustomFileEntry used to exercise the custom filesystem
// read paths (both the legacy preloaded path and the streaming/range-read path).
type fakeEntry struct {
	entryName string
	dir       bool
	children  []CustomFileEntry
	content   []byte
	streaming bool
	maxChunk  int // when > 0, ReadAt returns at most this many bytes per call

	dataCalls int // number of times Data() was called
	readCalls int // number of times ReadAt() was called
}

func (f *fakeEntry) Name() string { return f.entryName }
func (f *fakeEntry) IsDir() bool  { return f.dir }
func (f *fakeEntry) ChildCount() (int, error) { return len(f.children), nil }
func (f *fakeEntry) ChildAt(index int) (CustomFileEntry, error) { return f.children[index], nil }
func (f *fakeEntry) ModifiedTime() int64 { return 0 }
func (f *fakeEntry) Bytes() (int, error) { return len(f.content), nil }
func (f *fakeEntry) Streams() bool { return f.streaming }

func (f *fakeEntry) Data() ([]byte, error) {
	f.dataCalls++
	return f.content, nil
}

func (f *fakeEntry) ReadAt(offset int64, length int) ([]byte, error) {
	f.readCalls++
	if offset >= int64(len(f.content)) {
		return nil, nil // EOF
	}
	if f.maxChunk > 0 && length > f.maxChunk {
		length = f.maxChunk
	}
	end := offset + int64(length)
	if end > int64(len(f.content)) {
		end = int64(len(f.content))
	}
	return f.content[offset:end], nil
}

func newTestFS(file *fakeEntry) *customFilesystem {
	root := &fakeEntry{entryName: "", dir: true, children: []CustomFileEntry{file}}
	return &customFilesystem{fsType: fs.FilesystemType("test"), uri: "test", root: root}
}

func TestCustomFilesystemStreamingRead(t *testing.T) {
	content := []byte("0123456789abcdefghijABCDEFGHIJ") // 30 bytes
	file := &fakeEntry{entryName: "video.mov", content: content, streaming: true}
	cfs := newTestFS(file)

	// Stat reports the correct size without preloading the content.
	info, err := cfs.Stat("video.mov")
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Size() != int64(len(content)) {
		t.Fatalf("size = %d, want %d", info.Size(), len(content))
	}

	fh, err := cfs.Open("video.mov")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer fh.Close()

	// Streaming entries must not be preloaded through Data().
	if file.dataCalls != 0 {
		t.Fatalf("Data() called %d times for streaming entry, want 0", file.dataCalls)
	}

	// A sequential read returns the full content.
	got, err := io.ReadAll(fh)
	if err != nil {
		t.Fatalf("read all: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("read = %q, want %q", got, content)
	}

	// ReadAt at an offset returns the right slice.
	ra, ok := fh.(io.ReaderAt)
	if !ok {
		t.Fatal("custom file does not implement io.ReaderAt")
	}
	buf := make([]byte, 5)
	n, err := ra.ReadAt(buf, 10)
	if err != nil && err != io.EOF {
		t.Fatalf("readAt: %v", err)
	}
	if n != 5 || !bytes.Equal(buf, content[10:15]) {
		t.Fatalf("readAt = %q (n=%d), want %q", buf[:n], n, content[10:15])
	}

	// Reading at or past the end signals EOF.
	if n, err := ra.ReadAt(buf, int64(len(content))); err != io.EOF || n != 0 {
		t.Fatalf("readAt at EOF = (%d, %v), want (0, EOF)", n, err)
	}
}

// A streaming entry whose ReadAt returns only a few bytes per call (as a video export served in
// small pieces might) must still fill a larger read buffer correctly, with no gaps or duplication.
func TestCustomFilesystemStreamingChunkedRead(t *testing.T) {
	content := []byte("0123456789abcdefghijABCDEFGHIJ") // 30 bytes
	file := &fakeEntry{entryName: "video.mov", content: content, streaming: true, maxChunk: 4}
	cfs := newTestFS(file)

	fh, err := cfs.Open("video.mov")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer fh.Close()

	ra, ok := fh.(io.ReaderAt)
	if !ok {
		t.Fatal("custom file does not implement io.ReaderAt")
	}

	// A full sequential read must reassemble the 4-byte chunks to the exact content.
	got, err := io.ReadAll(fh)
	if err != nil {
		t.Fatalf("read all: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("read = %q, want %q", got, content)
	}

	// Reading a 16-byte window in a single ReadAt must also loop over 4-byte chunks to fill it.
	buf := make([]byte, 16)
	n, err := ra.ReadAt(buf, 7)
	if err != nil && err != io.EOF {
		t.Fatalf("readAt: %v", err)
	}
	if n != 16 || !bytes.Equal(buf, content[7:23]) {
		t.Fatalf("chunked readAt = %q (n=%d), want %q", buf[:n], n, content[7:23])
	}
}

func TestCustomFilesystemNonStreamingRead(t *testing.T) {
	content := []byte("hello world")
	file := &fakeEntry{entryName: "photo.jpg", content: content, streaming: false}
	cfs := newTestFS(file)

	fh, err := cfs.Open("photo.jpg")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer fh.Close()

	// Non-streaming entries are preloaded exactly once through Data().
	if file.dataCalls != 1 {
		t.Fatalf("Data() called %d times, want 1", file.dataCalls)
	}

	got, err := io.ReadAll(fh)
	if err != nil {
		t.Fatalf("read all: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("read = %q, want %q", got, content)
	}

	// The streaming path must never be used for non-streaming entries.
	if file.readCalls != 0 {
		t.Fatalf("ReadAt() called %d times for non-streaming entry, want 0", file.readCalls)
	}
}
