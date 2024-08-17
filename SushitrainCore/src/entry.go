// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"path"
	"path/filepath"
	"strings"

	"github.com/syncthing/syncthing/lib/ignore/ignoreresult"
	"github.com/syncthing/syncthing/lib/osutil"
	"github.com/syncthing/syncthing/lib/protocol"
)

type Entry struct {
	Folder *Folder
	info   protocol.FileInfo
}

type FetchDelegate interface {
	Fetched(blockNo int, blockOffset int64, blockSize int64, data []byte, last bool)
	Progress(p float64)
	Error(e int, message string)
}

const (
	FetchDelegateErrorBlockUnavailable int = 1
	FetchDelegateErrorPullFailed       int = 2
)

type FetchCallback func(success bool)

func (entry *Entry) Fetch(delegate FetchDelegate) {
	go func() {
		client := entry.Folder.client
		m := client.app.Internals
		delegate.Progress(0.0)

		fetchedBytes := int64(0)
		for blockNo, block := range entry.info.Blocks {
			av, err := m.BlockAvailability(entry.Folder.FolderID, entry.info, block)
			if err != nil {
				delegate.Error(FetchDelegateErrorBlockUnavailable, err.Error())
				return
			}
			if len(av) < 1 {
				delegate.Error(FetchDelegateErrorBlockUnavailable, "")
				return
			}

			buf, err := m.DownloadBlock(client.ctx, av[0].ID, entry.Folder.FolderID, entry.info.Name, blockNo, block, false)
			if err != nil {
				delegate.Error(FetchDelegateErrorPullFailed, err.Error())
				return
			}
			fetchedBytes += int64(block.Size)
			delegate.Fetched(blockNo, block.Offset, int64(block.Size), buf, blockNo == len(entry.info.Blocks)-1)
			delegate.Progress(float64(fetchedBytes) / float64(entry.info.FileSize()))
		}

		delegate.Progress(1.0)
	}()
}

func (entry *Entry) Path() string {
	return entry.info.FileName()
}

func (entry *Entry) FileName() string {
	ps := strings.Split(entry.info.FileName(), "/")
	return ps[len(ps)-1]
}

func (entry *Entry) Name() string {
	return entry.info.FileName()
}

func (entry *Entry) IsDirectory() bool {
	return entry.info.IsDirectory()
}

func (entry *Entry) IsSymlink() bool {
	return entry.info.IsSymlink()
}

func (entry *Entry) Size() int64 {
	return entry.info.FileSize()
}

func (entry *Entry) IsDeleted() bool {
	return entry.info.IsDeleted()
}

func (entry *Entry) ModifiedByShortDeviceID() string {
	return entry.info.FileModifiedBy().String()
}

func (entry *Entry) ModifiedAt() *Date {
	mt := entry.info.ModTime()
	if mt.IsZero() {
		return nil
	}
	return &Date{time: mt}
}

func (entry *Entry) LocalNativePath() (string, error) {
	nativeFilename := osutil.NativeFilename(entry.info.FileName())
	localFolderPath, err := entry.Folder.LocalNativePath()
	if err != nil {
		return "", err
	}
	return path.Join(localFolderPath, nativeFilename), nil
}

func (entry *Entry) IsLocallyPresent() bool {
	ffs := entry.Folder.folderConfiguration().Filesystem(nil)
	nativeFilename := osutil.NativeFilename(entry.info.FileName())
	_, err := ffs.Stat(nativeFilename)
	return err == nil
}

func (entry *Entry) IsSelected() bool {
	// FIXME: cache matcher
	matcher, err := entry.Folder.loadIgnores()
	if err != nil {
		Logger.Warnln("error loading ignore matcher", err)
		return false
	}

	res := matcher.Match(entry.info.Name)
	if res == ignoreresult.Ignored || res == ignoreresult.IgnoreAndSkip {
		return false
	}
	return true
}

func (entry *Entry) IsExplicitlySelected() bool {
	lines, _, err := entry.Folder.client.app.Internals.Ignores(entry.Folder.FolderID)
	if err != nil {
		return false
	}

	ignoreLine := entry.ignoreLine()
	for _, line := range lines {
		if len(line) > 0 && line[0] == '!' {
			if line == ignoreLine {
				return true
			}
		}
	}
	return false
}

func (entry *Entry) ignoreLine() string {
	return "!/" + entry.info.FileName()
}

func (entry *Entry) SetExplicitlySelected(selected bool) error {
	currentlySelected := entry.IsExplicitlySelected()

	if currentlySelected == selected {
		return nil
	}

	// Edit lines
	lines, _, err := entry.Folder.client.app.Internals.Ignores(entry.Folder.FolderID)
	if err != nil {
		return err
	}

	line := entry.ignoreLine()
	if !selected {
		lines = Filter(lines, func(l string) bool {
			return l != line
		})
	} else {
		lines = append([]string{line}, lines...)
	}

	// Save new ignores
	err = entry.Folder.client.app.Internals.SetIgnores(entry.Folder.FolderID, lines)
	if err != nil {
		return err
	}

	// Delete local file if !selected (and not still implicitly selected by parent folder)
	if !selected && !entry.IsSelected() {
		go func() {
			entry.Folder.client.app.Internals.ScanFolders()
			entry.Folder.DeleteLocalFile(entry.info.FileName())
		}()
	}
	return nil
}

func (entry *Entry) OnDemandURL() string {
	server := entry.Folder.client.Server
	if server == nil {
		return ""
	}

	return server.URLFor(entry.Folder.FolderID, entry.info.FileName())
}

func (entry *Entry) MIMEType() string {
	ext := filepath.Ext(entry.info.FileName())
	return MIMETypeForExtension(ext)
}

func (entry *Entry) Remove() error {
	return entry.Folder.DeleteLocalFile(entry.Path())
}
