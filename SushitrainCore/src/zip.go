// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"archive/zip"
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"sync"

	"golang.org/x/exp/maps"
)

type ArchiveFile interface {
	Downloadable
	AsDownloadable() Downloadable
	Size() int64
}

type archiveFileInternal interface {
	reader() (io.Reader, error)
}

type Archive interface {
	Files(prefix string) (*ListOfStrings, error)
	IsDirectory(path string) bool
	Name() string
	File(path string) (ArchiveFile, error)
}

type entryArchiveFile struct {
	archive *entryArchive
	file    *zip.File
}

type entryArchive struct {
	entry  *Entry
	puller *miniPuller
	mutex  sync.Mutex
	files  []*zip.File
}

func (e *Entry) IsArchive() bool {
	return e.MIMEType() == "application/zip"
}

func (e *Entry) Archive() Archive {
	ctx := context.Background()
	return &entryArchive{
		entry:  e,
		puller: newMiniPuller(ctx, e.Folder.client.Measurements),
		mutex:  sync.Mutex{},
		files:  nil,
	}
}

func (ea *entryArchive) Name() string {
	return ea.entry.FileName()
}

func (ea *entryArchive) Files(prefix string) (*ListOfStrings, error) {
	if len(prefix) > 0 && prefix[(len(prefix)-1):] != "/" {
		return nil, errors.New("prefix must end in a slash")
	}

	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	matches := map[string]struct{}{}
	for _, file := range files {
		if strings.HasPrefix(file.Name, prefix) {
			if len(file.Name) < len(prefix)+1 {
				continue
			}

			// Just one level
			if strings.Contains(file.Name[len(prefix):len(file.Name)-1], "/") {
				// In some archives, 'a/b/c.ext' appears without separate entries for 'a/' and 'a/b/'
				// Therefore, do add the 'a/' to the list here in case we see 'a/b/c.ext'.
				// If 'a/' has its own entry, it will be double (but we fix that by using a set)
				suffix := file.Name[len(prefix):]
				suffixParts := strings.Split(suffix, "/")
				if len(suffixParts) > 0 && len(suffixParts[0]) > 0 {
					var subDirPath = suffixParts[0] + "/"
					if prefix != "" {
						// When filled the prefix ends in '/'
						subDirPath = prefix + subDirPath
					}
					matches[subDirPath] = struct{}{}
				}
				continue
			}
			matches[file.Name] = struct{}{}
		}
	}
	return List(maps.Keys(matches)), nil
}

func (ea *entryArchive) File(path string) (ArchiveFile, error) {
	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	for _, fi := range files {
		if fi.Name == path {
			return &entryArchiveFile{
				file:    fi,
				archive: ea,
			}, nil
		}
	}
	return nil, errors.New("file not found in archive")
}

func (ea *entryArchive) IsDirectory(path string) bool {
	// Paths that end in a slash are directories
	return len(path) > 0 && path[len(path)-1:] == "/"
}

func (ea *entryArchive) allFiles() ([]*zip.File, error) {
	ea.mutex.Lock()
	defer ea.mutex.Unlock()

	if ea.files == nil {
		reader, err := zip.NewReader(ea, ea.entry.Size())
		if err != nil {
			return nil, err
		}
		ea.files = reader.File
	}

	return ea.files, nil
}

// ReadAt implements io.ReaderAt.
func (ea *entryArchive) ReadAt(p []byte, off int64) (n int, err error) {
	if buffer, err := ea.entry.FetchLocal(off, int64(len(p))); err == nil {
		// We have this file completely locally
		copy(p, buffer)
		return len(buffer), nil
	}

	xn, err := ea.puller.downloadRange(ea.entry.Folder.client.app.Internals, ea.entry.Folder.FolderID, ea.entry.info, p, off)
	return int(xn), err
}

func (ea *entryArchiveFile) FileName() string {
	ps := strings.Split(ea.file.Name, "/")
	return ps[len(ps)-1]
}

func (ea *entryArchiveFile) Download(toPath string, delegate DownloadDelegate) {
	go func() {
		// Create file to download to
		outFile, err := os.Create(toPath)
		if err != nil {
			delegate.OnError("could not open file for downloading to: " + err.Error())
			return
		}
		// close fi on exit and check for its returned error
		defer func() {
			if err := outFile.Close(); err != nil {
				panic(err)
			}
		}()

		delegate.OnProgress(0.0)

		reader, err := ea.reader()
		if err != nil {
			delegate.OnError("could not open file for downloading to: " + err.Error())
			return
		}

		cReader := cancelableReader{
			reader:     reader,
			delegate:   delegate,
			totalBytes: ea.file.UncompressedSize64,
			readBytes:  0,
		}
		_, err = io.Copy(outFile, &cReader)
		if err != nil {
			delegate.OnError("could not open file for downloading to: " + err.Error())
			return
		}
		delegate.OnFinished(toPath)
	}()
}

func (ea *entryArchiveFile) Size() int64 {
	return ea.file.FileInfo().Size()
}

func (ea *entryArchiveFile) reader() (io.Reader, error) {
	return ea.file.Open()
}

func (ea *entryArchiveFile) AsDownloadable() Downloadable {
	return ea
}

type cancelableReader struct {
	reader     io.Reader
	delegate   DownloadDelegate
	totalBytes uint64
	readBytes  uint64
}

func (c *cancelableReader) Read(p []byte) (n int, err error) {
	if c.delegate.IsCancelled() {
		return 0, errors.New("cancelled")
	}
	n, err = c.reader.Read(p)
	if err == nil {
		c.readBytes += uint64(n)
		c.delegate.OnProgress(float64(c.readBytes) / float64(c.totalBytes))
	}
	return n, err
}
