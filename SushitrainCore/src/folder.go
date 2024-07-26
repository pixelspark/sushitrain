// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/ignore"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	ignoreFileName string = ".stignore"
)

type Folder struct {
	client   *Client
	FolderID string
}

func (self *Folder) folderConfiguration() *config.FolderConfiguration {
	folders := self.client.config.Folders()
	folderInfo, ok := folders[self.FolderID]
	if !ok {
		return nil
	}
	return &folderInfo
}

func (self *Folder) Remove() error {
	ffs := self.folderConfiguration().Filesystem(nil)
	err := self.client.changeConfiguration(func(cfg *config.Configuration) {
		folders := make([]config.FolderConfiguration, 0)
		for _, fc := range cfg.Folders {
			if fc.ID != self.FolderID {
				folders = append(folders, fc)
			}
		}
		cfg.Folders = folders
	})

	if err != nil {
		return err
	}

	// Remove local copy
	return ffs.RemoveAll("")
}

func (self *Folder) Exists() bool {
	return self.folderConfiguration() != nil
}

func (self *Folder) IsPaused() bool {
	fc := self.folderConfiguration()
	if fc == nil {
		return false
	}

	return self.folderConfiguration().Paused
}

func (self *Folder) SetPaused(paused bool) error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		config := self.folderConfiguration()
		config.Paused = paused
		cfg.SetFolder(*config)
	})
}

func (self *Folder) State() (string, error) {
	if self.client.app == nil {
		return "", nil
	}
	if self.client.app.M == nil {
		return "", nil
	}

	state, _, err := self.client.app.M.State(self.FolderID)
	return state, err
}

func (self *Folder) GetFileInformation(path string) (*Entry, error) {
	if self.client.app == nil {
		return nil, nil
	}
	if self.client.app.M == nil {
		return nil, nil
	}

	if len(path) == 0 {
		return nil, errors.New("empty path")
	}

	// Strip initial slash
	if path[0] == '/' {
		path = path[1:]
	}

	info, ok, err := self.client.app.M.CurrentGlobalFile(self.FolderID, path)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	return &Entry{
		info:   info,
		Folder: self,
	}, nil
}

func (self *Folder) List(prefix string, directories bool) (*ListOfStrings, error) {
	if self.client.app == nil {
		return nil, nil
	}
	if self.client.app.M == nil {
		return nil, nil
	}
	entries, err := self.client.app.M.GlobalDirectoryTree(self.FolderID, prefix, 1, directories)
	if err != nil {
		return nil, err
	}
	return List(Map(entries, func(entry *model.TreeEntry) string {
		return entry.Name
	})), nil
}

func (self *Folder) ShareWithDevice(deviceID string, toggle bool, encryptionPassword string) error {
	devID, err := protocol.DeviceIDFromString(deviceID)
	if err != nil {
		return err
	}

	err = self.client.changeConfiguration(func(cfg *config.Configuration) {
		fc := self.folderConfiguration()

		devices := make([]config.FolderDeviceConfiguration, 0)
		for _, fc := range fc.Devices {
			if fc.DeviceID != devID {
				devices = append(devices, fc)
			}
		}
		fc.Devices = devices

		if toggle {
			fc.Devices = append(fc.Devices, config.FolderDeviceConfiguration{
				DeviceID:           devID,
				EncryptionPassword: encryptionPassword,
			})
		}

		cfg.SetFolder(*fc)
	})
	return err
}

func (self *Folder) SharedWithDeviceIDs() *ListOfStrings {
	fc := self.folderConfiguration()
	if fc == nil {
		return nil
	}

	return List(Map(fc.DeviceIDs(), func(di protocol.DeviceID) string {
		return di.String()
	}))
}

func (self *Folder) SharedEncryptedWithDeviceIDs() *ListOfStrings {
	fc := self.folderConfiguration()
	if fc == nil {
		return nil
	}
	var dis = make([]string, 0)

	for _, dfc := range fc.Devices {
		if len(dfc.EncryptionPassword) > 0 {
			dis = append(dis, dfc.DeviceID.String())
		}
	}

	return List(dis)
}

func (self *Folder) EncryptionPasswordFor(peer string) string {
	did, err := protocol.DeviceIDFromString(peer)
	if err != nil {
		return ""
	}

	fc := self.folderConfiguration()
	if fc == nil {
		return ""
	}

	for _, dfc := range fc.Devices {
		if dfc.DeviceID == did {
			return dfc.EncryptionPassword
		}
	}
	return ""
}

func (self *Folder) ConnectedPeerCount() int {
	fc := self.folderConfiguration()
	if fc == nil {
		return 0
	}

	devIDs := self.folderConfiguration().DeviceIDs()
	connected := 0
	for _, devID := range devIDs {
		if devID == self.client.deviceID() {
			continue
		}
		if self.client.app.M.ConnectedTo(devID) {
			connected++
		}
	}
	return connected
}

func (self *Folder) Label() string {
	fc := self.folderConfiguration()
	if fc == nil {
		return ""
	}
	return fc.Label
}

func (self *Folder) SetLabel(label string) error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		config := self.folderConfiguration()
		config.Label = label
		cfg.SetFolder(*config)
	})
}

var (
	errNoClient = errors.New("client not started up yet")
)

func (self *Folder) SetSelective(selective bool) error {
	if self.client.app == nil || self.client.app.M == nil {
		return errNoClient
	}

	var err error
	if selective {
		err = self.client.app.M.SetIgnores(self.FolderID, []string{"*"})
	} else {
		err = self.client.app.M.SetIgnores(self.FolderID, []string{})
	}

	if err != nil {
		return err
	}
	return nil
}

func (self *Folder) ClearSelection() error {
	err := self.client.app.M.SetIgnores(self.FolderID, []string{"*"})
	if err != nil {
		return err
	}

	return self.CleanSelection()
}

func (self *Folder) SelectedPaths() (*ListOfStrings, error) {
	fc := self.folderConfiguration()
	if fc == nil {
		return nil, errors.New("folder does not exist")
	}

	if self.client.app == nil || self.client.app.M == nil {
		return nil, errNoClient
	}

	lines, _, err := self.client.app.M.CurrentIgnores(self.FolderID)
	if err != nil {
		return nil, err
	}

	paths := ListOfStrings{data: []string{}}

	for _, pattern := range lines {
		if len(pattern) > 0 && pattern[0] == '!' {
			paths.data = append(paths.data, strings.TrimPrefix(pattern, "!"))
		}
	}

	return &paths, nil
}

func (self *Folder) HasSelectedPaths() bool {
	if self.client.app == nil || self.client.app.M == nil {
		return false
	}

	fc := self.folderConfiguration()
	if fc == nil {
		return false
	}

	if !self.IsSelective() {
		return false
	}

	lines, _, err := self.client.app.M.CurrentIgnores(self.FolderID)
	if err != nil {
		return false
	}

	// All except the last pattern must start with '!', the last pattern must be  '*'
	for _, pattern := range lines {
		if len(pattern) > 0 && pattern[0] == '!' {
			return true
		}
	}

	return false
}

const (
	FolderTypeSendReceive = "sendrecieve"
	FolderTypeReceiveOnly = "receiveonly"
)

func (self *Folder) FolderType() string {
	fc := self.folderConfiguration()
	if fc == nil {
		return ""
	}

	switch fc.Type {
	case config.FolderTypeReceiveOnly:
		return FolderTypeReceiveOnly
	default:
		fallthrough
	case config.FolderTypeSendReceive:
		return FolderTypeSendReceive
	}
}

func (self *Folder) SetFolderType(folderType string) error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		fc := self.folderConfiguration()
		switch folderType {
		case FolderTypeReceiveOnly:
			fc.Type = config.FolderTypeReceiveOnly
		case FolderTypeSendReceive:
			fc.Type = config.FolderTypeSendReceive
		default:
			// Don't change
			return
		}
		cfg.SetFolder(*fc)
	})
}

func (self *Folder) IsSelective() bool {
	if self.client.app == nil || self.client.app.M == nil {
		return false
	}

	fc := self.folderConfiguration()
	if fc == nil {
		return false
	}

	lines, _, err := self.client.app.M.CurrentIgnores(self.FolderID)
	if err != nil {
		return false
	}

	if len(lines) == 0 {
		return false
	}

	// All except the last pattern must start with '!', the last pattern must be  '*'
	for idx, pattern := range lines {
		if idx == len(lines)-1 {
			if pattern != "*" {
				return false
			}
		} else {
			if len(pattern) == 0 || pattern[0] != '!' {
				return false
			}
		}
	}

	return true
}

func (self *Folder) LocalNativePath() (string, error) {
	fc := self.folderConfiguration()
	if fc == nil {
		return "", errors.New("folder does not exist")
	}

	// This is a bit of a hack, according to similar code in model.warnAboutOverwritingProtectedFiles :-)
	ffs := self.folderConfiguration().Filesystem(nil)
	if ffs.Type() != fs.FilesystemTypeBasic {
		return "", errors.New("unsupported FS type")
	}
	return ffs.URI(), nil
}

func (self *Folder) loadIgnores() (*ignore.Matcher, error) {
	cfg := self.folderConfiguration()
	ignores := ignore.New(cfg.Filesystem(nil), ignore.WithCache(false))
	if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
		return nil, err
	}
	return ignores, nil
}

func (self *Folder) ExtraneousFiles() (*ListOfStrings, error) {
	return self.extraneousFiles(false)
}

func (self *Folder) HasExtraneousFiles() (bool, error) {
	files, err := self.extraneousFiles(true)
	if err != nil {
		return false, err
	}
	return files.Count() > 0, nil
}

// List of files that are not selected but exist locally. When stopAtOne = true, return after finding just one file
func (self *Folder) extraneousFiles(stopAtOne bool) (*ListOfStrings, error) {
	cfg := self.folderConfiguration()

	if cfg == nil {
		return nil, errors.New("folder does not exist")
	}

	ignores := ignore.New(cfg.Filesystem(nil), ignore.WithCache(false))
	if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
		return nil, err
	}

	extraFiles := make([]string, 0)

	ffs := self.folderConfiguration().Filesystem(nil)
	foundOneError := errors.New("found one")
	err := ffs.Walk("", func(path string, info fs.FileInfo, err error) error {
		if err != nil {
			fmt.Println("error walking: ", path, err)
			return nil
		}

		// Ignore directories, only files count
		if info.IsDir() {
			return nil
		}

		if strings.HasPrefix(filepath.Base(path), fs.UnixTempPrefix) {
			return nil
		}

		if strings.HasPrefix(path, cfg.MarkerName) {
			return nil
		}
		if path == ignoreFileName {
			return nil
		}

		// Check ignore status
		result := ignores.Match(path)
		if result.IsIgnored() {
			extraFiles = append(extraFiles, path)
			if stopAtOne {
				return foundOneError
			}
		}
		return nil
	})

	if err != nil && err != foundOneError {
		return nil, err
	}

	list := ListOfStrings{data: extraFiles}
	return &list, nil
}

// Remove ignored files from the local working copy
func (self *Folder) CleanSelection() error {
	// Make sure the initial scan has finished (ScanFolders is blocking)
	self.client.app.M.ScanFolders()

	cfg := self.folderConfiguration()
	ignores := ignore.New(cfg.Filesystem(nil), ignore.WithCache(false))
	if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
		return err
	}

	ffs := self.folderConfiguration().Filesystem(nil)
	return ffs.Walk("", func(path string, info fs.FileInfo, err error) error {
		if strings.HasPrefix(path, cfg.MarkerName) {
			return nil
		}
		if path == ignoreFileName {
			return nil
		}

		// Check ignore status
		result := ignores.Match(path)
		fmt.Println("- ", path, result)
		if result.IsIgnored() {
			return ffs.RemoveAll(path)
		}
		return nil
	})
}

func (self *Folder) DeleteLocalFile(path string) error {
	ffs := self.folderConfiguration().Filesystem(nil)
	err := ffs.Remove(path)
	if err != nil {
		return err
	}

	// Try to delete parent directories that are empty
	pathParts := fs.PathComponents(path)
	if len(pathParts) > 1 {
		for pathIndex := len(pathParts) - 2; pathIndex >= 0; pathIndex-- {
			dirPath := strings.Join(pathParts[0:pathIndex+1], string(fs.PathSeparator))
			ffs.Remove(dirPath) // Will only remove directories when empty
		}
	}

	err = self.client.app.M.ScanFolderSubdirs(self.FolderID, []string{path})
	if err != nil {
		return err
	}
	err = self.SetLocalFileExplicitlySelected(path, false)
	if err != nil {
		return err
	}

	return nil
}

func (self *Folder) SetLocalFileExplicitlySelected(path string, toggle bool) error {
	mockEntry := Entry{
		Folder: self,
		info: protocol.FileInfo{
			Name: path,
		},
	}
	return mockEntry.SetExplicitlySelected(toggle)
}

func (self *Folder) Statistics() (*FolderStats, error) {
	snap, err := self.client.app.M.DBSnapshot(self.FolderID)
	if err != nil {
		return nil, err
	}
	defer snap.Release()

	return &FolderStats{
		Global: newFolderCounts(snap.GlobalSize()),
		Local:  newFolderCounts(snap.LocalSize()),
	}, nil
}
