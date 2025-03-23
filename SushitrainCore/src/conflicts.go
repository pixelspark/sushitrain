// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"path/filepath"
	"regexp"
	"strings"
)

type Conflicts struct {
	conflictCopies      []string
	conflictsByOriginal map[string][]string
}

func isConflictPath(path string) bool {
	return strings.Contains(filepath.Base(path), ".sync-conflict-")
}

var conflictingFileNamePattern = regexp.MustCompile("\\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z]{7}")

func originalPathForConflictCopy(path string) string {
	return conflictingFileNamePattern.ReplaceAllLiteralString(path, "")
}

func (fld *Folder) ConflictsInSubdirectory(path string) (*Conflicts, error) {
	treeEntries, err := fld.listEntries(path, false, false)
	if err != nil {
		return nil, err
	}

	conflictCopies := make([]string, 0)
	conflictsByOriginal := make(map[string][]string, 0)

	for _, treeEntry := range treeEntries {
		if isConflictPath(treeEntry.Name) {
			fullPath := path + treeEntry.Name
			conflictCopies = append(conflictCopies, fullPath)
			originalPath := path + originalPathForConflictCopy(treeEntry.Name)
			if otherConflicts, ok := conflictsByOriginal[originalPath]; ok {
				otherConflicts = append(otherConflicts, fullPath)
				conflictsByOriginal[originalPath] = otherConflicts
			} else {
				conflictsByOriginal[originalPath] = []string{fullPath}
			}
		}
	}

	return &Conflicts{
		conflictCopies:      conflictCopies,
		conflictsByOriginal: conflictsByOriginal,
	}, nil
}

// Returns a list of all full paths of files in the same 'conflict group' (both the 'original file' as well as any
// conflict copies) when provided with a full path to either.
func (cf *Conflicts) ConflictSiblings(path string) *ListOfStrings {
	paths := make([]string, 0)

	if isConflictPath(path) {
		path = originalPathForConflictCopy(path)
	}
	paths = append(paths, path) // append the original path always

	if variants, ok := cf.conflictsByOriginal[path]; ok {
		if len(variants) == 0 {
			return List([]string{})
		}
		paths = append(paths, variants...)
	}

	return List(paths)
}

// Returns whether this file was created as a result of a conflict
func (entry *Entry) IsConflictCopy() bool {
	// Not perfect, but this is how Syncthing does it
	return strings.Contains(filepath.Base(entry.Name()), ".sync-conflict-")
}
