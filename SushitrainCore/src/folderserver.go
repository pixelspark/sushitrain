// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"time"

	"golang.org/x/exp/slog"
)

type selfSignedCertificate struct {
	privateKey     any
	certificateDer []byte
}

func newSelfSignedCertificate() (*selfSignedCertificate, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		return nil, err
	}

	notBefore := time.Now()
	notAfter := notBefore.Add(365 * 24 * time.Hour)

	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"localhost"},
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1)},
		DNSNames:              []string{"localhost"},
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return nil, err
	}

	return &selfSignedCertificate{
		privateKey:     priv,
		certificateDer: derBytes,
	}, nil
}

func (s *selfSignedCertificate) fingerprintSha256() [32]byte {
	return sha256.Sum256(s.certificateDer)
}

func (s *selfSignedCertificate) tlsCertificate() (*tls.Certificate, error) {
	parsed, err := x509.ParseCertificate(s.certificateDer)
	if err != nil {
		return nil, err
	}

	return &tls.Certificate{
		Certificate: [][]byte{s.certificateDer},
		PrivateKey:  s.privateKey,
		Leaf:        parsed,
	}, nil
}

type FolderServer struct {
	listener     net.Listener
	client       *Client
	folderID     string
	subdirectory string
	certificate  *selfSignedCertificate
	cookieToken  string
}

func NewFolderServer(client *Client, folderID string, subdirectory string) *FolderServer {
	cert, err := newSelfSignedCertificate()
	if err != nil {
		slog.Error("could not create self signed certificate", "cause", err)
		return nil
	}

	tokenLength := 64
	b := make([]byte, tokenLength+2)
	rand.Read(b)
	cookieToken := fmt.Sprintf("%x", b)[2 : tokenLength+2]

	return &FolderServer{
		folderID:     folderID,
		subdirectory: subdirectory,
		listener:     nil,
		client:       client,
		certificate:  cert,
		cookieToken:  cookieToken,
	}
}

func (srv *FolderServer) CookieValue() string {
	return srv.cookieToken
}

func (srv *FolderServer) CookieName() string {
	return "__sushitrain_folder_server_cookie"
}

func (srv *FolderServer) CertificateFingerprintSHA256() []byte {
	fingerprint := srv.certificate.fingerprintSha256()
	return fingerprint[:]
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

	cert, err := srv.certificate.tlsCertificate()
	if err != nil {
		slog.Error("could not obtain certificate", "cause", err)
		return err
	}

	config := &tls.Config{
		Certificates:             []tls.Certificate{*cert},
		MinVersion:               tls.VersionTLS12,
		CurvePreferences:         []tls.CurveID{tls.CurveP384},
		PreferServerCipherSuites: true,
		CipherSuites: []uint16{
			tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			tls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
			tls.TLS_RSA_WITH_AES_256_GCM_SHA384,
			tls.TLS_RSA_WITH_AES_256_CBC_SHA,
		},
	}

	listener, err := tls.Listen("tcp", ":0", config)
	if err != nil {
		slog.Error("could not listen", "cause", err)
		return err
	}

	go http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		srv.handle(w, r)
	}))

	srv.listener = listener
	slog.Info("HTTP folder service listening", "port", srv.port())
	return nil
}

func (srv *FolderServer) handle(w http.ResponseWriter, r *http.Request) {
	slog.Info("folder server serve", "folderID", srv.folderID, "subdirectory", srv.subdirectory, "method", r.Method, "path", r.URL.Path)

	if r.Method != "GET" && r.Method != "HEAD" {
		http.Error(w, "invalid method", http.StatusBadRequest)
		return
	}

	// Check whether the client sent the authentication cookie
	cookie, err := r.Cookie(srv.CookieName())
	if err != nil {
		http.Error(w, "cookie not found", http.StatusBadRequest)
		return
	}

	if cookie.Value != srv.CookieValue() {
		http.Error(w, "invalid cookie", http.StatusUnauthorized)
		return
	}

	path := r.URL.Path
	if len(path) > 0 && path[len(path)-1:] == "/" {
		path += "index.html"
	}

	// Remove slash prefixes
	for len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}

	if !filepath.IsLocal(path) {
		slog.Warn("folder server path is not local", "path", r.URL.Path)
		http.Error(w, "requested path is not local", http.StatusBadRequest)
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
		slog.Warn("folder server entry not found", "path", r.URL.Path, "pathInFolder", pathInFolder)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if stEntry == nil || stEntry.IsDeleted() {
		w.WriteHeader(404)
		return
	}

	if stEntry.IsDirectory() {
		// Redirect to path ending in slash so it gets directory treatment
		w.Header().Add("Location", r.URL.Path+"/")
		slog.Info("redirecting", "path", r.URL.Path, "to", r.URL.Path+"/")
		w.WriteHeader(301)
		return
	}

	if stEntry.IsSymlink() {
		http.Error(w, "requested entry is a symlink", http.StatusBadRequest)
		return
	}

	// Set MIME type
	ext := filepath.Ext(path)
	mime := MIMETypeForExtension(ext)
	if mime == "" {
		mime = "application/octet-stream"
	}
	w.Header().Add("Content-type", mime)

	// Obtain global file info
	m := srv.client.app.Internals
	info, ok, err := m.GlobalFileInfo(srv.folderID, pathInFolder)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	// Actually send the file
	serveEntry(w, r, srv.folderID, stEntry, info, srv.client.app.Internals, srv.client.Measurements, nil)
}

func (srv *FolderServer) port() int {
	return srv.listener.Addr().(*net.TCPAddr).Port
}

func (srv *FolderServer) URL() string {
	url := url.URL{
		Scheme: "https",
		Host:   fmt.Sprintf("localhost:%d", srv.port()),
		Path:   "/",
	}
	return url.String()
}
