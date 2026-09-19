package sushitrain

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/ignore"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/versioner"
)

type testTrash struct {
	mu    sync.Mutex
	root  string
	paths []string
	err   error
}

func (h *testTrash) Trash(path string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return h.err
	}
	dest := filepath.Join(h.root, fmt.Sprint(len(h.paths)))
	if err := os.Rename(path, dest); err != nil {
		return err
	}
	h.paths = append(h.paths, path)
	return nil
}

func installTestTrash(t *testing.T) *testTrash {
	t.Helper()
	h := &testTrash{root: t.TempDir()}
	systemTrash.RLock()
	previous := systemTrash.handler
	systemTrash.RUnlock()
	RegisterTrashHandler(h)
	t.Cleanup(func() { RegisterTrashHandler(previous) })
	return h
}

func writeTrashTestFile(t *testing.T, root, name string) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(name), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestTrashFilesystemRemoval(t *testing.T) {
	h := installTestTrash(t)
	root := t.TempDir()
	ffs := fs.NewFilesystem(filesystemTypeTrash, root)
	writeTrashTestFile(t, root, "dir/file")
	if err := ffs.Remove("dir"); err == nil {
		t.Fatal("Remove must reject a nonempty directory")
	}
	if err := ffs.Remove("dir/file"); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(h.root, "0")); err != nil || string(data) != "dir/file" {
		t.Fatalf("contents not recoverable: %q, %v", data, err)
	}
	if err := ffs.Remove("dir"); err != nil {
		t.Fatal(err)
	}
	if len(h.paths) != 1 {
		t.Fatalf("empty directory was trashed: %v", h.paths)
	}
	if err := ffs.Remove("missing"); !fs.IsNotExist(err) {
		t.Fatalf("Remove missing: %v", err)
	}
	if err := ffs.RemoveAll("missing/child"); err != nil {
		t.Fatalf("RemoveAll missing: %v", err)
	}
	writeTrashTestFile(t, root, "tree/child")
	if err := ffs.RemoveAll("tree"); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(h.root, "1", "child")); err != nil || string(data) != "tree/child" {
		t.Fatalf("subtree not recoverable: %q, %v", data, err)
	}
	writeTrashTestFile(t, root, "root-child")
	if err := ffs.RemoveAll(""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(h.root, "2", "root-child")); err != nil {
		t.Fatalf("root not recoverable: %v", err)
	}
}

func TestTrashFilesystemInternalCleanup(t *testing.T) {
	h := installTestTrash(t)
	root := t.TempDir()
	ffs := fs.NewFilesystem(filesystemTypeTrash, root)
	for _, name := range []string{".stignore", ".stfolder/marker", ".stversions/old", fs.TempName("dir/file"), "dir/~syncthing~file.tmp"} {
		writeTrashTestFile(t, root, name)
		if err := ffs.Remove(name); err != nil {
			t.Fatal(err)
		}
	}
	writeTrashTestFile(t, root, ".stversions/nested/old")
	if err := ffs.RemoveAll(".stversions"); err != nil {
		t.Fatal(err)
	}
	if len(h.paths) != 0 {
		t.Fatalf("internal cleanup polluted Trash: %v", h.paths)
	}
	// Hidden user files are still protected.
	writeTrashTestFile(t, root, ".notes")
	if err := ffs.Remove(".notes"); err != nil || len(h.paths) != 1 {
		t.Fatalf("hidden user file: %v, %v", err, h.paths)
	}
}

func TestTrashFilesystemCaseChecksAndConcurrentRemoval(t *testing.T) {
	h := installTestTrash(t)
	root := t.TempDir()
	ffs := fs.NewFilesystem(filesystemTypeTrash, root, new(fs.OptionDetectCaseConflicts))
	writeTrashTestFile(t, root, "MixedCase")
	if err := ffs.Remove("mixedcase"); !fs.IsErrCaseConflict(err) {
		t.Fatalf("case checking was bypassed: %v", err)
	}
	if _, err := ffs.Lstat("MixedCase"); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := range 12 {
		name := fmt.Sprintf("file-%d", i)
		writeTrashTestFile(t, root, name)
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := ffs.Remove(name); err != nil {
				t.Errorf("concurrent remove: %v", err)
			}
		}()
	}
	wg.Wait()
	if len(h.paths) != 12 {
		t.Fatalf("lost concurrent deletions: %v", h.paths)
	}
}

func TestTrashFilesystemFailureKeepsFiles(t *testing.T) {
	h := installTestTrash(t)
	root := t.TempDir()
	ffs := fs.NewFilesystem(filesystemTypeTrash, root)
	writeTrashTestFile(t, root, "file")
	h.err = errors.New("Trash unavailable on this volume")
	for _, remove := range []func(string) error{ffs.Remove, ffs.RemoveAll} {
		if err := remove("file"); !errors.Is(err, h.err) {
			t.Fatalf("lost native error: %v", err)
		}
		if _, err := ffs.Lstat("file"); err != nil {
			t.Fatal("failed trash permanently removed file")
		}
	}
	RegisterTrashHandler(nil)
	if err := ffs.Remove("file"); err == nil {
		t.Fatal("missing bridge allowed deletion")
	}
	if _, err := ffs.Lstat("file"); err != nil {
		t.Fatal(err)
	}
}

func TestTrashFilesystemSymlinksAndTraversal(t *testing.T) {
	h := installTestTrash(t)
	root, outside := t.TempDir(), t.TempDir()
	ffs := fs.NewFilesystem(filesystemTypeTrash, root)
	writeTrashTestFile(t, outside, "keep")
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"../keep", "..", filepath.Join(outside, "keep"), "link/keep"} {
		for _, remove := range []func(string) error{ffs.Remove, ffs.RemoveAll} {
			if err := remove(name); err == nil {
				t.Errorf("accepted unsafe path %q", name)
			}
		}
	}
	if err := ffs.Remove("link"); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(filepath.Join(h.root, "0")); err != nil || target != outside {
		t.Fatalf("symlink was not preserved: %q, %v", target, err)
	}
	if _, err := os.Stat(filepath.Join(outside, "keep")); err != nil {
		t.Fatalf("symlink target changed: %v", err)
	}
}

func TestTrashFilesystemVersioning(t *testing.T) {
	for _, external := range []bool{false, true} {
		t.Run(fmt.Sprint(external), func(t *testing.T) {
			h := installTestTrash(t)
			root := t.TempDir()
			archive := filepath.Join(root, ".stversions")
			cfg := config.FolderConfiguration{ID: "test", Path: root, FilesystemType: filesystemTypeTrash}
			cfg.Versioning.Type = "trashcan"
			cfg.Versioning.Params = map[string]string{"cleanoutDays": "1"}
			if external {
				archive = t.TempDir()
				cfg.Versioning.FSType = config.FilesystemTypeBasic
				cfg.Versioning.FSPath = archive
			}
			v, err := versioner.New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			writeTrashTestFile(t, root, "file")
			if err := v.Archive("file"); err != nil {
				t.Fatal(err)
			}
			if data, err := os.ReadFile(filepath.Join(archive, "file")); err != nil || string(data) != "file" {
				t.Fatalf("archive not recoverable: %q, %v", data, err)
			}
			old := time.Now().Add(-48 * time.Hour)
			if err := os.Chtimes(filepath.Join(archive, "file"), old, old); err != nil {
				t.Fatal(err)
			}
			if err := v.Clean(context.Background()); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(archive, "file")); !os.IsNotExist(err) {
				t.Fatalf("expired version retained: %v", err)
			}
			if len(h.paths) != 0 {
				t.Fatalf("versioning polluted Trash: %v", h.paths)
			}
		})
	}
}

func TestTrashSelectionCleanup(t *testing.T) {
	h := installTestTrash(t)
	root := t.TempDir()
	ffs := fs.NewFilesystem(filesystemTypeTrash, root)
	for _, name := range []string{"dir/last-copy", "dir/remote-copy"} {
		writeTrashTestFile(t, root, name)
	}
	matcher := ignore.New(ffs)
	if err := matcher.Parse(strings.NewReader("*\n"), ignoreFileName); err != nil {
		t.Fatal(err)
	}
	if err := cleanSelection(ffs, matcher, ".stfolder", true, func(name string) (bool, error) {
		return name == "dir/remote-copy", nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := ffs.Lstat("dir/last-copy"); err != nil {
		t.Fatalf("lost last copy: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(h.root, "0")); err != nil || string(data) != "dir/remote-copy" {
		t.Fatalf("deselected file not recoverable: %q, %v", data, err)
	}
	h.err = errors.New("native trash failure")
	if err := cleanSelection(ffs, matcher, ".stfolder", false, nil); !errors.Is(err, h.err) {
		t.Fatalf("cleanup swallowed failure: %v", err)
	}
}

func newTrashTestFolder(t *testing.T) *Folder {
	t.Helper()
	cfg := config.New(protocol.EmptyDeviceID)
	cfg.Folders = []config.FolderConfiguration{{ID: "test", Path: t.TempDir(), FilesystemType: config.FilesystemTypeBasic}}
	wrapper := config.Wrap(filepath.Join(t.TempDir(), "config.xml"), cfg, protocol.EmptyDeviceID, events.NoopLogger)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = wrapper.Serve(ctx)
	}()
	t.Cleanup(func() { cancel(); <-done })
	return &Folder{client: &Client{config: wrapper}, FolderID: "test"}
}

func TestTrashFolderConfiguration(t *testing.T) {
	h := installTestTrash(t)
	folder := newTrashTestFolder(t)
	if folder.IsTrashEnabled() || !folder.IsNativeFilesystem() {
		t.Fatal("incorrect default")
	}
	for _, enabled := range []bool{true, false, true} {
		if err := folder.SetTrashEnabled(enabled); err != nil {
			t.Fatal(err)
		}
		if folder.IsTrashEnabled() != enabled || !folder.IsNativeFilesystem() {
			t.Fatal("incorrect setting")
		}
		root, err := folder.LocalNativePath()
		if err != nil {
			t.Fatal(err)
		}
		// Configuration serialization must recreate the appropriate filesystem.
		file, err := os.Open(folder.client.config.ConfigPath())
		if err != nil {
			t.Fatal(err)
		}
		loaded, _, err := config.ReadXML(file, protocol.EmptyDeviceID)
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
		writeTrashTestFile(t, root, "file")
		before := len(h.paths)
		if err := loaded.Folders[0].Filesystem().Remove("file"); err != nil {
			t.Fatal(err)
		}
		if (len(h.paths) > before) != enabled {
			t.Fatal("saved configuration lost trash preference")
		}
	}
}

func TestTrashFolderRejectsVirtualFilesystem(t *testing.T) {
	folder := newTrashTestFolder(t)
	if err := folder.changeFolderConfiguration(func(fc *config.FolderConfiguration) {
		fc.FilesystemType = "photos"
	}); err != nil {
		t.Fatal(err)
	}
	if err := folder.SetTrashEnabled(true); err == nil {
		t.Fatal("enabled native Trash on a virtual filesystem")
	}
	if folder.IsNativeFilesystem() || folder.FilesystemType() != "photos" {
		t.Fatal("changed virtual filesystem")
	}
}

func TestTrashFolderRemovalFailureCanRetry(t *testing.T) {
	h := installTestTrash(t)
	folder := newTrashTestFolder(t)
	if err := folder.SetTrashEnabled(true); err != nil {
		t.Fatal(err)
	}
	root, _ := folder.LocalNativePath()
	writeTrashTestFile(t, root, "file")
	h.err = errors.New("trash unavailable")
	if err := folder.Remove(); !errors.Is(err, h.err) {
		t.Fatalf("lost failure: %v", err)
	}
	if !folder.Exists() || !folder.IsPaused() {
		t.Fatal("failed folder removal must remain configured and paused")
	}
	if _, err := os.Stat(filepath.Join(root, "file")); err != nil {
		t.Fatal(err)
	}
	h.err = nil
	if err := folder.Remove(); err != nil {
		t.Fatal(err)
	}
	if folder.Exists() {
		t.Fatal("successful folder removal retained configuration")
	}
	if _, err := os.Stat(filepath.Join(h.root, "0", "file")); err != nil {
		t.Fatalf("folder not recoverable: %v", err)
	}
}
