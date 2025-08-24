package sushitrain

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"math"
	"slices"
	"time"

	lru "github.com/hashicorp/golang-lru/v2"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
	"golang.org/x/exp/slog"
)

// Global cache of downloaded blocks. Block hash -> block data
// Blocks are between 128 KiB and 16 MiB size, this will use 1 GiB at most
var blockCache, _ = lru.New[string, []byte](64)

type miniPuller struct {
	measurements *Measurements
	experiences  map[protocol.DeviceID]bool
	context      context.Context
	internals    *syncthing.Internals
}

func ClearBlockCache() {
	slog.Info("Purging blocks cache", "entries", blockCache.Len())
	blockCache.Purge()
}

func (mp *miniPuller) downloadRange(m *syncthing.Internals, folderID string, file protocol.FileInfo, dest []byte, offset int64) (n int64, e error) {
	blockSize := int64(file.BlockSize())
	startBlock := offset / int64(blockSize)
	blockCount := min(ceilDiv(int64(len(dest)), blockSize), int64(len(file.Blocks)))

	// If we start halfway the first block, we need to fetch another one at the end to make up for it
	offsetInStartBlock := offset % int64(blockSize)
	if offsetInStartBlock > 0 {
		blockCount += 1
	}

	var written int64 = 0
	for blockIndex := startBlock; blockIndex < startBlock+blockCount; blockIndex++ {
		if int(blockIndex) > len(file.Blocks)-1 {
			break
		}

		// Fetch block
		block := file.Blocks[blockIndex]
		buf, err := mp.downloadBock(folderID, int(blockIndex), file, block)
		if err != nil {
			slog.Warn("error downloading block", "index", blockIndex, "total", len(file.Blocks), "cause", err)
			return 0, err
		}

		bufStart := int64(0)
		bufEnd := int64(len(buf))

		if block.Offset < offset {
			bufStart = offset - block.Offset
		}

		blockEnd := (block.Offset + int64(block.Size))
		rangeEnd := (int64(len(dest)) + offset)
		if blockEnd > rangeEnd {
			bufEnd = rangeEnd - block.Offset
		}
		if bufEnd < 0 {
			break
		}

		copy(dest[written:], buf[bufStart:bufEnd])
		written += bufEnd - bufStart
	}

	return written, nil
}

const minBytesPerSecond int = 1000 * 500 // Expect at least 62,5 KiB/s, or 500 kbit/s

func (mp *miniPuller) timeoutFor(block *protocol.BlockInfo) time.Duration {
	// At least one second, but otherwise at most the duration at the minimum expected rate
	return time.Duration(max(1.0, float32(block.Size)/float32(minBytesPerSecond))) * time.Second
}

func (mp *miniPuller) downloadBock(folderID string, blockIndex int, file protocol.FileInfo, block protocol.BlockInfo) ([]byte, error) {
	blockHashString := base64.StdEncoding.EncodeToString([]byte(block.Hash))

	// Do we have this file in the local cache?
	if cached, ok := blockCache.Get(blockHashString); ok {
		slog.Info("cache hit for block", "hash", blockHashString)
		return cached, nil
	}

	availables, err := mp.internals.BlockAvailability(folderID, file, block)
	if err != nil {
		return nil, err
	}
	if len(availables) < 1 {
		return nil, errors.New("no peer available")
	}

	slog.Info("download block", "index", blockIndex, "availablePeers", len(availables), "experiences", mp.experiences)

	// Sort availables by latency
	slices.SortFunc(availables, func(a model.Availability, b model.Availability) int {
		latencyA := mp.measurements.LatencyFor(a.ID.String())
		latencyB := mp.measurements.LatencyFor(b.ID.String())
		if math.IsNaN(latencyA) && math.IsNaN(latencyB) {
			return 0
		} else if math.IsNaN(latencyA) {
			return 1 // a > b
		} else if math.IsNaN(latencyB) {
			return -1 // b > a
		} else if latencyA > latencyB {
			return 1
		} else if latencyB > latencyA {
			return -1
		} else {
			return 0
		}
	})

	// Attempt to download the block from an available and 'known good' peers first
	for _, available := range availables {
		// Check if we were cancelled
		if err := mp.context.Err(); err != nil {
			return nil, mp.context.Err()
		}

		if exp, ok := mp.experiences[available.ID]; ok && exp {
			// Skip devices we're not connected to
			if !mp.internals.IsConnectedTo(available.ID) {
				continue
			}

			downloadBlockCtx, cancelDownloadBlock := context.WithTimeout(mp.context, mp.timeoutFor(&block))
			defer cancelDownloadBlock()
			buf, err := mp.internals.DownloadBlock(downloadBlockCtx, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
			// Remember our experience with this peer for next time
			mp.experiences[available.ID] = err == nil || err == context.Canceled
			if err == nil {
				blockCache.Add(blockHashString, buf)
				return buf, nil
			} else {
				slog.Info("good peer", "id", available.ID, "error", err, "bufferSize", len(buf))
			}
		}
	}

	// Failed to download from a good peer, let's try the peers we don't have any experience with
	for _, available := range availables {
		// Check if we were cancelled
		if err := mp.context.Err(); err != nil {
			return nil, mp.context.Err()
		}

		if _, ok := mp.experiences[available.ID]; !ok {
			// Skip devices we're not connected to
			if !mp.internals.IsConnectedTo(available.ID) {
				continue
			}

			downloadBlockCtx, cancelDownloadBlock := context.WithTimeout(mp.context, mp.timeoutFor(&block))
			defer cancelDownloadBlock()
			buf, err := mp.internals.DownloadBlock(downloadBlockCtx, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
			// Remember our experience with this peer for next time
			mp.experiences[available.ID] = err == nil || err == context.Canceled
			if err == nil {
				blockCache.Add(blockHashString, buf)
				return buf, nil
			} else {
				slog.Info("unknown peer", "id", available.ID, "error", err, "bufferSize", len(buf))
			}
		}
	}

	// Failed to download from a good or unknown peer, let's try the 'bad' peers once again
	for _, available := range availables {
		// Check if we were cancelled
		if err := mp.context.Err(); err != nil {
			return nil, mp.context.Err()
		}

		if exp, ok := mp.experiences[available.ID]; ok && !exp {
			// Skip devices we're not connected to
			if !mp.internals.IsConnectedTo(available.ID) {
				continue
			}

			downloadBlockCtx, cancelDownloadBlock := context.WithTimeout(mp.context, mp.timeoutFor(&block))
			defer cancelDownloadBlock()
			buf, err := mp.internals.DownloadBlock(downloadBlockCtx, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
			// Remember our experience with this peer for next time
			mp.experiences[available.ID] = err == nil || err == context.Canceled
			if err == nil {
				blockCache.Add(blockHashString, buf)
				return buf, nil
			} else {
				slog.Info("bad peer", "id", available.ID, "error", err, "bufferSize", len(buf))
			}
		}
	}

	return nil, errors.New("no peer to download this block from")
}

func newMiniPuller(ctx context.Context, measurements *Measurements, internals *syncthing.Internals) *miniPuller {
	return &miniPuller{
		experiences:  map[protocol.DeviceID]bool{},
		context:      ctx,
		measurements: measurements,
		internals:    internals,
	}
}

func (mp *miniPuller) DownloadInto(w io.Writer, folderID string, info protocol.FileInfo) error {
	for blockNo, block := range info.Blocks {
		buf, err := mp.downloadBock(folderID, blockNo, info, block)
		if err != nil {
			return err
		}
		_, err = w.Write(buf)
		if err != nil {
			return err
		}
	}
	return nil
}
