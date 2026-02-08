package sushitrain

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"math"
	"slices"
	"sync"
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
	experiences  *experiences
	internals    *syncthing.Internals
}

func ClearBlockCache() {
	slog.Info("Purging blocks cache", "entries", blockCache.Len())
	blockCache.Purge()
}

// Download a range. Will retry until cancelled, and fail if there is no way a peer will come online to provide us the range
func (mp *miniPuller) downloadRange(ctx context.Context, m *syncthing.Internals, folderID string, file protocol.FileInfo, dest []byte, offset int64) (n int64, e error) {
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
		buf, err := mp.downloadBlock(ctx, folderID, int(blockIndex), file)
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
	return time.Duration(1000.0*max(1.0, float32(block.Size)/float32(minBytesPerSecond))) * time.Millisecond
}

type experiences struct {
	data  map[protocol.DeviceID]bool
	mutex sync.Mutex
}

func (exp *experiences) get(device protocol.DeviceID) (wasGood bool, haveExperience bool) {
	exp.mutex.Lock()
	defer exp.mutex.Unlock()
	wasGood, haveExperience = exp.data[device]
	return
}

func (exp *experiences) set(device protocol.DeviceID, wasGood bool) {
	exp.mutex.Lock()
	defer exp.mutex.Unlock()
	exp.data[device] = wasGood
}

// Download a block. Will retry until cancelled, and fail if there is no way a peer will come online to provide us the block
func (mp *miniPuller) downloadBlock(ctx context.Context, folderID string, blockIndex int, file protocol.FileInfo) ([]byte, error) {
	block := file.Blocks[blockIndex]
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

	slog.Info("download block", "index", blockIndex, "availablePeers", len(availables))

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
	var attempt = 0
	for {
		attempt += 1
		slog.Debug("downloadBlock", "attempt", attempt)

		for _, available := range availables {
			// Check if we were cancelled
			if err := ctx.Err(); err != nil {
				return nil, ctx.Err()
			}

			if exp, ok := mp.experiences.get(available.ID); ok && exp {
				// Skip devices we're not connected to
				if !mp.internals.IsConnectedTo(available.ID) {
					continue
				}

				downloadBlockCtx, cancelDownloadBlock := context.WithTimeout(ctx, mp.timeoutFor(&block))
				defer cancelDownloadBlock()
				slog.Debug("downloadBlock fetch good", "blockIndex", blockIndex, "from", available.ID)
				buf, err := mp.internals.DownloadBlock(downloadBlockCtx, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)
				// Remember our experience with this peer for next time (if the whole operation wasn't cancelled, which
				// would cause this call to be cancelled as well and fail with err == context.Canceled)
				if ctx.Err() == nil {
					mp.experiences.set(available.ID, err == nil)
				}

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
			if err := ctx.Err(); err != nil {
				return nil, ctx.Err()
			}

			if _, ok := mp.experiences.get(available.ID); !ok {
				// Skip devices we're not connected to
				if !mp.internals.IsConnectedTo(available.ID) {
					continue
				}

				downloadBlockCtx, cancelDownloadBlock := context.WithTimeout(ctx, mp.timeoutFor(&block))
				defer cancelDownloadBlock()
				slog.Debug("downloadBlock fetch new", "blockIndex", blockIndex, "from", available.ID)
				buf, err := mp.internals.DownloadBlock(downloadBlockCtx, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)

				// Remember our experience with this peer for next time (if the whole operation wasn't cancelled, which
				// would cause this call to be cancelled as well and fail with err == context.Canceled)
				if ctx.Err() == nil {
					mp.experiences.set(available.ID, err == nil)
				}

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
			if err := ctx.Err(); err != nil {
				return nil, ctx.Err()
			}

			if exp, ok := mp.experiences.get(available.ID); ok && !exp {
				// Skip devices we're not connected to
				if !mp.internals.IsConnectedTo(available.ID) {
					continue
				}

				downloadBlockCtx, cancelDownloadBlock := context.WithTimeout(ctx, mp.timeoutFor(&block))
				defer cancelDownloadBlock()
				slog.Debug("downloadBlock fetch bad", "blockIndex", blockIndex, "from", available.ID)
				buf, err := mp.internals.DownloadBlock(downloadBlockCtx, available.ID, folderID, file.Name, int(blockIndex), block, available.FromTemporary)

				// Remember our experience with this peer for next time (if the whole operation wasn't cancelled, which
				// would cause this call to be cancelled as well and fail with err == context.Canceled)
				if ctx.Err() == nil {
					mp.experiences.set(available.ID, err == nil)
				}

				if err == nil {
					blockCache.Add(blockHashString, buf)
					return buf, nil
				} else {
					slog.Info("bad peer", "id", available.ID, "error", err, "bufferSize", len(buf))
				}
			}
		}

		retryTime := time.Duration(700) * time.Millisecond
		slog.Debug("waiting for retry", "retryTime", retryTime)
		time.Sleep(retryTime)
	}
}

func newMiniPuller(measurements *Measurements, internals *syncthing.Internals) *miniPuller {
	return &miniPuller{
		experiences:  newExperiences(),
		measurements: measurements,
		internals:    internals,
	}
}

func (mp *miniPuller) downloadInto(ctx context.Context, w io.Writer, folderID string, info protocol.FileInfo) error {
	var wg sync.WaitGroup
	parallellism := 2

	chans := make([]chan []byte, parallellism)
	errChan := make(chan error, 1)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Spawn `parallellism` goroutines, each will fetch block i + n*parallellism
	for threadIndex := range parallellism {
		chans[threadIndex] = make(chan []byte, 1)
		go func() {
			wg.Add(1)
			defer wg.Done()

			var i = threadIndex
			for i < len(info.Blocks) {
				// Check if we were cancelled
				if err := ctx.Err(); err != nil {
					slog.Debug("download worker cancelled", "index", i, "threadIndex", threadIndex)
					return
				}

				slog.Debug("download block", "index", i, "threadIndex", threadIndex)
				buf, err := mp.downloadBlock(ctx, folderID, i, info)
				if err != nil {
					slog.Debug("download block error", "cause", err, "index", i, "threadIndex", threadIndex)
					errChan <- err
					return
				}
				slog.Debug("done block", "index", i, "threadIndex", threadIndex)
				// this will block until the  previous block we produced was read
				chans[threadIndex] <- buf
				i += parallellism
			}
		}()
	}

	defer wg.Wait()

	// Read the blocks in order
	for blockNo, _ := range info.Blocks {
		select {
		case err := <-errChan:
			slog.Info("download into error", "cause", err)
			cancel()
			return err

		case block := <-chans[blockNo%parallellism]:
			slog.Debug("download into write", "bytes", len(block))
			_, err := w.Write(block)
			if err != nil {
				slog.Info("download into write error", "cause", err)
				cancel()
				return err
			}
		}
	}

	return nil
}

func newExperiences() *experiences {
	return &experiences{
		data: map[protocol.DeviceID]bool{},
	}
}
