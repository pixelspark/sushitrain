// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"mime"
	"strings"

	"github.com/syncthing/syncthing/lib/db"
	"github.com/syncthing/syncthing/lib/logger"
)

var (
	Logger = logger.DefaultLogger.NewFacility("sushitraincore", "Swift-Go interface layer")
)

type ListOfStrings struct {
	data []string
}

func List(data []string) *ListOfStrings {
	return &ListOfStrings{
		data: data,
	}
}

func (self *ListOfStrings) Count() int {
	return len(self.data)
}

func (self *ListOfStrings) ItemAt(index int) string {
	return self.data[index]
}

func Map[T, U any](ts []T, f func(T) U) []U {
	us := make([]U, len(ts))
	for i := range ts {
		us[i] = f(ts[i])
	}
	return us
}

func KeysOf[K comparable, V any](m map[K]V) []K {
	keys := make([]K, 0)
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

func Filter[T any](input []T, f func(T) bool) []T {
	output := make([]T, 0)
	for _, item := range input {
		if f(item) {
			output = append(output, item)
		}
	}
	return output
}

var mimesByExtension = map[string]string{
	".aac":    "audio/aac",
	".abw":    "application/x-abiword",
	".apng":   "image/apng",
	".arc":    "application/x-freearc",
	".avif":   "image/avif",
	".avi":    "video/x-msvideo",
	".azw":    "application/vnd.amazon.ebook",
	".bin":    "application/octet-stream",
	".bmp":    "image/bmp",
	".bz":     "application/x-bzip",
	".bz2":    "application/x-bzip2",
	".cda":    "application/x-cdf",
	".csh":    "application/x-csh",
	".css":    "text/css",
	".csv":    "text/csv",
	".doc":    "application/msword",
	".docx":   "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	".eot":    "application/vnd.ms-fontobject",
	".epub":   "application/epub+zip",
	".flac":   "audio/flac",
	".gz":     "application/gzip",
	".gif":    "image/gif",
	".heic":   "image/heif",
	".heif":   "image/heif",
	".htm":    "text/html",
	".html":   "text/html",
	".ico":    "image/vnd.microsoft.icon",
	".ics":    "text/calendar",
	".jar":    "application/java-archive",
	".jpg":    "image/jpeg",
	".jpeg":   "image/jpeg",
	".js":     "text/javascript",
	".json":   "application/json",
	".jsonld": "application/ld+json",
	".mid":    "audio/midi",
	".midi":   "audio/midi",
	".mjs":    "text/javascript",
	".mp3":    "audio/mpeg",
	".mp4":    "video/mp4",
	".m4v":    "video/mp4",
	".mov":    "video/quicktime",
	".mpeg":   "video/mpeg",
	".mpkg":   "application/vnd.apple.installer+xml",
	".odp":    "application/vnd.oasis.opendocument.presentation",
	".ods":    "application/vnd.oasis.opendocument.spreadsheet",
	".odt":    "application/vnd.oasis.opendocument.text",
	".oga":    "audio/ogg",
	".ogg":    "audio/ogg",
	".ogv":    "video/ogg",
	".ogx":    "application/ogg",
	".opus":   "audio/ogg",
	".otf":    "font/otf",
	".png":    "image/png",
	".pdf":    "application/pdf",
	".php":    "application/x-httpd-php",
	".ppt":    "application/vnd.ms-powerpoint",
	".pptx":   "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	".rar":    "application/vnd.rar",
	".rtf":    "application/rtf",
	".sh":     "application/x-sh",
	".svg":    "image/svg+xml",
	".tar":    "application/x-tar",
	".tif":    "image/tiff",
	".tiff":   "image/tiff",
	".ts":     "video/mp2t",
	".ttf":    "font/ttf",
	".txt":    "text/plain",
	".vsd":    "application/vnd.visio",
	".wav":    "audio/wav",
	".weba":   "audio/webm",
	".webm":   "video/webm",
	".webp":   "image/webp",
	".wma":    "audio/x-ms-wma",
	".wmv":    "video/x-ms-asf",
	".woff":   "font/woff",
	".woff2":  "font/woff2",
	".xhtml":  "application/xhtml+xml",
	".xls":    "application/vnd.ms-excel",
	".xlsx":   "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	".xml":    "application/xml",
	".xul":    "application/vnd.mozilla.xul+xml",
	".zip":    "application/zip",
	".3gp":    "video/3gpp",
	".3g2":    "video/3gpp2",
	".7z":     "application/x-7z-compressed",
}

// ext should include the dot
func MIMETypeForExtension(ext string) string {
	tp, ok := mimesByExtension[strings.ToLower(ext)]
	if ok {
		return tp
	}

	tp = mime.TypeByExtension(ext)
	if len(tp) > 0 {
		return tp
	}

	return ""
}

type FolderCounts struct {
	Bytes       int64
	Files       int
	Directories int
}

type FolderStats struct {
	Global    *FolderCounts
	Local     *FolderCounts
	LocalNeed *FolderCounts
}

func newFolderCounts(from db.Counts) *FolderCounts {
	return &FolderCounts{
		Bytes:       from.Bytes,
		Files:       from.Files,
		Directories: from.Directories,
	}
}

func (self *FolderCounts) add(other *FolderCounts) {
	self.Bytes += other.Bytes
	self.Files += other.Files
	self.Directories += other.Directories
}
