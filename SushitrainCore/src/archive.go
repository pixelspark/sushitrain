// Copyright (C) 2025-2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"io"
	"slices"
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

var zipArchiveMIMETypes = []string{
	"application/zip",
	"application/java-archive",
	"application/epub+zip",
	"model/3mf",
	"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	"application/vnd.openxmlformats-officedocument.presentationml.presentation",
}

var isoArchiveMIMETypes = []string{
	"application/x-iso9660-image",
}

func (e *Entry) IsArchive() bool {
	mimeType := e.MIMEType()
	return slices.Contains(zipArchiveMIMETypes, mimeType) || slices.Contains(isoArchiveMIMETypes, mimeType)
}

func (e *Entry) Archive() Archive {
	puller := newMiniPuller(e.Folder.client.Measurements, e.Folder.client.app.Internals)

	mimeType := e.MIMEType()
	if slices.Contains(zipArchiveMIMETypes, mimeType) {
		return &zipArchive{
			entry:  e,
			puller: puller,
			mutex:  sync.Mutex{},
			files:  nil,
		}
	} else if slices.Contains(isoArchiveMIMETypes, mimeType) {
		return NewISOArchive(e, puller)
	} else {
		return nil
	}
}
