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
)

type Selection struct {
	lines []string
}

func NewSelection(lines []string) *Selection {
	return &Selection{
		lines: lines,
	}
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
	return sel.lines
}

func (sel *Selection) SetExplicitlySelected(paths map[string]bool) error {
	for path, selected := range paths {
		line := ignoreLineForSelectingPath(path)
		Logger.Infof("Edit ignore line (%t): %s\n", selected, line)

		// Is this entry currently selected explicitly?
		currentlySelected := slices.Contains(sel.lines, line)
		if currentlySelected == selected {
			Logger.Debugln("not changing selecting status for path " + path + ": it is the status quo")
			continue
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
