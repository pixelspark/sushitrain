// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/protocol"
)

type customFilesystem struct {
	fsType fs.FilesystemType
	uri    string
	root   CustomFileEntry
}

type customFile struct {
	info     *customFileWrapper
	position int64
	data     []byte
	mut      *sync.Mutex
}

type customFileWrapper struct {
	file     CustomFileEntry
	fullName string
}

// Swift-side interface
type CustomFileEntry interface {
	Name() string
	ChildCount() (int, error)
	ChildAt(index int) (CustomFileEntry, error)
	IsDir() bool
	Data() ([]byte, error)
	ModifiedTime() int64
	Bytes() (int, error)
}

type CustomFilesystemType interface {
	Root(uri string) (CustomFileEntry, error)
}

// The custom**-types should conform to the corresponding Syncthing filesystem interfaces
var _ fs.Filesystem = &customFilesystem{}
var _ fs.File = &customFile{}
var _ fs.FileInfo = &customFileWrapper{}

var errNotImplemented = errors.New("not implemented by custom filesystem")

func RegisterCustomFilesystemType(fsType string, fsHandler CustomFilesystemType) {
	fsTypeStruct := fs.FilesystemType(fsType)
	fs.RegisterFilesystemType(fsTypeStruct, func(uri string, _opts ...fs.Option) (fs.Filesystem, error) {
		root, err := fsHandler.Root(uri)
		if err != nil {
			return nil, err
		}

		return &customFilesystem{
			fsType: fsTypeStruct,
			uri:    uri,
			root:   root,
		}, nil
	})
}

func (p *customFilesystem) Roots() ([]string, error) {
	return []string{"/"}, nil
}

func (p *customFilesystem) Open(name string) (fs.File, error) {
	return p.OpenFile(name, os.O_RDONLY, 0)
}

func (p *customFilesystem) OpenFile(name string, flags int, mode fs.FileMode) (fs.File, error) {
	var item *customFileWrapper
	var err error
	if item, err = p.itemAt(name); err != nil {
		return nil, err
	}

	var data []byte
	if data, err = item.file.Data(); err != nil {
		return nil, err
	}

	return &customFile{info: item, data: data, mut: &sync.Mutex{}}, nil
}

func (p *customFilesystem) Glob(pattern string) ([]string, error) {
	panic("unimplemented")
}

func (p *customFilesystem) itemAt(path string) (*customFileWrapper, error) {
	parts := strings.Split(path, "/")

	item := p.root
	for _, p := range parts {
		if p == "." || p == "" {
			continue
		}

		childCount, err := item.ChildCount()
		if err != nil {
			return nil, err
		}

		if childCount == 0 || !item.IsDir() {
			return nil, fs.ErrNotExist
		}

		found := false
		for i := range childCount {
			child, err := item.ChildAt(i)
			if err != nil {
				return nil, err
			}

			if child.Name() == p {
				item = child
				found = true
				break
			}
		}

		if !found {
			return nil, fs.ErrNotExist
		}
	}

	return &customFileWrapper{file: item, fullName: path}, nil
}

func (p *customFilesystem) DirNames(name string) ([]string, error) {
	folder, err := p.itemAt((name))
	if err != nil {
		return nil, err
	}

	childCount, err := folder.file.ChildCount()
	if err != nil {
		return nil, err
	}

	names := make([]string, 0)
	for i := range childCount {
		child, err := folder.file.ChildAt(i)
		if err != nil {
			return nil, err
		}
		names = append(names, child.Name())
	}

	return names, nil
}

// Lstat is equal to Stat, except that when name refers to a symlink, Lstat returns data about the link, not the target
// We don't have links, so Stat == Lstat
func (p *customFilesystem) Lstat(name string) (fs.FileInfo, error) {
	return p.Stat(name)
}

func (p *customFilesystem) SameFile(fi1 fs.FileInfo, fi2 fs.FileInfo) bool {
	return fi1.Name() == fi2.Name()
}

func (p *customFilesystem) Stat(name string) (fs.FileInfo, error) {
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

func (p *customFilesystem) Usage(name string) (fs.Usage, error) {
	return fs.Usage{
		Free:  0,
		Total: 1,
	}, nil
}

func (p *customFilesystem) Walk(name string, walkFn fs.WalkFunc) error {
	// Implemented by Syncthing itself through WalkFS
	panic("unimplemented")
}

// We support no options
func (p *customFilesystem) Options() []fs.Option {
	return make([]fs.Option, 0)
}

func (p *customFilesystem) SymlinksSupported() bool {
	return false
}

func (p *customFilesystem) PlatformData(name string, withOwnership bool, withXattrs bool, xattrFilter fs.XattrFilter) (protocol.PlatformData, error) {
	return protocol.PlatformData{}, nil
}

func (p *customFilesystem) ReadSymlink(name string) (string, error) {
	return "", errNotImplemented
}

func (p *customFilesystem) Type() fs.FilesystemType {
	return p.fsType
}

func (p *customFilesystem) URI() string {
	return p.uri
}

// We don't have no xattrs
func (p *customFilesystem) GetXattr(name string, xattrFilter fs.XattrFilter) ([]protocol.Xattr, error) {
	return make([]protocol.Xattr, 0), nil
}

func (p *customFilesystem) Underlying() (fs.Filesystem, bool) {
	return nil, false
}

// Unimplemented parts of the Filesystem interface return an error. They should not normally be called
func (p *customFilesystem) Chmod(name string, mode fs.FileMode) error {
	return errNotImplemented
}

func (p *customFilesystem) Chtimes(name string, atime time.Time, mtime time.Time) error {
	return errNotImplemented
}

func (p *customFilesystem) Create(name string) (fs.File, error) {
	return nil, errNotImplemented
}

func (p *customFilesystem) CreateSymlink(target string, name string) error {
	return errNotImplemented
}

func (p *customFilesystem) Hide(name string) error {
	return errNotImplemented
}

func (p *customFilesystem) Lchown(name string, uid string, gid string) error {
	return errNotImplemented
}

func (p *customFilesystem) Mkdir(name string, perm fs.FileMode) error {
	return errNotImplemented
}

func (p *customFilesystem) MkdirAll(name string, perm fs.FileMode) error {
	return errNotImplemented
}

func (p *customFilesystem) Remove(name string) error {
	return errNotImplemented
}

func (p *customFilesystem) RemoveAll(name string) error {
	return errNotImplemented
}

func (p *customFilesystem) Rename(oldname string, newname string) error {
	return errNotImplemented
}

func (p *customFilesystem) SetXattr(path string, xattrs []protocol.Xattr, xattrFilter fs.XattrFilter) error {
	return errNotImplemented
}

func (p *customFilesystem) Unhide(name string) error {
	return errNotImplemented
}

func (p *customFilesystem) Watch(path string, ignore fs.Matcher, ctx context.Context, ignorePerms bool) (<-chan fs.Event, <-chan error, error) {
	return nil, nil, errNotImplemented
}

// Photo file implementation
func (p *customFile) Close() error {
	p.mut.Lock()
	defer p.mut.Unlock()
	p.position = 0
	return nil
}

func (p *customFile) Name() string {
	return p.info.fullName
}

func (cf *customFile) Read(p []byte) (n int, err error) {
	n, err = cf.ReadAt(p, cf.position)
	return
}

func (cf *customFile) ReadAt(p []byte, offset int64) (n int, err error) {
	cf.mut.Lock()
	defer cf.mut.Unlock()

	if offset >= int64(len(cf.data)) {
		return 0, io.EOF
	}

	n = copy(p, cf.data[int(offset):])
	cf.position = offset + int64(n)
	return n, nil
}

var errSeekBeforeStart = errors.New("seek before start")

func (cf *customFile) Seek(offset int64, whence int) (int64, error) {
	cf.mut.Lock()
	defer cf.mut.Unlock()

	size := cf.info.Size()

	switch whence {
	case io.SeekCurrent:
		cf.position += offset
	case io.SeekEnd:
		cf.position = size - offset
	case io.SeekStart:
		cf.position = offset
	}

	if cf.position < 0 {
		cf.position = 0
		return cf.position, errSeekBeforeStart
	}

	if cf.position > size {
		cf.position = size
		return cf.position, io.EOF
	}
	return cf.position, nil
}

// Stat implements fs.File.
func (p *customFile) Stat() (fs.FileInfo, error) {
	return p.info, nil
}

// Sync implements fs.File.
func (p *customFile) Sync() error {
	p.mut.Lock()
	defer p.mut.Unlock()
	return nil
}

// Unimplemented parts of fs.File for PhotoFile return an error
func (p *customFile) Truncate(size int64) error {
	return errNotImplemented
}

func (*customFile) Write(p []byte) (n int, err error) {
	return 0, errNotImplemented
}

func (*customFile) WriteAt(p []byte, off int64) (n int, err error) {
	return 0, errNotImplemented
}

// PhotoFileInfo implementation
func (p *customFileWrapper) Group() int {
	return 0
}

func (p *customFileWrapper) InodeChangeTime() time.Time {
	return time.Time{}
}

func (p *customFileWrapper) IsDir() bool {
	return p.file.IsDir()
}

func (p *customFileWrapper) IsRegular() bool {
	return !p.file.IsDir()
}

// We don't do symlinks
func (p *customFileWrapper) IsSymlink() bool {
	return false
}

func (p *customFileWrapper) ModTime() time.Time {
	return time.Unix(p.file.ModifiedTime(), 0)
}

func (p *customFileWrapper) Mode() fs.FileMode {
	if p.IsDir() {
		return 0555 // Read-only with execute bit to list dir
	}
	return 0444 // Read-only
}

func (p *customFileWrapper) Name() string {
	return p.file.Name()
}

func (p *customFileWrapper) Owner() int {
	return 0
}

func (p *customFileWrapper) Size() int64 {
	if p.IsDir() {
		return 0
	}

	size, err := p.file.Bytes()
	if err != nil {
		return -1
	}
	return int64(size)
}

func (p *customFileWrapper) Sys() interface{} {
	return nil
}
