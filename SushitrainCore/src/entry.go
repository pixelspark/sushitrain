// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"fmt"
	"os"
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
	fn := entry.info.FileName()

	// Escape special characters: https://docs.syncthing.net/users/ignoring.html
	specialChars := []string{"\\", "!", "*", "?", "[", "]", "{", "}"}
	for _, sp := range specialChars {
		fn = strings.ReplaceAll(fn, sp, "\\"+sp)
	}
	return "!/" + fn
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
			// Force a (minimal) scan. The current implementation also reloads the ignore file here (regardless of the path that is scanned)
			// Note, this could potentially take a while
			err := entry.Folder.client.app.Internals.ScanFolderSubdirs(entry.Folder.FolderID, []string{ignoreFileName})
			if err != nil {
				Logger.Warnln("ScanFolderSubdirs failed in SetExplicitlySelected for entry " + entry.info.FileName())
				return
			}

			// Delete the local file, if it is still deselected (the scan might take a while to complete)
			if !entry.IsSelected() {
				Logger.Infoln("Deleted local deselected file: " + entry.info.FileName())
				entry.Folder.DeleteLocalFile(entry.info.FileName())
			} else {
				Logger.Infoln("Not deleting local deselected file, it apparently was reselected: " + entry.info.FileName())
			}
		}()
	}
	return nil
}

type DownloadDelegate interface {
	OnError(error string)
	OnFinished(path string)
	OnProgress(fraction float64)
	IsCancelled() bool
}

/** Download this file to the specific location (should be outside the synced folder!) **/
func (entry *Entry) Download(toPath string, delegate DownloadDelegate) {
	go func() {
		context := context.WithoutCancel(context.Background())
		m := entry.Folder.client.app.Internals
		folderID := entry.Folder.FolderID
		info, ok, err := m.GlobalFileInfo(folderID, entry.info.FileName())
		if err != nil {
			delegate.OnError(err.Error())
			return
		}

		if !ok {
			delegate.OnError("file not found")
			return
		}

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

		for blockNo, block := range info.Blocks {
			if delegate.IsCancelled() {
				return
			}
			delegate.OnProgress(float64(block.Offset) / float64(info.Size))
			av, err := m.BlockAvailability(folderID, info, block)
			if err != nil {
				delegate.OnError(fmt.Sprintf("could not fetch availability for block %d: %s", blockNo, err.Error()))
				return
			}
			if len(av) < 1 {
				delegate.OnError(fmt.Sprintf("Part of the file is not available (block %d)", blockNo))
				return
			}

			// Fetch the block
			buf, err := m.DownloadBlock(context, av[0].ID, folderID, info.Name, int(blockNo), block, false)
			if err != nil {
				delegate.OnError(fmt.Sprintf("could not fetch block %d: %s", blockNo, err.Error()))
				return
			}
			_, err = outFile.Write(buf)
			if err != nil {
				delegate.OnError(fmt.Sprintf("could not write block %d: %s", blockNo, err.Error()))
				return
			}
		}
		delegate.OnFinished(toPath)
	}()
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
