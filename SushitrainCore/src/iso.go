// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/hooklift/iso9660"
	"golang.org/x/exp/maps"
	"golang.org/x/exp/slog"
)

type isoArchive struct {
	entry  *Entry
	puller *miniPuller
	mutex  sync.Mutex
	files  []*isoArchiveFile
}

type isoArchiveFile struct {
	archive  *isoArchive
	fileInfo os.FileInfo
}

var _ Archive = &isoArchive{}
var _ ArchiveFile = &isoArchiveFile{}

func NewISOArchive(entry *Entry, puller *miniPuller) *isoArchive {
	return &isoArchive{
		entry:  entry,
		puller: puller,
		mutex:  sync.Mutex{},
	}
}

func (ef *isoArchiveFile) name() string {
	return strings.TrimPrefix(ef.fileInfo.Name(), "/")
}

func (ea *isoArchive) reader(ctx context.Context) io.ReadSeeker {
	return newEntryReadSeeker(ea.entry.info, ea.puller, ea.entry, ctx, nil)
}

// Enumerate all files in this ISO archive
func (ea *isoArchive) allFiles() ([]*isoArchiveFile, error) {
	ea.mutex.Lock()
	defer ea.mutex.Unlock()

	if ea.files == nil {
		files := make([]*isoArchiveFile, 0)

		ctx := context.Background()
		ers := ea.reader(ctx)
		isoReader, err := iso9660.NewReader(ers)
		if err != nil {
			slog.Warn("ISO archive newReader failed", "cause", err)
			return nil, err
		}

		for {
			isoFile, err := isoReader.Next()
			if err == io.EOF {
				break
			}

			if err != nil {
				slog.Warn("ISO archive read failed", "cause", err)
				return nil, err
			}

			files = append(files, &isoArchiveFile{
				archive:  ea,
				fileInfo: isoFile,
			})
		}

		ea.files = files
	}

	return ea.files, nil
}

// File implements [Archive].
func (ea *isoArchive) File(path string) (ArchiveFile, error) {
	if strings.HasSuffix(path, "/") {
		return nil, fmt.Errorf("ISO archive file request path cannot end in slash: %s", path)
	}
	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	for _, fi := range files {
		if fi.name() == path {
			return fi, nil
		}
	}
	return nil, errors.New("file not found in archive")
}

// Files implements [Archive].
func (ea *isoArchive) Files(prefix string) (*ListOfStrings, error) {
	if len(prefix) > 0 && prefix[(len(prefix)-1):] != "/" {
		prefix = prefix + "/"
		// return nil, errors.New("prefix must end in a slash")
	}

	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	matches := map[string]struct{}{}
	for _, file := range files {
		fileName := file.name()
		if strings.HasPrefix(fileName, prefix) {
			if len(fileName) < len(prefix)+1 {
				continue
			}

			// Just one level
			if strings.Contains(fileName[len(prefix):len(fileName)-1], "/") {
				// In some archives, 'a/b/c.ext' appears without separate entries for 'a/' and 'a/b/'
				// Therefore, do add the 'a/' to the list here in case we see 'a/b/c.ext'.
				// If 'a/' has its own entry, it will be double (but we fix that by using a set)
				suffix := fileName[len(prefix):]
				suffixParts := strings.Split(suffix, "/")
				if len(suffixParts) > 0 && len(suffixParts[0]) > 0 {
					var subDirPath = suffixParts[0]
					if prefix != "" {
						// When filled the prefix ends in '/'
						subDirPath = prefix + subDirPath
					}
					matches[subDirPath] = struct{}{}
				}
				continue
			}
			matches[fileName] = struct{}{}
		}
	}
	return List(maps.Keys(matches)), nil
}

// IsDirectory implements [Archive].
func (ea *isoArchive) IsDirectory(path string) bool {
	file, err := ea.File(path)
	if err != nil {
		return false
	}
	return file.(*isoArchiveFile).fileInfo.IsDir()
}

// Name implements [Archive].
func (ea *isoArchive) Name() string {
	return ea.entry.FileName()
}

// FileName implements [ArchiveFile].
func (ea *isoArchiveFile) FileName() string {
	// Subdirectory entries have a slash at the end, if we don't trim that the file name will be ""
	path := strings.TrimSuffix(ea.fileInfo.Name(), "/")
	ps := strings.Split(path, "/")
	return ps[len(ps)-1]
}

// Size implements [ArchiveFile].
func (ea *isoArchiveFile) Size() int64 {
	if ea.fileInfo.IsDir() {
		return 0
	}
	return ea.fileInfo.Size()
}

// AsDownloadable implements [ArchiveFile].
func (ea *isoArchiveFile) AsDownloadable() Downloadable {
	return ea
}

// Download implements [ArchiveFile].
func (ea *isoArchiveFile) Download(toPath string, delegate DownloadDelegate) {
	go func() {
		if ea.fileInfo.IsDir() {
			// Enumerate all files in this directory and run downloadFile on them
			delegate.OnProgress(0.0)
			ea.downloadDirectory(toPath, delegate)
		} else {
			ea.downloadFile(toPath, delegate)
		}
	}()
}

/** Recursively download the directory to the spcified location */
func (ea *isoArchiveFile) downloadDirectory(toPath string, delegate DownloadDelegate) {
	ea.archive.downloadDirectoryPath(ea.name(), toPath, delegate)
}

func (ea *isoArchive) downloadDirectoryPath(archivePath string, toPath string, delegate DownloadDelegate) {
	childPaths, err := ea.Files(archivePath)
	if err != nil {
		delegate.OnError(err.Error())
		return
	}

	err = os.MkdirAll(toPath, 0o700)
	if err != nil {
		delegate.OnError(err.Error())
		return
	}

	entryCount := len(childPaths.data)
	perEntryFraction := 1.0 / float64(entryCount)

	for pathIndex, path := range childPaths.data {
		strippedPath, found := strings.CutPrefix(path, archivePath)
		if !found {
			slog.Warn("invalid prefix", "path", path, "self", archivePath)
			return
		}

		entryToPath := filepath.Join(toPath, strippedPath)

		var failed = false
		subDelegate := &subDownloadDelegate{
			parent: delegate,
			errorCallback: func(err string) {
				if !failed {
					failed = true
					slog.Warn("iso file download failed", "error", err)
					delegate.OnError(err)
				}
			},
			progressCallback: func(fraction float64) {
				delegate.OnProgress((float64(pathIndex) + fraction) * perEntryFraction)
			},
		}

		if strings.HasSuffix(path, "/") {
			ea.downloadDirectoryPath(path, entryToPath, subDelegate)
		} else {
			archiveFile, err := ea.File(path)
			if err != nil {
				delegate.OnError(err.Error())
				return
			}
			archiveEntry := archiveFile.(*isoArchiveFile)
			archiveEntry.downloadFile(entryToPath, subDelegate)
		}

		if failed {
			return
		}

		delegate.OnProgress(float64(pathIndex+1) / float64(entryCount))
	}

	delegate.OnFinished(toPath)
}

func (ea *isoArchiveFile) reader() (io.Reader, error) {
	if ea.fileInfo.IsDir() || ea.fileInfo.Size() == 0 {
		return nil, errors.New("file is empty or a directory")
	}

	ctx := context.Background()
	ers := ea.archive.reader(ctx)
	isoReader, err := iso9660.NewReader(ers)
	if err != nil {
		return nil, err
	}

	for {
		isoFile, err := isoReader.Next()
		if err == io.EOF {
			break
		}

		if err != nil {
			slog.Warn("ISO archive read failed", "cause", err)
			return nil, err
		}

		if isoFile.Name() == ea.fileInfo.Name() {
			fileReader := isoFile.Sys()
			if fileReader == nil {
				return nil, errors.New("file reader is nil")
			}
			return fileReader.(io.Reader), nil
		}
	}

	return nil, errors.New("file not found")
}

func (ea *isoArchiveFile) downloadFile(toPath string, delegate DownloadDelegate) {
	// Create file to download to
	outFile, err := os.Create(toPath)
	if err != nil {
		delegate.OnError("could not open file from ISO for downloading to: " + err.Error())
		return
	}
	// close fi on exit and check for its returned error
	defer func() {
		if err := outFile.Close(); err != nil {
			panic(err)
		}
	}()

	delegate.OnProgress(0.0)

	reader, err := ea.reader()
	if err != nil {
		delegate.OnError("could not read ISO file: " + err.Error())
		return
	}

	cReader := cancelableReader{
		reader:     reader,
		delegate:   delegate,
		totalBytes: uint64(ea.fileInfo.Size()),
		readBytes:  0,
	}
	_, err = io.Copy(outFile, &cReader)
	if err != nil {
		delegate.OnError("could not open file for downloading to: " + err.Error())
		return
	}
	delegate.OnFinished(toPath)
}
