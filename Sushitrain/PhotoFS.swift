// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
@preconcurrency import SushitrainCore
import Photos

let PhotoFSType: String = "sushitrain.photos.v1"

private class PhotoFS: NSObject {
}

enum CustomFSError: Error {
	case notADirectory
	case notAFile
}

enum PhotoFSError: LocalizedError {
	case albumNotFound
	case invalidURI
	case assetUnavailable

	var errorDescription: String {
		switch self {
		case .albumNotFound:
			return String(localized: "album not found")
		case .invalidURI:
			return String(localized: "invalid configuration")
		case .assetUnavailable:
			return String(localized: "media file is currently unavailable")
		}
	}
}

private class CustomFSEntry: NSObject, SushitrainCustomFileEntryProtocol {
	let entryName: String

	internal init(_ name: String, _ children: [CustomFSEntry]? = nil) {
		self.entryName = name
	}

	func isDir() -> Bool {
		return false
	}

	func name() -> String {
		return self.entryName
	}

	func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		throw CustomFSError.notADirectory
	}

	func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		throw CustomFSError.notADirectory
	}

	func data() throws -> Data {
		throw CustomFSError.notAFile
	}

	func modifiedTime() -> Int64 {
		return 0
	}
}

private class StaticCustomFSDirectory: CustomFSEntry {
	let children: [CustomFSEntry]
	let modTime: Date

	init(_ name: String, children: [CustomFSEntry]) {
		self.children = children
		self.modTime = Date()
		super.init(name)
	}

	override func isDir() -> Bool {
		return true
	}

	override func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		return self.children[index]
	}

	override func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		ret?.pointee = self.children.count
	}

	override func modifiedTime() -> Int64 {
		return Int64(self.modTime.timeIntervalSince1970)
	}
}

private class StaticCustomFSEntry: CustomFSEntry {
	let contents: Data
	let modTime: Date

	init(_ name: String, contents: Data) {
		self.contents = contents
		self.modTime = Date()
		super.init(name, nil)
	}

	override func isDir() -> Bool {
		return false
	}

	override func data() throws -> Data {
		return self.contents
	}

	override func modifiedTime() -> Int64 {
		return Int64(self.modTime.timeIntervalSince1970)
	}
}

private class PhotoFSAssetEntry: CustomFSEntry {
	let asset: PHAsset

	init(_ name: String, asset: PHAsset) {
		self.asset = asset
		super.init(name)
	}

	override func modifiedTime() -> Int64 {
		return Int64(asset.creationDate?.timeIntervalSince1970 ?? 0.0)
	}

	override func isDir() -> Bool {
		return false
	}

	override func data() throws -> Data {
		let options = PHImageRequestOptions()
		options.isSynchronous = true
		options.resizeMode = .none
		options.deliveryMode = .highQualityFormat
		options.isNetworkAccessAllowed = true
		options.allowSecondaryDegradedImage = false
		options.version = .current

		var exported: Data? = nil
		PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
			if let info = info, let errorMessage = info[PHImageErrorKey] {
				Log.warn("Could not export asset \(self.asset.localIdentifier): \(errorMessage) \(info)")
			}
			exported = data
		}
		Log.info("Exported asset \(asset.localIdentifier) \(self.modifiedTime()) bytes=\(exported?.count ?? -1)")
		
		if let exported = exported {
			return exported
		}
		throw PhotoFSError.assetUnavailable
	}
}

private class PhotoFSAlbumEntry: CustomFSEntry {
	private var children: [CustomFSEntry]? = nil
	private let config: PhotoFSAlbumConfiguration
	private var lastUpdate: Date? = nil
	private var lastChangeCounter = -1

	init(_ name: String, config: PhotoFSAlbumConfiguration) throws {
		self.config = config
		super.init(name)
	}

	override func isDir() -> Bool {
		return true
	}

	// Returns true when listing this directory requires fetching assets from the photo library anew first
	// This is either when we detected a change, or when a time interval has passed (as fallback)
	private var isStale: Bool {
		if self.children == nil || self.lastUpdate == nil
			|| self.lastChangeCounter < PhotoFSLibraryObserver.shared.changeCounter
		{
			return true
		}
		if let d = self.lastUpdate, d.timeIntervalSinceNow < TimeInterval(-60 * 60) {
			return true
		}
		return false
	}

	private func update() throws {
		if self.isStale {
			self.lastChangeCounter = PhotoFSLibraryObserver.shared.changeCounter
			let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [self.config.albumID], options: nil)
			guard let album = fetchResult.firstObject else {
				throw PhotoFSError.albumNotFound
			}

			let assets = PHAsset.fetchAssets(in: album, options: nil)
			var children: [CustomFSEntry] = []

			assets.enumerateObjects { asset, index, stop in
				if asset.mediaType == .image {
					children.append(PhotoFSAssetEntry(asset.originalFilename, asset: asset))
				}
			}

			children.sort { a, b in
				return a.name() < b.name()
			}

			self.lastUpdate = Date()
			Log.info("Enumerated album \(self.config.albumID): \(children.count) assets")
			self.children = children
		}
	}

	override func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		try self.update()
		return self.children![index]
	}

	override func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		try self.update()
		ret?.pointee = self.children!.count
	}
}

struct PhotoFSAlbumConfiguration: Codable, Equatable {
	var albumID: String = ""

	var isValid: Bool {
		return !self.albumID.isEmpty
	}
}

struct PhotoFSConfiguration: Codable, Equatable {
	var folders: [String: PhotoFSAlbumConfiguration] = [:]
}

extension PhotoFS: SushitrainCustomFilesystemTypeProtocol {
	func root(_ uri: String?) throws -> any SushitrainCustomFileEntryProtocol {
		guard let uri = uri else {
			throw PhotoFSError.invalidURI
		}

		// Attempt to decode URI as JSON containing a configuration struct
		var config = PhotoFSConfiguration()
		if let d = uri.data(using: .utf8) {
			config = (try? JSONDecoder().decode(PhotoFSConfiguration.self, from: d)) ?? config
		}

		var albumFolders: [CustomFSEntry] = []
		for (folderName, albumConfig) in config.folders {
			if !folderName.isEmpty && folderName != ".stfolder" && folderName != ".stignore" {
				let folderNameClean = folderName.replacingOccurrences(of: "/", with: "_")
				albumFolders.append(try PhotoFSAlbumEntry(folderNameClean, config: albumConfig))
			}
		}

		let fs = StaticCustomFSDirectory(
			"",
			children: [
				// Folder marker (needs to be present for Syncthing to know the folder is healthy
				StaticCustomFSDirectory(
					".stfolder",
					children: [
						StaticCustomFSEntry(".photofs-marker", contents: "# EMPTY ON PURPOSE\n".data(using: .ascii)!)
					]),

				// Ignore file (empty for now)
				StaticCustomFSEntry(".stignore", contents: "# EMPTY ON PURPOSE\n".data(using: .ascii)!),

				// Albums (one directory for each)
			] + albumFolders)
		return fs
	}
}

private final class PhotoFSLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
	nonisolated(unsafe) var changeCounter: Int = 0
	private let lock = DispatchSemaphore(value: 1)

	static let shared = PhotoFSLibraryObserver()

	func photoLibraryDidChange(_ changeInstance: PHChange) {
		Log.info("Photo library did change: \(changeInstance) \(self.changeCounter)")
		self.lock.wait()
		defer { self.lock.signal() }
		self.changeCounter += 1
	}
}

func RegisterPhotoFilesystem() {
	SushitrainRegisterCustomFilesystemType(PhotoFSType, PhotoFS())
	PHPhotoLibrary.shared().register(PhotoFSLibraryObserver.shared)
}
