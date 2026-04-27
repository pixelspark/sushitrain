// Copyright (C) 2024-2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"fmt"
	"slices"
	"strings"

	"github.com/gobwas/glob"
	"golang.org/x/exp/slog"
)

type Selection struct {
	lines []string
}

func NewSelection(lines []string) *Selection {
	sel := &Selection{
		lines: lines,
	}

	if sel.isSelectiveIgnore() {
		lines, err := cleanSelectiveSelection(sel.lines)
		if !sel.isSelectiveIgnore() || err != nil {
			panic("selective status changed after removeNestedSelections")
		}
		sel.lines = lines
	}

	return sel
}

func isCommentPattern(pattern string) bool {
	return len(pattern) == 0 || strings.HasPrefix(pattern, "//")
}

func cleanSelectiveSelection(lines []string) ([]string, error) {
	result := make([]string, 0)

	// First, find all selection patterns
	selectionPatterns := make([]string, 0)

	for idx, line := range lines {
		if idx == len(lines)-1 && line == "*" {
			continue
		} else if isSelectionPattern(line) {
			selectionPatterns = append(selectionPatterns, line)
		} else if IsGlobalIgnorePattern(line) {
			result = append(result, line)
		} else if isCommentPattern(line) {
			// Throw these out
			continue
		} else {
			return nil, fmt.Errorf("invalid pattern: %s", line)
		}
	}

	slices.Sort(selectionPatterns)

	// Write new ignore lines for selection patterns
	for _, line := range lines {
		if isSelectionPattern(line) {
			foundIndex := slices.IndexFunc(selectionPatterns, func(otherLine string) bool {
				return otherLine != line && strings.HasPrefix(line, otherLine)
			})

			if foundIndex >= 0 {
				// Some other line has this line as a prefix; skip it
				slog.Warn("selection contains a path that is also selected by a parent; removing", "prefix", lines[foundIndex], "path", line)
				continue
			}
			result = append(result, line)
		}
	}

	result = append(result, "*")
	return result, nil
}

// Returns whether the provided set of ignore lines are valid for 'selective' mode
func (sel *Selection) isSelectiveIgnore() bool {
	if len(sel.lines) == 0 {
		return false
	}

	// At the beginning, we allow zero or more patterns that start with "(?d)" and do not contain "*" or "/" (global ignores)
	// Then, we allow zero or more patterns that start with "!/" and do not contain '*' (selection patterns)
	// The last pattern must be  '*'
	inSelectionPatterns := false
	for idx, pattern := range sel.lines {
		// The last line must be "*"
		if idx == len(sel.lines)-1 {
			if pattern != "*" {
				return false
			}
		} else {
			if isCommentPattern(pattern) {
				continue
			} else if pattern[0] == '!' {
				// Allow patterns that start with '!/' and disallow global ignore patterns from that point onwards
				// These patterns may not contain '*'
				if !isSelectionPattern(pattern) {
					return false
				}
				inSelectionPatterns = true
			} else if IsGlobalIgnorePattern(pattern) {
				if inSelectionPatterns {
					return false
				} else {
					continue
				}
			} else {
				return false
			}
		}
	}

	return true
}

func isSelectionPattern(pattern string) bool {
	return strings.HasPrefix(pattern, "!/") && !strings.Contains(pattern, "*")
}

func IsGlobalIgnorePattern(pattern string) bool {
	return strings.HasPrefix(pattern, "(?d)") && !strings.Contains(pattern, "**") && !strings.Contains(pattern, "/")
}

func (sel *Selection) GlobalIgnorePatterns() []string {
	patterns := make([]string, 0)
	for _, pattern := range sel.lines {
		if IsGlobalIgnorePattern(pattern) {
			patterns = append(patterns, pathForIgnoreLine(pattern))
		}
	}
	return patterns
}

func (sel *Selection) SetGlobalIgnorePatterns(patterns []string) error {
	// Check whether the patterns supplied are valid global ignores
	for _, pattern := range patterns {
		if !IsGlobalIgnorePattern(pattern) {
			return fmt.Errorf("pattern is not a valid global ignore pattern: '%s'", pattern)
		}
	}

	// Build new list of patterns; start with the new global ignores, then append the existing patterns *except* the
	// old global ignores
	newSel := make([]string, 0)
	newSel = append(newSel, patterns...)
	for _, pattern := range sel.lines {
		if !IsGlobalIgnorePattern(pattern) {
			newSel = append(newSel, pattern)
		}
	}

	sel.lines = newSel
	return nil
}

func globPatternFromGlobalIgnorePattern(pattern string) string {
	return strings.TrimPrefix(pattern, "(?d)")
}

// Returns a set of globs that correspond to the global ignores in a selective folder.
func (sel *Selection) globalIgnoreGlobs() ([]glob.Glob, error) {
	globs := make([]glob.Glob, 0)

	for _, pattern := range sel.lines {
		if IsGlobalIgnorePattern(pattern) {
			globPattern := globPatternFromGlobalIgnorePattern(pattern)
			gl, err := glob.Compile(globPattern, '/')
			if err != nil {
				return nil, err
			}

			// Unrooted patterns in Syncthing will also match in subdirectories, therefore add a glob that also matches
			// these.
			glRecursive, err := glob.Compile("**/"+globPattern, '/')
			if err != nil {
				return nil, err
			}

			globs = append(globs, gl, glRecursive)
		}
	}

	return globs, nil
}

func (sel *Selection) IsGloballyIgnored(path string) (bool, error) {
	for _, pattern := range sel.lines {
		if IsGlobalIgnorePattern(pattern) {
			globPattern := globPatternFromGlobalIgnorePattern(pattern)
			gl, err := glob.Compile(globPattern, '/')
			if err != nil {
				return false, err
			}
			if gl.Match(path) {
				return true, nil
			}
		}
	}
	return false, nil
}

func (sel *Selection) Lines() []string {
	return sel.lines
}

func (sel *Selection) SetExplicitlySelected(paths map[string]bool) error {
	// This requires a (valid) selective ignore file
	if !sel.isSelectiveIgnore() {
		return fmt.Errorf("ignore file is not valid for selective sync")
	}

	globalIgnoreGlobs, err := sel.globalIgnoreGlobs()
	if err != nil {
		return fmt.Errorf("ignore file contains invalid global ignores: %w", err)
	}

	newLines := sel.lines

	for path, selectPath := range paths {
		line := ignoreLineForSelectingPath(path)
		slog.Info("Edit ignore line", "selected", selectPath, "line", line)

		// Is ths entry ignored and do we now want to select it? Then deny
		if selectPath {
			for _, globalIgnoreGlob := range globalIgnoreGlobs {
				if globalIgnoreGlob.Match(path) {
					slog.Warn("cannot select path because it is globally ignored", "path", path, "glob", globalIgnoreGlob)
					return fmt.Errorf("cannot select path '%s', because it is globally ignored", path)
				}
			}
		}

		// Is this entry currently selected explicitly?
		currentlySelectedExplicitly := slices.Contains(newLines, line)
		if currentlySelectedExplicitly == selectPath {
			// not changing selecting status for path, it is the status quo
			continue
		}

		// Is this entry currently selected implicitly? (i.e. due to a parent path being selected)
		currentlySelectedImplicitly := slices.ContainsFunc(newLines, func(existingLine string) bool {
			return existingLine != line && strings.HasPrefix(line, existingLine)
		})

		if currentlySelectedImplicitly {
			return fmt.Errorf("cannot change selection: the path '%s' is already implicitly selected", path)
		}

		// Is this entry a prefix of another explicitly selected entry? Then refuse changes
		childrenSelectedImplicitly := slices.ContainsFunc(newLines, func(existingLine string) bool {
			return existingLine != line && strings.HasPrefix(existingLine, line)
		})

		if childrenSelectedImplicitly {
			return fmt.Errorf("cannot change selection: an item in the subdirectory '%s' is already selected", path)
		}

		// To deselect, remove the relevant ignore line
		countBefore := len(newLines)
		if !selectPath {
			newLines = Filter(newLines, func(l string) bool {
				return l != line
			})
			if len(newLines) != countBefore-1 {
				return fmt.Errorf("failed to remove ignore line '%s'", line)
			}
		} else {
			// To select, append it (but before the last '*')
			slog.Info("adding", "before", newLines)
			newLines = append(newLines[:len(newLines)-1], line, "*")
			slog.Info("adding", "after", newLines)
		}
	}

	sel.lines = newLines

	// We should end up with a valid ignore file
	if !sel.isSelectiveIgnore() {
		panic("ignore file is not selective anymore after SetExplicitlySelected")
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
		// Filter patterns that start with '!', these are selection patterns
		if len(pattern) > 0 && pattern[0] == '!' {
			if retain(pathForIgnoreLine(pattern)) {
				newLines = append(newLines, pattern)
			}
		} else {
			// Allow any other pattern to remain
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
