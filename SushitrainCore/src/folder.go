// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"errors"
	"path/filepath"
	"slices"
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

func (fld *Folder) folderConfiguration() *config.FolderConfiguration {
	folders := fld.client.config.Folders()
	folderInfo, ok := folders[fld.FolderID]
	if !ok {
		return nil
	}
	return &folderInfo
}

func (fld *Folder) Remove() error {
	ffs := fld.folderConfiguration().Filesystem(nil)
	err := fld.client.changeConfiguration(func(cfg *config.Configuration) {
		folders := make([]config.FolderConfiguration, 0)
		for _, fc := range cfg.Folders {
			if fc.ID != fld.FolderID {
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

func (fld *Folder) Exists() bool {
	return fld.folderConfiguration() != nil
}

func (fld *Folder) IsPaused() bool {
	fc := fld.folderConfiguration()
	if fc == nil {
		return false
	}

	return fld.folderConfiguration().Paused
}

func (fld *Folder) SetPaused(paused bool) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		config := fld.folderConfiguration()
		config.Paused = paused
		cfg.SetFolder(*config)
	})
}

func (fld *Folder) State() (string, error) {
	if fld.client.app == nil {
		return "", nil
	}
	if fld.client.app.Internals == nil {
		return "", nil
	}

	state, _, err := fld.client.app.Internals.FolderState(fld.FolderID)
	return state, err
}

func (fld *Folder) GetFileInformation(path string) (*Entry, error) {
	if fld.client.app == nil {
		return nil, nil
	}
	if fld.client.app.Internals == nil {
		return nil, nil
	}

	if len(path) == 0 {
		return nil, errors.New("empty path")
	}

	// Strip initial slash
	if path[0] == '/' {
		path = path[1:]
	}

	info, ok, err := fld.client.app.Internals.GlobalFileInfo(fld.FolderID, path)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	return &Entry{
		info:   info,
		Folder: fld,
	}, nil
}

func (fld *Folder) List(prefix string, directories bool) (*ListOfStrings, error) {
	if fld.client.app == nil {
		return nil, nil
	}
	if fld.client.app.Internals == nil {
		return nil, nil
	}
	entries, err := fld.client.app.Internals.GlobalTree(fld.FolderID, prefix, 1, directories)
	if err != nil {
		return nil, err
	}
	return List(Map(entries, func(entry *model.TreeEntry) string {
		return entry.Name
	})), nil
}

func (fld *Folder) ShareWithDevice(deviceID string, toggle bool, encryptionPassword string) error {
	devID, err := protocol.DeviceIDFromString(deviceID)
	if err != nil {
		return err
	}

	err = fld.client.changeConfiguration(func(cfg *config.Configuration) {
		fc := fld.folderConfiguration()

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

func (fld *Folder) SharedWithDeviceIDs() *ListOfStrings {
	fc := fld.folderConfiguration()
	if fc == nil {
		return nil
	}

	return List(Map(fc.DeviceIDs(), func(di protocol.DeviceID) string {
		return di.String()
	}))
}

func (fld *Folder) SharedEncryptedWithDeviceIDs() *ListOfStrings {
	fc := fld.folderConfiguration()
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

func (fld *Folder) EncryptionPasswordFor(peer string) string {
	did, err := protocol.DeviceIDFromString(peer)
	if err != nil {
		return ""
	}

	fc := fld.folderConfiguration()
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

func (fld *Folder) ConnectedPeerCount() int {
	fc := fld.folderConfiguration()
	if fc == nil {
		return 0
	}

	devIDs := fld.folderConfiguration().DeviceIDs()
	connected := 0
	for _, devID := range devIDs {
		if devID == fld.client.deviceID() {
			continue
		}
		if fld.client.app.Internals.IsConnectedTo(devID) {
			connected++
		}
	}
	return connected
}

func (fld *Folder) Label() string {
	fc := fld.folderConfiguration()
	if fc == nil {
		return ""
	}
	return fc.Label
}

func (fld *Folder) SetLabel(label string) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		config := fld.folderConfiguration()
		config.Label = label
		cfg.SetFolder(*config)
	})
}

var (
	errNoClient = errors.New("client not started up yet")
)

func (fld *Folder) whilePaused(block func() error) error {
	pausedBefore := fld.IsPaused()
	if !pausedBefore {
		err := fld.SetPaused(true)
		if err != nil {
			return err
		}
		defer fld.SetPaused(pausedBefore)
	}
	return block()
}

func (fld *Folder) SetSelective(selective bool) error {
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return errNoClient
	}

	return fld.whilePaused(func() error {
		if selective {
			return fld.client.app.Internals.SetIgnores(fld.FolderID, []string{"*"})
		} else {
			return fld.client.app.Internals.SetIgnores(fld.FolderID, []string{})
		}
	})
}

func (fld *Folder) ClearSelection() error {
	err := fld.client.app.Internals.SetIgnores(fld.FolderID, []string{"*"})
	if err != nil {
		return err
	}

	return fld.CleanSelection()
}

func (fld *Folder) SelectedPaths() (*ListOfStrings, error) {
	fc := fld.folderConfiguration()
	if fc == nil {
		return nil, errors.New("folder does not exist")
	}

	if fld.client.app == nil || fld.client.app.Internals == nil {
		return nil, errNoClient
	}

	lines, _, err := fld.client.app.Internals.Ignores(fld.FolderID)
	if err != nil {
		return nil, err
	}

	paths := ListOfStrings{data: []string{}}

	for _, pattern := range lines {
		if len(pattern) > 0 && pattern[0] == '!' {
			paths.data = append(paths.data, PathForIgnoreLine(pattern))
		}
	}

	return &paths, nil
}

func (fld *Folder) HasSelectedPaths() bool {
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return false
	}

	fc := fld.folderConfiguration()
	if fc == nil {
		return false
	}

	if !fld.IsSelective() {
		return false
	}

	lines, _, err := fld.client.app.Internals.Ignores(fld.FolderID)
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

func (fld *Folder) FolderType() string {
	fc := fld.folderConfiguration()
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

func (fld *Folder) SetFolderType(folderType string) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		fc := fld.folderConfiguration()
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

func (fld *Folder) IsSelective() bool {
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return false
	}

	fc := fld.folderConfiguration()
	if fc == nil {
		return false
	}

	lines, _, err := fld.client.app.Internals.Ignores(fld.FolderID)
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

func (fld *Folder) LocalNativePath() (string, error) {
	fc := fld.folderConfiguration()
	if fc == nil {
		return "", errors.New("folder does not exist")
	}

	// This is a bit of a hack, according to similar code in model.warnAboutOverwritingProtectedFiles :-)
	ffs := fld.folderConfiguration().Filesystem(nil)
	if ffs.Type() != fs.FilesystemTypeBasic {
		return "", errors.New("unsupported FS type")
	}
	return ffs.URI(), nil
}

func (fld *Folder) loadIgnores() (*ignore.Matcher, error) {
	cfg := fld.folderConfiguration()
	ignores := ignore.New(cfg.Filesystem(nil), ignore.WithCache(false))
	if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
		return nil, err
	}
	return ignores, nil
}

func (fld *Folder) ExtraneousFiles() (*ListOfStrings, error) {
	return fld.extraneousFiles(false)
}

func (fld *Folder) HasExtraneousFiles() (bool, error) {
	files, err := fld.extraneousFiles(true)
	if err != nil {
		return false, err
	}
	return files.Count() > 0, nil
}

// List of files that are not selected but exist locally. When stopAtOne = true, return after finding just one file
func (fld *Folder) extraneousFiles(stopAtOne bool) (*ListOfStrings, error) {
	cfg := fld.folderConfiguration()

	if cfg == nil {
		return nil, errors.New("folder does not exist")
	}

	if !fld.IsSelective() {
		return List([]string{}), nil
	}

	ignores := ignore.New(cfg.Filesystem(nil), ignore.WithCache(false))
	if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
		return nil, err
	}

	extraFiles := make([]string, 0)

	ffs := fld.folderConfiguration().Filesystem(nil)
	foundOneError := errors.New("found one")
	err := ffs.Walk("", func(path string, info fs.FileInfo, err error) error {
		if err != nil {
			Logger.Warnln("error walking: ", path, err)
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
func (fld *Folder) CleanSelection() error {
	return fld.whilePaused(func() error {
		// Make sure the initial scan has finished (ScanFolders is blocking)
		fld.client.app.Internals.ScanFolders()

		cfg := fld.folderConfiguration()
		ignores := ignore.New(cfg.Filesystem(nil), ignore.WithCache(false))
		if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
			return err
		}

		ffs := fld.folderConfiguration().Filesystem(nil)
		return ffs.Walk("", func(path string, info fs.FileInfo, err error) error {
			if strings.HasPrefix(path, cfg.MarkerName) {
				return nil
			}
			if path == ignoreFileName {
				return nil
			}

			// Check ignore status
			result := ignores.Match(path)
			if result.IsIgnored() {
				return ffs.RemoveAll(path)
			}
			return nil
		})
	})
}

func (fld *Folder) DeleteLocalFile(path string) error {
	ffs := fld.folderConfiguration().Filesystem(nil)
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

	err = fld.client.app.Internals.ScanFolderSubdirs(fld.FolderID, []string{path})
	if err != nil {
		return err
	}
	err = fld.SetLocalFileExplicitlySelected(path, false)
	if err != nil {
		return err
	}

	return nil
}

func (fld *Folder) SetLocalPathsExplicitlySelected(paths *ListOfStrings) error {
	// Edit lines
	lines, _, err := fld.client.app.Internals.Ignores(fld.FolderID)
	if err != nil {
		return err
	}

	for _, path := range paths.data {
		line := IgnoreLineForSelectingPath(path)
		if !slices.Contains(lines, line) {
			Logger.Infof("Adding ignore line: %s", line)
			lines = append([]string{line}, lines...)
		}
	}

	// Save new ignores
	err = fld.client.app.Internals.SetIgnores(fld.FolderID, lines)
	if err != nil {
		return err
	}

	// Do a small scan to force reloading ignores
	err = fld.client.app.Internals.ScanFolderSubdirs(fld.FolderID, append(paths.data, ignoreFileName))
	if err != nil {
		return nil
	}

	return nil
}

func (fld *Folder) SetLocalFileExplicitlySelected(path string, toggle bool) error {
	mockEntry := Entry{
		Folder: fld,
		info: protocol.FileInfo{
			Name: path,
		},
	}
	return mockEntry.SetExplicitlySelected(toggle)
}

func (fld *Folder) Statistics() (*FolderStats, error) {
	snap, err := fld.client.app.Internals.DBSnapshot(fld.FolderID)
	if err != nil {
		return nil, err
	}
	defer snap.Release()

	return &FolderStats{
		Global:    newFolderCounts(snap.GlobalSize()),
		Local:     newFolderCounts(snap.LocalSize()),
		LocalNeed: newFolderCounts(snap.NeedSize(fld.client.deviceID())),
	}, nil
}

type Completion struct {
	CompletionPct float64
	GlobalBytes   int64
	NeedBytes     int64
	GlobalItems   int
	NeedItems     int
	NeedDeletes   int
	Sequence      int64
}

func (fld *Folder) CompletionForDevice(deviceID string) (*Completion, error) {
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return nil, ErrStillLoading
	}

	devID, err := protocol.DeviceIDFromString(deviceID)
	if err != nil {
		return nil, err
	}

	completion, err := fld.client.app.Internals.Completion(devID, fld.FolderID)
	if err != nil {
		return nil, err
	}

	ourCompletion := Completion{
		CompletionPct: completion.CompletionPct,
		GlobalBytes:   completion.GlobalBytes,
		NeedBytes:     completion.NeedBytes,
		GlobalItems:   completion.GlobalItems,
		NeedItems:     completion.NeedItems,
		NeedDeletes:   completion.NeedDeletes,
		Sequence:      completion.Sequence,
	}

	return &ourCompletion, nil
}
