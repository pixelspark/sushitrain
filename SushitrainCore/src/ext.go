package sushitrain

import (
	"github.com/syncthing/syncthing/lib/ext"
	"github.com/syncthing/syncthing/lib/fs"
)

func init() {
	ext.Callback = ExtCallbacks{}
}

type ExtCallbacks struct{}

func (e ExtCallbacks) ExtAccessPath(path string) string {
	return path
}

func (e ExtCallbacks) ExtCheckAvailableSpace(req uint64) bool {
	// Just use the regular mechanism?
	return true
}

// ExtNewFilesystem implements ext.ExtCallback.
func (e ExtCallbacks) ExtNewFilesystem(path string) fs.Filesystem {
	return nil
}
