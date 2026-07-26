// Copyright (C) 2025-2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"io"
	"sync"
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

func (e *Entry) IsArchive() bool {
	return e.MIMEType() == "application/zip" || e.MIMEType() == "application/x-iso9660-image"
}

func (e *Entry) Archive() Archive {
	puller := newMiniPuller(e.Folder.client.Measurements, e.Folder.client.app.Internals)

	switch e.MIMEType() {
	case "application/zip":
		return &zipArchive{
			entry:  e,
			puller: puller,
			mutex:  sync.Mutex{},
			files:  nil,
		}
	case "application/x-iso9660-image":
		return NewISOArchive(e, puller)
	default:
		return nil
	}
}
