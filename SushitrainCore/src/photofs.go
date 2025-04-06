// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"errors"
	"time"

	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/protocol"
)

type PhotoFilesystem struct {
	uri string
}

type PhotoFile struct {
	name string
}

type PhotoFileInfo struct {
	file *PhotoFile
}

var _ fs.Filesystem = PhotoFilesystem{}
var _ fs.File = PhotoFile{}
var _ fs.FileInfo = PhotoFileInfo{}

var PhotoFilesystemType fs.FilesystemType = "sushitrain.photos.v1"
var errNotImplemented = errors.New("not implemented by photo filesystem")

func init() {
	fs.RegisterFilesystemType(PhotoFilesystemType, func(uri string, _opts ...fs.Option) (fs.Filesystem, error) {
		return &PhotoFilesystem{
			uri: uri,
		}, nil
	})
}

func (p PhotoFilesystem) Roots() ([]string, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) Open(name string) (fs.File, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) OpenFile(name string, flags int, mode fs.FileMode) (fs.File, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) Glob(pattern string) ([]string, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) DirNames(name string) ([]string, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) Lstat(name string) (fs.FileInfo, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) SameFile(fi1 fs.FileInfo, fi2 fs.FileInfo) bool {
	panic("unimplemented")
}

func (p PhotoFilesystem) Stat(name string) (fs.FileInfo, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) Usage(name string) (fs.Usage, error) {
	panic("unimplemented")
}

func (p PhotoFilesystem) Walk(name string, walkFn fs.WalkFunc) error {
	panic("unimplemented")
}

// We support no options
func (p PhotoFilesystem) Options() []fs.Option {
	return make([]fs.Option, 0)
}

func (p PhotoFilesystem) SymlinksSupported() bool {
	return false
}

func (p PhotoFilesystem) PlatformData(name string, withOwnership bool, withXattrs bool, xattrFilter fs.XattrFilter) (protocol.PlatformData, error) {
	return protocol.PlatformData{}, nil
}

func (p PhotoFilesystem) ReadSymlink(name string) (string, error) {
	return "", errNotImplemented
}

func (p PhotoFilesystem) Type() fs.FilesystemType {
	return PhotoFilesystemType
}

func (p PhotoFilesystem) URI() string {
	return p.uri
}

// We don't have no xattrs
func (p PhotoFilesystem) GetXattr(name string, xattrFilter fs.XattrFilter) ([]protocol.Xattr, error) {
	return make([]protocol.Xattr, 0), nil
}

func (p PhotoFilesystem) Underlying() (fs.Filesystem, bool) {
	return nil, false
}

// Unimplemented parts of the Filesystem interface return an error. They should not normally be called
func (p PhotoFilesystem) Chmod(name string, mode fs.FileMode) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Chtimes(name string, atime time.Time, mtime time.Time) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Create(name string) (fs.File, error) {
	return nil, errNotImplemented
}

func (p PhotoFilesystem) CreateSymlink(target string, name string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Hide(name string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Lchown(name string, uid string, gid string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Mkdir(name string, perm fs.FileMode) error {
	return errNotImplemented
}

func (p PhotoFilesystem) MkdirAll(name string, perm fs.FileMode) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Remove(name string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) RemoveAll(name string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Rename(oldname string, newname string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) SetXattr(path string, xattrs []protocol.Xattr, xattrFilter fs.XattrFilter) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Unhide(name string) error {
	return errNotImplemented
}

func (p PhotoFilesystem) Watch(path string, ignore fs.Matcher, ctx context.Context, ignorePerms bool) (<-chan fs.Event, <-chan error, error) {
	return nil, nil, errNotImplemented
}

// Photo file implementation
func (p PhotoFile) Close() error {
	return nil
}

// Name implements fs.File.
func (p PhotoFile) Name() string {
	return p.name
}

// Read implements fs.File.
func (PhotoFile) Read(p []byte) (n int, err error) {
	panic("unimplemented")
}

// ReadAt implements fs.File.
func (PhotoFile) ReadAt(p []byte, off int64) (n int, err error) {
	panic("unimplemented")
}

// Seek implements fs.File.
func (p PhotoFile) Seek(offset int64, whence int) (int64, error) {
	panic("unimplemented")
}

// Stat implements fs.File.
func (p PhotoFile) Stat() (fs.FileInfo, error) {
	return PhotoFileInfo{file: &p}, nil
	panic("unimplemented")
}

// Sync implements fs.File.
func (p PhotoFile) Sync() error {
	return nil
}

// Unimplemented parts of fs.File for PhotoFile return an error
func (p PhotoFile) Truncate(size int64) error {
	return errNotImplemented
}

func (PhotoFile) Write(p []byte) (n int, err error) {
	return 0, errNotImplemented
}

func (PhotoFile) WriteAt(p []byte, off int64) (n int, err error) {
	return 0, errNotImplemented
}

// PhotoFileInfo implementation
func (p PhotoFileInfo) Group() int {
	return 0
}

// InodeChangeTime implements fs.FileInfo.
func (p PhotoFileInfo) InodeChangeTime() time.Time {
	panic("unimplemented")
}

// IsDir implements fs.FileInfo.
func (p PhotoFileInfo) IsDir() bool {
	panic("unimplemented")
}

// IsRegular implements fs.FileInfo.
func (p PhotoFileInfo) IsRegular() bool {
	panic("unimplemented")
}

// We don't do symlinks
func (p PhotoFileInfo) IsSymlink() bool {
	return false
}

// ModTime implements fs.FileInfo.
func (p PhotoFileInfo) ModTime() time.Time {
	panic("unimplemented")
}

func (p PhotoFileInfo) Mode() fs.FileMode {
	if p.IsDir() {
		return 0555 // Read-only with execute bit to list dir
	}
	return 0444 // Read-only
}

func (p PhotoFileInfo) Name() string {
	return p.file.name
}

func (p PhotoFileInfo) Owner() int {
	return 0
}

// Size implements fs.FileInfo.
func (p PhotoFileInfo) Size() int64 {
	panic("unimplemented")
}

func (p PhotoFileInfo) Sys() interface{} {
	return nil
}
