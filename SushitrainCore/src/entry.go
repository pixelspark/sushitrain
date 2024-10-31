// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/syncthing/syncthing/lib/ignore/ignoreresult"
	"github.com/syncthing/syncthing/lib/model"
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

func (entry *Entry) ParentPath() string {
	p := path.Dir(entry.info.FileName())
	if p == "/" || p == "." {
		return ""
	}
	return p + "/"
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

func (entry *Entry) SymlinkTarget() string {
	return entry.info.SymlinkTarget
}

func (entry *Entry) SymlinkTargetEntry() (*Entry, error) {
	if !entry.info.IsSymlink() {
		return nil, errors.New("entry is not a symlink")
	}
	target := entry.info.SymlinkTarget
	if !filepath.IsAbs(entry.info.SymlinkTarget) {
		target = filepath.Join(entry.info.Name, "..", entry.info.SymlinkTarget)
	}
	return entry.Folder.GetFileInformation(target)
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

func (entry *Entry) BlocksHash() string {
	return base64.StdEncoding.EncodeToString(entry.info.BlocksHash)
}

func (entry *Entry) IsLocallyPresent() bool {
	fc := entry.Folder.folderConfiguration()
	if fc == nil {
		return false
	}

	ffs := fc.Filesystem(nil)
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
	path := entry.info.FileName()
	return IgnoreLineForSelectingPath(path)
}

// Escape special characters: https://docs.syncthing.net/users/ignoring.html
var specialChars = []string{"\\", "!", "*", "?", "[", "]", "{", "}"}

// Generate a line for use in the .stignore file that selects the file at `path`. The path should *not* start with a slash.
func IgnoreLineForSelectingPath(path string) string {
	for _, sp := range specialChars {
		path = strings.ReplaceAll(path, sp, "\\"+sp)
	}
	return "!/" + path
}

func PathForIgnoreLine(line string) string {
	line = strings.TrimPrefix(line, "!/")
	for _, sp := range specialChars {
		line = strings.ReplaceAll(line, "\\"+sp, sp)
	}
	return line
}

func (entry *Entry) SetExplicitlySelected(selected bool) error {
	paths := map[string]bool{}
	paths[entry.info.Name] = selected
	return entry.Folder.setExplicitlySelected(paths)
}

func walkEntries(prefix string, entries []*model.TreeEntry, block func(prefix string, entry *model.TreeEntry) (bool, error)) error {
	for _, entry := range entries {
		goOn, err := block(prefix, entry)
		if err != nil {
			return err
		}
		if !goOn {
			return nil
		}

		subPrefix := prefix + "/" + entry.Name
		err = walkEntries(subPrefix, entry.Children, block)
		if err != nil {
			return err
		}
	}

	return nil
}

func (entry *Entry) PeersWithFullCopy() (*ListOfStrings, error) {
	if entry.IsDeleted() {
		return nil, errors.New("file was deleted")
	}

	if entry.IsDirectory() {
		// Enumerate all files and check availability
		fullPeers := make(map[protocol.DeviceID]bool)
		allPeers, err := entry.Folder.sharedWith()
		if err != nil {
			return nil, err
		}

		for _, p := range allPeers {
			fullPeers[p] = true
		}

		prefix := entry.Path() + "/"
		Logger.Infoln("Determining peers that have a full copy of folder", prefix)
		leaves, err := entry.Folder.listEntries(prefix, false, true)
		if err != nil {
			return nil, err
		}

		err = walkEntries(entry.Path(), leaves, func(leafPrefix string, leaf *model.TreeEntry) (bool, error) {
			if len(fullPeers) == 0 {
				return false, nil
			}

			leafEntry, err := entry.Folder.GetFileInformation(leafPrefix + "/" + leaf.Name)
			if err != nil {
				return false, err
			}

			if leafEntry == nil {
				return false, errors.New("leaf entry not found: " + leaf.Name)
			}

			if leafEntry.IsDeleted() || leafEntry.IsSymlink() || leafEntry.IsDirectory() {
				return true, nil
			}

			// Check if this file is available
			leafBlocksPerDevice, leafBlockCount, err := leafEntry.availabilityPerDevice()
			if err != nil {
				return false, err
			}

			for deviceID, _ := range fullPeers {
				// Check if the per has this leaf in full
				blocksOnPeer, ok := leafBlocksPerDevice[deviceID]
				if !ok || blocksOnPeer != leafBlockCount {
					// This peer does not have this file in full, remove it from the list
					delete(fullPeers, deviceID)
				}
			}
			return true, nil
		})

		if err != nil {
			return nil, err
		}

		// Return the list of peers that have all the files
		peerIDStrings := make([]string, 0)
		for deviceID, _ := range fullPeers {
			peerIDStrings = append(peerIDStrings, deviceID.String())
		}

		return List(peerIDStrings), nil
	}

	// Single file availability
	blocksPerDevice, blockCount, err := entry.availabilityPerDevice()
	if err != nil {
		return nil, err
	}

	devices := make([]string, 0)
	for deviceID, blocksOnDevice := range blocksPerDevice {
		if blocksOnDevice == blockCount {
			devices = append(devices, deviceID.String())
		}
	}

	return List(devices), nil
}

func (entry *Entry) availabilityPerDevice() (map[protocol.DeviceID]int, int, error) {
	m := entry.Folder.client.app.Internals
	folderID := entry.Folder.FolderID

	info, ok, err := m.GlobalFileInfo(folderID, entry.info.FileName())
	if err != nil {
		return nil, 0, err
	}

	if !ok {
		return nil, 0, errors.New("file not found globally")
	}

	var deviceStatus = make(map[protocol.DeviceID]int)

	for _, block := range info.Blocks {
		avs, err := m.BlockAvailability(folderID, info, block)
		if err != nil {
			return nil, 0, err
		}

		for _, av := range avs {
			blockCount, ok := deviceStatus[av.ID]
			if !ok {
				deviceStatus[av.ID] = 1
			} else {
				deviceStatus[av.ID] = blockCount + 1
			}
		}
	}

	return deviceStatus, len(info.Blocks), nil
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
	return entry.Folder.DeselectAndDeleteLocalFile(entry.Path())
}
