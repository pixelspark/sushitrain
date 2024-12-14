// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/build"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/db/backend"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/logger"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/osutil"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
)

type Client struct {
	app                        *syncthing.App
	backend                    backend.Backend
	cancel                     context.CancelFunc
	cert                       tls.Certificate
	config                     config.Wrapper
	ctx                        context.Context
	Delegate                   ClientDelegate
	evLogger                   events.Logger
	filesPath                  string
	IgnoreEvents               bool
	IsUsingCustomConfiguration bool
	Server                     *StreamingServer

	connectedDeviceAddresses map[string]string
	downloadProgress         map[string]map[string]*model.PullerProgress // folderID, path => progress
	uploadProgress           map[string]map[string]map[string]int        // deviceID, folderID, path => block count
	foldersDownloading       map[string]bool
	ResolvedListenAddresses  map[string][]string
	mutex                    sync.Mutex
	extraneousIgnored        []string
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

const (
	ConfigFileName       = "config.xml"
	ExportConfigFileName = "exported-config.xml"
	CertFileName         = "cert.pem"
	KeyFileName          = "key.pem"
	bookmarkFileName     = "sushitrain-bookmark.dat"
)

func NewClient(configPath string, filesPath string, saveLog bool) (*Client, error) {
	// Set version info
	build.Version = "v1.28.1"
	build.Host = "t-shaped.nl"
	build.User = "sushitrain"

	// Log to file
	if saveLog {
		logFilePath := path.Join(filesPath, fmt.Sprintf("%s.log", time.Now().UTC().Format("synctrain-2006-2-1-15-04-05")))
		logFile, err := os.Create(logFilePath)
		if err != nil {
			fmt.Println(err)
		}
		writer := bufio.NewWriter(logFile)
		logger.DefaultLogger.AddHandler(logger.LevelVerbose, func(l logger.LogLevel, msg string) {
			timeStamp := time.Now().UTC().Format("2006-02-01 15:04:05")
			var level string
			switch l {
			case logger.LevelDebug:
				level = "DEBUG"
			case logger.LevelInfo:
				level = "INFO"
			case logger.LevelWarn:
				level = "WARN"
			case logger.LevelVerbose:
				level = "VERBO"
			default:
				level = "OTHER"
			}

			_, err := writer.WriteString(fmt.Sprintf("%s\t%s: %s\n", level, timeStamp, msg))
			if err != nil {
				return
			}

			err = writer.Flush()
			if err != nil {
				return
			}
		})
	}

	// Some early chores
	osutil.MaximizeOpenFileLimit()

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
	customConfigFilePath := path.Join(filesPath, ConfigFileName)
	if info, err := os.Stat(customConfigFilePath); err == nil {
		if !info.IsDir() {
			Logger.Infoln("Config XML exists in files dir, using it at", customConfigFilePath)
			locations.Set(locations.ConfigFile, customConfigFilePath)
			isUsingCustomConfiguration = true
		}
	}

	// Check for custom user-provided identity
	customCertPath := path.Join(filesPath, CertFileName)
	customKeyPath := path.Join(filesPath, KeyFileName)
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
		foldersDownloading:         make(map[string]bool, 0),
		connectedDeviceAddresses:   make(map[string]string, 0),
		IsUsingCustomConfiguration: isUsingCustomConfiguration,
		filesPath:                  filesPath,
		IgnoreEvents:               false,
		uploadProgress:             make(map[string]map[string]map[string]int),
		ResolvedListenAddresses:    make(map[string][]string),
		extraneousIgnored:          make([]string, 0),
	}, nil
}

func (clt *Client) SetExtraneousIgnored(names []string) {
	clt.extraneousIgnored = names
}

func (clt *Client) SetExtraneousIgnoredJSON(js []byte) error {
	var names []string
	if err := json.Unmarshal(js, &names); err != nil {
		return err
	}
	clt.SetExtraneousIgnored(names)
	return nil
}

func (clt *Client) isExtraneousIgnored(name string) bool {
	// Must be an equal match for now
	return slices.Contains(clt.extraneousIgnored, name)
}

func (clt *Client) CurrentConfigDirectory() string {
	return locations.GetBaseDir(locations.ConfigBaseDir)
}

func (clt *Client) ExportConfigurationFile() error {
	cfg := clt.config.RawCopy()
	homeDir := locations.GetBaseDir(locations.UserHomeBaseDir)
	customConfigFilePath := path.Join(homeDir, ExportConfigFileName)
	fd, err := osutil.CreateAtomic(customConfigFilePath)
	if err != nil {
		return err
	}

	if err := cfg.WriteXML(osutil.LineEndingsWriter(fd)); err != nil {
		fd.Close()
		return err
	}

	if err := fd.Close(); err != nil {
		return err
	}
	return nil
}

func (clt *Client) Stop() {
	clt.app.Stop(svcutil.ExitSuccess)
	clt.cancel()
	clt.app.Wait()
}

func (clt *Client) handleEvent(evt events.Event) {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

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
		clt.foldersDownloading[folder] = folderTransferring
		if !clt.IgnoreEvents && clt.Delegate != nil {
			clt.Delegate.OnEvent(evt.Type.String())
		}

	case events.ListenAddressesChanged:
		if !clt.IgnoreEvents && clt.Delegate != nil {
			addrs := make([]string, 0)
			data := evt.Data.(map[string]interface{})
			addressSpec := data["address"].(*url.URL)
			wanAddresses := data["wan"].([]*url.URL)
			lanAddresses := data["lan"].([]*url.URL)

			for _, wa := range wanAddresses {
				addrs = append(addrs, wa.String())
			}
			for _, la := range lanAddresses {
				addrs = append(addrs, la.String())
			}
			clt.ResolvedListenAddresses[addressSpec.String()] = addrs

			// Get all current addresses and send to client
			currentResolved := make([]string, 0)
			for _, addrs := range clt.ResolvedListenAddresses {
				currentResolved = append(currentResolved, addrs...)
			}
			clt.Delegate.OnListenAddressesChanged(List(currentResolved))
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

	case events.RemoteDownloadProgress:
		peerData := evt.Data.(map[string]interface{})
		peerID := peerData["device"].(string)
		folderID := peerData["folder"].(string)
		state := peerData["state"].(map[string]int) // path: number of blocks downloaded
		if _, ok := clt.uploadProgress[peerID]; !ok {
			clt.uploadProgress[peerID] = make(map[string]map[string]int)
		}

		if _, ok := clt.uploadProgress[peerID][folderID]; !ok {
			clt.uploadProgress[peerID][folderID] = make(map[string]int)
		}

		clt.uploadProgress[peerID][folderID] = state

		if !clt.IgnoreEvents && clt.Delegate != nil {
			clt.Delegate.OnEvent(evt.Type.String())
		}

	case events.ItemFinished, events.ItemStarted:
		// Ignore these events
		break

	default:
		Logger.Debugln("EVENT", evt.Type.String(), evt)
	}
}

func (clt *Client) startEventListener() {
	sub := clt.evLogger.Subscribe(events.AllEvents)
	defer sub.Unsubscribe()

	for {
		select {
		case <-clt.ctx.Done():
			return
		case evt := <-sub.C():
			clt.handleEvent(evt)
		}
	}
}

func (clt *Client) IsUploading() bool {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	for _, uploadsPerFolder := range clt.uploadProgress {
		for _, uploads := range uploadsPerFolder {
			if len(uploads) > 0 {
				return true
			}
		}
	}
	return false
}

func (clt *Client) UploadingToPeers() *ListOfStrings {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	peers := make([]string, 0)
	for peerID, uploadsPerFolder := range clt.uploadProgress {
		peerHasUploads := false
		for _, uploads := range uploadsPerFolder {
			if len(uploads) > 0 {
				peerHasUploads = true
				break
			}
		}
		if peerHasUploads {
			peers = append(peers, peerID)
			break
		}
	}
	return List(peers)
}

func (clt *Client) UploadingFilesForPeerAndFolder(deviceID string, folderID string) *ListOfStrings {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	if uploads, ok := clt.uploadProgress[deviceID]; ok {
		if files, ok := uploads[folderID]; ok {
			return List(KeysOf(files))
		}
	}
	return &ListOfStrings{}
}

func (clt *Client) UploadingFoldersForPeer(deviceID string) *ListOfStrings {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	if uploads, ok := clt.uploadProgress[deviceID]; ok {
		return List(KeysOf(uploads))
	}
	return &ListOfStrings{}
}

func (clt *Client) GetLastPeerAddress(deviceID string) string {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	if addr, ok := clt.connectedDeviceAddresses[deviceID]; ok {
		return addr
	}
	return ""
}

func (clt *Client) IsDownloading() bool {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	for _, isTransferring := range clt.foldersDownloading {
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

		// On iOS and probably macOS, the absolute path to the apps container that has the synchronized folders changes on each
		// run. Therefore we re-set the absolute folder path here to [app documents directory]/[folder ID] if we don't have
		// a folder marker in the old location but do have one in the new.
		for _, folderConfig := range conf.Folders {
			standardPath := path.Join(filesPath, folderConfig.ID)
			if folderConfig.Path != standardPath {
				Logger.Warnln("Configured folder path differs from expected path:", folderConfig.Path, standardPath)

				oldMarkerPath := path.Join(folderConfig.Path, folderConfig.MarkerName)
				if _, err := os.Stat(oldMarkerPath); errors.Is(err, os.ErrNotExist) {
					newMarkerPath := path.Join(standardPath, folderConfig.MarkerName)
					if _, err := os.Stat(newMarkerPath); errors.Is(err, os.ErrNotExist) {
						Logger.Warnln("Marker does not exist at either old or new location, not changing anything", oldMarkerPath, newMarkerPath)
					} else {
						Logger.Warnln("Marker does not exist at old location and exists at new location, resetting standard path", oldMarkerPath, newMarkerPath, standardPath)
						folderConfig.Path = standardPath
						conf.SetFolder(folderConfig)
					}
				}
			}
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

/** Returns our node's device ID */
func (clt *Client) DeviceID() string {
	return protocol.NewDeviceID(clt.cert.Certificate[0]).String()
}

/** Returns our node's short device ID */
func (clt *Client) ShortDeviceID() string {
	return protocol.NewDeviceID(clt.cert.Certificate[0]).Short().String()
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

func (clt *Client) SuspendPeers() (*ListOfStrings, error) {
	suspended := make([]string, 0)
	clt.changeConfiguration(func(cfg *config.Configuration) {
		for _, dc := range clt.config.DeviceList() {
			if !dc.Paused {
				dc.Paused = true
				cfg.SetDevice(dc)
				suspended = append(suspended, dc.DeviceID.String())
			}
		}
	})
	Logger.Infoln("Suspended devices", suspended)
	return List(suspended), nil
}

func (clt *Client) Unsuspend(peers *ListOfStrings) error {
	ids := peers.data
	Logger.Infoln("Unsuspend IDs", ids)

	clt.changeConfiguration(func(cfg *config.Configuration) {
		for _, dc := range clt.config.DeviceList() {
			Logger.Infoln("Unsuspend?", dc.Paused, dc.DeviceID.String())
			if dc.Paused && slices.ContainsFunc(ids, func(v string) bool {
				did, err := protocol.DeviceIDFromString(v)
				return err == nil && dc.DeviceID.Equals(did)
			}) {
				dc.Paused = false
				cfg.SetDevice(dc)
				Logger.Infoln("Unsuspend", dc.DeviceID.String())
			}
		}
	})
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

// Leave path empty to add folder at default location
func (clt *Client) AddFolder(folderID string, folderPath string, createAsOnDemand bool) error {
	if clt.app == nil || clt.app.Internals == nil {
		return ErrStillLoading
	}

	folderConfig := clt.config.DefaultFolder()
	folderConfig.ID = folderID
	folderConfig.Label = folderID
	if len(folderPath) == 0 {
		folderConfig.Path = path.Join(clt.filesPath, folderID)
	} else {
		folderConfig.Path = folderPath
	}
	folderConfig.FSWatcherEnabled = false
	folderConfig.Paused = false

	// Add to configuration
	err := clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.SetFolder(folderConfig)
	})
	if err != nil {
		return err
	}

	// Set default ignores for on-demand sync
	if createAsOnDemand {
		return clt.app.Internals.SetIgnores(folderID, []string{"*"})
	} else {
		// Create empty .stignore anyway because there may be an old one lingering around
		return clt.app.Internals.SetIgnores(folderID, []string{})
	}
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

func (clt *Client) UploadProgressForPeerFolderPath(deviceID string, folderID string, path string) *Progress {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	if uploads, ok := clt.uploadProgress[deviceID]; ok {
		if files, ok := uploads[folderID]; ok {
			if blocksTransferred, ok := files[path]; ok {
				info, ok, err := clt.app.Internals.GlobalFileInfo(folderID, path)
				if !ok || err != nil {
					return nil
				}

				bytesTotal := info.FileSize()
				if bytesTotal == 0 {
					return nil
				}
				bytesDone := min(bytesTotal, int64(blocksTransferred)*int64(info.BlockSize()))

				return &Progress{
					BytesTotal: bytesTotal,
					BytesDone:  bytesDone,
					FilesTotal: 1,
					Percentage: float32(float64(bytesDone) / float64(bytesTotal)),
				}
			}
		}
	}
	return nil
}

func (clt *Client) GetTotalUploadProgress() *Progress {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

	if clt.uploadProgress == nil {
		return nil
	}

	var totalBytes int64 = 0
	var transferredBytes int64 = 0
	var totalFiles int64 = 0

	for _, info := range clt.uploadProgress {
		for folderID, finfo := range info {
			for path, blocksTransferred := range finfo {
				info, ok, err := clt.app.Internals.GlobalFileInfo(folderID, path)
				if !ok || err != nil {
					continue
				}
				totalBytes += info.Size
				bytesDone := min(info.Size, int64(blocksTransferred)*int64(info.BlockSize()))
				transferredBytes += bytesDone
				totalFiles += 1
			}
		}
	}

	if totalBytes == 0 {
		return nil
	}

	return &Progress{
		BytesTotal: totalBytes,
		BytesDone:  transferredBytes,
		FilesTotal: totalFiles,
		Percentage: float32(float64(transferredBytes) / float64(totalBytes)),
	}
}

func (clt *Client) GetTotalDownloadProgress() *Progress {
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

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
	clt.mutex.Lock()
	defer clt.mutex.Unlock()

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

			if gimmeMore && !f.IsDeleted() && strings.Contains(lowerFileName, text) {
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

func (clt *Client) ListenAddresses() *ListOfStrings {
	return List(clt.config.Options().RawListenAddresses)
}

func (clt *Client) SetListenAddresses(addrs *ListOfStrings) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.RawListenAddresses = addrs.data
	})
}

func (clt *Client) DiscoveryAddresses() *ListOfStrings {
	return List(clt.config.Options().RawGlobalAnnServers)
}

func (clt *Client) SetDiscoveryAddresses(addrs *ListOfStrings) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.RawGlobalAnnServers = addrs.data
	})
}

func (clt *Client) StunAddresses() *ListOfStrings {
	return List(clt.config.Options().RawStunServers)
}

func (clt *Client) SetStunAddresses(addrs *ListOfStrings) error {
	return clt.changeConfiguration(func(cfg *config.Configuration) {
		cfg.Options.RawStunServers = addrs.data
	})
}

func IsValidDeviceID(devID string) bool {
	_, err := protocol.DeviceIDFromString(devID)
	return err == nil
}

func Version() string {
	return build.Version
}

func LogInfo(message string) {
	Logger.Infoln("[App] " + message)
}

func LogWarn(message string) {
	Logger.Warnln("[App] " + message)
}
