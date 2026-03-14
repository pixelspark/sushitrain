// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"errors"
	"slices"
	"strings"

	"golang.org/x/exp/slog"
)

type Selection struct {
	lines []string
}

func NewSelection(lines []string) *Selection {
	return &Selection{
		lines: removeNestedSelections(lines),
	}
}

func removeNestedSelections(lines []string) []string {
	slices.Sort(lines)

	result := make([]string, 0)

	// FIXME: this is O(n^2).
	for _, line := range lines {
		foundIndex := slices.IndexFunc(lines, func(otherLine string) bool {
			return otherLine != line && strings.HasPrefix(line, otherLine)
		})

		// foundIndex, found := slices.BinarySearchFunc(lines, func(otherLine string) int {
		// 	if otherLine != line && strings.HasPrefix(otherLine, line) {
		// 		return 0
		// 	}
		// 	return strings.Compare(otherLine, line)
		// })

		if foundIndex >= 0 {
			// Some other line has this line as a prefix; skip it
			slog.Warn("selection contains a path that is also selected by a parent; removing", "prefix", lines[foundIndex], "path", line)
			continue
		}

		result = append(result, line)
	}
	return result
}

// Returns whether the provided set of ignore lines are valid for 'selective' mode
func (sel *Selection) isSelectiveIgnore() bool {
	if len(sel.lines) == 0 {
		return false
	}

	// All except the last pattern must start with '!', the last pattern must be  '*'
	for idx, pattern := range sel.lines {
		if idx == len(sel.lines)-1 {
			if pattern != "*" {
				return false
			}
		} else {
			if len(pattern) == 0 || pattern[0] != '!' {
				return false
			}
		}
	}

	return true
}

func (sel *Selection) Lines() []string {
	return removeNestedSelections(sel.lines)
}

func (sel *Selection) SetExplicitlySelected(paths map[string]bool) error {
	for path, selected := range paths {
		line := ignoreLineForSelectingPath(path)
		slog.Info("Edit ignore line", "selected", selected, "line", line)

		// Is this entry currently selected explicitly?
		currentlySelectedExplicitly := slices.Contains(sel.lines, line)
		if currentlySelectedExplicitly == selected {
			// not changing selecting status for path, it is the status quo
			continue
		}

		// Is this entry currently selected implicitly? (i.e. due to a parent path being selected)
		currentlySelectedImplicitly := slices.ContainsFunc(sel.lines, func(existingLine string) bool {
			return existingLine != line && strings.HasPrefix(line, existingLine)
		})
		if currentlySelectedImplicitly {
			return errors.New("cannot change selection: the path is already implicitly selected")
		}

		// Is this entry a prefix of another explicitly selected entry? Then refuse changes
		childrenSelectedImplicitly := slices.ContainsFunc(sel.lines, func(existingLine string) bool {
			return existingLine != line && strings.HasPrefix(existingLine, line)
		})
		if childrenSelectedImplicitly {
			return errors.New("cannot change selection: an item in this subdirectory is already selected")
		}

		// To deselect, remove the relevant ignore line
		countBefore := len(sel.lines)
		if !selected {
			sel.lines = Filter(sel.lines, func(l string) bool {
				return l != line
			})
			if len(sel.lines) != countBefore-1 {
				return errors.New("failed to remove ignore line: " + line)
			}
		} else {
			// To select, prepend it
			sel.lines = append([]string{line}, sel.lines...)
		}
	}
	return nil
}

func (sel *Selection) IsEntryExplicitlySelected(entry *Entry) bool {
	path := entry.info.FileName()
	return sel.IsPathExplicitlySelected(path)
}

func (sel *Selection) IsPathExplicitlySelected(path string) bool {
	ignoreLine := ignoreLineForSelectingPath(path)

	for _, line := range sel.lines {
		if len(line) > 0 && line[0] == '!' {
			if line == ignoreLine {
				return true
			}
		}
	}

	return false
}

func (sel *Selection) SelectedPaths() []string {
	paths := make([]string, 0)
	for _, pattern := range sel.lines {
		if len(pattern) > 0 && pattern[0] == '!' {
			paths = append(paths, pathForIgnoreLine(pattern))
		}
	}
	return paths
}

func (sel *Selection) FilterSelectedPaths(retain func(string) bool) {
	newLines := make([]string, 0)

	for _, pattern := range sel.lines {
		if len(pattern) > 0 && pattern[0] == '!' {
			if retain(pathForIgnoreLine(pattern)) {
				newLines = append(newLines, pattern)
			}
		} else {
			newLines = append(newLines, pattern)
		}
	}
	sel.lines = newLines
}

// Escape special characters: https://docs.syncthing.net/users/ignoring.html
var specialChars = []string{"\\", "!", "*", "?", "[", "]", "{", "}"}

// Generate a line for use in the .stignore file that selects the file at `path`. The path should *not* start with a slash.
func ignoreLineForSelectingPath(path string) string {
	for _, sp := range specialChars {
		path = strings.ReplaceAll(path, sp, "\\"+sp)
	}
	return "!/" + path
}

func pathForIgnoreLine(line string) string {
	line = strings.TrimPrefix(line, "!/")
	for _, sp := range specialChars {
		line = strings.ReplaceAll(line, "\\"+sp, sp)
	}
	return line
}
