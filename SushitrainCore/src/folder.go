// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"encoding/json"
	"errors"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/ignore"
	"github.com/syncthing/syncthing/lib/ignore/ignoreresult"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/osutil"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	ignoreFileName string = ".stignore"
)

type CachedIgnore struct {
	matcher *ignore.Matcher
	modTime time.Time
}

type Folder struct {
	client       *Client
	FolderID     string
	cachedIgnore CachedIgnore
}

func (fld *Folder) folderConfiguration() *config.FolderConfiguration {
	folders := fld.client.config.Folders()
	folderInfo, ok := folders[fld.FolderID]
	if !ok {
		return nil
	}
	return &folderInfo
}

func (fld *Folder) RescanSubdirectory(path string) error {
	go func() {
		Logger.Infoln("Rescan folder", fld.FolderID, "subdirectory", path)
		fld.client.app.Internals.ScanFolderSubdirs(fld.FolderID, []string{path})
	}()
	return nil
}

func (fld *Folder) Rescan() error {
	go func() {
		Logger.Infoln("Rescan folder", fld.FolderID)
		fld.client.app.Internals.ScanFolderSubdirs(fld.FolderID, nil)
	}()
	return nil
}

func (fld *Folder) RescanIntervalSeconds() int {
	fc := fld.folderConfiguration()
	if fc == nil {
		return 0
	}

	return fc.RescanIntervalS
}

func (fld *Folder) SetRescanInterval(seconds int) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		config := fld.folderConfiguration()
		if config == nil {
			return
		}
		config.RescanIntervalS = seconds
		cfg.SetFolder(*config)
	})
}

func (fld *Folder) WatcherDelaySeconds() int {
	fc := fld.folderConfiguration()
	if fc == nil {
		return 0
	}

	return int(fc.FSWatcherDelayS)
}

func (fld *Folder) SetWatcherDelaySeconds(seconds int) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		config := fld.folderConfiguration()
		if config == nil {
			return
		}
		config.FSWatcherDelayS = float64(seconds)
		cfg.SetFolder(*config)
	})
}

func (fld *Folder) Unlink() error {
	fc := fld.folderConfiguration()
	if fc == nil {
		return errors.New("folder does not exist")
	}
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

	return nil
}

func (fld *Folder) filesystem() (fs.Filesystem, error) {
	fc := fld.folderConfiguration()
	if fc == nil {
		return nil, errors.New("folder does not exist")
	}
	return fc.Filesystem(), nil
}

func (fld *Folder) Remove() error {
	ffs, err := fld.filesystem()
	if err != nil {
		return err
	}

	err = fld.Unlink()
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

func (fld *Folder) IsWatcherEnabled() bool {
	fc := fld.folderConfiguration()
	if fc == nil {
		return false
	}

	return fld.folderConfiguration().FSWatcherEnabled
}

func (fld *Folder) SetWatcherEnabled(enabled bool) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		config := fld.folderConfiguration()
		if config == nil {
			return
		}
		config.FSWatcherEnabled = enabled
		cfg.SetFolder(*config)
	})
}

// See documentation; -1 means 'automatically determined number', 0 means disabled.
func (fld *Folder) MaxConflicts() int {
	fc := fld.folderConfiguration()
	if fc == nil {
		return -1
	}

	return fld.folderConfiguration().MaxConflicts
}

func (fld *Folder) SetMaxConflicts(mx int) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		config := fld.folderConfiguration()
		if config == nil {
			return
		}
		config.MaxConflicts = mx
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

func (fld *Folder) listEntries(prefix string, directories bool, recurse bool) ([]*model.TreeEntry, error) {
	if fld.client.app == nil {
		return nil, nil
	}

	if fld.client.app.Internals == nil {
		return nil, nil
	}

	levels := 0
	if recurse {
		levels = -1
	}

	return fld.client.app.Internals.GlobalTree(fld.FolderID, prefix, levels, directories)
}

func (fld *Folder) List(prefix string, directories bool, recurse bool) (*ListOfStrings, error) {
	entries, err := fld.listEntries(prefix, directories, recurse)
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

func (fld *Folder) sharedWith() ([]protocol.DeviceID, error) {
	fc := fld.folderConfiguration()
	if fc == nil {
		return nil, errors.New("folder configuration does not exist")
	}

	return fc.DeviceIDs(), nil
}

func (fld *Folder) SharedWithDeviceIDs() *ListOfStrings {
	devIDs, err := fld.sharedWith()
	if err != nil {
		return nil
	}

	return List(Map(devIDs, func(di protocol.DeviceID) string {
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
	fld.cachedIgnore.matcher = nil // Purge our cache
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return errNoClient
	}

	return fld.whilePaused(func() error {
		if selective {
			fld.cachedIgnore.matcher = nil // Purge our cache
			return fld.client.app.Internals.SetIgnores(fld.FolderID, []string{"*"})
		} else {
			fld.cachedIgnore.matcher = nil // Purge our cache
			return fld.client.app.Internals.SetIgnores(fld.FolderID, []string{})
		}
	})
}

func (fld *Folder) ClearSelection() error {
	fld.cachedIgnore.matcher = nil // Purge our cache
	err := fld.client.app.Internals.SetIgnores(fld.FolderID, []string{"*"})
	if err != nil {
		return err
	}

	return fld.CleanSelection()
}

func (fld *Folder) SelectedPaths(onlyExisting bool) (*ListOfStrings, error) {
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

	selection := NewSelection(lines)
	paths := selection.SelectedPaths()

	if onlyExisting {
		ffs, err := fld.filesystem()
		if err != nil {
			return nil, err
		}
		paths = Filter(paths, func(path string) bool {
			_, statErr := ffs.Lstat(path)
			return statErr == nil
		})
	}
	return &ListOfStrings{data: paths}, nil
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

// Returns true when this folder is 'external', i.e. some other app's folder
func (fld *Folder) IsExternal() (bool, error) {
	fc := fld.folderConfiguration()
	if fc == nil {
		return false, errors.New("cannot obtain folder configuration")
	}

	defaultPath := path.Join(fld.client.filesPath, fld.FolderID)
	return defaultPath != fc.Path, nil
}

func (fld *Folder) SetPath(path string) error {
	return fld.client.changeConfiguration(func(cfg *config.Configuration) {
		fc := fld.folderConfiguration()
		if fc == nil {
			return
		}
		fc.Path = path
		cfg.SetFolder(*fc)
	})
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

	return NewSelection(ignores.Lines()).isSelectiveIgnore()
}

func (fld *Folder) LocalNativePath() (string, error) {
	fc := fld.folderConfiguration()
	if fc == nil {
		return "", errors.New("folder does not exist")
	}

	// This is a bit of a hack, according to similar code in model.warnAboutOverwritingProtectedFiles :-)
	ffs := fld.folderConfiguration().Filesystem()
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

	ffs := cfg.Filesystem()
	stat, statErr := ffs.Lstat(ignoreFileName)

	// If we have a matcher cached and the 'last modified time' matches, assume it's the same
	if fld.cachedIgnore.matcher != nil && !fld.cachedIgnore.modTime.IsZero() && statErr == nil {
		if stat.ModTime().Equal(fld.cachedIgnore.modTime) {
			return fld.cachedIgnore.matcher, nil
		}
	}

	ignores := ignore.New(cfg.Filesystem(), ignore.WithCache(false))
	if err := ignores.Load(ignoreFileName); err != nil && !fs.IsNotExist(err) {
		return nil, err
	}

	// Save to cache
	if statErr == nil {
		fld.cachedIgnore.modTime = stat.ModTime()
		fld.cachedIgnore.matcher = ignores
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

	selection := NewSelection(ignores.Lines())

	// Can't have extraneous files when you are not a selective ignore folder
	if !selection.isSelectiveIgnore() {
		return &ListOfStrings{}, nil
	}

	extraFiles := make([]string, 0)

	ffs := fld.folderConfiguration().Filesystem()
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

		// Ignore whatever is on the 'extraneous ignore' list (used to ignore .DS_Store and similar)
		if fld.client.isExtraneousIgnored(filepath.Base(path)) {
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
		fld.client.app.Internals.ScanFolderSubdirs(fld.FolderID, []string{""})

		cfg := fld.folderConfiguration()
		if cfg == nil {
			return errors.New("folder does not exist")
		}

		ignores, err := fld.loadIgnores()
		if err != nil {
			return err
		}

		fc := fld.folderConfiguration()
		if fc == nil {
			return errors.New("folder does not exist")
		}
		ffs := fc.Filesystem()
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

func deleteEmptyParentDirectories(ffs fs.Filesystem, path string) {
	// Try to delete parent directories that are empty
	pathParts := fs.PathComponents(path)
	if len(pathParts) > 1 {
		for pathIndex := len(pathParts) - 2; pathIndex >= 0; pathIndex-- {
			dirPath := strings.Join(pathParts[0:pathIndex+1], string(fs.PathSeparator))
			ffs.Remove(dirPath) // Will only remove directories when empty
		}
	}
}

func (fld *Folder) RemoveSuperfluousSelectionEntries() error {
	fld.cachedIgnore.matcher = nil // Purge our cache
	state, err := fld.State()
	if err != nil {
		return err
	}
	if state != "idle" && state != "syncing" {
		return errors.New("cannot remove superfluous selection entries when not idle or syncing")
	}

	// Load ignores from file
	ignores, err := fld.loadIgnores()
	if err != nil {
		return err
	}

	selection := NewSelection(ignores.Lines())
	if !selection.isSelectiveIgnore() {
		return errors.New("folder is not a selective folder")
	}

	fc := fld.folderConfiguration()
	if fc == nil {
		return errors.New("invalid folder state")
	}

	ffs := fc.Filesystem()

	// Enumerate selection entries, find out if we need them
	selection.FilterSelectedPaths(func(path string) bool {
		// Find entry
		entry, err := fld.GetFileInformation(path)
		if err != nil || entry == nil {
			Logger.Infoln("Entry not found for path", path, err)
			return false
		}

		// If this entry exists on disk, don't change anything
		nativeFilename := osutil.NativeFilename(path)
		_, err = ffs.Stat(nativeFilename)
		if err == nil {
			Logger.Infoln("Entry exists, keeping:", nativeFilename)
			return true
		}

		// Only keep files that we can find a global entry for, and never delete if we still have a local entry
		keep := (err == nil && entry != nil && !entry.IsDeleted()) || (entry != nil && entry.IsLocallyPresent())
		Logger.Infoln("Keep selected path", path, keep, err, entry != nil && entry.IsDeleted(), entry != nil && entry.IsLocallyPresent())
		return keep
	})

	// Save new ignores (this triggers a reload of ignores and eventually a scan)
	err = fld.client.app.Internals.SetIgnores(fld.FolderID, selection.Lines())
	if err != nil {
		return err
	}

	return nil
}

// Remove empty, ignored directories that exist locally in selective folders
func (fld *Folder) RemoveSuperfluousSubdirectories() error {
	if !fld.IsSelective() {
		return errors.New("Folder is not selective")
	}

	ffs := fld.folderConfiguration().Filesystem()
	return fld.removeRedundantChildren(ffs, "", true)
}

func (fld *Folder) removeRedundantChildren(ffs fs.Filesystem, path string, directoriesAndAlwaysIgnoredOnly bool) error {
	ignores, err := fld.loadIgnores()
	if err != nil {
		return err
	}

	Logger.Infoln("RemoveRedundantChildren subdirectory at path", path)
	toDelete := make([]string, 0)

	err = ffs.Walk(path, func(childPath string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}

		Logger.Infoln("-", childPath)

		// Leave internal files alone
		if fs.IsInternal(childPath) || childPath == ignoreFileName {
			Logger.Infoln("- Skip, is internal:", childPath)
			return nil
		}

		// Delete items that match the 'extraneous ignore' list (used to ignore .DS_Store and similar)
		// *also* when directoriesAndAlwaysIgnoredOnly is set!
		if fld.client.isExtraneousIgnored(filepath.Base(childPath)) {
			Logger.Infoln("Ignoring always ignored extraneous file:", childPath, filepath.Base(childPath))
			toDelete = append(toDelete, childPath)
			return nil
		}

		if !directoriesAndAlwaysIgnoredOnly || info.IsDir() {
			// Check file ignore status
			ignoreStatus := ignores.Match(childPath)
			if ignoreStatus.IsIgnored() {
				// Check remote availability
				entry, err := fld.GetFileInformation(childPath)
				if err != nil {
					return err
				}

				if entry == nil || entry.IsDeleted() {
					// File is not known in the global index at all. Leave it in place except when it is an empty directory
					if info.IsDir() {
						toDelete = append(toDelete, childPath)
					}
					return nil
				}

				lst, err := entry.PeersWithFullCopy()
				if err != nil {
					return err
				}

				if lst.Count() > 0 {
					toDelete = append(toDelete, childPath)
				} else {
					// File is not available elsewhere, skip it
				}
			}
		}
		return nil
	})

	if err != nil {
		return err
	}

	// Scan complete, sort the list of paths to be deleted from long to short so we can delete them in child-first orer
	sort.Strings(toDelete)
	slices.Reverse(toDelete)

	Logger.Infoln("- Delete:", toDelete)

	for _, delPath := range toDelete {
		// Swallow delete errors. Parent directories may have been removed before we get to them
		_ = ffs.Remove(delPath)
		deleteEmptyParentDirectories(ffs, delPath)
	}
	return nil
}

// If `path` points to a file, remove it. If `path` points to a subdirectory, delete children that we are reasonably sure
// are also on other devices, then try to remove the subdirectory if empty. Finally, remove any empty parent directories.
func (fld *Folder) deleteLocalFileAndRedundantChildren(path string) error {
	ffs := fld.folderConfiguration().Filesystem()

	stat, err := ffs.Lstat(path)
	if err != nil {
		return err
	}

	// Try to recursively remove children that are ignored and available on other peers
	if stat.IsDir() {
		err = fld.removeRedundantChildren(ffs, path, false)
		if err != nil {
			return err
		}
	}

	err = ffs.Remove(path)
	if err != nil {
		return err
	}

	deleteEmptyParentDirectories(ffs, path)
	return nil
}

func (fld *Folder) deleteAndDeselectLocalFile(path string) error {
	err := fld.deleteLocalFileAndRedundantChildren(path)
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

func (fld *Folder) IgnoreLines() (*ListOfStrings, error) {
	// Load ignores from file
	ignores, err := fld.loadIgnores()
	if err != nil {
		return nil, err
	}
	return List(ignores.Lines()), nil
}

func (fld *Folder) SetIgnoreLines(lines *ListOfStrings) error {
	Logger.Infoln("Set ignore lines: ", len(lines.data))
	fld.cachedIgnore.matcher = nil // Purge our cache

	state, err := fld.State()
	if err != nil {
		return err
	}
	if state != "idle" && state != "syncing" {
		return errors.New("cannot change ignore lines when not idle or syncing")
	}

	// Save new ignores (this triggers a reload of ignores and eventually a scan)
	err = fld.client.app.Internals.SetIgnores(fld.FolderID, lines.data)
	if err != nil {
		return err
	}

	return nil
}

func (fld *Folder) setExplicitlySelected(paths map[string]bool) error {
	Logger.Infoln("Set explicitly selected: ", paths)
	fld.cachedIgnore.matcher = nil // Purge our cache
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

	selection := NewSelection(ignores.Lines())
	if !selection.isSelectiveIgnore() {
		return errors.New("folder is not a selective folder")
	}

	hashBefore := ignores.Hash()
	Logger.Debugf("Ignore hash before editing:", hashBefore)

	// Edit lines
	err = selection.SetExplicitlySelected(paths)
	if err != nil {
		return err
	}

	// Save new ignores (this triggers a reload of ignores and eventually a scan)
	err = fld.client.app.Internals.SetIgnores(fld.FolderID, selection.Lines())
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
				fld.deleteLocalFileAndRedundantChildren(path)
			} else {
				Logger.Infoln("Not deleting local deselected file, it apparently was reselected: "+path, res)
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
	if fld.client.app == nil || fld.client.app.Internals == nil {
		return nil, ErrStillLoading
	}

	internals := fld.client.app.Internals
	globalSize, err := internals.GlobalSize(fld.FolderID)
	if err != nil {
		return nil, err
	}

	localSize, err := internals.LocalSize(fld.FolderID)
	if err != nil {
		return nil, err
	}

	needSize, err := internals.NeedSize(fld.FolderID, protocol.LocalDeviceID)
	if err != nil {
		return nil, err
	}

	return &FolderStats{
		Global:    newFolderCounts(globalSize),
		Local:     newFolderCounts(localSize),
		LocalNeed: newFolderCounts(needSize),
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
