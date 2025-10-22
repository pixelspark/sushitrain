// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import QuickLookThumbnailing
import AVKit

#if os(macOS)
	extension NSImage {
		static func fromCIImage(_ ciImage: CIImage) -> NSImage {
			let rep = NSCIImageRep(ciImage: ciImage)
			let nsImage = NSImage(size: rep.size)
			nsImage.addRepresentation(rep)
			return nsImage
		}
	}
#endif

enum ImageFetchError: Swift.Error {
	case failedToFetchImage
	case failedToDownsample
}

private func fetchQuicklookThumbnail(_ url: URL, size: CGSize) async -> AsyncImagePhase {
	#if os(iOS)
		let scale = await UIScreen.main.scale
	#else
		let scale = 1.0
	#endif
	let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
	do {
		let thumb = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
		#if os(iOS)
			return .success(Image(uiImage: thumb.uiImage))
		#else
			return .success(Image(decorative: thumb.cgImage, scale: 1, orientation: .up))
		#endif
	}
	catch {
		return .failure(error)
	}
}

private func fetchVideoThumbnail(url: URL, maxDimensionsInPixels: Int) async -> AsyncImagePhase {
	return await
		(Task {
			let asset = AVURLAsset(url: url)
			let avAssetImageGenerator = AVAssetImageGenerator(asset: asset)
			avAssetImageGenerator.appliesPreferredTrackTransform = true
			let thumbnailTime = CMTimeMake(value: 2, timescale: 1)
			do {
				let (cgThumbImage, _) = try await avAssetImageGenerator.image(at: thumbnailTime)
				let thumbnailSize = CGSizeMake(
					CGFloat(cgThumbImage.width), CGFloat(cgThumbImage.height)
				)
				.fitScale(maxDimension: CGFloat(maxDimensionsInPixels))

				if let downsampledImage = cgThumbImage.resize(size: thumbnailSize) {
					#if os(iOS)
						return AsyncImagePhase.success(
							Image(uiImage: UIImage(cgImage: downsampledImage)))
					#else
						return AsyncImagePhase.success(
							Image(nsImage: NSImage(cgImage: downsampledImage, size: .zero)))
					#endif
				}
				else {
					return AsyncImagePhase.empty
				}
			}
			catch {
				return AsyncImagePhase.failure(error)
			}
		}.value)
}

let fetchQueue = DispatchQueue(label: "fetchImageQueue", qos: .background)

private func fetchImageThumbnail(_ url: URL, maxDimensionsInPixels: Int) async -> AsyncImagePhase {
	// This is here to fix "Thread running at User-initiated quality-of-service class waiting on a lower QoS thread
	// running at Default quality-of-service class. Investigate ways to avoid priority inversions" warning from
	// thread performance checker.
	await Task(priority: .background) {
		// For other files, fetch from URL
		let imageSourceOption = [kCGImageSourceShouldCache: false] as CFDictionary
		guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOption) else {
			return .failure(ImageFetchError.failedToFetchImage)
		}

		let downsampledOptions =
			[
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceShouldCache: true,
				kCGImageSourceCreateThumbnailWithTransform: true,
				kCGImageSourceThumbnailMaxPixelSize: maxDimensionsInPixels,
			] as CFDictionary

		guard
			let downsampledImage = CGImageSourceCreateThumbnailAtIndex(
				imageSource,
				0,
				downsampledOptions
			)
		else {
			return .failure(ImageFetchError.failedToDownsample)
		}

		#if os(iOS)
			return .success(Image(uiImage: UIImage(cgImage: downsampledImage)))
		#else
			return .success(Image(nsImage: NSImage(cgImage: downsampledImage, size: .zero)))
		#endif
	}.value

}

enum ThumbnailStrategy {
	case image
	case video
}

private let maxThumbnailDimensionsInPixels = 255

private enum ThumbnailImageError: Error {
	case invalidCacheKey
	case invalidLocalURL
}

struct ThumbnailImage<Content>: View where Content: View {
	private let entry: SushitrainEntry
	@ViewBuilder var content: (AsyncImagePhase) -> Content

	@State private var phase: AsyncImagePhase = .empty

	init(
		entry: SushitrainEntry,
		@ViewBuilder content: @escaping (AsyncImagePhase) -> Content
	) {
		self.entry = entry
		self.content = content
	}

	var body: some View {
		self.content(phase)
			.task {
				self.phase = await fetchOrCached()
			}
			.onChange(of: self.entry) { (ov, nv) in
				Task {
					self.phase = await fetchOrCached()
				}
			}
	}

	private func fetchOrCached() async -> AsyncImagePhase {
		return await ImageCache.forFolder(entry.folder).getThumbnail(file: self.entry, forceCache: false)
	}
}

@MainActor class ImageCache {
	static let shared = ImageCache()
	private static var byFolder: [String: ImageCache] = [:]

	static func forFolder(_ folder: SushitrainFolder?) -> ImageCache {
		guard let folder = folder else {
			return Self.shared
		}

		let settings = FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
		switch settings {
		case .global:
			Self.byFolder.removeValue(forKey: folder.folderID)
			return Self.shared

		case .deviceLocal, .inside(_), .disabled:
			guard let bf = Self.byFolder[folder.folderID] else {
				let ic = ImageCache()
				Self.byFolder[folder.folderID] = ic
				return ic
			}

			bf.configure(settings, folder: folder)
			return bf
		}
	}

	private var cache: [String: Image] = [:]
	private var maxCacheSize = 255
	private var minDiskFreeBytes = 1024 * 1024 * 1024 * 1  // 1 GiB
	var diskCacheEnabled: Bool = true
	var customCacheDirectory: URL? = nil

	private func configure(_ settings: ThumbnailGeneration, folder: SushitrainFolder) {
		switch settings {
		case .disabled:
			self.diskCacheEnabled = false

		case .global:
			// Unreachable because for these folders we return the global cache
			self.diskCacheEnabled = false
			self.customCacheDirectory = nil

		case .deviceLocal:
			let folderSpecificPath = URL.cachesDirectory.appendingPathComponent("thumbnails", isDirectory: true)
				.appendingPathComponent(folder.folderID, isDirectory: true)
			self.customCacheDirectory = folderSpecificPath
			self.diskCacheEnabled = true

		case .inside(var path):
			if path.isEmpty {
				path = ThumbnailGeneration.defaultInsideFolderThumbnailPath
			}
			self.customCacheDirectory = folder.localNativeURL?.appendingPathComponent(path, isDirectory: true)
			self.diskCacheEnabled = true
		}
	}

	private var cacheDirectory: URL {
		if let cc = self.customCacheDirectory {
			return cc
		}
		return URL.cachesDirectory.appendingPathComponent("thumbnails", isDirectory: true)
	}

	var diskHasSpace: Bool {
		if let vals = try? self.cacheDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
			if let f = vals.volumeAvailableCapacity {
				return f > self.minDiskFreeBytes
			}
			else {
				Log.warn("Did not get volume capacity")
			}
		}
		else {
			Log.warn("Could not get free disk space - resourceValues call failed")
		}
		return true
	}

	private func pathFor(cacheKey: String) -> URL {
		assert(cacheKey.count > 3, "cache key too short")
		let prefixA = String(cacheKey.prefix(1))
		let prefixB = String(cacheKey.prefix(2).suffix(1))
		let fileName = cacheKey.suffix(cacheKey.count - 2)

		return self.cacheDirectory
			.appendingPathComponent(prefixA, isDirectory: true)
			.appendingPathComponent(prefixB, isDirectory: true)
			.appendingPathComponent("\(fileName).jpg", isDirectory: false)
	}

	// Clears in-memory image caches
	static func clearMemoryCache() {
		self.shared.cache.removeAll()
		for (_, cache) in self.byFolder {
			cache.cache.removeAll()
		}
	}

	func clear() {
		do {
			self.cache.removeAll()
			//try FileManager.default.removeItem(at: self.cacheDirectory)
			// Remove folders inside the cache path that have a name that consists of just one character
			let fileManager = FileManager.default
			let fileURLs = try fileManager.contentsOfDirectory(
				at: self.cacheDirectory, includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants)
			for url in fileURLs {
				if url.lastPathComponent.count == 1 {
					try fileManager.removeItem(at: url)
				}
			}
		}
		catch {
			Log.warn("Could not clear cache: \(error.localizedDescription)")
		}
	}

	nonisolated func diskCacheSizeBytes() async throws -> UInt {
		return try await Task(priority: .utility) {
			return try await FileManager.default.sizeOfFolder(path: self.cacheDirectory)
		}.value
	}

	func remove(cacheKey: String) throws {
		if cacheKey.count < 3 {
			return
		}
		self.cache.removeValue(forKey: cacheKey)
		if self.diskCacheEnabled {
			try FileManager.default.removeItem(atPath: self.pathFor(cacheKey: cacheKey).path(percentEncoded: false))
		}
	}

	subscript(cacheKey: String) -> Image? {
		get {
			if cacheKey.count < 3 {
				return nil
			}
			// Attempt to retrieve from memory cache first
			if let img = self.cache[cacheKey] {
				return img
			}

			if self.diskCacheEnabled {
				let url = self.pathFor(cacheKey: cacheKey)
				let path = url.path(percentEncoded: false)
				if FileManager.default.fileExists(atPath: path) {
					#if os(iOS)
						if let img = UIImage(contentsOfFile: path) {
							return Image(uiImage: img)
						}
						else {
							Log.warn("Cached thumbnail exists but failed to load: for \(cacheKey) at \(path)")
						}
					#elseif os(macOS)
						if let img = NSImage(byReferencingFile: path), img.isValid {
							return Image(nsImage: img)
						}
						else {
							Log.warn("Cached thumbnail exists but failed to load: for \(cacheKey) at \(path)")
						}
					#endif
				}
			}

			// If we are not the shared cache, try the shared cache
			if self !== Self.shared {
				return Self.shared[cacheKey]
			}

			return nil
		}
		set {
			if cacheKey.count < 3 {
				return
			}

			// Memory cache (always enabled)
			while cache.count >= maxCacheSize {
				// This is a rather random way to remove items from the cache, investigate using an ordered map
				_ = self.cache.popFirst()
			}
			self.cache[cacheKey] = newValue

			if let image = newValue {
				self.writeToDiskCache(image: image, cacheKey: cacheKey)
			}
		}
	}

	fileprivate func writeToDiskCache(image: Image, cacheKey: String) {
		if diskCacheEnabled && diskHasSpace {
			let renderer = ImageRenderer(content: image)
			renderer.isOpaque = true
			let isShared = self === Self.shared
			Log.info("Writing to disk cache: shared=\(isShared) \(cacheKey) \(self.pathFor(cacheKey: cacheKey))")

			#if os(iOS)
				// We're using JPEG for now, because HEIC leads to distorted thumbnails for HDR videos
				if let data = renderer.uiImage?.jpegData(compressionQuality: 0.8) {
					let url = self.pathFor(cacheKey: cacheKey)
					let dirURL = url.deletingLastPathComponent()

					do {
						try FileManager.default.createDirectory(
							at: dirURL, withIntermediateDirectories: true)
						try data.write(to: url)

						// If we're using the default thumbnails directory, do not set complete protection for thumbnails
						if self.customCacheDirectory == nil {
							try (url as NSURL).setResourceValue(
								URLFileProtection.complete, forKey: .fileProtectionKey)
						}
					}
					catch {
						Log.warn(
							"Could not write to cache file \(url.path()): \(error.localizedDescription)"
						)
					}
				}
			#else
				// Let's do things the more old-fashioned way on macOS
				if let nsImage = renderer.nsImage {
					if let tiff = nsImage.tiffRepresentation,
						let rep = NSBitmapImageRep(data: tiff),
						let jpegData = rep.representation(
							using: .jpeg, properties: [.compressionFactor: 0.8])
					{
						let url = self.pathFor(cacheKey: cacheKey)
						let dirURL = url.deletingLastPathComponent()
						do {
							try FileManager.default.createDirectory(
								at: dirURL, withIntermediateDirectories: true)
							try FileManager.default.createDirectory(
								at: self.cacheDirectory,
								withIntermediateDirectories: true)
							try jpegData.write(to: url)

							// If we're using the default thumbnails directory, do not set complete protection for thumbnails
							if self.customCacheDirectory == nil {
								try (url as NSURL).setResourceValue(
									URLFileProtection.complete,
									forKey: .fileProtectionKey)
							}
						}
						catch {
							Log.warn(
								"Could not write to cache file \(url.path()): \(error.localizedDescription)"
							)
						}
					}
					else {
						Log.warn("Could not generate JPEG")
					}
				}
			#endif
		}
	}

	let remoteThumbnailDownloadLimiter = ConcurrentActor<AsyncImagePhase>(maxConcurrent: 5)

	nonisolated func getThumbnail(file: SushitrainEntry, forceCache: Bool) async -> AsyncImagePhase {
		let cacheKey = file.cacheKey
		if cacheKey.count < 6 {
			return AsyncImagePhase.failure(ThumbnailImageError.invalidCacheKey)
		}

		// If we have a cached thumbnail, use that
		if let cached = await self[cacheKey] {
			if forceCache {
				await self.writeToDiskCache(image: cached, cacheKey: cacheKey)
			}
			return .success(cached)
		}

		// For local files, ask QuickLook (and bypass our cache)
		if file.isLocallyPresent() {
			if let url = file.localNativeFileURL {
				let result = await Task {
					return await fetchQuicklookThumbnail(
						url,
						size: CGSize(
							width: maxThumbnailDimensionsInPixels,
							height: maxThumbnailDimensionsInPixels))
				}.value

				// If caching is forced, save successful result to disk cache
				if case .success(let image) = result, forceCache {
					await self.writeToDiskCache(image: image, cacheKey: cacheKey)
				}

				return result
			}
			else {
				return AsyncImagePhase.failure(ThumbnailImageError.invalidLocalURL)
			}
		}

		// Remote files
		let strategy = file.thumbnailStrategy
		let url = URL(string: file.onDemandURL())!

		let ph = await remoteThumbnailDownloadLimiter.dispatch {
			dispatchPrecondition(condition: .notOnQueue(.main))
			switch strategy {
			case .image:
				return await fetchImageThumbnail(
					url, maxDimensionsInPixels: maxThumbnailDimensionsInPixels)
			case .video:
				return await fetchVideoThumbnail(
					url: url, maxDimensionsInPixels: maxThumbnailDimensionsInPixels)
			}
		}

		// Save remote thumbnail to in-memory cache
		if case .success(let image) = ph {
			DispatchQueue.main.async {
				self[cacheKey] = image
			}
		}
		return ph
	}
}

extension SushitrainEntry {
	var cacheKey: String {
		return self.blocksHash().lowercased().replacingOccurrences(
			of: "[^a-z0-9]", with: "", options: .regularExpression)
	}
}

actor ConcurrentActor<Result: Sendable> {
	struct Item {
		var block: () async -> Result
		var continuation: CheckedContinuation<Result, Never>
	}

	private var queue: [Item] = []
	let maxConcurrent: Int
	private var activeTasks: Int = 0

	init(maxConcurrent: Int) {
		self.maxConcurrent = maxConcurrent
	}

	func dispatch(_ block: @escaping () async -> Result) async -> Result {
		return await withCheckedContinuation { cb in
			queue.append(Item(block: block, continuation: cb))
			startTasksIfNeeded()
		}
	}

	private func startTasksIfNeeded() {
		while activeTasks < maxConcurrent && !queue.isEmpty {
			let task = queue.removeFirst()
			activeTasks += 1
			Task {
				let result = await task.block()
				task.continuation.resume(returning: result)
				activeTasks -= 1
				startTasksIfNeeded()
			}
		}
	}
}

typealias GenerateStatusCallback = (_ thumbnail: AsyncImagePhase?) -> Void

@MainActor func generateThumbnailsFor(
	folder: SushitrainFolder, prefix: String?, userSettings: AppUserSettings, generation tg: ThumbnailGeneration,
	callback: GenerateStatusCallback? = nil
) async throws {
	let ic = ImageCache.forFolder(folder)

	// If thumbnails are written to a custom folder, also write thumbnails for local images
	let forceCachingLocalFiles: Bool
	switch tg {
	case .global:
		forceCachingLocalFiles = !userSettings.cacheThumbnailsToFolderID.isEmpty
	case .disabled:
		forceCachingLocalFiles = false
	case .deviceLocal:
		forceCachingLocalFiles = false
	case .inside(_):
		forceCachingLocalFiles = true
	}

	// Iterate over this folder's entries
	let files = try folder.list(prefix, directories: false, recurse: false)

	for idx in 0..<files.count() {
		let filePath = files.item(at: idx)
		if Task.isCancelled {
			Log.info("Thumbnail generate task cancelled")
			return
		}

		let fullPath = (prefix ?? "") + "/" + filePath

		if case .inside(path: let insidePath) = tg, fullPath.withoutStartingSlash.starts(with: insidePath) {
			Log.info("Skipping file \(fullPath), inside thumbnail directory")
			continue
		}

		if let file = try? folder.getFileInformation(fullPath) {
			// Recurse into subdirectories (depth-first)
			if file.isDirectory() {
				try await generateThumbnailsFor(
					folder: folder, prefix: file.path(), userSettings: userSettings, generation: tg, callback: callback)
			}

			// Generate thumbnail for files that are not locally present (otherwise QuickLook will manage it for us)
			// except when we are writing to a custom thumbnail folder (this device can then generate thumbnails for
			// another from local files)
			if file.canThumbnail && (forceCachingLocalFiles || !file.isLocallyPresent()) {
				let thumb = await ic.getThumbnail(file: file, forceCache: forceCachingLocalFiles)
				callback?(thumb)
			}
			else {
				callback?(nil)
			}
		}
		else {
			Log.warn("Could not get file entry for path \(filePath)")
		}
	}
}
