// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"fmt"
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

func (self *Entry) Fetch(delegate FetchDelegate) {
	go func() {
		client := self.Folder.client
		m := client.app.Model
		delegate.Progress(0.0)

		fetchedBytes := int64(0)
		for blockNo, block := range self.info.Blocks {
			av, err := m.Availability(self.Folder.FolderID, self.info, block)
			if err != nil {
				delegate.Error(FetchDelegateErrorBlockUnavailable, err.Error())
				return
			}
			if len(av) < 1 {
				delegate.Error(FetchDelegateErrorBlockUnavailable, "")
				return
			}

			buf, err := m.RequestGlobal(client.ctx, av[0].ID, self.Folder.FolderID, self.info.Name, blockNo, block.Offset, block.Size, block.Hash, block.WeakHash, false)
			if err != nil {
				delegate.Error(FetchDelegateErrorPullFailed, err.Error())
				return
			}
			fetchedBytes += int64(block.Size)
			delegate.Fetched(blockNo, block.Offset, int64(block.Size), buf, blockNo == len(self.info.Blocks)-1)
			delegate.Progress(float64(fetchedBytes) / float64(self.info.FileSize()))
		}

		delegate.Progress(1.0)
	}()
}

func (self *Entry) Path() string {
	return self.info.FileName()
}

func (self *Entry) FileName() string {
	ps := strings.Split(self.info.FileName(), "/")
	return ps[len(ps)-1]
}

func (self *Entry) Name() string {
	return self.info.FileName()
}

func (self *Entry) IsDirectory() bool {
	return self.info.IsDirectory()
}

func (self *Entry) IsSymlink() bool {
	return self.info.IsSymlink()
}

func (self *Entry) Size() int64 {
	return self.info.FileSize()
}

func (self *Entry) IsDeleted() bool {
	return self.info.IsDeleted()
}

func (self *Entry) ModifiedBy() string {
	return self.info.FileModifiedBy().String()
}

func (self *Entry) LocalNativePath() (string, error) {
	nativeFilename := osutil.NativeFilename(self.info.FileName())
	localFolderPath, err := self.Folder.LocalNativePath()
	if err != nil {
		return "", err
	}
	return path.Join(localFolderPath, nativeFilename), nil
}

func (self *Entry) IsLocallyPresent() bool {
	ffs := self.Folder.folderConfiguration().Filesystem(nil)
	nativeFilename := osutil.NativeFilename(self.info.FileName())
	_, err := ffs.Stat(nativeFilename)
	return err == nil
}

func (self *Entry) IsSelected() bool {
	// FIXME: cache matcher
	matcher, err := self.Folder.loadIgnores()
	if err != nil {
		fmt.Println("error loading ignore matcher", err)
		return false
	}

	res := matcher.Match(self.info.Name)
	if res == ignoreresult.Ignored || res == ignoreresult.IgnoreAndSkip {
		return false
	}
	return true
}

func (self *Entry) IsExplicitlySelected() bool {
	lines, _, err := self.Folder.client.app.Model.CurrentIgnores(self.Folder.FolderID)
	if err != nil {
		return false
	}

	ignoreLine := self.ignoreLine()
	for _, line := range lines {
		if len(line) > 0 && line[0] == '!' {
			if line == ignoreLine {
				return true
			}
		}
	}
	return false
}

func (self *Entry) ignoreLine() string {
	return "!/" + self.info.FileName()
}

func (self *Entry) SetExplicitlySelected(selected bool) error {
	currentlySelected := self.IsExplicitlySelected()

	if currentlySelected == selected {
		return nil
	}

	// Edit lines
	lines, _, err := self.Folder.client.app.Model.CurrentIgnores(self.Folder.FolderID)
	if err != nil {
		return err
	}

	line := self.ignoreLine()
	if !selected {
		lines = Filter(lines, func(l string) bool {
			return l != line
		})
	} else {
		lines = append([]string{line}, lines...)
	}

	// Save new ignores
	err = self.Folder.client.app.Model.SetIgnores(self.Folder.FolderID, lines)
	if err != nil {
		return err
	}

	// Delete local file if !selected (and not still implicitly selected by parent folder)
	if !selected && !self.IsSelected() {
		go func() {
			self.Folder.client.app.Model.ScanFolders()
			self.Folder.DeleteLocalFile(self.info.FileName())
		}()
	}
	return nil
}

func (self *Entry) OnDemandURL() string {
	server := self.Folder.client.Server
	if server == nil {
		return ""
	}

	return server.URLFor(self.Folder.FolderID, self.info.FileName())
}

func (self *Entry) MIMEType() string {
	ext := filepath.Ext(self.info.FileName())
	return MIMETypeForExtension(ext)
}

func (self *Entry) Remove() error {
	return self.Folder.DeleteLocalFile(self.Path())
}
