// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
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
