// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"strings"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/ignore"
	"github.com/syncthing/syncthing/lib/ignore/ignoreresult"
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
	fc := fld.folderConfiguration()
	if fc == nil {
		return errors.New("folder does not exist")
	}
	ffs := fc.Filesystem(nil)
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
		if config == nil {
			return
		}
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
		if fc == nil {
			return
		}

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
		if config != nil {
			config.Label = label
			cfg.SetFolder(*config)
		}
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
		if fc == nil {
			return
		}

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

// Returns whether the provided set of ignore lines are valid for 'selective' mode
func isSelectiveIgnore(lines []string) bool {
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

func (fld *Folder) IsSelective() bool {
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return false
	}

	fc := fld.folderConfiguration()
	if fc == nil {
		return false
	}

	ignores, err := fld.loadIgnores()
	if err != nil {
		return false
	}

	return isSelectiveIgnore(ignores.Lines())
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
	if cfg == nil {
		return nil, errors.New("folder does not exist")
	}

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

	ignores, err := fld.loadIgnores()
	if err != nil {
		return nil, err
	}

	// Can't have extraneous files when you are not a selective ignore folder
	if !isSelectiveIgnore(ignores.Lines()) {
		return &ListOfStrings{}, nil
	}

	extraFiles := make([]string, 0)

	ffs := fld.folderConfiguration().Filesystem(nil)
	foundOneError := errors.New("found one")
	err = ffs.Walk("", func(path string, info fs.FileInfo, err error) error {
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
		if cfg == nil {
			return errors.New("folder does not exist")
		}

		ignores, err := fld.loadIgnores()
		if err != nil {
			return err
		}

		if !isSelectiveIgnore(ignores.Lines()) {
			return errors.New("folder is not a selective folder")
		}

		fc := fld.folderConfiguration()
		if fc == nil {
			return errors.New("folder does not exist")
		}
		ffs := fc.Filesystem(nil)
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

func (fld *Folder) deleteLocalFile(path string) error {
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
	return nil
}

func (fld *Folder) DeselectAndDeleteLocalFile(path string) error {
	err := fld.deleteLocalFile(path)
	if err != nil {
		return err
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

func (fld *Folder) reloadIgnores() error {
	if !fld.IsPaused() {
		err := fld.SetPaused(true)
		if err != nil {
			return err
		}
		fld.SetPaused(false)

		// Force a (minimal) scan. The current implementation also reloads the ignore file here (regardless of the path that is scanned)
		// Note, this could potentially take a while
		err = fld.client.app.Internals.ScanFolderSubdirs(fld.FolderID, []string{ignoreFileName})
		if err != nil {
			return err
		}
	}
	return nil
}

func (fld *Folder) SetExplicitlySelectedJSON(js []byte) error {
	var paths map[string]bool
	if err := json.Unmarshal(js, &paths); err != nil {
		return err
	}
	return fld.setExplicitlySelected(paths)
}

func (fld *Folder) setExplicitlySelected(paths map[string]bool) error {
	Logger.Infoln("Set explicitly selected: ", paths)
	state, err := fld.State()
	if err != nil {
		return err
	}
	if state != "idle" && state != "syncing" {
		return errors.New("cannot change explicit selection state when not idle or syncing")
	}

	// Check if we have any work to do
	if len(paths) == 0 {
		return nil
	}

	// Load ignores from file
	ignores, err := fld.loadIgnores()
	if err != nil {
		return err
	}
	lines := ignores.Lines()

	if !isSelectiveIgnore(lines) {
		return errors.New("folder is not a selective folder")
	}

	hashBefore := ignores.Hash()
	Logger.Debugf("Ignore hash before editing:", hashBefore)

	// Edit lines
	for path, selected := range paths {
		line := IgnoreLineForSelectingPath(path)
		Logger.Infof("Edit ignore line (%b): %s\n", selected, line)

		// Is this entry currently selected explicitly?
		currentlySelected := slices.Contains(lines, line)
		if currentlySelected == selected {
			Logger.Debugln("not changing selecting status for path " + path + ": it is the status quo")
			continue
		}

		// To deselect, remove the relevant ignore line
		countBefore := len(lines)
		if !selected {
			lines = Filter(lines, func(l string) bool {
				return l != line
			})
			if len(lines) != countBefore-1 {
				return errors.New("failed to remove ignore line: " + line)
			}
		} else {
			// To select, prepend it
			lines = append([]string{line}, lines...)
		}
	}

	// Save new ignores (this triggers a reload of ignores and eventually a scan)
	err = fld.client.app.Internals.SetIgnores(fld.FolderID, lines)
	if err != nil {
		return err
	}

	// Delete files if necessary
	ignores, err = fld.loadIgnores()
	if err != nil {
		return err
	}

	hashAfter := ignores.Hash()
	if hashAfter == hashBefore {
		Logger.Warnln("ignore file did not change after edits")
	}
	Logger.Debugf("Hash before", hashBefore, "after", hashAfter)

	for path, selected := range paths {
		// Delete local file if it is not selected anymore
		if !selected {
			// Check if not still implicitly selected
			res := ignores.Match(path)
			if res == ignoreresult.Ignored || res == ignoreresult.IgnoreAndSkip {
				Logger.Infoln("Deleting local deselected file: " + path)
				fld.deleteLocalFile(path)
			} else {
				Logger.Infoln("Not deleting local deselected file, it apparently was reselected: "+path, lines, res)
			}
		}
	}
	return nil
}

func (fld *Folder) SetLocalPathsExplicitlySelected(paths *ListOfStrings) error {
	pathsMap := map[string]bool{}
	for _, path := range paths.data {
		pathsMap[path] = true
	}
	return fld.setExplicitlySelected(pathsMap)
}

func (fld *Folder) SetLocalFileExplicitlySelected(path string, toggle bool) error {
	pathsMap := map[string]bool{}
	pathsMap[path] = toggle
	return fld.setExplicitlySelected(pathsMap)
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
