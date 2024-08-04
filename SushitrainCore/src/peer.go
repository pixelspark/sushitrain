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

func (self *Peer) DeviceID() string {
	return self.deviceID.String()
}

type Date struct {
	time time.Time
}

func (self *Date) IsZero() bool {
	return self.time.IsZero()
}

func (self *Date) UnixMilliseconds() int64 {
	return self.time.UnixMilli()
}

func (self *Peer) LastSeen() *Date {
	if self.client.app == nil {
		return nil
	}

	if self.client.app.Model == nil {
		return nil
	}

	stats, err := self.client.app.Model.DeviceStatistics()
	if err != nil {
		return nil
	}
	return &Date{time: stats[self.deviceID].LastSeen}
}

func (self *Peer) deviceConfiguration() *config.DeviceConfiguration {
	devs := self.client.config.Devices()
	dev, ok := devs[self.deviceID]
	if !ok {
		return nil
	}
	return &dev
}

func (self *Peer) Name() string {
	return self.deviceConfiguration().Name
}

func (self *Peer) SetName(name string) error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		dc, ok := cfg.DeviceMap()[self.deviceID]
		if !ok {
			return
		}
		dc.Name = name
		cfg.SetDevice(dc)
	})
}

func (self *Peer) Addresses() *ListOfStrings {
	return List(self.deviceConfiguration().Addresses)
}

func (self *Peer) IsConnected() bool {
	if self.client.app == nil {
		return false
	}
	if self.client.app.Model == nil {
		return false
	}

	return self.client.app.Model.IsConnectedTo(self.deviceID)
}

func (self *Peer) SetPaused(paused bool) error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		dc, ok := cfg.DeviceMap()[self.deviceID]
		if !ok {
			return
		}
		dc.Paused = paused
		cfg.SetDevice(dc)
	})
}

func (self *Peer) IsPaused() bool {
	return self.deviceConfiguration().Paused
}

func (self *Peer) SetUntrusted(untrusted bool) error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		dc, ok := cfg.DeviceMap()[self.deviceID]
		if !ok {
			return
		}
		dc.Untrusted = untrusted
		cfg.SetDevice(dc)
	})
}

func (self *Peer) IsUntrusted() bool {
	return self.deviceConfiguration().Untrusted
}

func (self *Peer) IsSelf() bool {
	return self.client.deviceID().Equals(self.deviceID)
}

func (self *Peer) Remove() error {
	return self.client.changeConfiguration(func(cfg *config.Configuration) {
		devices := make([]config.DeviceConfiguration, 0)
		for _, dc := range cfg.Devices {
			if dc.DeviceID != self.deviceID {
				devices = append(devices, dc)
			}
		}
		cfg.Devices = devices
	})
}

func (self *Peer) SharedFolderIDs() *ListOfStrings {
	folders := self.client.config.Folders()
	sharedWith := make([]string, 0)

	for fid, folder := range folders {
		for _, did := range folder.DeviceIDs() {
			if did == self.deviceID {
				sharedWith = append(sharedWith, fid)
				break
			}
		}
	}

	return List(sharedWith)
}

func (self *Peer) PendingFolderIDs() (*ListOfStrings, error) {
	pfs, err := self.client.app.Model.PendingFolders(self.deviceID)
	if err != nil {
		return nil, err
	}

	fids := make([]string, 0)
	for fid, _ := range pfs {
		fids = append(fids, fid)
	}

	return List(fids), nil
}

func (self *Peer) Exists() bool {
	return self.deviceConfiguration() != nil
}
