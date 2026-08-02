package sushitrain

import (
	"os"
	"testing"
	"time"
)

type fakeISOFileInfo struct {
	name  string
	size  int64
	isDir bool
}

func (f fakeISOFileInfo) Name() string       { return f.name }
func (f fakeISOFileInfo) Size() int64        { return f.size }
func (f fakeISOFileInfo) Mode() os.FileMode  { return 0 }
func (f fakeISOFileInfo) ModTime() time.Time { return time.Time{} }
func (f fakeISOFileInfo) IsDir() bool        { return f.isDir }
func (f fakeISOFileInfo) Sys() any           { return nil }

func TestISOArchiveImplicitDirectoriesHaveTrailingSlash(t *testing.T) {
	archive := &isoArchive{
		files: []*isoArchiveFile{
			{fileInfo: fakeISOFileInfo{name: "foo", isDir: true}},
			{fileInfo: fakeISOFileInfo{name: "foo/bar/baz.txt", size: 5}},
		},
	}

	files, err := archive.Files("foo/")
	if err != nil {
		t.Fatalf("Files(foo/): %v", err)
	}

	if len(files.data) != 1 || files.data[0] != "foo/bar/" {
		t.Fatalf("unexpected child paths: %#v", files.data)
	}

	if !archive.IsDirectory("foo/bar/") {
		t.Fatal("implicit ISO directory should be recognized as a directory")
	}

	child, err := archive.File("foo/bar/")
	if err != nil {
		t.Fatalf("File(foo/bar/): %v", err)
	}

	if child.FileName() != "bar" {
		t.Fatalf("unexpected implicit directory name: %q", child.FileName())
	}
}
