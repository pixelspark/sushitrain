// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
package sushitrain

import (
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

type Peer struct {
	client   *Client
	deviceID protocol.DeviceID
}

func (peer *Peer) DeviceID() string {
	return peer.deviceID.String()
}

type Date struct {
	time time.Time
}

func (date *Date) IsZero() bool {
	return date.time.IsZero()
}

func (date *Date) UnixMilliseconds() int64 {
	return date.time.UnixMilli()
}

func (peer *Peer) LastSeen() *Date {
	if peer.client.app == nil {
		return nil
	}

	if peer.client.app.Internals == nil {
		return nil
	}

	stats, err := peer.client.app.Internals.DeviceStatistics()
	if err != nil {
		return nil
	}
	return &Date{time: stats[peer.deviceID].LastSeen}
}

func (peer *Peer) deviceConfiguration() *config.DeviceConfiguration {
	devs := peer.client.config.Devices()
	dev, ok := devs[peer.deviceID]
	if !ok {
		return nil
	}
	return &dev
}

func (peer *Peer) Name() string {
	return peer.deviceConfiguration().Name
}

func (peer *Peer) SetName(name string) error {
	return peer.client.changeConfiguration(func(cfg *config.Configuration) {
		dc, ok := cfg.DeviceMap()[peer.deviceID]
		if !ok {
			return
		}
		dc.Name = name
		cfg.SetDevice(dc)
	})
}

func (peer *Peer) Addresses() *ListOfStrings {
	return List(peer.deviceConfiguration().Addresses)
}

func (peer *Peer) IsConnected() bool {
	if peer.client.app == nil {
		return false
	}
	if peer.client.app.Internals == nil {
		return false
	}

	return peer.client.app.Internals.IsConnectedTo(peer.deviceID)
}

func (peer *Peer) SetPaused(paused bool) error {
	return peer.client.changeConfiguration(func(cfg *config.Configuration) {
		dc, ok := cfg.DeviceMap()[peer.deviceID]
		if !ok {
			return
		}
		dc.Paused = paused
		cfg.SetDevice(dc)
	})
}

func (peer *Peer) IsPaused() bool {
	return peer.deviceConfiguration().Paused
}

func (peer *Peer) SetUntrusted(untrusted bool) error {
	return peer.client.changeConfiguration(func(cfg *config.Configuration) {
		dc, ok := cfg.DeviceMap()[peer.deviceID]
		if !ok {
			return
		}
		dc.Untrusted = untrusted
		cfg.SetDevice(dc)
	})
}

func (peer *Peer) IsUntrusted() bool {
	return peer.deviceConfiguration().Untrusted
}

func (peer *Peer) IsSelf() bool {
	return peer.client.deviceID().Equals(peer.deviceID)
}

func (peer *Peer) Remove() error {
	return peer.client.changeConfiguration(func(cfg *config.Configuration) {
		devices := make([]config.DeviceConfiguration, 0)
		for _, dc := range cfg.Devices {
			if dc.DeviceID != peer.deviceID {
				devices = append(devices, dc)
			}
		}
		cfg.Devices = devices
	})
}

func (peer *Peer) SharedFolderIDs() *ListOfStrings {
	folders := peer.client.config.Folders()
	sharedWith := make([]string, 0)

	for fid, folder := range folders {
		for _, did := range folder.DeviceIDs() {
			if did == peer.deviceID {
				sharedWith = append(sharedWith, fid)
				break
			}
		}
	}

	return List(sharedWith)
}

func (peer *Peer) PendingFolderIDs() (*ListOfStrings, error) {
	pfs, err := peer.client.app.Internals.PendingFolders(peer.deviceID)
	if err != nil {
		return nil, err
	}

	fids := make([]string, 0)
	for fid := range pfs {
		fids = append(fids, fid)
	}

	return List(fids), nil
}

func (peer *Peer) Exists() bool {
	return peer.deviceConfiguration() != nil
}
