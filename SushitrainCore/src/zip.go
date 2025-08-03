// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"archive/zip"
	"context"
	"strings"
	"sync"
)

type Archive interface {
	Files(prefix string) (*ListOfStrings, error)
	IsDirectory(path string) bool
	Name() string
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
	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	matches := make([]string, 0)
	for _, file := range files {
		if strings.HasPrefix(file.Name, prefix) {
			// Just one level
			if len(file.Name) < len(prefix)+1 {
				continue
			}

			if strings.Contains(file.Name[len(prefix):len(file.Name)-1], "/") {
				continue
			}
			matches = append(matches, file.Name)
		}
	}
	return List(matches), nil
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
		Logger.Debugln("We have this file completely locally; writing ", len(buffer), " bytes")
		copy(p, buffer)
		return len(buffer), nil
	}

	xn, err := ea.puller.downloadRange(ea.entry.Folder.client.app.Internals, ea.entry.Folder.FolderID, ea.entry.info, p, off)
	return int(xn), err
}
