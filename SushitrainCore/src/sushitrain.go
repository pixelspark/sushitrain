// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"context"
	"crypto/tls"
	"errors"
	"net/url"
	"os"
	"path"
	"strings"

	"github.com/syncthing/syncthing/lib/build"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/db/backend"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/osutil"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/sha256"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
)

type Client struct {
	app                        *syncthing.App
	backend                    backend.Backend
	cancel                     context.CancelFunc
	cert                       tls.Certificate
	config                     config.Wrapper
	connectedDeviceAddresses   map[string]string
	ctx                        context.Context
	Delegate                   ClientDelegate
	downloadProgress           map[string]map[string]*model.PullerProgress
	evLogger                   events.Logger
	filesPath                  string
	foldersTransferring        map[string]bool
	IgnoreEvents               bool
	IsUsingCustomConfiguration bool
	Server                     *StreamingServer
}

type Change struct {
	FolderID string
	Path     string
	Action   string
	ShortID  string
	Time     *Date
}

type ClientDelegate interface {
	OnEvent(event string)
	OnDeviceDiscovered(deviceID string, addresses *ListOfStrings)
	OnListenAddressesChanged(addresses *ListOfStrings)
	OnChange(change *Change)
}

var (
	ErrStillLoading = errors.New("still loading")
)

func NewClient(configPath string, filesPath string) (*Client, error) {
	// Set version info
	build.Version = "v1.27.9"
	build.Host = "t-shaped.nl"
	build.User = "sushitrain"

	// Some early chores
	osutil.MaximizeOpenFileLimit()
	sha256.SelectAlgo()
	sha256.Report()

	// Set up logging and context for cancellation
	ctx, cancel := context.WithCancel(context.Background())
	evLogger := events.NewLogger()
	go evLogger.Serve(ctx)

	// Set up default locations
	locations.SetBaseDir(locations.DataBaseDir, configPath)
	locations.SetBaseDir(locations.ConfigBaseDir, configPath)
	locations.SetBaseDir(locations.UserHomeBaseDir, filesPath)
	Logger.Infof("Database dir: %s\n", configPath)
	Logger.Infof("Files dir: %s\n", filesPath)

	// Check for custom user-provided config file
	isUsingCustomConfiguration := false
	customConfigFilePath := path.Join(filesPath, "config.xml")
	if info, err := os.Stat(customConfigFilePath); err == nil {
		if !info.IsDir() {
			Logger.Infoln("Config XML exists in files dir, using it at", customConfigFilePath)
			locations.Set(locations.ConfigFile, customConfigFilePath)
			isUsingCustomConfiguration = true
		}
	}

	// Check for custom user-provided identity
	customCertPath := path.Join(filesPath, "cert.pem")
	customKeyPath := path.Join(filesPath, "key.pem")
	if keyInfo, err := os.Stat(customKeyPath); err == nil {
		if !keyInfo.IsDir() {
			if certInfo, err := os.Stat(customCertPath); err == nil {
				if !certInfo.IsDir() {
					Logger.Infoln("Found user-provided identity files, using those")
					locations.Set(locations.CertFile, customCertPath)
					locations.Set(locations.KeyFile, customKeyPath)
					isUsingCustomConfiguration = true
				}
			}
		}
	}

	// Print final locations
	Logger.Infof("Config file: %s\n", locations.Get(locations.ConfigFile))
	Logger.Infof("Cert file: %s key file: %s\n", locations.Get(locations.CertFile), locations.Get(locations.KeyFile))

	// Ensure that we have a certificate and key.
	cert, err := syncthing.LoadOrGenerateCertificate(
		locations.Get(locations.CertFile),
		locations.Get(locations.KeyFile),
	)
	if err != nil {
		cancel()
		return nil, err
	}

	// Load or create the config
	devID := protocol.NewDeviceID(cert.Certificate[0])
	Logger.Infof("Loading config file from %s\n", locations.Get(locations.ConfigFile))
	config, err := loadOrDefaultConfig(devID, ctx, evLogger, filesPath)
	if err != nil {
		cancel()
		return nil, err
	}

	// Load database
	dbFile := locations.Get(locations.Database)
	ldb, err := syncthing.OpenDBBackend(dbFile, config.Options().DatabaseTuning)
	if err != nil {
		cancel()
		return nil, err
	}

	appOpts := syncthing.Options{
		NoUpgrade:            false,
		ProfilerAddr:         "",
		ResetDeltaIdxs:       false,
		Verbose:              false,
		DBRecheckInterval:    0,
		DBIndirectGCInterval: 0,
	}

	app, err := syncthing.New(config, ldb, evLogger, cert, appOpts)
	if err != nil {
		cancel()
		return nil, err
	}

	server, err := NewServer(app, ctx)
	if err != nil {
		cancel()
		return nil, err
	}

	return &Client{
		Delegate:                   nil,
		cert:                       cert,
		config:                     config,
		cancel:                     cancel,
		ctx:                        ctx,
		backend:                    ldb,
		app:                        app,
		evLogger:                   evLogger,
		Server:                     server,
		foldersTransferring:        make(map[string]bool, 0),
		connectedDeviceAddresses:   make(map[string]string, 0),
		IsUsingCustomConfiguration: isUsingCustomConfiguration,
		filesPath:                  filesPath,
		IgnoreEvents:               false,
	}, nil
}

func (clt *Client) Stop() {
	clt.app.Stop(svcutil.ExitSuccess)
	clt.cancel()
	clt.app.Wait()
}

func (clt *Client) startEventListener() {
	sub := clt.evLogger.Subscribe(events.AllEvents)
	defer sub.Unsubscribe()

	for {
		select {
		case <-clt.ctx.Done():
			return
		case evt := <-sub.C():
			switch evt.Type {
			case events.DeviceDiscovered:
				if !clt.IgnoreEvents && clt.Delegate != nil {
					data := evt.Data.(map[string]interface{})
					devID := data["device"].(string)
					addresses := data["addrs"].([]string)
					clt.Delegate.OnDeviceDiscovered(devID, &ListOfStrings{data: addresses})
				}

			case events.FolderRejected:
				// FolderRejected is deprecated
				break

			case events.StateChanged:
				// Keep track of which folders are in syncing state. We need to know whether we are idling or not
				data := evt.Data.(map[string]interface{})
				folder := data["folder"].(string)
				state := data["to"].(string)
				folderTransferring := (state == model.FolderSyncing.String() || state == model.FolderSyncWaiting.String() || state == model.FolderSyncPreparing.String())
				clt.foldersTransferring[folder] = folderTransferring
				if !clt.IgnoreEvents && clt.Delegate != nil {
					clt.Delegate.OnEvent(evt.Type.String())
				}

			case events.ListenAddressesChanged:
				if !clt.IgnoreEvents && clt.Delegate != nil {
					addrs := make([]string, 0)
					data := evt.Data.(map[string]interface{})
					wanAddresses := data["wan"].([]*url.URL)
					lanAddresses := data["lan"].([]*url.URL)

					for _, wa := range wanAddresses {
						addrs = append(addrs, wa.String())
					}
					for _, la := range lanAddresses {
						addrs = append(addrs, la.String())
					}

					clt.Delegate.OnListenAddressesChanged(List(addrs))
				}

			case events.DeviceConnected:
				data := evt.Data.(map[string]string)
				devID := data["id"]
				address := data["addr"]
				clt.connectedDeviceAddresses[devID] = address

				if !clt.IgnoreEvents && clt.Delegate != nil {
					clt.Delegate.OnEvent(evt.Type.String())
				}

			case events.LocalChangeDetected, events.RemoteChangeDetected:
				data := evt.Data.(map[string]string)
				modifiedBy, ok := data["modifiedBy"]
				if !ok {
					modifiedBy = clt.DeviceID()
				}

				if !clt.IgnoreEvents && clt.Delegate != nil {
					clt.Delegate.OnChange(&Change{
						FolderID: data["folder"],
						ShortID:  modifiedBy,
						Action:   data["action"],
						Path:     data["path"],
						Time:     &Date{time: evt.Time},
					})
					clt.Delegate.OnEvent(evt.Type.String())
				}

			case events.LocalIndexUpdated, events.DeviceDisconnected, events.ConfigSaved,
				events.ClusterConfigReceived, events.FolderResumed, events.FolderPaused:
				// Just deliver the event
				if !clt.IgnoreEvents && clt.Delegate != nil {
					clt.Delegate.OnEvent(evt.Type.String())
				}

			case events.DownloadProgress:
				clt.downloadProgress = evt.Data.(map[string]map[string]*model.PullerProgress)
				if !clt.IgnoreEvents && clt.Delegate != nil {
					clt.Delegate.OnEvent(evt.Type.String())
				}

			case events.RemoteDownloadProgress, events.ItemFinished, events.ItemStarted:
				// Ignore these events
				break

			default:
				Logger.Debugln("EVENT", evt.Type.String(), evt)
			}

		}
	}
}

func (clt *Client) GetLastPeerAddress(deviceID string) string {
	if addr, ok := clt.connectedDeviceAddresses[deviceID]; ok {
		return addr
	}
	return ""
}

func (clt *Client) IsTransferring() bool {
	for _, isTransferring := range clt.foldersTransferring {
		if isTransferring {
			return true
		}
	}
	return false
}

func (clt *Client) Start() error {
	// Subscribe to events
	go clt.startEventListener()

	if err := clt.app.Start(); err != nil {
		return err
	}

	return nil
}

func loadOrDefaultConfig(devID protocol.DeviceID, ctx context.Context, logger events.Logger, filesPath string) (config.Wrapper, error) {
	cfgFile := locations.Get(locations.ConfigFile)
	cfg, _, err := config.Load(cfgFile, devID, logger)
	if err != nil {
		newCfg := config.New(devID)
		newCfg.GUI.Enabled = false
		cfg = config.Wrap(cfgFile, newCfg, devID, logger)

	}

	go cfg.Serve(ctx)

	// Always override the following options in config
	waiter, err := cfg.Modify(func(conf *config.Configuration) {
		conf.GUI.Enabled = false                         // Don't need the web UI, we have our own :-)
		conf.Options.CREnabled = false                   // No crash reporting for now
		conf.Options.URAccepted = -1                     // No usage reporting for now
		conf.Options.ProgressUpdateIntervalS = 1         // We want to update the user often, it improves the experience and is worth the compute cost
		conf.Options.CRURL = ""                          // No crash reporting for now
		conf.Options.URURL = ""                          // No usage reporting for now
		conf.Options.ReleasesURL = ""                    // Disable auto update, we can't do so on iOS anyway
		conf.Options.InsecureAllowOldTLSVersions = false // Never allow insecure TLS
		conf.Defaults.Folder.IgnorePerms = true          // iOS doesn't expose permissions to users
		conf.Options.RelayReconnectIntervalM = 1         // Set this to one minute (from the default 10) because on mobile networks this is more often necessary

		// For each folder, set the path to be filesPath/folderID
		for _, folderConfig := range conf.Folders {
			folderConfig.Path = path.Join(filesPath, folderConfig.ID)
			conf.SetFolder(folderConfig)
		}
	})

	if err != nil {
		return nil, err
	}
	waiter.Wait()

	err = cfg.Save()
	if err != nil {
		return nil, err
	}

	return cfg, err
}

/** Returns the device ID */
func (clt *Client) DeviceID() string {
	return protocol.NewDeviceID(clt.cert.Certificate[0]).String()
}

func (clt *Client) deviceID() protocol.DeviceID {
	return protocol.NewDeviceID(clt.cert.Certificate[0])
}

func (clt *Client) Folders() *ListOfStrings {
	if clt.config == nil {
		return nil
	}

	return List(Map(clt.config.FolderList(), func(folder config.FolderConfiguration) string {
		return folder.ID
	}))
}

func (clt *Client) FolderWithID(id string) *Folder {
	if clt.config == nil {
		return nil
	}

	fi, ok := clt.config.Folders()[id]
	if !ok {
		return nil // Folder with this ID does not exist
	}

	return &Folder{
		client:   clt,
		FolderID: fi.ID,
	}
}

func (clt *Client) ConnectedPeerCount() int {
	if clt.app == nil || clt.app.Internals == nil {
		return 0
	}

	if clt.config == nil || clt.app == nil || clt.app.Internals == nil {
		return 0
	}

	devIDs := clt.config.Devices()
	connected := 0
	for devID := range devIDs {
		if devID == clt.deviceID() {
			continue
		}
		if clt.app.Internals.IsConnectedTo(devID) {
			connected++
		}
	}
	return connected
}

func (clt *Client) Peers() *ListOfStrings {
	if clt.config == nil {
		return nil
	}

	return List(Map(clt.config.DeviceList(), func(device config.DeviceConfiguration) string {
		return device.DeviceID.String()
	}))
}

func (clt *Client) PeerWithID(deviceID string) *Peer {
	devID, err := protocol.DeviceIDFromString(deviceID)

	if err != nil {
		return nil
	}

	return &Peer{
		client:   clt,
		deviceID: devID,
	}
}

func (clt *Client) PeerWithShortID(shortID string) *Peer {
	for _, dc := range clt.config.DeviceList() {
		if dc.DeviceID.Short().String() == shortID {
			return &Peer{
				client:   clt,
				deviceID: dc.DeviceID,
			}
		}
	}
	return nil
}

func (clt *Client) changeConfiguration(block config.ModifyFunction) error {
	waiter, err := clt.config.Modify(block)
	if err != nil {
		return err
	}
	waiter.Wait()

	err = clt.config.Save()
	return err
}

func (clt *Client) AddPeer(deviceID string) error {
	addedDevice, err := protocol.DeviceIDFromString(deviceID)
	if err != nil {
		return err
	}

	deviceConfig := clt.config.DefaultDevice()
	deviceConfig.DeviceID = addedDevice

	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetDevice(deviceConfig)
	})
}

func (clt *Client) AddFolder(folderID string) error {
	if clt.app == nil || clt.app.Internals == nil {
		return ErrStillLoading
	}

	folderConfig := clt.config.DefaultFolder()
	folderConfig.ID = folderID
	folderConfig.Label = folderID
	folderConfig.Path = path.Join(clt.filesPath, folderID)
	folderConfig.FSWatcherEnabled = false
	folderConfig.Paused = false

	err := clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetFolder(folderConfig)
	})
	if err != nil {
		return err
	}

	// Set default ignores for on-demand sync
	return clt.app.Internals.SetIgnores(folderID, []string{"*"})
}

func (clt *Client) SetNATEnabled(enabled bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.NATEnabled = enabled
	})
}

func (clt *Client) IsNATEnabled() bool {
	return clt.config.Options().NATEnabled
}

func (clt *Client) SetRelaysEnabled(enabled bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.RelaysEnabled = enabled
	})
}

func (clt *Client) IsRelaysEnabled() bool {
	return clt.config.Options().RelaysEnabled
}

func (clt *Client) SetLocalAnnounceEnabled(enabled bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.LocalAnnEnabled = enabled
	})
}

func (clt *Client) IsLocalAnnounceEnabled() bool {
	return clt.config.Options().LocalAnnEnabled
}

func (clt *Client) SetGlobalAnnounceEnabled(enabled bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.GlobalAnnEnabled = enabled
	})
}

func (clt *Client) IsGlobalAnnounceEnabled() bool {
	return clt.config.Options().GlobalAnnEnabled
}

func (clt *Client) SetAnnounceLANAddresses(enabled bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.AnnounceLANAddresses = enabled
	})
}

func (clt *Client) IsAnnounceLANAddressesEnabled() bool {
	return clt.config.Options().AnnounceLANAddresses
}

func (clt *Client) IsBandwidthLimitedInLAN() bool {
	return clt.config.Options().LimitBandwidthInLan
}

func (clt *Client) SetBandwidthLimitedInLAN(enabled bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.LimitBandwidthInLan = enabled
	})
}

func (clt *Client) GetBandwidthLimitUpMbitsPerSec() int {
	return clt.config.Options().MaxSendKbps / 1000
}

func (clt *Client) GetBandwidthLimitDownMbitsPerSec() int {
	return clt.config.Options().MaxRecvKbps / 1000
}

func (clt *Client) SetBandwidthLimitsMbitsPerSec(down int, up int) error {
	if down < 0 {
		down = 0
	}
	if up < 0 {
		up = 0
	}

	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.MaxRecvKbps = down * 1000
		cfg.Options.MaxSendKbps = up * 1000
	})
}

type Progress struct {
	BytesTotal int64
	BytesDone  int64
	FilesTotal int64
	Percentage float32
}

func (clt *Client) GetTotalDownloadProgress() *Progress {
	if clt.downloadProgress == nil {
		return nil
	}

	var doneBytes, totalBytes int64
	doneBytes = 0
	totalBytes = 0
	fileCount := 0
	for _, info := range clt.downloadProgress {
		for _, fileInfo := range info {
			doneBytes += fileInfo.BytesDone
			totalBytes += fileInfo.BytesTotal
			fileCount++
		}
	}

	if totalBytes == 0 {
		return nil
	}

	return &Progress{
		BytesTotal: totalBytes,
		BytesDone:  doneBytes,
		FilesTotal: int64(fileCount),
		Percentage: float32(doneBytes) / float32(totalBytes),
	}
}

func (clt *Client) GetDownloadProgressForFile(path string, folder string) *Progress {
	if clt.downloadProgress == nil {
		return nil
	}

	if folderInfo, ok := clt.downloadProgress[folder]; ok {
		if fileInfo, ok := folderInfo[path]; ok {
			return &Progress{
				BytesTotal: fileInfo.BytesTotal,
				BytesDone:  fileInfo.BytesDone,
				FilesTotal: 1,
				Percentage: float32(fileInfo.BytesDone) / float32(fileInfo.BytesTotal),
			}
		}
	}

	return nil
}

func (clt *Client) GetName() (string, error) {
	devID := clt.deviceID()

	selfConfig, ok := clt.config.Devices()[devID]
	if !ok {
		return "", errors.New("cannot find myself")
	}
	return selfConfig.Name, nil
}

func (clt *Client) SetName(name string) error {
	devID := clt.deviceID()

	selfConfig, ok := clt.config.Devices()[devID]
	if !ok {
		return errors.New("cannot find myself")
	}
	selfConfig.Name = name

	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetDevice(selfConfig)
	})
}

func (clt *Client) Statistics() (*FolderStats, error) {
	if clt.app == nil || clt.app.Internals == nil {
		return nil, ErrStillLoading
	}

	globalTotal := FolderCounts{}
	localTotal := FolderCounts{}

	for _, folder := range clt.config.FolderList() {
		snap, err := clt.app.Internals.DBSnapshot(folder.ID)
		defer snap.Release()
		if err != nil {
			return nil, err
		}
		globalTotal.add(newFolderCounts(snap.GlobalSize()))
		localTotal.add(newFolderCounts(snap.LocalSize()))
	}

	return &FolderStats{
		Global: &globalTotal,
		Local:  &localTotal,
	}, nil
}

type SearchResultDelegate interface {
	Result(entry *Entry)
	IsCancelled() bool
}

/*
* Search for files by name in the global index. Calls back the delegate up to `maxResults` times with a result in no
particular order, unless/until the delegate returns true from IsCancelled. Set maxResults to <=0 to collect all results.
*/
func (clt *Client) Search(text string, delegate SearchResultDelegate, maxResults int, folderID string, prefix string) error {
	if clt.app == nil || clt.app.Internals == nil {
		return ErrStillLoading
	}

	text = strings.ToLower(text)
	resultCount := 0

	for _, folder := range clt.config.FolderList() {
		if folderID != "" && folder.ID != folderID {
			continue
		}

		folderObject := Folder{
			client:   clt,
			FolderID: folder.ID,
		}

		snap, err := clt.app.Internals.DBSnapshot(folder.ID)
		if err != nil {
			return err
		}
		defer snap.Release()

		snap.WithGlobal(func(f protocol.FileIntf) bool {
			if delegate.IsCancelled() {
				// This shouild cancel the scan
				return false
			}

			gimmeMore := maxResults <= 0 || resultCount < maxResults

			// Check prefix
			if !strings.HasPrefix(f.FileName(), prefix) {
				return gimmeMore
			}

			pathParts := strings.Split(f.FileName(), "/")
			lowerFileName := strings.ToLower(pathParts[len(pathParts)-1])

			if gimmeMore && strings.Contains(lowerFileName, text) {
				entry := &Entry{
					Folder: &folderObject,
					info:   f.(protocol.FileInfo),
				}

				if err == nil {
					resultCount += 1
					delegate.Result(entry)
				}
			}

			return gimmeMore
		})
	}
	return nil
}

func (clt *Client) GetEnoughConnections() int {
	return clt.config.Options().ConnectionLimitEnough
}

func (clt *Client) SetEnoughConnections(enough int) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.ConnectionLimitEnough = enough
	})
}

// To make Syncthing 'not listening' we set the listen address to localhost. Setting it to empty will not do much, as
// the default will be reloaded (which is 'default', and which means 'listen')
const (
	NoListenAddress = "tcp://127.0.0.1:22000"
)

func (clt *Client) IsListening() bool {
	addrs := clt.config.Options().ListenAddresses()
	return len(addrs) > 0 && addrs[0] != NoListenAddress
}

func (clt *Client) SetListening(listening bool) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		if listening {
			cfg.Options.RawListenAddresses = []string{"default"}
		} else {
			cfg.Options.RawListenAddresses = []string{NoListenAddress}
		}
	})
}

func (clt *Client) pendingFolders() (map[string][]string, error) {
	if clt.app == nil || clt.app.Internals == nil {
		return nil, ErrStillLoading
	}

	peers := clt.config.DeviceList()
	fids := map[string][]string{}
	for _, peer := range peers {
		peerFids, err := clt.app.Internals.PendingFolders(peer.DeviceID)
		if err != nil {
			return nil, err
		}
		for peerFid := range peerFids {
			existing := fids[peerFid]
			existing = append(existing, peer.DeviceID.String())
			fids[peerFid] = existing
		}
	}

	return fids, nil
}

func (clt *Client) PendingFolderIDs() (*ListOfStrings, error) {
	if clt.app == nil || clt.app.Internals == nil {
		return nil, ErrStillLoading
	}

	pfs, err := clt.pendingFolders()
	if err != nil {
		return nil, err
	}
	return List(KeysOf(pfs)), nil
}

func (clt *Client) DevicesPendingFolder(folderID string) (*ListOfStrings, error) {
	if clt.app == nil || clt.app.Internals == nil {
		return nil, ErrStillLoading
	}

	pfs, err := clt.pendingFolders()
	if err != nil {
		return nil, err
	}

	if devs, ok := pfs[folderID]; ok {
		return List(devs), nil
	}
	return List([]string{}), nil
}

func (clt *Client) SetReconnectIntervalS(secs int) error {
	Logger.Infoln("Set reconnect interval to", secs)
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.ReconnectIntervalS = secs
	})
}

func IsValidDeviceID(devID string) bool {
	_, err := protocol.DeviceIDFromString(devID)
	return err == nil
}

func Version() string {
	return build.Version
}
