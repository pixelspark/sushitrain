// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
@preconcurrency import SushitrainCore
import Photos

let photoFSType: String = "sushitrain.photos.v1"

private class PhotoFS: NSObject {
	private let cacheLock = DispatchSemaphore(value: 1)
	private var cachedRoots: [String: StaticCustomFSDirectory] = [:]
}

enum CustomFSError: Error {
	case notADirectory
	case notAFile
}

enum PhotoFSError: LocalizedError {
	case albumNotFound
	case invalidURI
	case assetUnavailable

	var errorDescription: String? {
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
	// Mutable so a containing directory can rename an entry to resolve a name collision (see
	// StaticCustomFSDirectory.place).
	var entryName: String

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

	func bytes(_ ret: UnsafeMutablePointer<Int>?) throws {
		throw CustomFSError.notAFile
	}

	// By default entries are fully loaded into memory once (through data()). Large entries
	// (e.g. videos) override streams() to return true and implement read(at:length:) so they
	// can be read lazily in ranges without loading the whole file into memory.
	func streams() -> Bool {
		return false
	}

	func read(at offset: Int64, length: Int) throws -> Data {
		// Only invoked for streaming entries; non-streaming entries are served from data().
		throw CustomFSError.notAFile
	}
}

private protocol CustomFSDirectory {
	func getOrCreateSubdirectory(_ name: String) -> CustomFSDirectory
	func place(_ entry: CustomFSEntry)
}

private class StaticCustomFSDirectory: CustomFSEntry {
	var children: [CustomFSEntry]
	// Names already present among the children, kept in sync with `children` for O(1) collision checks.
	fileprivate var usedNames: Set<String>
	let modTime: Date

	init(_ name: String, children: [CustomFSEntry]) {
		self.children = children
		self.usedNames = Set(children.map { $0.name() })
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

extension StaticCustomFSDirectory: CustomFSDirectory {
	func getOrCreateSubdirectory(_ name: String) -> CustomFSDirectory {
		if let subDir = children.first(where: { $0.name() == name }) {
			if let subDir = subDir as? CustomFSDirectory {
				return subDir
			}
			else {
				fatalError("Expected a subdirectory, but found something else")
			}
		}
		else {
			// Create
			let subDir = StaticCustomFSDirectory(name, children: [])
			self.children.append(subDir)
			self.usedNames.insert(name)
			return subDir
		}
	}

	func place(_ entry: CustomFSEntry) {
		// Two assets can map to the same file name (e.g. re-imported photos, or a live photo's .MOV
		// colliding with a real video). Rename on collision so every child in a directory is unique;
		// otherwise the bridge would only ever resolve the first one and list the name twice.
		if self.usedNames.contains(entry.name()) {
			entry.entryName = self.uniqueName(for: entry.name())
		}
		self.usedNames.insert(entry.name())
		self.children.append(entry)
	}

	// Returns `name` if free, otherwise inserts a numeric suffix before the extension (IMG.MOV ->
	// IMG-1.MOV) until an unused name is found.
	private func uniqueName(for name: String) -> String {
		let ns = name as NSString
		let base = ns.deletingPathExtension
		let ext = ns.pathExtension
		var i = 1
		while true {
			let candidate = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
			if !self.usedNames.contains(candidate) {
				return candidate
			}
			i += 1
		}
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
	private let allowNetworkAccess: Bool
	private var cachedSize: Int? = nil

	init(_ name: String, asset: PHAsset, allowNetworkAccess: Bool) {
		self.asset = asset
		self.allowNetworkAccess = allowNetworkAccess
		super.init(name)
	}

	override func modifiedTime() -> Int64 {
		return Int64(asset.creationDate?.timeIntervalSince1970 ?? 0.0)
	}

	override func isDir() -> Bool {
		return false
	}

	override func bytes(_ ret: UnsafeMutablePointer<Int>?) throws {
		if let s = self.cachedSize {
			ret?.pointee = s
			return
		}
		let d = try self.data()
		self.cachedSize = d.count
		ret?.pointee = self.cachedSize!
	}

	override func data() throws -> Data {
		let options = PHImageRequestOptions()
		options.isSynchronous = true
		options.resizeMode = .none
		options.deliveryMode = .highQualityFormat
		options.isNetworkAccessAllowed = self.allowNetworkAccess
		options.allowSecondaryDegradedImage = false
		options.version = .current

		var exported: Data? = nil
		let start = Date()
		PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
			if let inICloud = info?[PHImageResultIsInCloudKey] as? NSNumber, inICloud.boolValue {
				Log.warn("Asset is in iCloud and therefore ignored: '\(self.asset.localIdentifier)'")
			}
			else if let info = info, let errorMessage = info[PHImageErrorKey] {
				Log.warn("Could not export asset '\(self.asset.localIdentifier)': \(errorMessage) \(info)")
			}
			exported = data
		}
		let duration = Date().timeIntervalSince(start)
		if duration > 1.0 {
			Log.warn(
				"Slow asset export: \(asset.localIdentifier) \(self.modifiedTime()) bytes=\(exported?.count ?? -1) duration=\(duration)"
			)
		}

		if let exported = exported {
			return exported
		}
		throw PhotoFSError.assetUnavailable
	}
}

// Base for file system entries whose contents are exported once to a cached file on disk and then
// read lazily in ranges through read(at:length:). Unlike images (small enough to be loaded into
// memory through data()), this avoids ever holding a whole video in memory, which would get the app
// killed by iOS, especially in the background. Subclasses provide which asset resource to export.
private class PhotoFSExportedMediaEntry: CustomFSEntry {
	fileprivate let asset: PHAsset
	private let allowNetworkAccess: Bool
	private let exportLock = NSLock()
	private var exportedURL: URL? = nil
	private var cachedSize: Int? = nil
	private var lastTouched: Date? = nil

	init(_ name: String, asset: PHAsset, allowNetworkAccess: Bool) {
		self.asset = asset
		self.allowNetworkAccess = allowNetworkAccess
		super.init(name)
	}

	override func isDir() -> Bool {
		return false
	}

	// Read lazily in ranges instead of being preloaded into memory.
	override func streams() -> Bool {
		return true
	}

	override func modifiedTime() -> Int64 {
		return Int64(asset.creationDate?.timeIntervalSince1970 ?? 0.0)
	}

	// The asset resource to export to disk. Overridden by subclasses (e.g. the original video, or the
	// paired video of a live photo). Returning nil makes the entry unavailable.
	fileprivate func resourceToExport() -> PHAssetResource? {
		return nil
	}

	// Discriminator added to the cache file name so different exports of the same asset (e.g. a video
	// versus a live photo's paired video) never collide.
	fileprivate var cacheDiscriminator: String {
		return ""
	}

	override func bytes(_ ret: UnsafeMutablePointer<Int>?) throws {
		// Fast path: size already known in memory.
		self.exportLock.lock()
		let cached = self.cachedSize
		self.exportLock.unlock()
		if let s = cached {
			ret?.pointee = s
			return
		}

		// Avoid exporting the whole file just to report its size (Syncthing calls this on every scan):
		// use the persisted size sidecar if present, even when the media file itself has been evicted.
		let key = self.currentCacheKey()
		if let key = key, let s = PhotoFSExportedMediaEntry.persistedSize(forKey: key) {
			self.exportLock.lock()
			self.cachedSize = s
			self.exportLock.unlock()
			ret?.pointee = s
			return
		}

		// Unknown size: export, measure, and persist it so future scans don't need to export again.
		let url = try self.ensureExported()
		let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
		let size = (attrs[.size] as? Int) ?? 0
		self.exportLock.lock()
		self.cachedSize = size
		self.exportLock.unlock()
		if let key = key {
			PhotoFSExportedMediaEntry.persistSize(size, forKey: key)
		}
		ret?.pointee = size
	}

	// The cache key for this entry's export, or nil if no resource is available. Does not export.
	private func currentCacheKey() -> String? {
		guard let resource = self.resourceToExport() else { return nil }
		return PhotoFSExportedMediaEntry.cacheKey(for: asset, resource: resource, discriminator: self.cacheDiscriminator)
	}

	// Refresh the cached file's modification date (LRU marker), at most once a minute. Caller holds exportLock.
	private func touchIfNeeded(_ url: URL) {
		if let last = self.lastTouched, Date().timeIntervalSince(last) < 60.0 {
			return
		}
		self.touch(url)
	}

	private func touch(_ url: URL) {
		try? FileManager.default.setAttributes(
			[.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
		self.lastTouched = Date()
	}

	override func read(at offset: Int64, length: Int) throws -> Data {
		let url = try self.ensureExported()
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		try handle.seek(toOffset: UInt64(max(0, offset)))
		return try handle.read(upToCount: length) ?? Data()
	}

	// Exports the asset resource to a cached file exactly once. Subsequent calls (including across tree
	// rebuilds, since the cache is keyed by asset identity and modification date) reuse the existing
	// file. Guarded by a lock so concurrent Syncthing reads never export twice.
	private func ensureExported() throws -> URL {
		self.exportLock.lock()
		defer { self.exportLock.unlock() }

		if let url = self.exportedURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
			// Keep an actively-read file out of the LRU eviction window during a long transfer.
			self.touchIfNeeded(url)
			return url
		}

		guard let resource = self.resourceToExport() else {
			throw PhotoFSError.assetUnavailable
		}

		let cacheDir = try PhotoFSExportedMediaEntry.cacheDirectory()
		let destURL = cacheDir.appendingPathComponent(
			PhotoFSExportedMediaEntry.cacheKey(for: asset, resource: resource, discriminator: self.cacheDiscriminator))

		// Reuse a previously exported file if it is still present. Touch its modification date so the
		// cache eviction (which is LRU by modification date) treats it as recently used.
		if FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false)) {
			self.touch(destURL)
			self.exportedURL = destURL
			return destURL
		}

		// Export to a unique temporary file first, then move it into place, so an interrupted export
		// can never be mistaken for a complete cache entry. writeData streams to disk, so the whole
		// file is never held in memory.
		let tmpURL = cacheDir.appendingPathComponent("tmp-" + UUID().uuidString)
		let options = PHAssetResourceRequestOptions()
		options.isNetworkAccessAllowed = self.allowNetworkAccess  // download iCloud-only assets if enabled

		let semaphore = DispatchSemaphore(value: 0)
		var exportError: Error? = nil
		PHAssetResourceManager.default().writeData(for: resource, toFile: tmpURL, options: options) { error in
			exportError = error
			semaphore.signal()
		}

		// Safety net: never block a Syncthing worker thread indefinitely (e.g. on a stuck iCloud fetch).
		if semaphore.wait(timeout: .now() + 120.0) == .timedOut {
			try? FileManager.default.removeItem(at: tmpURL)
			Log.warn("Timed out exporting media '\(asset.localIdentifier)'")
			throw PhotoFSError.assetUnavailable
		}

		if let exportError = exportError {
			try? FileManager.default.removeItem(at: tmpURL)
			Log.warn("Could not export media '\(asset.localIdentifier)': \(exportError.localizedDescription)")
			throw PhotoFSError.assetUnavailable
		}

		try? FileManager.default.removeItem(at: destURL)
		try FileManager.default.moveItem(at: tmpURL, to: destURL)
		self.exportedURL = destURL
		self.lastTouched = Date()  // freshly written

		// Keep the on-disk cache bounded. pruneCache() returns immediately (work runs on its own queue).
		PhotoFSExportedMediaEntry.pruneCache()
		return destURL
	}

	private static func cacheDirectory() throws -> URL {
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		let dir = base.appendingPathComponent("photofs-media", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private static func cacheKey(for asset: PHAsset, resource: PHAssetResource, discriminator: String) -> String {
		let id = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
		let mod = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0.0)
		let ext = (resource.originalFilename as NSString).pathExtension
		let disc = discriminator.isEmpty ? "" : "-\(discriminator)"
		return "\(id)\(disc)-\(mod).\(ext.isEmpty ? "mov" : ext)"
	}

	// Persisted exported-size sidecars (`<cacheKey>.size`). They are tiny, deterministic for a given
	// cache key (same original resource bytes), and outlive the media file so a scan can report a size
	// without re-exporting an evicted file. A missing/corrupt sidecar simply falls back to exporting.
	private static func sizeSidecarURL(forKey key: String) throws -> URL {
		return try cacheDirectory().appendingPathComponent(key + ".size")
	}

	private static func persistedSize(forKey key: String) -> Int? {
		guard let url = try? sizeSidecarURL(forKey: key),
			let data = try? Data(contentsOf: url),
			let text = String(data: data, encoding: .utf8),
			let size = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
		else {
			return nil
		}
		return size
	}

	private static func persistSize(_ size: Int, forKey key: String) {
		guard let url = try? sizeSidecarURL(forKey: key), let data = "\(size)".data(using: .utf8) else {
			return
		}
		try? data.write(to: url, options: .atomic)
	}

	// Soft cap on the on-disk export cache. A single asset larger than this is still kept (it is needed
	// to serve the file); iOS may additionally purge the Caches directory under storage pressure.
	private static let maxCacheBytes: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB

	// Files used (exported or touched) within this window are never evicted, to avoid deleting a file
	// that is currently being read, and to drop only genuinely orphaned temporary files.
	private static let evictionGrace: TimeInterval = 5 * 60

	// Serial queue that serializes cache pruning so concurrent exports never prune at the same time.
	private static let pruneQueue = DispatchQueue(label: "nl.t-shaped.sushitrain.photofs.prune", qos: .utility)

	// Asynchronously bounds the export cache (LRU by modification date) and removes orphaned temporary
	// files. Returns immediately; the work runs on a dedicated serial queue. A file deleted while still
	// being read either keeps serving its open handle or is transparently re-exported.
	fileprivate static func pruneCache() {
		PhotoFSExportedMediaEntry.pruneQueue.async {
			PhotoFSExportedMediaEntry.pruneCacheNow()
		}
	}

	private static func pruneCacheNow() {
		guard let dir = try? PhotoFSExportedMediaEntry.cacheDirectory() else { return }
		let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
		guard
			let urls = try? FileManager.default.contentsOfDirectory(
				at: dir, includingPropertiesForKeys: Array(keys))
		else { return }

		let now = Date()
		var items: [(url: URL, size: Int64, modified: Date)] = []
		var total: Int64 = 0

		for url in urls {
			guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
				continue
			}
			let size = Int64(values.fileSize ?? 0)
			let modified = values.contentModificationDate ?? .distantPast

			// Size sidecars are tiny and must outlive the media they describe: never count or evict them.
			if url.pathExtension == "size" {
				continue
			}

			// Drop orphaned temporary files left behind by interrupted or crashed exports.
			if url.lastPathComponent.hasPrefix("tmp-") {
				if now.timeIntervalSince(modified) > Self.evictionGrace {
					try? FileManager.default.removeItem(at: url)
				}
				continue
			}

			items.append((url: url, size: size, modified: modified))
			total += size
		}

		if total <= Self.maxCacheBytes {
			return
		}

		for item in items.sorted(by: { $0.modified < $1.modified }) {
			if total <= Self.maxCacheBytes {
				break
			}
			// Never evict very recently used files (likely in active use).
			if now.timeIntervalSince(item.modified) <= Self.evictionGrace {
				continue
			}
			if (try? FileManager.default.removeItem(at: item.url)) != nil {
				total -= item.size
			}
		}
	}
}

// A single video asset, exported as its original video resource.
private final class PhotoFSVideoEntry: PhotoFSExportedMediaEntry {
	fileprivate override func resourceToExport() -> PHAssetResource? {
		return asset.primaryResource
	}

	fileprivate override var cacheDiscriminator: String {
		return "video"
	}
}

// The paired video of a live photo, exported as a separate .MOV entry alongside the still image.
private final class PhotoFSLivePhotoEntry: PhotoFSExportedMediaEntry {
	fileprivate override func resourceToExport() -> PHAssetResource? {
		let resources = PHAssetResource.assetResources(for: asset)
		return resources.first(where: { $0.type == .fullSizePairedVideo })
			?? resources.first(where: { $0.type == .pairedVideo })
	}

	fileprivate override var cacheDiscriminator: String {
		return "live"
	}
}

// File system entry (directory) that represents a single album from the system photo library.
private class PhotoFSAlbumEntry: CustomFSEntry {
	private var children: [CustomFSEntry]? = nil
	private let config: PhotoFSAlbumConfiguration
	private var lastUpdate: Date? = nil
	private var lastChangeCounter = -1
	// Serializes update()/children access: the bridge calls childCount()/child(at:) from concurrent
	// Syncthing worker threads, and update() replaces `children` wholesale on library changes.
	private let lock = NSLock()

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

			// Faux directory used to give folderStructure.place a CustomFSDirectory interface for the root directory
			let fauxRoot = StaticCustomFSDirectory("", children: [])
			let structure = self.config.folderStructure ?? .singleFolder
			let timeZone = self.config.timeZone ?? .specific(timeZone: TimeZone.gmt.identifier)
			let categories = self.config.effectiveCategories
			let replaceExtension = self.config.livePhotoReplaceExtension ?? false
			let allowNetworkAccess = self.config.effectiveAllowNetworkAccess

			// Enumerate relevant assets
			let assets = PHAsset.fetchAssets(in: album, options: nil)
			assets.enumerateObjects { asset, index, stop in
				switch asset.mediaType {
				case .image:
					if categories.contains(.photo) {
						structure.place(
							asset: asset, root: fauxRoot, timeZone: timeZone, allowNetworkAccess: allowNetworkAccess)
					}
					// A live photo is an image asset with a paired video, exposed as a separate .MOV entry.
					if categories.contains(.livePhoto) && asset.mediaSubtypes.contains(.photoLive) {
						structure.placeLivePhoto(
							asset: asset, root: fauxRoot, timeZone: timeZone, replaceExtension: replaceExtension,
							allowNetworkAccess: allowNetworkAccess)
					}
				case .video:
					if categories.contains(.video) {
						structure.place(
							asset: asset, root: fauxRoot, timeZone: timeZone, allowNetworkAccess: allowNetworkAccess)
					}
				default:
					break
				}
			}

			self.lastUpdate = Date()
			var childrenList = fauxRoot.children
			Log.info("Enumerated album \(self.config.albumID): \(childrenList.count) assets")
			childrenList.sort { a, b in
				return a.name() < b.name()
			}
			self.children = childrenList
		}
	}

	override func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		self.lock.lock()
		defer { self.lock.unlock() }
		try self.update()
		let children = self.children ?? []
		// The library may have changed (and the tree shrunk) between the caller's childCount() and this
		// call; guard against an out-of-range index rather than crashing.
		guard index >= 0 && index < children.count else {
			throw CustomFSError.notAFile
		}
		return children[index]
	}

	override func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		self.lock.lock()
		defer { self.lock.unlock() }
		try self.update()
		ret?.pointee = self.children?.count ?? 0
	}
}

struct PhotoFSAlbumConfiguration: Codable, Equatable {
	var albumID: String = ""

	// Needs to be optional because older versions did not have this field
	var folderStructure: PhotoBackupFolderStructure? = nil

	var timeZone: PhotoBackupTimeZone? = nil

	// Media types to expose. Optional/nil for backward compatibility with configurations written
	// by older versions, which only ever synchronized photos.
	var categories: Set<PhotoBackupCategory>? = nil

	// Whether the paired video of a live photo replaces (IMG.MOV) or appends (IMG.HEIC.MOV) the .MOV
	// extension. Optional for backward compatibility; defaults to appending.
	var livePhotoReplaceExtension: Bool? = nil

	// Whether assets stored only in iCloud may be downloaded on access. When false (the default),
	// iCloud-only assets are skipped rather than downloaded. Optional for backward compatibility.
	var allowNetworkAccess: Bool? = nil

	var effectiveAllowNetworkAccess: Bool {
		return self.allowNetworkAccess ?? false
	}

	// The effective set of media types, defaulting to photos only (the historical behavior).
	var effectiveCategories: Set<PhotoBackupCategory> {
		return self.categories ?? [.photo]
	}

	var isValid: Bool {
		return !self.albumID.isEmpty
	}
}

struct PhotoFSConfiguration: Codable, Equatable {
	var folders: [String: PhotoFSAlbumConfiguration] = [:]
}

extension PhotoBackupFolderStructure {
	fileprivate func place(
		asset: PHAsset, root: CustomFSDirectory, timeZone: PhotoBackupTimeZone, allowNetworkAccess: Bool
	) {
		let translatedFileName = asset.fileNameInFolder(structure: self)
		let subdirs = asset.subdirectoriesInFolder(structure: self, timeZone: timeZone)

		var dir = root
		for dirName in subdirs {
			dir = dir.getOrCreateSubdirectory(dirName)
		}

		switch asset.mediaType {
		case .video:
			// Videos are read lazily in ranges from a cached export (see PhotoFSVideoEntry).
			dir.place(PhotoFSVideoEntry(translatedFileName, asset: asset, allowNetworkAccess: allowNetworkAccess))
		default:
			dir.place(PhotoFSAssetEntry(translatedFileName, asset: asset, allowNetworkAccess: allowNetworkAccess))
		}
	}

	// Places the paired video of a live photo as a separate .MOV entry, using the same naming as the
	// photo back-up (optionally in a "Live" subdirectory for type-grouped folder structures).
	fileprivate func placeLivePhoto(
		asset: PHAsset, root: CustomFSDirectory, timeZone: PhotoBackupTimeZone, replaceExtension: Bool,
		allowNetworkAccess: Bool
	) {
		let fileName = asset.livePhotoFileName(structure: self, replaceExtension: replaceExtension)
		let subdirs = asset.livePhotoSubdirectories(structure: self, timeZone: timeZone)

		var dir = root
		for dirName in subdirs {
			dir = dir.getOrCreateSubdirectory(dirName)
		}

		dir.place(PhotoFSLivePhotoEntry(fileName, asset: asset, allowNetworkAccess: allowNetworkAccess))
	}
}

extension PhotoFS: SushitrainCustomFilesystemTypeProtocol {
	func root(_ uri: String?) throws -> any SushitrainCustomFileEntryProtocol {
		guard let uri = uri else {
			throw PhotoFSError.invalidURI
		}

		// See if we have a root cached for this URI
		do {
			self.cacheLock.wait()
			defer {
				self.cacheLock.signal()
			}
			if let r = self.cachedRoots[uri] {
				return r
			}
		}

		// Attempt to decode URI as JSON containing a configuration struct
		var config = PhotoFSConfiguration()
		if let d = uri.data(using: .utf8) {
			config = (try? JSONDecoder().decode(PhotoFSConfiguration.self, from: d)) ?? config
		}

		let folderRoot = StaticCustomFSDirectory(
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
			])

		// Go over all configured albums and place them at the right locations in the entry tree
		for (folderPath, albumConfig) in config.folders {
			let trimmedPath = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmedPath.isEmpty {
				// Must have a path (can't place at root)
				Log.warn("Can't place folder album at root")
				continue
			}

			var subdirs = trimmedPath.split(separator: "/")
			guard let first = subdirs.first else {
				Log.warn("PhotoFS: skipping invalid subdirectory; folderPath was '\(folderPath)'")
				continue
			}

			// Check path components; they cannot be empty or just be "." or ".."
			var invalid = false
			for component in subdirs {
				let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(["."])))
				if trimmedComponent.isEmpty {
					Log.warn("PhotoFS: invalid path component: '\(component)'")
					invalid = true
					break
				}
			}

			if invalid {
				continue
			}

			if first.lowercased().starts(with: ".st") {
				// Can't place anything in .stfolder or over .stignore
				Log.warn("Can't place folder album over reserved subdirectory name: \(folderPath) \(first)")
				continue
			}

			var dir: CustomFSDirectory = folderRoot
			let lastDirName = String(subdirs.removeLast())
			for subdir in subdirs {
				dir = dir.getOrCreateSubdirectory(String(subdir))
			}

			let albumDirectory = try PhotoFSAlbumEntry(lastDirName, config: albumConfig)
			dir.place(albumDirectory)
		}

		// Cache root
		do {
			self.cacheLock.wait()
			defer {
				self.cacheLock.signal()
			}
			self.cachedRoots[uri] = folderRoot
		}

		// Ensure we are registered for photo library notifications
		Task.detached {
			// Apparently the PHPhotoLibrary.shared().register call can take a while, so we really don't want to do this on the main thread
			PhotoFSLibraryObserver.shared.registerForNotifications()

			// Opportunistically bound the export cache and clean up orphaned temporary files on load.
			PhotoFSExportedMediaEntry.pruneCache()
		}

		return folderRoot
	}
}

private final class PhotoFSLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
	nonisolated(unsafe) var changeCounter: Int = 0
	private let lock = DispatchSemaphore(value: 1)
	nonisolated(unsafe) private var registeredForNotifications = false

	static let shared = PhotoFSLibraryObserver()

	nonisolated func registerForNotifications() {
		var register = false
		self.lock.wait()
		if !self.registeredForNotifications {
			self.registeredForNotifications = true
			register = true
		}
		self.lock.signal()

		if register {
			PHPhotoLibrary.shared().register(self)
		}
	}

	func photoLibraryDidChange(_ changeInstance: PHChange) {
		Log.info("Photo library did change: \(changeInstance) \(self.changeCounter)")
		self.lock.wait()
		defer { self.lock.signal() }
		self.changeCounter += 1
	}
}

func registerPhotoFilesystem() {
	SushitrainRegisterCustomFilesystemType(photoFSType, PhotoFS())
}
