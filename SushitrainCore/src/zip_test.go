package sushitrain

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

type testDownloadDelegate struct {
	progress []float64
	finished string
	err      string
}

func (t *testDownloadDelegate) IsCancelled() bool {
	return false
}

func (t *testDownloadDelegate) OnError(err string) {
	t.err = err
}

func (t *testDownloadDelegate) OnFinished(path string) {
	t.finished = path
}

func (t *testDownloadDelegate) OnProgress(fraction float64) {
	t.progress = append(t.progress, fraction)
}

func TestArchiveDirectoryDownloadHandlesImplicitSubdirectories(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)

	rootDir, err := writer.Create("foo/")
	if err != nil {
		t.Fatalf("Create root dir: %v", err)
	}
	if _, err := rootDir.Write(nil); err != nil {
		t.Fatalf("Write root dir: %v", err)
	}

	fileWriter, err := writer.Create("foo/bar/baz.txt")
	if err != nil {
		t.Fatalf("Create file: %v", err)
	}
	if _, err := fileWriter.Write([]byte("hello")); err != nil {
		t.Fatalf("Write file: %v", err)
	}

	if err := writer.Close(); err != nil {
		t.Fatalf("Close zip writer: %v", err)
	}

	reader, err := zip.NewReader(bytes.NewReader(buffer.Bytes()), int64(buffer.Len()))
	if err != nil {
		t.Fatalf("NewReader: %v", err)
	}

	archive := &entryArchive{files: reader.File}
	rootArchiveFile, err := archive.File("foo/")
	if err != nil {
		t.Fatalf("Archive.File(foo/): %v", err)
	}
	implicitDir, err := archive.File("foo/bar/")
	if err != nil {
		t.Fatalf("Archive.File(foo/bar/): %v", err)
	}
	if implicitDir.FileName() != "bar" {
		t.Fatalf("unexpected implicit directory name: %q", implicitDir.FileName())
	}

	tempDir := t.TempDir()
	delegate := &testDownloadDelegate{}
	rootArchiveFile.(*entryArchiveFile).downloadDirectory(filepath.Join(tempDir, "foo"), delegate)

	if delegate.err != "" {
		t.Fatalf("downloadDirectory returned error: %s", delegate.err)
	}

	if delegate.finished == "" {
		t.Fatal("downloadDirectory did not finish")
	}

	downloadedBytes, err := os.ReadFile(filepath.Join(tempDir, "foo", "bar", "baz.txt"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	if string(downloadedBytes) != "hello" {
		t.Fatalf("unexpected file contents: %q", string(downloadedBytes))
	}
}
