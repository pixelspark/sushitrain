// Copyright (C) 2025 Tommy van der Vorst
// Copyright (C) 2014 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
//
// This file contains helper functions to obtain encrypted file paths and file encryption keys.
// Some code is not accessible directly inside Syncthing, so it is copied here (under the MPL 2.0 license)
package sushitrain

import (
	"encoding/base32"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/miscreant/miscreant.go"
	"github.com/syncthing/syncthing/lib/fs"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/scanner"
	"google.golang.org/protobuf/encoding/protowire"
)

const (
	keySize               = 32 // fits both chacha20poly1305 and AES-SIV
	miscreantAlgo         = "AES-SIV"
	maxPathComponent      = 200              // characters
	encryptedDirExtension = ".syncthing-enc" // for top level dirs
)

var base32Hex = base32.HexEncoding.WithPadding(base32.NoPadding)

// encryptDeterministic encrypts bytes using AES-SIV
func encryptDeterministic(data []byte, key *[keySize]byte, additionalData []byte) []byte {
	aead, err := miscreant.NewAEAD(miscreantAlgo, key[:], 0)
	if err != nil {
		panic("cipher failure: " + err.Error())
	}
	return aead.Seal(nil, nil, data, additionalData)
}

// decryptDeterministic decrypts bytes using AES-SIV
func decryptDeterministic(data []byte, key *[keySize]byte, additionalData []byte) ([]byte, error) {
	aead, err := miscreant.NewAEAD(miscreantAlgo, key[:], 0)
	if err != nil {
		panic("cipher failure: " + err.Error())
	}
	return aead.Open(nil, nil, data, additionalData)
}

// slashify inserts slashes (and file extension) in the string to create an
// appropriate tree. ABCDEFGH... => A.syncthing-enc/BC/DEFGH... We can use
// forward slashes here because we're on the outside of native path formats,
// the slash is the wire format.
func slashify(s string) string {
	// We somewhat sloppily assume bytes == characters here, but the only
	// file names we should deal with are those that come from our base32
	// encoding.

	comps := make([]string, 0, len(s)/maxPathComponent+3)
	comps = append(comps, s[:1]+encryptedDirExtension)
	s = s[1:]
	comps = append(comps, s[:2])
	s = s[2:]

	for len(s) > maxPathComponent {
		comps = append(comps, s[:maxPathComponent])
		s = s[maxPathComponent:]
	}
	if len(s) > 0 {
		comps = append(comps, s)
	}
	return strings.Join(comps, "/")
}

// deslashify removes slashes and encrypted file extensions from the string.
// This is the inverse of slashify().
func deslashify(s string) (string, error) {
	if s == "" || !strings.HasPrefix(s[1:], encryptedDirExtension) {
		return "", fmt.Errorf("invalid encrypted path: %q", s)
	}
	s = s[:1] + s[1+len(encryptedDirExtension):]
	return strings.ReplaceAll(s, "/", ""), nil
}

// decryptName decrypts a string from encryptName
func decryptName(name string, key *[keySize]byte) (string, error) {
	name, err := deslashify(name)
	if err != nil {
		return "", err
	}
	bs, err := base32Hex.DecodeString(name)
	if err != nil {
		return "", err
	}
	dec, err := decryptDeterministic(bs, key, nil)
	if err != nil {
		return "", err
	}

	return string(dec), nil
}

func (folder *Folder) folderKey(password string) *[keySize]byte {
	keyGen := protocol.NewKeyGenerator()
	return keyGen.KeyFromPassword(folder.FolderID, password)
}

type FolderKey struct {
	key *[keySize]byte
}

func NewFolderKey(folderID string, password string) *FolderKey {
	keyGen := protocol.NewKeyGenerator()
	return &FolderKey{
		key: keyGen.KeyFromPassword(folderID, password),
	}
}

func (fk *FolderKey) DecryptedFilePath(path string) (string, error) {
	return decryptName(path, fk.key)
}

func (fk *FolderKey) DecryptFile(encryptedRoot string, encryptedPathWithVersion string, encryptedPathWithoutVersion string, destRoot string, keepFolderStructure bool) error {
	destPath, err := fk.DecryptedFilePath(encryptedPathWithoutVersion)
	if err != nil {
		return err
	}

	if !keepFolderStructure {
		// Just keep the encrypted file's name
		destPath = filepath.Base(destPath)
	}

	keyGen := protocol.NewKeyGenerator()

	// Create destination folder
	dstFs := fs.NewFilesystem(fs.FilesystemTypeBasic, destRoot)
	dstFs.MkdirAll(filepath.Dir(destPath), 0o700)

	// Load encrypted file info
	srcFs := fs.NewFilesystem(fs.FilesystemTypeBasic, encryptedRoot)
	encFd, err := srcFs.Open(encryptedPathWithVersion)
	if err != nil {
		return err
	}
	defer encFd.Close()

	// Create destination file
	dstFd, err := dstFs.Create(destPath)
	if err != nil {
		return err
	}
	defer dstFd.Close()

	encryptedBlocks, encryptedFileInfoBytes, err := loadBlocks(encFd)
	if err != nil {
		return fmt.Errorf("%s: loading metadata trailer: %w", encryptedPathWithVersion, err)
	}

	// Construct a fake FileInfo object that satisfies protocol.DecryptFileInfo just enough to trick it into decrypting
	// the Encrypted field.
	encryptedFileInfo := protocol.FileInfo{
		Name:      encryptedPathWithoutVersion,
		Encrypted: encryptedFileInfoBytes,
	}

	plainFileInfo, err := protocol.DecryptFileInfo(keyGen, encryptedFileInfo, fk.key)
	if err != nil {
		return fmt.Errorf("decrypting metadata: %w", err)
	}

	if len(encryptedBlocks) != len(plainFileInfo.Blocks) {
		return fmt.Errorf("block count differs: encrypted %d != plaintext %d", len(encryptedBlocks), len(plainFileInfo.Blocks))
	}

	fileKey := keyGen.FileKey(plainFileInfo.Name, fk.key)

	// Decrypt blocks!
	for i, encryptedBlock := range encryptedBlocks {
		plainBlock := plainFileInfo.Blocks[i]

		// Read the encrypted block
		buf := make([]byte, encryptedBlock.size)
		if _, err := encFd.ReadAt(buf, int64(encryptedBlock.offset)); err != nil {
			return fmt.Errorf("reading encrypted block %d (%d bytes): %w", i, encryptedBlock.size, err)
		}

		// Decrypt the block
		decryptedBlock, err := protocol.DecryptBytes(buf, fileKey)
		if err != nil {
			return fmt.Errorf("decrypting block %d (%d bytes): %w", i, encryptedBlock.size, err)
		}

		// remove padding from last block (if length mismatches)
		if i == len(plainFileInfo.Blocks)-1 && len(decryptedBlock) > plainBlock.Size {
			decryptedBlock = decryptedBlock[:plainBlock.Size]
		} else if len(decryptedBlock) != plainBlock.Size {
			return fmt.Errorf("plain-text block %d size mismatch, actual %d != expected %d", i, len(decryptedBlock), plainBlock.Size)
		}

		// verify block hash using plain block info
		if !scanner.Validate(decryptedBlock, plainBlock.Hash) {
			return fmt.Errorf("has for block %d mismatches", i)
		}

		// Write to the destination
		if _, err := dstFd.WriteAt(decryptedBlock, plainBlock.Offset); err != nil {
			return err
		}
	}

	// Set metadata
	if err = dstFs.Chtimes(destPath, plainFileInfo.ModTime(), plainFileInfo.ModTime()); err != nil {
		return err
	}

	return nil
}

func (entry *Entry) EncryptedFilePath(folderPassword string) string {
	key := entry.Folder.folderKey(folderPassword)
	enc := encryptDeterministic([]byte(entry.info.Name), key, nil)
	return slashify(base32Hex.EncodeToString(enc))
}

func (folder *Folder) DecryptedFilePath(encryptedPath string, folderPassword string) string {
	path, err := decryptName(encryptedPath, folder.folderKey(folderPassword))
	if err != nil {
		return ""
	}
	return path
}

func (entry *Entry) FileKeyBase32(password string) string {
	folderKey := entry.Folder.folderKey(password)
	keyGen := protocol.NewKeyGenerator()
	fileKey := keyGen.FileKey(entry.info.Name, folderKey)
	return base32Hex.EncodeToString(fileKey[:])
}

type encryptedBlock struct {
	offset uint64
	size   uint64
}

// See https://github.com/syncthing/syncthing/tree/main/proto/bep
const FileInfoFieldBlockInfoList protowire.Number = 16
const FileInfoFieldEncrypted protowire.Number = 19
const BlockInfoFieldOffset protowire.Number = 1
const BlockInfoFieldSize protowire.Number = 2

// Poor man's Protobuf wire format parser. Used because we don't want to import the whole BEP schema nor want to deal with
// protoc in our build workflow. We just stream the Protobuf type-length-value structures and pluck out the fields we need.
func parseProtobuf(buffer []byte, parser func(field protowire.Number, fieldType protowire.Type, buffer []byte) (int, error)) error {
	for len(buffer) > 0 {
		fieldNumber, fieldType, length := protowire.ConsumeTag(buffer)
		if length < 0 {
			return protowire.ParseError(length)
		}
		buffer = buffer[length:]

		n, err := parser(fieldNumber, fieldType, buffer)
		if err != nil {
			return err
		}
		if n < 0 {
			return protowire.ParseError(length)
		}
		buffer = buffer[n:]
	}

	return nil
}

func parseBlockInfo(biBuffer []byte) (encryptedBlock, error) {
	block := encryptedBlock{}
	e := parseProtobuf(biBuffer, func(field protowire.Number, fieldType protowire.Type, buffer []byte) (n int, err error) {
		switch field {
		case BlockInfoFieldOffset:
			if fieldType != protowire.VarintType {
				return 0, errors.New("invalid field type")
			}
			block.offset, n = protowire.ConsumeVarint(buffer)
			return

		case BlockInfoFieldSize:
			if fieldType != protowire.VarintType {
				return 0, errors.New("invalid field type")
			}
			block.size, n = protowire.ConsumeVarint(buffer)
			return

		default:
			return protowire.ConsumeFieldValue(field, fieldType, buffer), nil
		}
	})

	return block, e
}

func loadBlocks(fd fs.File) (blocks []encryptedBlock, encryptedFileInfo []byte, err error) {
	// Seek to the size of the trailer block
	if _, err := fd.Seek(-4, io.SeekEnd); err != nil {
		return nil, nil, err
	}
	var bs [4]byte
	if _, err := io.ReadFull(fd, bs[:]); err != nil {
		return nil, nil, err
	}
	size := int64(binary.BigEndian.Uint32(bs[:]))

	// Seek to the start of the trailer
	if _, err := fd.Seek(-(4 + size), io.SeekEnd); err != nil {
		return nil, nil, err
	}
	trailer := make([]byte, size)
	if _, err := io.ReadFull(fd, trailer); err != nil {
		return nil, nil, err
	}

	// Parse the trailer. In particular we want the list of blocks and the sequence
	blocks = make([]encryptedBlock, 0)
	parseProtobuf(trailer, func(field protowire.Number, fieldType protowire.Type, buffer []byte) (n int, err error) {
		switch field {
		case FileInfoFieldEncrypted:
			if fieldType != protowire.BytesType {
				return 0, errors.New("invalid field type")
			}
			encryptedFileInfo, n = protowire.ConsumeBytes(buffer)
			return

		case FileInfoFieldBlockInfoList:
			var blockInfoBytes []byte
			if fieldType != protowire.BytesType {
				return 0, errors.New("invalid field type")
			}
			blockInfoBytes, n = protowire.ConsumeBytes(buffer)
			var blockInfo encryptedBlock
			blockInfo, err = parseBlockInfo(blockInfoBytes)
			if err != nil {
				return 0, errors.New("invalid field type")
			}
			blocks = append(blocks, blockInfo)
			return

		default:
			return protowire.ConsumeFieldValue(field, fieldType, buffer), nil
		}
	})

	return blocks, encryptedFileInfo, nil
}
