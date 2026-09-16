package sushitrain

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/ignore"
)

func TestCleanSelectionKeepsLastCopies(t *testing.T) {
	for _, keepLastCopy := range []bool{true, false} {
		name := "hard"
		if keepLastCopy {
			name = "keep last copy"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			paths := []string{
				"mixed/only-copy", "mixed/unknown", "mixed/deleted", "mixed/remote-copy", "mixed/keep",
				"redundant/nested/remote-copy", ".stversions/version", ".stfolder/marker", ".stignore", "custom-marker/data",
			}
			for _, path := range paths {
				absolute := filepath.Join(root, path)
				if err := os.MkdirAll(filepath.Dir(absolute), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(absolute, []byte("local contents"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.Mkdir(filepath.Join(root, "empty"), 0700); err != nil {
				t.Fatal(err)
			}
			ffs := fs.NewFilesystem(fs.FilesystemTypeBasic, root)
			matcher := ignore.New(ffs)
			if err := matcher.Parse(strings.NewReader("!/mixed/keep\n*\n"), ignoreFileName); err != nil {
				t.Fatal(err)
			}
			checked := make(map[string]bool)
			err := cleanSelection(ffs, matcher, "custom-marker", keepLastCopy, func(path string) (bool, error) {
				if !keepLastCopy {
					t.Fatal("hard cleanup must not require a peer copy")
				}
				checked[path] = true
				return strings.HasSuffix(path, "remote-copy"), nil
			})
			if err != nil {
				t.Fatal(err)
			}
			for _, path := range paths {
				wantPresent := strings.HasPrefix(path, ".st") || strings.HasPrefix(path, "custom-marker/") || path == "mixed/keep" || (keepLastCopy && !strings.HasSuffix(path, "remote-copy"))
				_, err := os.Lstat(filepath.Join(root, path))
				if wantPresent && err != nil {
					t.Errorf("lost protected file %s: %v", path, err)
				}
				if !wantPresent && !os.IsNotExist(err) {
					t.Errorf("file %s was not removed: %v", path, err)
				}
			}
			for _, path := range []string{"empty", "redundant"} {
				if _, err := ffs.Lstat(path); !fs.IsNotExist(err) {
					t.Errorf("empty directory %s remains: %v", path, err)
				}
			}
			if keepLastCopy {
				for _, path := range []string{"mixed/only-copy", "mixed/unknown", "mixed/deleted", "mixed/remote-copy", "redundant/nested/remote-copy"} {
					if !checked[path] {
						t.Errorf("did not check %s independently", path)
					}
				}
			}
		})
	}
}

func TestCleanSelectionAvailabilityErrorDoesNotDelete(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"a", "b"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("last copy"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	ffs := fs.NewFilesystem(fs.FilesystemTypeBasic, root)
	matcher := ignore.New(ffs)
	if err := matcher.Parse(strings.NewReader("*\n"), ignoreFileName); err != nil {
		t.Fatal(err)
	}
	unavailable := errors.New("peer availability unavailable")
	err := cleanSelection(ffs, matcher, ".stfolder", true, func(path string) (bool, error) {
		if path == "b" {
			return false, unavailable
		}
		return true, nil
	})
	if !errors.Is(err, unavailable) {
		t.Fatalf("got %v, want availability error", err)
	}
	for _, path := range []string{"a", "b"} {
		if _, err := ffs.Lstat(path); err != nil {
			t.Errorf("deleted %s before finishing availability checks: %v", path, err)
		}
	}
}
