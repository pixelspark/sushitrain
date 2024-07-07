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

func (self *Date) UnixMilliseconds() int64 {
	return self.time.UnixMilli()
}

func (self *Peer) LastSeen() *Date {
	if self.client.app == nil {
		return nil
	}

	if self.client.app.M == nil {
		return nil
	}

	stats, err := self.client.app.M.DeviceStatistics()
	if err != nil {
		return nil
	}
	return &Date{time: stats[self.deviceID].LastSeen}
}

func (self *Peer) deviceConfiguration() config.DeviceConfiguration {
	devs := self.client.config.Devices()
	return devs[self.deviceID]
}

func (self *Peer) Name() string {
	return self.deviceConfiguration().Name
}

func (self *Peer) Addresses() *ListOfStrings {
	return List(self.deviceConfiguration().Addresses)
}

func (self *Peer) IsConnected() bool {
	if self.client.app == nil {
		return false
	}
	if self.client.app.M == nil {
		return false
	}

	return self.client.app.M.ConnectedTo(self.deviceID)
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
