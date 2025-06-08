// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
)

type FolderServer struct {
	listener     net.Listener
	client       *Client
	folderID     string
	subdirectory string
}

func NewFolderServer(client *Client, folderID string, subdirectory string) *FolderServer {
	return &FolderServer{
		folderID:     folderID,
		subdirectory: subdirectory,
		listener:     nil,
		client:       client,
	}
}

func (srv *FolderServer) Shutdown() {
	if srv.listener != nil {
		srv.listener.Close()
		srv.listener = nil
	}
}

func (srv *FolderServer) Listen() error {
	// Close existing listener
	srv.Shutdown()

	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		return err
	}

	go http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		srv.handle(w, r)
	}))

	srv.listener = listener
	Logger.Infoln("HTTP folder service listening on port", srv.port())
	return nil
}

func (srv *FolderServer) handle(w http.ResponseWriter, r *http.Request) {
	Logger.Infoln("Folder server " + srv.folderID + " " + srv.subdirectory + " " + r.Method + " " + r.URL.Path)

	if r.Method != "GET" && r.Method != "HEAD" {
		w.WriteHeader(400) // Bad request
		return
	}

	path := r.URL.Path
	if len(path) > 0 && path[len(path)-1:] == "/" {
		path += "index.html"
	}

	// Remove slash prefix
	if len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}

	if !filepath.IsLocal(path) {
		w.WriteHeader(403)
		w.Write([]byte("requested path is not local"))
		return
	}

	stFolder := srv.client.FolderWithID(srv.folderID)
	if stFolder == nil {
		w.WriteHeader(404)
		return
	}

	pathInFolder := filepath.Join(srv.subdirectory, path)
	stEntry, err := stFolder.GetFileInformation(pathInFolder)
	if err != nil {
		w.WriteHeader(500)
		w.Write([]byte(err.Error()))
		return
	}

	if stEntry == nil || stEntry.IsDeleted() {
		w.WriteHeader(404)
		return
	}

	if stEntry.IsDirectory() {
		// Redirect to path ending in slash so it gets directory treatment
		w.Header().Add("Location", r.URL.Path+"/")
		Logger.Infoln("Redirecting " + r.URL.Path + " to " + r.URL.Path + "/")
		w.WriteHeader(301)
		return
	}

	if stEntry.IsSymlink() {
		w.WriteHeader(400)
		return
	}

	// Set MIME type
	ext := filepath.Ext(path)
	mime := MIMETypeForExtension(ext)
	w.Header().Add("Content-type", mime)

	if r.Method == "HEAD" {
		w.Header().Add("Content-length", string(stEntry.Size()))
		w.WriteHeader(204)
		return
	}

	// Obtain global file info
	m := srv.client.app.Internals
	info, ok, err := m.GlobalFileInfo(srv.folderID, pathInFolder)
	if err != nil {
		w.WriteHeader(500)
		w.Write([]byte(err.Error()))
		return
	}
	if !ok {
		w.WriteHeader(404)
		return
	}

	// Actually send the file
	serveEntry(w, r, srv.folderID, stEntry, info, srv.client.app.Internals, nil)
}

func (srv *FolderServer) port() int {
	return srv.listener.Addr().(*net.TCPAddr).Port
}

func (srv *FolderServer) URL() string {
	url := url.URL{
		Scheme: "http",
		Host:   fmt.Sprintf("localhost:%d", srv.port()),
		Path:   "/",
	}
	return url.String()
}
