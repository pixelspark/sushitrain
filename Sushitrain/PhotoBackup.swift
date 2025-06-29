// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
@preconcurrency import SushitrainCore
import Photos

enum PhotoSyncCategories: String, Codable {
	case photo = "photo"
	case livePhoto = "live"
	case video = "video"
}

enum PhotoBackupFolderStructure: String, Codable {
	case byType = "byType"
	case byDate = "byDate"
	case byDateAndType = "byDateAndType"
	case byDateComponent = "byDateComponent"
	case byDateComponentAndType = "byDateComponentAndType"
	case singleFolder = "singleFolder"
	case singleFolderDatePrefixed = "singleFolderDatePrefixed"

	var examplePath: String {
		switch self {
		case .byDate: return String(localized: "2024-08-11/IMG_2020.HEIC")
		case .byDateAndType: return String(localized: "2024-08-11/Video/IMG_2020.MOV")
		case .byDateComponent: return String(localized: "2024/08/11/IMG_2020.HEIC")
		case .byDateComponentAndType: return String(localized: "2024/08/11/Video/IMG_2020.MOV")
		case .byType: return String(localized: "Video/IMG_2020.MOV")
		case .singleFolder: return String(localized: "IMG_2020.MOV")
		case .singleFolderDatePrefixed: return String(localized: "2024-08-11_IMG_2020.MOV")
		}
	}
}

enum PhotoSyncProgress {
	case starting
	case exportingPhotos(index: Int, total: Int, current: String?)
	case exportingVideos(index: Int, total: Int, current: String?)
	case exportingLivePhotos(index: Int, total: Int, current: String?)
	case selecting
	case purging
	case finished(error: String?)

	var stepProgress: Float {
		switch self {
		case .starting: return 0.0

		case .exportingPhotos(let index, let total, current: _):
			if total > 0 { return Float(index) / Float(total) }
			return 1.0
		case .exportingVideos(let index, let total, current: _):
			if total > 0 { return Float(index) / Float(total) }
			return 1.0
		case .exportingLivePhotos(let index, let total, current: _):
			if total > 0 { return Float(index) / Float(total) }
			return 1.0
		case .selecting: return 0.0
		case .purging: return 0.0
		case .finished(error: _): return 1.0
		}
	}

	var badgeText: String {
		switch self {

		case .starting: return ""
		case .exportingPhotos(let index, let total, current: _): return String(localized: "\(index+1) of \(total)")
		case .exportingVideos(let index, let total, current: _): return String(localized: "\(index+1) of \(total)")
		case .exportingLivePhotos(let index, let total, current: _): return String(localized: "\(index+1) of \(total)")
		case .purging: return ""
		case .selecting: return ""
		case .finished(error: _): return ""
		}
	}

	var localizedDescription: String {
		switch self {
		case .starting: return String(localized: "Preparing to save photos and videos")
		case .exportingPhotos(index: _, total: _, current: _): return String(localized: "Saving photos")
		case .exportingVideos(index: _, total: _, current: _): return String(localized: "Saving videos")
		case .exportingLivePhotos(index: _, total: _, current: _): return String(localized: "Saving live photos")
		case .purging: return String(localized: "Removing originals")
		case .selecting: return String(localized: "Selecting files to be synchronized")
		case .finished(let error):
			if let e = error {
				return String(localized: "Failed: \(e)")
			}
			else {
				return String(localized: "Finished")
			}
		}
	}
}

@MainActor class PhotoBackup: ObservableObject {
	// These settings are prefixed 'photoSync' because that is what the feature used to be called
	@AppStorage("photoSyncSelectedAlbumID") var selectedAlbumID: String = ""
	@AppStorage("photoSyncFolderID") var selectedFolderID: String = ""

	// Album to put photos that have been saved in
	@AppStorage("photoSyncSavedAlbumID") var savedAlbumID: String = ""

	@AppStorage("photoSyncLastCompletedDate") var lastCompletedDate: Double = -1.0
	@AppStorage("photoSyncEnableBackgroundCopy") var enableBackgroundCopy: Bool = false
	@AppStorage("photoSyncCategories") var categories: Set<PhotoSyncCategories> = Set([.photo, .video, .livePhoto])
	@AppStorage("photoSyncPurgeEnabled") var purgeEnabled = false
	@AppStorage("photoSyncPurgeAfterDays") var purgeAfterDays = 7
	@AppStorage("PhotoBackupFolderStructure") var folderStructure = PhotoBackupFolderStructure.byDateAndType
	@AppStorage("photoSyncSubdirectoryPath") var subDirectoryPath = ""
	@AppStorage("photoSyncMaxAgeDays") var maxAgeDays = 6 * 30  // The maximum age for assets to be considered for export

	@Published var isSynchronizing = false
	@Published var progress: PhotoSyncProgress = .finished(error: nil)
	@Published var photoBackupTask: Task<(), Error>? = nil

	var selectedAlbumTitle: String? {
		if !self.selectedAlbumID.isEmpty {
			if let selectedAlbum = PHAssetCollection.fetchAssetCollections(
				withLocalIdentifiers: [self.selectedAlbumID], options: nil
			).firstObject {
				return selectedAlbum.localizedTitle
			}
		}
		return nil
	}

	var isReady: Bool { return !self.selectedAlbumID.isEmpty && !self.selectedFolderID.isEmpty }

	@MainActor func cancel() {
		self.photoBackupTask?.cancel()
		self.photoBackupTask = nil
	}

	@discardableResult
	@MainActor func backup(appState: AppState, fullExport: Bool, isInBackground: Bool) -> Task<(), Error>? {
		if !self.isReady { return nil }
		if self.selectedAlbumID.isEmpty { return nil }
		if self.photoBackupTask != nil { return nil }
		self.isSynchronizing = true

		let selectedAlbumID = self.selectedAlbumID
		let selectedFolderID = self.selectedFolderID
		let categories = self.categories

		// Start the actual synchronization task
		self.photoBackupTask = Task.detached(priority: .background) {
			DispatchQueue.main.async { self.progress = .starting }

			defer {
				DispatchQueue.main.async {
					self.photoBackupTask = nil
					self.isSynchronizing = false
				}
			}

			guard let folder = await appState.client.folder(withID: selectedFolderID) else {
				DispatchQueue.main.async {
					self.progress = .finished(error: String(localized: "Cannot find selected folder with ID '\(selectedFolderID)'"))
				}
				return
			}

			if !folder.exists() {
				DispatchQueue.main.async { self.progress = .finished(error: String(localized: "Selected folder does not exist")) }
				return
			}

			if !folder.isSuitablePhotoBackupDestination {
				DispatchQueue.main.async {
					self.progress = .finished(error: String(localized: "The selected folder cannot be used to save photos to"))
				}
				return
			}

			// Let iOS know we are about to do some background stuff
			#if os(iOS)
				let bgIdentifier = await UIApplication.shared.beginBackgroundTask(
					withName: "Photo back-up",
					expirationHandler: {
						Log.info("Cancelling background task due to expiration")
						self.cancel()
					})
				defer {
					Log.info("Signalling end of background task")
					DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(bgIdentifier) }
				}
				Log.info("Background time remaining: \(await UIApplication.shared.backgroundTimeRemaining))")
			#endif

			// Pause the folder while backing up so we can change selection state
			let folderWasPaused = folder.isPaused()
			try folder.setPaused(true)
			defer {
				try? folder.setPaused(folderWasPaused)
			}

			// Get local path for destination folder
			var err: NSError? = nil
			let folderPath = folder.localNativePath(&err)
			if let err = err {
				DispatchQueue.main.async { self.progress = .finished(error: err.localizedDescription) }
				return
			}

			// Ensure the subdirectory exists
			let subDirectoryPath = EntryPath(await self.subDirectoryPath, isDirectory: true)
			if subDirectoryPath.pathInFolder != "" {
				let subDirectoryPathURL = URL(fileURLWithPath: folderPath).appendingPathComponent(subDirectoryPath.pathInFolder)
				try FileManager.default.createDirectory(at: subDirectoryPathURL, withIntermediateDirectories: true)
			}

			let folderURL = URL(fileURLWithPath: folderPath)
			let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [selectedAlbumID], options: nil)
			guard let album = fetchResult.firstObject else {
				DispatchQueue.main.async { self.progress = .finished(error: String(localized: "Could not find selected album")) }
				return
			}

			try await self.backupAlbum(
				appState: appState,
				album: album,
				folder: folder,
				folderURL: folderURL,
				subDirectoryPath: subDirectoryPath,
				fullExport: fullExport,
				categories: categories,
				isInBackground: isInBackground
			)
		}
		return self.photoBackupTask
	}

	private nonisolated func backupAlbum(
		appState: AppState,
		album: PHAssetCollection,
		folder: SushitrainFolder,
		folderURL: URL,
		subDirectoryPath: EntryPath,
		fullExport: Bool,
		categories: Set<PhotoSyncCategories>,
		isInBackground: Bool
	) async throws {
		var cancellingError: Error? = nil
		let assets = PHAsset.fetchAssets(in: album, options: nil)
		let count = assets.count
		DispatchQueue.main.async { self.progress = .exportingPhotos(index: 0, total: count, current: nil) }

		var videosToExport: [(PHAsset, URL, EntryPath)] = []
		var livePhotosToExport: [(PHAsset, URL, EntryPath)] = []
		var selectPaths: [EntryPath] = []
		var originalsToPurge: [PHAsset] = []
		var assetsSavedSuccessfully: [PHAsset] = []
		let structure = await self.folderStructure
		let purgeCutoffDate = await Date.now - Double.maximum(Double(self.purgeAfterDays), 0.0) * 86400.0
		let isSelective = folder.isSelective()
		let myShortDeviceID = await appState.client.shortDeviceID()
		let purgeEnabled = await self.purgeEnabled
		let maxAgeInterval = TimeInterval(Double(await self.maxAgeDays) * 86400.0)

		// Enumerate assets in this album and export them (or queue them for export)
		assets.enumerateObjects { asset, index, stop in
			if Task.isCancelled {
				stop.pointee = true
				return
			}

			do {
				Log.info("Asset: \(asset.originalFilename) \(asset.localIdentifier)")

				if let cd = asset.creationDate, maxAgeInterval > 0 && Date.now.timeIntervalSince(cd) > maxAgeInterval {
					// Skip, file is too old
					return
				}

				DispatchQueue.main.async {
					self.progress = .exportingPhotos(index: index, total: count, current: asset.originalFilename)
				}

				// Create containing directory
				let assetDirectoryPath = asset.directoryPathInFolder(structure: structure, subdirectoryPath: subDirectoryPath)
				let dirInFolder = folderURL.appending(path: assetDirectoryPath.pathInFolder, directoryHint: .isDirectory)
				Log.info("assetDirectoryPath \(assetDirectoryPath) \(dirInFolder)")
				try FileManager.default.createDirectory(at: dirInFolder, withIntermediateDirectories: true)

				let inFolderPath = asset.pathInFolder(structure: structure, subdirectoryPath: subDirectoryPath)
				Log.info("- \(inFolderPath) \(dirInFolder) \(subDirectoryPath)")

				// Check if this photo was saved or deleted before
				if purgeEnabled || !fullExport {
					if let entry = try? folder.getFileInformation(inFolderPath.pathInFolder) {
						// If purging is enabled, check if we should remove the photo from the source
						if purgeEnabled {
							if let mTime = entry.modifiedAt(), mTime.date() < purgeCutoffDate {
								let lastModifiedByShortDeviceID = entry.modifiedByShortDeviceID()
								if lastModifiedByShortDeviceID == myShortDeviceID {
									// The photo is already saved and was last modified by this device; we can delete from source
									Log.info("Purge entry: \(inFolderPath) \(mTime.date()) \(lastModifiedByShortDeviceID)")
									originalsToPurge.append(asset)
								}
								else {
									// The photo already exists but it was not last modified by us; do not delete from source
								}
							}
							else {
								// Could not fetch modified date or modified too recently; do not delete from source
							}
						}

						// If the photo was saved then deleted, do not try to save again (unless we are in full export)
						if !fullExport {
							if entry.isDeleted() {
								Log.info("Entry at \(inFolderPath) was deleted, not saving again")
							}
							else {
								Log.info("Entry at \(inFolderPath) exists, not saving again")
							}
							return
						}
					}
				}

				// Save asset if it doesn't exist already locally
				let fileURL = folderURL.appending(path: inFolderPath.pathInFolder, directoryHint: .notDirectory)
				if !FileManager.default.fileExists(atPath: fileURL.path) || fullExport {
					// If a video: queue video export session
					if asset.mediaType == .video {
						if categories.contains(.video) {
							Log.info("Requesting video export session for \(asset.originalFilename)")
							videosToExport.append((asset, fileURL, inFolderPath))
						}
					}
					else {
						if categories.contains(.photo) {
							// Save image
							let options = PHImageRequestOptions()
							options.isSynchronous = true
							options.resizeMode = .none
							options.deliveryMode = .highQualityFormat
							options.isNetworkAccessAllowed = true
							options.allowSecondaryDegradedImage = false
							options.version = .current

							PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
								if let data = data {
									do {
										try data.write(to: fileURL)
										selectPaths.append(inFolderPath)

										// Set file creation and modified date to photo creation date. The modified date is what is synced
										if let cd = asset.creationDate {
											try FileManager.default.setAttributes(
												[FileAttributeKey.creationDate: cd, FileAttributeKey.modificationDate: cd],
												ofItemAtPath: fileURL.path(percentEncoded: false))
										}

										assetsSavedSuccessfully.append(asset)
									}
									catch { cancellingError = error }
								}
							}
						}
					}
				}

				// If the image is a live photo, queue the live photo for saving as well
				if asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive) && categories.contains(.livePhoto) {
					let liveInFolderPath = asset.livePhotoPathInFolder(structure: structure, subdirectoryPath: subDirectoryPath)
					let liveDirectoryURL = folderURL.appending(
						path: asset.livePhotoDirectoryPathInFolder(structure: structure, subdirectoryPath: subDirectoryPath)
							.pathInFolder,
						directoryHint: .isDirectory)
					try FileManager.default.createDirectory(at: liveDirectoryURL, withIntermediateDirectories: true)
					let liveFileURL = folderURL.appending(path: liveInFolderPath.pathInFolder, directoryHint: .notDirectory)
					Log.info("Found live photo \(asset.originalFilename) \(liveInFolderPath)")

					if !FileManager.default.fileExists(atPath: liveFileURL.path) {
						livePhotosToExport.append((asset, liveFileURL, liveInFolderPath))
					}
				}
			}
			catch {
				cancellingError = error
				stop.pointee = true
			}
		}

		// Select paths a first time for photos (video export may take too long)
		if isSelective {
			Log.info("Selecting paths (photos only)")
			#if os(iOS)
				Log.info("Background time remaining: \(await UIApplication.shared.backgroundTimeRemaining))")
			#endif

			DispatchQueue.main.async { self.progress = .selecting }

			let stList = SushitrainNewListOfStrings()!
			for path in selectPaths {
				stList.append(path.pathInFolder)
			}

			do {
				try folder.setLocalPathsExplicitlySelected(stList)
			}
			catch {
				Log.warn("Could not select files: \(error.localizedDescription)")
			}
		}

		// Report error
		if let ce = cancellingError {
			DispatchQueue.main.async { self.progress = .finished(error: ce.localizedDescription) }
			return
		}

		// Export videos
		if categories.contains(.video) {
			let videoCount = videosToExport.count
			Log.info("Starting video exports for \(videoCount) videos")
			#if os(iOS)
				Log.info("Background time remaining: \(await UIApplication.shared.backgroundTimeRemaining)")
			#endif

			DispatchQueue.main.async { self.progress = .exportingVideos(index: 0, total: videoCount, current: nil) }

			for (idx, (asset, fileURL, selectPath)) in videosToExport.enumerated() {
				if Task.isCancelled { break }

				DispatchQueue.main.async { self.progress = .exportingVideos(index: idx, total: videoCount, current: nil) }

				_ = await withCheckedContinuation { resolve in
					Log.info("Exporting video \(asset.originalFilename)")
					let options = PHVideoRequestOptions()
					options.deliveryMode = .highQualityFormat

					PHImageManager.default().requestExportSession(
						forVideo: asset, options: options, exportPreset: AVAssetExportPresetPassthrough
					) { exportSession, info in
						if let es = exportSession {
							es.outputURL = fileURL
							es.outputFileType = .mov
							es.shouldOptimizeForNetworkUse = false

							es.exportAsynchronously {
								Log.info("Done exporting video \(asset.originalFilename)")
								resolve.resume(returning: true)
							}
						}
						else {
							Log.info("Could not start export setting for \(asset.originalFilename): \(String(describing: info))")
							resolve.resume(returning: false)
						}
					}
				}

				if let cd = asset.creationDate {
					do {
						try FileManager.default.setAttributes(
							[FileAttributeKey.creationDate: cd, FileAttributeKey.modificationDate: cd],
							ofItemAtPath: fileURL.path(percentEncoded: false))
					}
					catch {
						Log.warn("Could not set creation time of file: \(fileURL) \(error.localizedDescription)")
					}
				}

				selectPaths.append(selectPath)
				assetsSavedSuccessfully.append(asset)
			}
		}

		// Export live photos
		if categories.contains(.livePhoto) {
			Log.info("Exporting live photos")
			#if os(iOS)
				Log.info("Background time remaining: \(await UIApplication.shared.backgroundTimeRemaining))")
			#endif

			let liveCount = livePhotosToExport.count
			DispatchQueue.main.async { self.progress = .exportingLivePhotos(index: 0, total: liveCount, current: nil) }
			for (idx, (asset, destURL, selectPath)) in livePhotosToExport.enumerated() {
				if Task.isCancelled { break }
				Log.info("Exporting live photo \(asset.originalFilename) \(selectPath)")

				do {
					try await withCheckedThrowingContinuation { resolve in
						// Export live photo
						let options = PHLivePhotoRequestOptions()
						options.deliveryMode = .highQualityFormat
						var found = false
						PHImageManager.default().requestLivePhoto(
							for: asset, targetSize: CGSize(width: 1920, height: 1080), contentMode: PHImageContentMode.default,
							options: options
						) { livePhoto, info in
							if found {
								// The callback can be called twice
								return
							}
							found = true

							guard let livePhoto = livePhoto else {
								Log.warn("Did not receive live photo for \(asset.originalFilename)")
								resolve.resume()
								return
							}
							let assetResources = PHAssetResource.assetResources(for: livePhoto)
							guard let videoResource = assetResources.first(where: { $0.type == .pairedVideo }) else {
								Log.warn("Could not find paired video resource for \(asset.originalFilename) \(assetResources)")
								resolve.resume()
								return
							}

							PHAssetResourceManager.default().writeData(for: videoResource, toFile: destURL, options: nil) { error in
								if let error = error {
									resolve.resume(throwing: error)
								}
								else {
									resolve.resume()
								}
							}
						}
					}

					selectPaths.append(selectPath)
					assetsSavedSuccessfully.append(asset)

					if let cd = asset.creationDate {
						try FileManager.default.setAttributes(
							[FileAttributeKey.creationDate: cd, FileAttributeKey.modificationDate: cd],
							ofItemAtPath: destURL.path(percentEncoded: false))
					}
				}
				catch {
					Log.warn("Failed to save \(destURL): \(error.localizedDescription)")
				}

				DispatchQueue.main.async { self.progress = .exportingLivePhotos(index: idx, total: liveCount, current: nil) }
			}
		}

		// Select paths
		if isSelective {
			Log.info("Selecting paths")
			#if os(iOS)
				Log.info("Background time remaining: \(await UIApplication.shared.backgroundTimeRemaining))")
			#endif

			DispatchQueue.main.async { self.progress = .selecting }

			let stList = SushitrainNewListOfStrings()!
			for path in selectPaths {
				stList.append(path.pathInFolder)
			}

			do {
				try folder.setLocalPathsExplicitlySelected(stList)
			}
			catch {
				Log.warn("Could not select files: \(error.localizedDescription)")
			}
		}

		// Tag saved items
		if await !savedAlbumID.isEmpty && !assetsSavedSuccessfully.isEmpty {
			Log.info("Tagging \(assetsSavedSuccessfully.count) saved items")
			if let savedAlbum = await PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [savedAlbumID], options: nil)
				.firstObject
			{
				let assets = PHAsset.fetchAssets(
					withLocalIdentifiers: assetsSavedSuccessfully.map { $0.localIdentifier }, options: nil)
				try? await PHPhotoLibrary.shared().performChanges {
					if let phac = PHAssetCollectionChangeRequest(for: savedAlbum) {
						phac.addAssets(assets)
					}
					else {
						Log.warn("Cannot add asset, PHAssetCollectionChangeRequest is nil!")
					}
				}
			}
		}

		// Purge
		if !isInBackground && purgeEnabled && !originalsToPurge.isEmpty {
			Log.info("Purge \(originalsToPurge.count) originals")
			DispatchQueue.main.async { self.progress = .purging }
			let assets = PHAsset.fetchAssets(withLocalIdentifiers: originalsToPurge.map { $0.localIdentifier }, options: nil)

			// this could fail in the background
			try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
		}

		// Write 'last completed' date
		let completedDate = Date.now.timeIntervalSinceReferenceDate
		DispatchQueue.main.async {
			self.lastCompletedDate = completedDate
			self.progress = .finished(error: nil)
		}
		Log.info("Photo back-up done")

		#if os(iOS)
			Log.info("Background time remaining: \(await UIApplication.shared.backgroundTimeRemaining))")
		#endif
	}
}

extension PHAsset {
	fileprivate var primaryResource: PHAssetResource? {
		let types: Set<PHAssetResourceType>

		switch mediaType {
		case .video: types = [.video, .fullSizeVideo]
		case .image: types = [.photo, .fullSizePhoto]
		case .audio: types = [.audio]
		case .unknown: types = []
		@unknown default: types = []
		}

		let resources = PHAssetResource.assetResources(for: self)
		let resource = resources.first { types.contains($0.type) }

		return resource ?? resources.first
	}

	var originalFilename: String {
		guard let result = primaryResource else { return "file" }
		return result.originalFilename.replacingOccurrences(of: "/", with: "_")
	}

	fileprivate func directoryPathInFolder(structure: PhotoBackupFolderStructure, subdirectoryPath: EntryPath) -> EntryPath
	{
		var path = subdirectoryPath
		for c in self.subdirectoriesInFolder(structure: structure) {
			path = path.appending(c, isDirectory: true)
		}
		return path
	}

	func subdirectoriesInFolder(structure: PhotoBackupFolderStructure) -> [String] {
		var components: [String] = []

		switch structure {
		case .byDate, .byDateAndType:
			if let creationDate = self.creationDate {
				// FIXME: this uses the currently set local timezone. When moving between timezones, asset's creation
				// day may be +/- one day, which leads to the asset being saved twice.
				let dateFormatter = DateFormatter()
				dateFormatter.dateFormat = "yyyy-MM-dd"
				let dateString = dateFormatter.string(from: creationDate)
				components.append(dateString)
			}

		case .byDateComponent, .byDateComponentAndType:
			if let creationDate = self.creationDate {
				// FIXME: this uses the currently set local timezone. When moving between timezones, asset's creation
				// day may be +/- one day, which leads to the asset being saved twice.
				let dateComponents = ["yyyy", "MM", "dd"]
				let dateFormatter = DateFormatter()
				for dateComponent in dateComponents {
					dateFormatter.dateFormat = dateComponent
					let dateString = dateFormatter.string(from: creationDate)
					components.append(dateString)
				}
			}

		case .singleFolder, .byType, .singleFolderDatePrefixed: break
		}

		// Postfix media type
		switch structure {
		case .byDateAndType, .byType, .byDateComponentAndType:
			if self.mediaType == .video {
				components.append("Video")
			}
		case .byDate, .singleFolder, .singleFolderDatePrefixed, .byDateComponent: break
		}

		return components
	}

	fileprivate func livePhotoDirectoryPathInFolder(structure: PhotoBackupFolderStructure, subdirectoryPath: EntryPath)
		-> EntryPath
	{
		var path = self.directoryPathInFolder(structure: structure, subdirectoryPath: subdirectoryPath)
		switch structure {
		case .byDateAndType, .byType, .byDateComponentAndType:
			path = path.appending("Live", isDirectory: true)
		case .byDate, .singleFolder, .singleFolderDatePrefixed, .byDateComponent: break
		}
		return path
	}

	fileprivate func livePhotoPathInFolder(structure: PhotoBackupFolderStructure, subdirectoryPath: EntryPath) -> EntryPath
	{
		let fileName = self.fileNameInFolder(structure: structure) + ".MOV"
		return self.livePhotoDirectoryPathInFolder(structure: structure, subdirectoryPath: subdirectoryPath)
			.appending(fileName, isDirectory: false)
	}

	func fileNameInFolder(structure: PhotoBackupFolderStructure) -> String {
		switch structure {
		case .byDate, .byDateAndType, .byDateComponent, .byDateComponentAndType, .singleFolder, .byType:
			return self.originalFilename

		case .singleFolderDatePrefixed:
			if let creationDate = self.creationDate {
				let dateFormatter = DateFormatter()
				dateFormatter.dateFormat = "yyyy-MM-dd"
				let dateString = dateFormatter.string(from: creationDate)
				return "\(dateString)_\(self.originalFilename)"
			}
			return self.originalFilename
		}
	}

	fileprivate func pathInFolder(structure: PhotoBackupFolderStructure, subdirectoryPath: EntryPath) -> EntryPath {
		return self.directoryPathInFolder(structure: structure, subdirectoryPath: subdirectoryPath)
			.appending(self.fileNameInFolder(structure: structure), isDirectory: false)
	}
}

private struct EntryPath {
	let url: URL

	init(_ path: String = "", isDirectory: Bool) {
		self.url = URL(filePath: "/" + path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
	}

	private init(url: URL) {
		self.url = url
	}

	func appending(_ p: String, isDirectory: Bool) -> EntryPath {
		return EntryPath(url: self.url.appendingPathComponent(p, isDirectory: isDirectory))
	}

	// Absolute path, not starting with a leading '/' (as accepted by SushitrainEntry.getFileInformation).
	var pathInFolder: String {
		return self.url.path(percentEncoded: false).withoutStartingSlash
	}
}

extension SushitrainFolder {
	// Whether this folder can be used as a photo backup destination folder
	var isSuitablePhotoBackupDestination: Bool {
		return self.isRegularFolder && self.folderType() != SushitrainFolderTypeReceiveOnly && self.exists()
	}
}
