// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"archive/zip"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"golang.org/x/exp/maps"
	"golang.org/x/exp/slog"
)

type ArchiveFile interface {
	Downloadable
	AsDownloadable() Downloadable
	Size() int64
}

type archiveFileInternal interface {
	reader() (io.Reader, error)
}

type Archive interface {
	Files(prefix string) (*ListOfStrings, error)
	IsDirectory(path string) bool
	Name() string
	File(path string) (ArchiveFile, error)
}

type entryArchiveFile struct {
	archive *entryArchive
	file    *zip.File
}

type archiveDirectoryFile struct {
	archive *entryArchive
	path    string
}

type entryArchive struct {
	entry  *Entry
	puller *miniPuller
	mutex  sync.Mutex
	files  []*zip.File
}

func (e *Entry) IsArchive() bool {
	return e.MIMEType() == "application/zip"
}

func (e *Entry) Archive() Archive {
	return &entryArchive{
		entry:  e,
		puller: newMiniPuller(e.Folder.client.Measurements, e.Folder.client.app.Internals),
		mutex:  sync.Mutex{},
		files:  nil,
	}
}

func (ea *entryArchive) Name() string {
	return ea.entry.FileName()
}

func (ea *entryArchive) Files(prefix string) (*ListOfStrings, error) {
	if len(prefix) > 0 && prefix[(len(prefix)-1):] != "/" {
		return nil, errors.New("prefix must end in a slash")
	}

	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	matches := map[string]struct{}{}
	for _, file := range files {
		if strings.HasPrefix(file.Name, prefix) {
			if len(file.Name) < len(prefix)+1 {
				continue
			}

			// Just one level
			if strings.Contains(file.Name[len(prefix):len(file.Name)-1], "/") {
				// In some archives, 'a/b/c.ext' appears without separate entries for 'a/' and 'a/b/'
				// Therefore, do add the 'a/' to the list here in case we see 'a/b/c.ext'.
				// If 'a/' has its own entry, it will be double (but we fix that by using a set)
				suffix := file.Name[len(prefix):]
				suffixParts := strings.Split(suffix, "/")
				if len(suffixParts) > 0 && len(suffixParts[0]) > 0 {
					var subDirPath = suffixParts[0] + "/"
					if prefix != "" {
						// When filled the prefix ends in '/'
						subDirPath = prefix + subDirPath
					}
					matches[subDirPath] = struct{}{}
				}
				continue
			}
			matches[file.Name] = struct{}{}
		}
	}
	return List(maps.Keys(matches)), nil
}

func (ea *entryArchive) File(path string) (ArchiveFile, error) {
	files, err := ea.allFiles()
	if err != nil {
		return nil, err
	}

	for _, fi := range files {
		if fi.Name == path {
			return &entryArchiveFile{
				file:    fi,
				archive: ea,
			}, nil
		}
	}

	if ea.IsDirectory(path) {
		childPaths, err := ea.Files(path)
		if err != nil {
			return nil, err
		}
		if len(childPaths.data) > 0 {
			return &archiveDirectoryFile{
				archive: ea,
				path:    path,
			}, nil
		}
	}
	return nil, errors.New("file not found in archive")
}

func (ea *entryArchive) IsDirectory(path string) bool {
	// Paths that end in a slash are directories
	return len(path) > 0 && path[len(path)-1:] == "/"
}

func (ea *entryArchive) allFiles() ([]*zip.File, error) {
	ea.mutex.Lock()
	defer ea.mutex.Unlock()

	if ea.files == nil {
		reader, err := zip.NewReader(ea, ea.entry.Size())
		if err != nil {
			return nil, err
		}
		ea.files = reader.File
	}

	return ea.files, nil
}

// ReadAt implements io.ReaderAt.
func (ea *entryArchive) ReadAt(p []byte, off int64) (n int, err error) {
	if buffer, err := ea.entry.FetchLocal(off, int64(len(p))); err == nil {
		// We have this file completely locally
		copy(p, buffer)
		return len(buffer), nil
	}

	xn, err := ea.puller.downloadRange(context.Background(), ea.entry.Folder.client.app.Internals, ea.entry.Folder.FolderID, ea.entry.info, p, off)
	return int(xn), err
}

func (ea *entryArchiveFile) FileName() string {
	// Subdirectory entries have a slash at the end, if we don't trim that the file name will be ""
	path := strings.TrimSuffix(ea.file.Name, "/")
	ps := strings.Split(path, "/")
	return ps[len(ps)-1]
}

func (ea *entryArchiveFile) Download(toPath string, delegate DownloadDelegate) {
	go func() {
		if ea.file.FileInfo().IsDir() {
			// Enumerate all files in this directory and run downloadFile on them
			delegate.OnProgress(0.0)
			ea.downloadDirectory(toPath, delegate)
		} else {
			ea.downloadFile(toPath, delegate)
		}
	}()
}

/** Recursively download the directory to the spcified location */
func (ea *entryArchiveFile) downloadDirectory(toPath string, delegate DownloadDelegate) {
	ea.archive.downloadDirectoryPath(ea.file.Name, toPath, delegate)
}

func (ea *entryArchive) downloadDirectoryPath(archivePath string, toPath string, delegate DownloadDelegate) {
	childPaths, err := ea.Files(archivePath)
	if err != nil {
		delegate.OnError(err.Error())
		return
	}
	slog.Info("zip downloadDirectory", "toPath", toPath, "childPaths", childPaths)

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
		slog.Info("zip entry", "path", path, "strippedPath", strippedPath, "toPath", entryToPath)

		var failed = false
		subDelegate := &subDownloadDelegate{
			parent: delegate,
			errorCallback: func(err string) {
				if !failed {
					failed = true
					slog.Warn("zip file download failed", "error", err)
					delegate.OnError(err)
				}
			},
			progressCallback: func(fraction float64) {
				delegate.OnProgress((float64(pathIndex) + fraction) * perEntryFraction)
			},
		}

		if strings.HasSuffix(path, "/") {
			slog.Info("zip subdirectory", "path", path, "toPath", entryToPath)
			ea.downloadDirectoryPath(path, entryToPath, subDelegate)
		} else {
			archiveFile, err := ea.File(path)
			if err != nil {
				delegate.OnError(err.Error())
				return
			}
			archiveEntry := archiveFile.(*entryArchiveFile)
			archiveEntry.downloadFile(entryToPath, subDelegate)
		}

		if failed {
			return
		}

		delegate.OnProgress(float64(pathIndex+1) / float64(entryCount))
	}

	delegate.OnFinished(toPath)
}

func (ea *entryArchiveFile) downloadFile(toPath string, delegate DownloadDelegate) {
	// Create file to download to
	outFile, err := os.Create(toPath)
	if err != nil {
		delegate.OnError("could not open file for downloading to: " + err.Error())
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
		delegate.OnError("could not open file for downloading to: " + err.Error())
		return
	}

	cReader := cancelableReader{
		reader:     reader,
		delegate:   delegate,
		totalBytes: ea.file.UncompressedSize64,
		readBytes:  0,
	}
	_, err = io.Copy(outFile, &cReader)
	if err != nil {
		delegate.OnError("could not open file for downloading to: " + err.Error())
		return
	}
	delegate.OnFinished(toPath)
}

func (ea *entryArchiveFile) Size() int64 {
	return ea.file.FileInfo().Size()
}

func (ea *entryArchiveFile) reader() (io.Reader, error) {
	return ea.file.Open()
}

func (ea *entryArchiveFile) AsDownloadable() Downloadable {
	return ea
}

func (ea *archiveDirectoryFile) FileName() string {
	path := strings.TrimSuffix(ea.path, "/")
	ps := strings.Split(path, "/")
	return ps[len(ps)-1]
}

func (ea *archiveDirectoryFile) Download(toPath string, delegate DownloadDelegate) {
	go func() {
		delegate.OnProgress(0.0)
		ea.archive.downloadDirectoryPath(ea.path, toPath, delegate)
	}()
}

func (ea *archiveDirectoryFile) AsDownloadable() Downloadable {
	return ea
}

func (ea *archiveDirectoryFile) Size() int64 {
	return 0
}

type cancelableReader struct {
	reader     io.Reader
	delegate   DownloadDelegate
	totalBytes uint64
	readBytes  uint64
}

func (c *cancelableReader) Read(p []byte) (n int, err error) {
	if c.delegate.IsCancelled() {
		return 0, errors.New("cancelled")
	}
	n, err = c.reader.Read(p)
	if err == nil {
		c.readBytes += uint64(n)
		c.delegate.OnProgress(float64(c.readBytes) / float64(c.totalBytes))
	}
	return n, err
}
