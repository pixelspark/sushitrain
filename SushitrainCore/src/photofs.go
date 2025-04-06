// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/protocol"
)

type photoFilesystem struct {
	uri  string
	root *photoFileInfo
}

type photoFile struct {
	info *photoFileInfo
}

type photoFileInfo struct {
	leafName string
	children []*photoFileInfo
}

var _ fs.Filesystem = photoFilesystem{}
var _ fs.File = photoFile{}
var _ fs.FileInfo = photoFileInfo{}

var PhotoFilesystemType fs.FilesystemType = "sushitrain.photos.v1"
var errNotImplemented = errors.New("not implemented by photo filesystem")

func init() {
	fs.RegisterFilesystemType(PhotoFilesystemType, func(uri string, _opts ...fs.Option) (fs.Filesystem, error) {
		return &photoFilesystem{
			uri: uri,
			root: &photoFileInfo{
				leafName: "",
				children: []*photoFileInfo{
					&photoFileInfo{
						leafName: ".stfolder",
						children: []*photoFileInfo{},
					},
					&photoFileInfo{
						leafName: "DIRA",
						children: []*photoFileInfo{
							&photoFileInfo{
								leafName: "FileA",
							},
						},
					},
					&photoFileInfo{
						leafName: "DIRB",
						children: []*photoFileInfo{},
					},
				},
			},
		}, nil
	})
}

func (p photoFilesystem) Roots() ([]string, error) {
	return []string{"/"}, nil
}

func (p photoFilesystem) Open(name string) (fs.File, error) {
	return p.OpenFile(name, os.O_RDONLY, 0)
}

func (p photoFilesystem) OpenFile(name string, flags int, mode fs.FileMode) (fs.File, error) {
	var item *photoFileInfo
	var err error
	if item, err = p.itemAt(name); err != nil {
		return nil, err
	}
	return photoFile{info: item}, nil
}

func (p photoFilesystem) Glob(pattern string) ([]string, error) {
	panic("unimplemented")
}

func (p photoFilesystem) itemAt(path string) (*photoFileInfo, error) {
	parts := strings.Split(path, "/")

	item := p.root
	for _, p := range parts {
		if p == "." || p == "" {
			continue
		}

		if item.children == nil || !item.IsDir() {
			return nil, fs.ErrNotExist
		}

		found := false
		for _, child := range item.children {
			if child.leafName == p {
				item = child
				found = true
				break
			}
		}

		if !found {
			return nil, fs.ErrNotExist
		}
	}

	return item, nil
}

func (p photoFilesystem) DirNames(name string) ([]string, error) {
	folder, err := p.itemAt((name))
	if err != nil {
		return nil, err
	}

	names := make([]string, 0)
	for _, child := range folder.children {
		names = append(names, child.leafName)
	}

	return names, nil
}

// Lstat is equal to Stat, except that when name refers to a symlink, Lstat returns data about the link, not the target
func (p photoFilesystem) Lstat(name string) (fs.FileInfo, error) {
	return p.Stat(name)
}

func (p photoFilesystem) SameFile(fi1 fs.FileInfo, fi2 fs.FileInfo) bool {
	return false
}

func (p photoFilesystem) Stat(name string) (fs.FileInfo, error) {
	Logger.Infoln("PFS Stat", name)
	path := strings.TrimPrefix(name, "/")
	item, err := p.itemAt((path))
	if err != nil {
		return nil, err
	}

	if item == nil {
		return nil, fs.ErrNotExist
	}

	return item, nil
}

func (p photoFilesystem) Usage(name string) (fs.Usage, error) {
	return fs.Usage{
		Free:  0,
		Total: 0,
	}, nil
}

func (p photoFilesystem) Walk(name string, walkFn fs.WalkFunc) error {
	// Implemented by Syncthing itself through WalkFS
	panic("unimplemented")
}

// We support no options
func (p photoFilesystem) Options() []fs.Option {
	return make([]fs.Option, 0)
}

func (p photoFilesystem) SymlinksSupported() bool {
	return false
}

func (p photoFilesystem) PlatformData(name string, withOwnership bool, withXattrs bool, xattrFilter fs.XattrFilter) (protocol.PlatformData, error) {
	return protocol.PlatformData{}, nil
}

func (p photoFilesystem) ReadSymlink(name string) (string, error) {
	return "", errNotImplemented
}

func (p photoFilesystem) Type() fs.FilesystemType {
	return PhotoFilesystemType
}

func (p photoFilesystem) URI() string {
	return p.uri
}

// We don't have no xattrs
func (p photoFilesystem) GetXattr(name string, xattrFilter fs.XattrFilter) ([]protocol.Xattr, error) {
	return make([]protocol.Xattr, 0), nil
}

func (p photoFilesystem) Underlying() (fs.Filesystem, bool) {
	return nil, false
}

// Unimplemented parts of the Filesystem interface return an error. They should not normally be called
func (p photoFilesystem) Chmod(name string, mode fs.FileMode) error {
	return errNotImplemented
}

func (p photoFilesystem) Chtimes(name string, atime time.Time, mtime time.Time) error {
	return errNotImplemented
}

func (p photoFilesystem) Create(name string) (fs.File, error) {
	return nil, errNotImplemented
}

func (p photoFilesystem) CreateSymlink(target string, name string) error {
	return errNotImplemented
}

func (p photoFilesystem) Hide(name string) error {
	return errNotImplemented
}

func (p photoFilesystem) Lchown(name string, uid string, gid string) error {
	return errNotImplemented
}

func (p photoFilesystem) Mkdir(name string, perm fs.FileMode) error {
	return errNotImplemented
}

func (p photoFilesystem) MkdirAll(name string, perm fs.FileMode) error {
	return errNotImplemented
}

func (p photoFilesystem) Remove(name string) error {
	return errNotImplemented
}

func (p photoFilesystem) RemoveAll(name string) error {
	return errNotImplemented
}

func (p photoFilesystem) Rename(oldname string, newname string) error {
	return errNotImplemented
}

func (p photoFilesystem) SetXattr(path string, xattrs []protocol.Xattr, xattrFilter fs.XattrFilter) error {
	return errNotImplemented
}

func (p photoFilesystem) Unhide(name string) error {
	return errNotImplemented
}

func (p photoFilesystem) Watch(path string, ignore fs.Matcher, ctx context.Context, ignorePerms bool) (<-chan fs.Event, <-chan error, error) {
	return nil, nil, errNotImplemented
}

// Photo file implementation
func (p photoFile) Close() error {
	return nil
}

// Name implements fs.File.
func (p photoFile) Name() string {
	return p.info.leafName
}

// Read implements fs.File.
func (photoFile) Read(p []byte) (n int, err error) {
	panic("unimplemented")
}

// ReadAt implements fs.File.
func (photoFile) ReadAt(p []byte, off int64) (n int, err error) {
	panic("unimplemented")
}

// Seek implements fs.File.
func (p photoFile) Seek(offset int64, whence int) (int64, error) {
	panic("unimplemented")
}

// Stat implements fs.File.
func (p photoFile) Stat() (fs.FileInfo, error) {
	return p.info, nil
}

// Sync implements fs.File.
func (p photoFile) Sync() error {
	return nil
}

// Unimplemented parts of fs.File for PhotoFile return an error
func (p photoFile) Truncate(size int64) error {
	return errNotImplemented
}

func (photoFile) Write(p []byte) (n int, err error) {
	return 0, errNotImplemented
}

func (photoFile) WriteAt(p []byte, off int64) (n int, err error) {
	return 0, errNotImplemented
}

// PhotoFileInfo implementation
func (p photoFileInfo) Group() int {
	return 0
}

func (p photoFileInfo) InodeChangeTime() time.Time {
	return time.Time{}
}

func (p photoFileInfo) IsDir() bool {
	return p.children != nil
}

func (p photoFileInfo) IsRegular() bool {
	return p.children == nil
}

// We don't do symlinks
func (p photoFileInfo) IsSymlink() bool {
	return false
}

func (p photoFileInfo) ModTime() time.Time {
	return time.Time{}
}

func (p photoFileInfo) Mode() fs.FileMode {
	if p.IsDir() {
		return 0555 // Read-only with execute bit to list dir
	}
	return 0444 // Read-only
}

func (p photoFileInfo) Name() string {
	return p.leafName
}

func (p photoFileInfo) Owner() int {
	return 0
}

func (p photoFileInfo) Size() int64 {
	if p.IsDir() {
		return 0
	}
	return 0
}

func (p photoFileInfo) Sys() interface{} {
	return nil
}
