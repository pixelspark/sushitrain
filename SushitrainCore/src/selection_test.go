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
		sel := NewSelection(ba[0])
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
		if !NewSelection(file).isSelectiveIgnore() {
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
		if NewSelection(file).isSelectiveIgnore() {
			t.Errorf("file is selective ignore: %s", file)
		}
	}
}
