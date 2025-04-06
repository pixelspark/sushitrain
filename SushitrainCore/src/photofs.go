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
}

var PhotoFilesystemType fs.FilesystemType = "sushitrain.photos.v1"
var notImplementedErr = errors.New("not implemented by photo filesystem")
var _ fs.Filesystem = PhotoFilesystem{}
var _ fs.File = PhotoFile{}

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
	return "", notImplementedErr
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
	return notImplementedErr
}

func (p PhotoFilesystem) Chtimes(name string, atime time.Time, mtime time.Time) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Create(name string) (fs.File, error) {
	return nil, notImplementedErr
}

func (p PhotoFilesystem) CreateSymlink(target string, name string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Hide(name string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Lchown(name string, uid string, gid string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Mkdir(name string, perm fs.FileMode) error {
	return notImplementedErr
}

func (p PhotoFilesystem) MkdirAll(name string, perm fs.FileMode) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Remove(name string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) RemoveAll(name string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Rename(oldname string, newname string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) SetXattr(path string, xattrs []protocol.Xattr, xattrFilter fs.XattrFilter) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Unhide(name string) error {
	return notImplementedErr
}

func (p PhotoFilesystem) Watch(path string, ignore fs.Matcher, ctx context.Context, ignorePerms bool) (<-chan fs.Event, <-chan error, error) {
	return nil, nil, notImplementedErr
}

// Photo file implementation
func (p PhotoFile) Close() error {
	return nil
}

// Name implements fs.File.
func (p PhotoFile) Name() string {
	panic("unimplemented")
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
	panic("unimplemented")
}

// Sync implements fs.File.
func (p PhotoFile) Sync() error {
	return nil
}

// Unimplemented parts of fs.File for PhotoFile return an error
func (p PhotoFile) Truncate(size int64) error {
	return notImplementedErr
}

func (PhotoFile) Write(p []byte) (n int, err error) {
	return 0, notImplementedErr
}

func (PhotoFile) WriteAt(p []byte, off int64) (n int, err error) {
	return 0, notImplementedErr
}
