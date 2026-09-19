// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/osutil"
)

const filesystemTypeTrash = "basic-trash"

// TrashHandler is implemented by the native app. Trash must move the item itself
// (not a symlink's target) to the system trash, or return an error without deleting it.
// Calls can arrive concurrently from Syncthing's background workers.
type TrashHandler interface {
	Trash(path string) error
}

var systemTrash struct {
	sync.RWMutex
	handler TrashHandler
}

// RegisterTrashHandler must be called before starting the client. The filesystem
// is registered even without a handler, so a missing bridge can never turn a saved
// trash preference into permanent deletion.
func RegisterTrashHandler(handler TrashHandler) {
	systemTrash.Lock()
	defer systemTrash.Unlock()
	systemTrash.handler = handler
}

func init() {
	fs.RegisterFilesystemType(fs.FilesystemType(filesystemTypeTrash), func(root string, opts ...fs.Option) (fs.Filesystem, error) {
		return &trashFilesystem{
			Filesystem: fs.NewFilesystem(fs.FilesystemTypeBasic, root, opts...),
			trash:      moveToSystemTrash,
		}, nil
	})
}

func moveToSystemTrash(path string) error {
	systemTrash.RLock()
	handler := systemTrash.handler
	systemTrash.RUnlock()
	if handler == nil {
		return errors.New("system Trash is unavailable; the file has been kept on this device")
	}
	return handler.Trash(path)
}

func isNativeFilesystem(fsType config.FilesystemType) bool {
	return fsType.ToFS() == fs.FilesystemTypeBasic || fsType.String() == filesystemTypeTrash
}

type trashFilesystem struct {
	fs.Filesystem
	trash func(string) error
}

var _ fs.Filesystem = (*trashFilesystem)(nil)

// Type deliberately remains "basic": paths, watches and renames have native
// semantics. In particular, Syncthing constructs its version-history filesystem
// from Type(), and expiring an archived version must not send it to Trash again.
// The persisted FolderConfiguration.FilesystemType selects this wrapper instead.
func (f *trashFilesystem) Underlying() (fs.Filesystem, bool) {
	return f.Filesystem, true
}

func (f *trashFilesystem) checkedPath(name string) (string, error) {
	// Unlike BasicFS's compatibility handling of a leading slash, accept only
	// relative paths at the native bridge boundary.
	if filepath.IsAbs(name) {
		return "", &os.PathError{Op: "trash", Path: name, Err: os.ErrInvalid}
	}
	name, err := fs.Canonicalize(name)
	if err != nil {
		return "", err
	}
	if err := osutil.TraversesSymlink(f.Filesystem, filepath.Dir(name)); err != nil {
		return "", err
	}
	return name, nil
}

func (f *trashFilesystem) Remove(name string) error {
	name, err := f.checkedPath(name)
	if err != nil {
		return err
	}
	info, err := f.Filesystem.Lstat(name)
	if err != nil {
		return err
	}
	// Keep Remove's non-recursive contract. Deselection relies on this to retain
	// children which are still selected or have no other copy.
	if info.IsDir() || fs.IsInternal(name) || fs.IsTemporary(name) {
		return f.Filesystem.Remove(name)
	}
	return f.trashItem(name)
}

func (f *trashFilesystem) RemoveAll(name string) error {
	name, err := f.checkedPath(name)
	if err != nil {
		return err
	}
	if _, err := f.Filesystem.Lstat(name); fs.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	if fs.IsInternal(name) || fs.IsTemporary(name) {
		return f.Filesystem.RemoveAll(name)
	}
	// "." (including an original empty name) means the configured folder itself.
	// Folder.Remove pauses synchronization before moving it as one recoverable item.
	return f.trashItem(name)
}

func (f *trashFilesystem) trashItem(name string) error {
	if err := f.trash(filepath.Join(f.URI(), name)); err != nil {
		return fmt.Errorf("move %q to system Trash: %w", name, err)
	}
	return nil
}

func (fld *Folder) IsNativeFilesystem() bool {
	fc := fld.folderConfiguration()
	return fc != nil && isNativeFilesystem(fc.FilesystemType)
}

func (fld *Folder) IsTrashEnabled() bool {
	fc := fld.folderConfiguration()
	return fc != nil && fc.FilesystemType.String() == filesystemTypeTrash
}

func (fld *Folder) SetTrashEnabled(enabled bool) error {
	fc := fld.folderConfiguration()
	if fc == nil {
		return errFolderConfigNotFound
	}
	if !isNativeFilesystem(fc.FilesystemType) {
		return errors.New("system Trash is only supported for native folders")
	}
	return fld.changeFolderConfiguration(func(fc *config.FolderConfiguration) {
		fc.FilesystemType = config.FilesystemTypeBasic
		if enabled {
			fc.FilesystemType = config.FilesystemType(filesystemTypeTrash)
		}
	})
}
