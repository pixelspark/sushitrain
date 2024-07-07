package sushitrain

import (
	"fmt"
	"path"
	"path/filepath"
	"strings"

	"github.com/syncthing/syncthing/lib/ignore/ignoreresult"
	"github.com/syncthing/syncthing/lib/osutil"
	"github.com/syncthing/syncthing/lib/protocol"
)

type Entry struct {
	folder *Folder
	path   string
	info   protocol.FileInfo
}

type FetchDelegate interface {
	Fetched(blockNo int, blockOffset int64, blockSize int64, data []byte, last bool)
	Progress(p float64)
	Error(e int, message string)
}

const (
	FetchDelegateErrorBlockUnavailable int = 1
	FetchDelegateErrorPullFailed       int = 2
)

type FetchCallback func(success bool)

func (self *Entry) Fetch(delegate FetchDelegate) {
	go func() {
		client := self.folder.client
		m := client.app.M
		delegate.Progress(0.0)

		fetchedBytes := int64(0)
		for blockNo, block := range self.info.Blocks {
			av, err := m.Availability(self.folder.FolderID, self.info, block)
			if err != nil {
				delegate.Error(FetchDelegateErrorBlockUnavailable, err.Error())
				return
			}
			if len(av) < 1 {
				delegate.Error(FetchDelegateErrorBlockUnavailable, "")
				return
			}

			buf, err := m.RequestGlobal(client.ctx, av[0].ID, self.folder.FolderID, self.info.Name, blockNo, block.Offset, block.Size, block.Hash, block.WeakHash, false)
			if err != nil {
				delegate.Error(FetchDelegateErrorPullFailed, err.Error())
				return
			}
			fetchedBytes += int64(block.Size)
			delegate.Fetched(blockNo, block.Offset, int64(block.Size), buf, blockNo == len(self.info.Blocks)-1)
			delegate.Progress(float64(fetchedBytes) / float64(self.info.FileSize()))
		}

		delegate.Progress(1.0)
	}()
}

func (self *Entry) Path() string {
	return self.path
}

func (self *Entry) FileName() string {
	ps := strings.Split(self.info.FileName(), "/")
	return ps[len(ps)-1]
}

func (self *Entry) Name() string {
	return self.info.FileName()
}

func (self *Entry) IsDirectory() bool {
	return self.info.IsDirectory()
}

func (self *Entry) IsSymlink() bool {
	return self.info.IsSymlink()
}

func (self *Entry) Size() int64 {
	return self.info.FileSize()
}

func (self *Entry) IsDeleted() bool {
	return self.info.IsDeleted()
}

func (self *Entry) ModifiedBy() string {
	return self.info.FileModifiedBy().String()
}

func (self *Entry) LocalNativePath() (string, error) {
	nativeFilename := osutil.NativeFilename(self.info.FileName())
	localFolderPath, err := self.folder.LocalNativePath()
	if err != nil {
		return "", err
	}
	return path.Join(localFolderPath, nativeFilename), nil
}

func (self *Entry) IsLocallyPresent() bool {
	ffs := self.folder.folderConfiguration().Filesystem(nil)
	nativeFilename := osutil.NativeFilename(self.info.FileName())
	_, err := ffs.Stat(nativeFilename)
	return err == nil
}

func (self *Entry) IsSelected() bool {
	// FIXME: cache matcher
	matcher, err := self.folder.loadIgnores()
	if err != nil {
		fmt.Println("error loading ignore matcher", err)
		return false
	}

	res := matcher.Match(self.info.Name)
	if res == ignoreresult.Ignored || res == ignoreresult.IgnoreAndSkip {
		return false
	}
	return true
}

func (self *Entry) IsExplicitlySelected() bool {
	lines, _, err := self.folder.client.app.M.CurrentIgnores(self.folder.FolderID)
	if err != nil {
		return false
	}

	ignoreLine := self.ignoreLine()
	for _, line := range lines {
		if len(line) > 0 && line[0] == '!' {
			if line == ignoreLine {
				return true
			}
		}
	}
	return false
}

func (self *Entry) ignoreLine() string {
	return "!/" + self.info.FileName()
}

func (self *Entry) SetExplicitlySelected(selected bool) error {
	currentlySelected := self.IsExplicitlySelected()

	if currentlySelected == selected {
		return nil
	}

	// Edit lines
	lines, _, err := self.folder.client.app.M.CurrentIgnores(self.folder.FolderID)
	if err != nil {
		return err
	}

	line := self.ignoreLine()
	if !selected {
		lines = Filter(lines, func(l string) bool {
			return l != line
		})
	} else {
		lines = append([]string{line}, lines...)
	}

	// Save new ignores
	err = self.folder.client.app.M.SetIgnores(self.folder.FolderID, lines)
	if err != nil {
		return err
	}

	// Delete local file if !selected
	if !selected {
		go func() {
			self.folder.client.app.M.ScanFolders()
			self.folder.DeleteLocalFile(self.path)
		}()
	}
	return nil
}

func (self *Entry) OnDemandURL() string {
	server := self.folder.client.Server
	if server == nil {
		return ""
	}

	return server.URLFor(self.folder.FolderID, self.path)
}

func (self *Entry) MIMEType() string {
	ext := filepath.Ext(self.path)
	return MIMETypeForExtension(ext)
}
