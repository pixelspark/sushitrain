package sushitrain

import (
	"slices"
	"testing"
)

func TestRemoveNested(t *testing.T) {
	beforeAfter := [][][]string{
		[][]string{
			[]string{"!/a", "!/a/b", "*"}, []string{"!/a", "*"},
			[]string{"!/a", "!/a", "*"}, []string{"!/a", "*"},
			[]string{"!/a", "!/a", "!/a/b", "*"}, []string{"!/a", "*"},
			[]string{"(?d).DS_Store", "!/a", "!/a", "!/a/b", "*"}, []string{"!/a", "*"},
		},
	}

	for _, ba := range beforeAfter {
		sel := newSelection(ba[0])
		if !slices.Equal(sel.lines, ba[1]) {
			t.Errorf("mismatch: %s %s", sel.lines, ba[1])
		}
	}
}

func TestIsSelective(t *testing.T) {
	goodFiles := [][]string{
		[]string{"*"},
		[]string{"!/a", "*"},
		[]string{"!/a", "", "!/b", "*"},
		[]string{"(?d).DS_Store", "!/2016-02-13", "!/b", "*"},
		[]string{"(?d).DS_Store", "!/2016-02-13", "!/b", "!/b/c", "*"},
		[]string{"(?d).DS_Store", "!/2016-02-13", "!/b", "// some comment in between", "!/b/c", "*"},
	}

	for _, file := range goodFiles {
		if !newSelection(file).isSelectiveIgnore() {
			t.Errorf("file is not selective ignore: %s", file)
		}
	}

	badFiles := [][]string{
		[]string{""},
		[]string{"!a", "*"},
		[]string{"!/a", "*", "// last line cant be a comment"},
		[]string{"!/a", "", "b", "*"},
		[]string{"(?d).DS_Store", "!/2016-02-13", "(?d)*.txt", "!/b", "*"},
		[]string{"(?d).DS_Store", "!/2016-02-13", "(?d)**s/*.txt", "!/b", "*"},
	}

	for _, file := range badFiles {
		if newSelection(file).isSelectiveIgnore() {
			t.Errorf("file is selective ignore: %s", file)
		}
	}
}

func TestChanges(t *testing.T) {
	lines := []string{"(?d).DS_Store", "(?d)*.json", "(?d)*.json", "!/a/b", "*"}

	sel := newSelection(lines)
	if !sel.isSelectiveIgnore() {
		t.Errorf("file is not selective ignore but it should be")
	}

	// Remove invalid file selection and check if we are still selective
	sel.setExplicitlySelected(map[string]bool{
		"!/x/y/z": false,
	})

	if !sel.isSelectiveIgnore() {
		t.Errorf("file is not selective ignore after change 1 but it should be")
	}

	// Remove file selection and check if we are still selective
	sel.setExplicitlySelected(map[string]bool{
		"!/a/b": false,
	})

	if !sel.isSelectiveIgnore() {
		t.Errorf("file is not selective ignore after change 2 but it should be")
	}

	// Add a file selection and check if we are still selective
	sel.setExplicitlySelected(map[string]bool{
		"!/q/w/e/r": true,
	})

	if !sel.isSelectiveIgnore() {
		t.Errorf("file is not selective ignore after change 3 but it should be")
	}

	// Set global patterns and check if we are still selective
	err := sel.setGlobalIgnorePatterns([]string{"(?d)*.json", "(?d)*.txt", "(?d).DS_Store"})
	if err != nil {
		t.Errorf("SetGlobalIgnorePatterns failed: %e", err)
	}

	if !sel.isSelectiveIgnore() {
		t.Errorf("file is not selective ignore after change 4 but it should be")
	}
}
