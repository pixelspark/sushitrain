package sushitrain

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// Inject access failures independently of the host user's filesystem privileges.
type ignoreAccessFilesystem struct {
	fs.Filesystem
	rootErr error
	openErr error
	statErr error
}

func (f *ignoreAccessFilesystem) DirNames(name string) ([]string, error) {
	if f.rootErr != nil {
		return nil, f.rootErr
	}
	return f.Filesystem.DirNames(name)
}
func (f *ignoreAccessFilesystem) Lstat(name string) (fs.FileInfo, error) {
	if f.statErr != nil {
		return nil, f.statErr
	}
	return f.Filesystem.Lstat(name)
}
func (f *ignoreAccessFilesystem) Open(name string) (fs.File, error) {
	if f.openErr != nil {
		return nil, f.openErr
	}
	return f.Filesystem.Open(name)
}
func (f *ignoreAccessFilesystem) OpenFile(name string, flags int, mode fs.FileMode) (fs.File, error) {
	if f.openErr != nil {
		return nil, f.openErr
	}
	return f.Filesystem.OpenFile(name, flags, mode)
}

func TestLoadIgnoreMatcherAccess(t *testing.T) {
	for _, tc := range []struct {
		name                       string
		contents                   string
		missingRoot, missingIgnore bool
		rootErr, openErr, statErr  error
		wantErr                    bool
		selective                  bool
	}{
		{name: "readable root without ignore file", missingIgnore: true},
		{name: "selective", contents: "!/keep\n*\n", selective: true},
		{name: "ordinary patterns", contents: "*.tmp\n"},
		{name: "missing root", missingRoot: true, missingIgnore: true, wantErr: true},
		{name: "root denied with absent ignore", missingIgnore: true, rootErr: os.ErrPermission, wantErr: true},
		{name: "ignore denied", contents: "*\n", openErr: os.ErrPermission, wantErr: true},
		{name: "metadata denied", statErr: os.ErrPermission, wantErr: true},
		{name: "missing include", contents: "#include missing\n", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			if tc.missingRoot {
				root = filepath.Join(root, "unmounted")
			}
			if !tc.missingIgnore {
				if err := os.WriteFile(filepath.Join(root, ignoreFileName), []byte(tc.contents), 0600); err != nil {
					t.Fatal(err)
				}
			}
			ffs := &ignoreAccessFilesystem{Filesystem: fs.NewFilesystem(fs.FilesystemTypeBasic, root), rootErr: tc.rootErr, openErr: tc.openErr, statErr: tc.statErr}
			matcher, err := loadIgnoreMatcher(ffs, &CachedIgnore{})
			if tc.wantErr {
				if err == nil || matcher != nil {
					t.Fatalf("expected unavailable matcher, got %v, %v", matcher, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got := newSelection(matcher.Lines()).isSelectiveIgnore(); got != tc.selective {
				t.Fatalf("selective = %v, want %v", got, tc.selective)
			}
		})
	}
}

func TestLoadIgnoreMatcherPermissionRecovery(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ignoreFileName), []byte("*\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ffs := &ignoreAccessFilesystem{Filesystem: fs.NewFilesystem(fs.FilesystemTypeBasic, root)}
	cache := &CachedIgnore{}
	if _, err := loadIgnoreMatcher(ffs, cache); err != nil {
		t.Fatal(err)
	}
	// Metadata and timestamps still work, but opening the cached file no longer does.
	ffs.openErr = os.ErrPermission
	if matcher, err := loadIgnoreMatcher(ffs, cache); !errors.Is(err, os.ErrPermission) || matcher != nil {
		t.Fatalf("expected permission error, got %v, %v", matcher, err)
	}
	ffs.openErr = nil
	matcher, err := loadIgnoreMatcher(ffs, cache)
	if err != nil {
		t.Fatal(err)
	}
	if !newSelection(matcher.Lines()).isSelectiveIgnore() {
		t.Fatal("selective mode did not recover")
	}
	if err := os.Remove(filepath.Join(root, ignoreFileName)); err != nil {
		t.Fatal(err)
	}
	matcher, err = loadIgnoreMatcher(ffs, cache)
	if err != nil {
		t.Fatal(err)
	}
	if len(matcher.Lines()) != 0 || cache.matcher != nil {
		t.Fatal("missing ignore file retained stale patterns")
	}
}

func TestIsSelectiveUnavailableClient(t *testing.T) {
	if mode, err := (&Folder{}).IsSelective(); mode != false || err == nil {
		t.Fatalf("got %v, %v", mode, err)
	}
}

func TestIsSelectiveRootRecovery(t *testing.T) {
	root := filepath.Join(t.TempDir(), "volume")
	cfg := config.New(protocol.EmptyDeviceID)
	cfg.Folders = []config.FolderConfiguration{{ID: "test", Path: root, FilesystemType: config.FilesystemTypeBasic}}
	client := &Client{
		config: config.Wrap("", cfg, protocol.EmptyDeviceID, events.NoopLogger),
		app:    &syncthing.App{Internals: &syncthing.Internals{}},
	}
	folder := &Folder{client: client, FolderID: "test"}
	if mode, err := folder.IsSelective(); mode != false || err == nil {
		t.Fatalf("missing root: got %v, %v", mode, err)
	}
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if mode, err := folder.IsSelective(); mode != false || err != nil {
		t.Fatalf("readable empty root: got %v, %v", mode, err)
	}
	if err := os.WriteFile(filepath.Join(root, ignoreFileName), []byte("*\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if mode, err := folder.IsSelective(); mode != true || err != nil {
		t.Fatalf("selective root: got %v, %v", mode, err)
	}
	if err := os.Rename(root, root+"-unmounted"); err != nil {
		t.Fatal(err)
	}
	if mode, err := folder.IsSelective(); mode != false || err == nil {
		t.Fatalf("unmounted cached root: got %v, %v", mode, err)
	}
	if err := os.Rename(root+"-unmounted", root); err != nil {
		t.Fatal(err)
	}
	if mode, err := folder.IsSelective(); mode != true || err != nil {
		t.Fatalf("remounted root: got %v, %v", mode, err)
	}
	folder.FolderID = "missing"
	if mode, err := folder.IsSelective(); mode != false || err == nil {
		t.Fatalf("missing configuration: got %v, %v", mode, err)
	}
}

func TestIsSelectiveUnsupportedFolderTypes(t *testing.T) {
	for _, folderType := range []config.FolderType{config.FolderTypeSendOnly, config.FolderTypeReceiveEncrypted} {
		cfg := config.New(protocol.EmptyDeviceID)
		cfg.Folders = []config.FolderConfiguration{{ID: "test", Path: filepath.Join(t.TempDir(), "absent"), Type: folderType, FilesystemType: config.FilesystemTypeBasic}}
		folder := &Folder{FolderID: "test", client: &Client{
			config: config.Wrap("", cfg, protocol.EmptyDeviceID, events.NoopLogger),
			app:    &syncthing.App{Internals: &syncthing.Internals{}},
		}}
		if mode, err := folder.IsSelective(); mode != false || err != nil {
			t.Fatalf("type %v: got %v, %v", folderType, mode, err)
		}
	}
}
