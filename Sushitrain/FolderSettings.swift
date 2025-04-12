// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
@preconcurrency import SushitrainCore

enum ThumbnailGeneration: Equatable, Hashable, Codable {
	case disabled	// Do not generate thumbnails for this folder, regardless of global setting
	case global		// Just use the global app setting
	case deviceLocal // Use the device local thumbnail folder
	case inside(path: String)	// Generate thumbnails and place them inside this folder at the specified path
	
	static let DefaultInsideFolderThumbnailPath = ".thumbnails"
}

struct FolderSettings: Equatable, Hashable, Codable {
	var externalSharing: ExternalSharingType = .none
	var bookmark: Data? = nil
	var thumbnailGeneration: ThumbnailGeneration = .global
}

class FolderSettingsManager {
	@MainActor static let shared = FolderSettingsManager()
	private static let defaultsKey = "folderSettings"
	private static let oldExternalSharingDefaultsKey = "externalSharingConfiguration"
	private static let oldBookmarksDefaultsKey = "bookmarksByFolderID"

	private var cachedSettings: [String: FolderSettings]? = nil
	
	private init() {
		var s = self.settings
		
		// Migrate external sharing settings from older stores
		if let json = UserDefaults.standard.data(forKey: Self.oldExternalSharingDefaultsKey),
			let oldData = (try? JSONDecoder().decode([String: ExternalSharingType].self, from: json)) {
			Log.info("Migrating external sharing settings to folder settings")
			
			for (folderID, externalSharingSetting) in oldData {
				var folderSettings = s[folderID] ?? FolderSettings()
				folderSettings.externalSharing = externalSharingSetting
				s[folderID] = folderSettings
				Log.info("External sharing for \(folderID) = \(externalSharingSetting)")
			}
			UserDefaults.standard.removeObject(forKey: Self.oldExternalSharingDefaultsKey)
		}
		
		// Migrate bookmarks from older stores
		if let oldData = UserDefaults.standard.object(forKey: Self.oldBookmarksDefaultsKey) as? [String: Data] {
			Log.info("Migrating bookmarks to folder settings")
			for (folderID, bookmark) in oldData {
				var folderSettings = s[folderID] ?? FolderSettings()
				folderSettings.bookmark = bookmark
				s[folderID] = folderSettings
				Log.info("Bookmark for \(folderID) = \(bookmark)")
			}
			UserDefaults.standard.removeObject(forKey: Self.oldBookmarksDefaultsKey)
		}
		
		self.settings = s
	}

	private var settings: [String: FolderSettings] {
		get {
			if let c = cachedSettings {
				return c
			}

			if let json = UserDefaults.standard.data(forKey: Self.defaultsKey) {
				return (try? JSONDecoder().decode([String: FolderSettings].self, from: json))
					?? [:]
			}
			return [:]
		}
		set {
			let json = try! JSONEncoder().encode(newValue)
			UserDefaults.standard.set(json, forKey: Self.defaultsKey)
			self.cachedSettings = newValue
		}
	}

	func settingsFor(folderID: String) -> FolderSettings {
		return self.settings[folderID] ?? FolderSettings()
	}

	private func setSettingsFor(folderID: String, settings: FolderSettings) {
		var c = self.settings
		c[folderID] = settings
		self.settings = c
	}

	func removeSettingsFor(folderID: String) {
		var c = self.settings
		c.removeValue(forKey: folderID)
		self.settings = c
	}

	func removeSettingsForFoldersNotIn(_ folderIDs: Set<String>) {
		var c = self.settings
		let toRemove = c.keys.filter({ !folderIDs.contains($0) })
		for toRemoveKey in toRemove {
			Log.warn("Removing stale external sharing settings for \(toRemoveKey)")
			c.removeValue(forKey: toRemoveKey)
		}
		self.settings = c
	}
	
	func mutateSettingsFor(folderID: String, _ block: (inout FolderSettings) -> ()) {
		var s = self.settingsFor(folderID: folderID)
		block(&s)
		self.setSettingsFor(folderID: folderID, settings: s)
	}
}

@MainActor
struct BookmarkManager {
	static var shared = BookmarkManager()
	
	private var accessing: [String: Accessor] = [:]

	enum BookmarkManagerError: Error {
		case cannotAccess
	}

	class Accessor {
		var url: URL

		init(url: URL) throws {
			self.url = url
			if !url.startAccessingSecurityScopedResource() {
				throw BookmarkManagerError.cannotAccess
			}
			Log.info("Start accessing \(url)")
		}

		deinit {
			Log.info("Stop accessing \(url)")
			url.stopAccessingSecurityScopedResource()
		}
	}

	mutating func saveBookmark(folderID: String, url: URL) throws {
		self.accessing[folderID] = try Accessor(url: url)
		#if os(macOS)
			let newBookmark = try url.bookmarkData(options: .withSecurityScope)
		#else
			let newBookmark = try url.bookmarkData(options: .minimalBookmark)
		#endif
		
		FolderSettingsManager.shared.mutateSettingsFor(folderID: folderID) { fs in
			fs.bookmark = newBookmark
		}
	}
	
	private func bookmarkFor(folderID: String) -> Data? {
		return FolderSettingsManager.shared.settingsFor(folderID: folderID).bookmark
	}

	func hasBookmarkFor(folderID: String) -> Bool {
		return self.bookmarkFor(folderID: folderID) != nil
	}

	mutating func resolveBookmark(folderID: String) throws -> URL? {
		guard let bookmarkData = self.bookmarkFor(folderID: folderID) else { return nil }
		var isStale = false

		#if os(macOS)
			let url = try URL(
				resolvingBookmarkData: bookmarkData, options: [.withSecurityScope],
				bookmarkDataIsStale: &isStale)
		#else
			let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
		#endif

		if isStale {
			// Refresh bookmark
			Log.info("Bookmark for \(folderID) is stale")
			do {
				#if os(macOS)
					let newBookmark = try url.bookmarkData(options: .withSecurityScope)
				#else
					let newBookmark = try url.bookmarkData(options: .minimalBookmark)
				#endif
				
				FolderSettingsManager.shared.mutateSettingsFor(folderID: folderID) { fs in
					fs.bookmark = newBookmark
				}
			}
			catch {
				Log.warn("Could not refresh stale bookmark: \(error.localizedDescription)")
			}
		}

		// Start accessing
		if let currentAccessor = self.accessing[folderID] {
			if currentAccessor.url != url {
				self.accessing[folderID] = try Accessor(url: url)
			}
		}
		else {
			self.accessing[folderID] = try Accessor(url: url)
		}
		return url
	}
}
