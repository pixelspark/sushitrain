// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@preconcurrency import SushitrainCore

enum ExternalSharingType: Equatable, Hashable, Codable {
	case none
	case unencrypted(ExternalSharingUnencrypted)
	case encrypted(ExternalSharingEncrypted)

	func urlForFile(_ entry: SushitrainEntry) -> URL? {
		switch self {
		case .none: return nil
		case .unencrypted(let e): return e.urlForFile(path: entry.path(), isDirectory: entry.isDirectory())
		case .encrypted(let e):
			if entry.isDirectory() {
				return nil
			}
			return e.urlForFile(entry)
		}
	}

	func hasURLForFile(_ entry: SushitrainEntry) -> Bool {
		switch self {
		case .none: return false
		case .unencrypted(let e):
			return !entry.isDeleted()
				&& e.hasURLForFile(path: entry.path(), isDirectory: entry.isDirectory())
		case .encrypted(let e): return !entry.isDeleted() && e.hasURLForFile
		}
	}
}

enum EncryptedLinkFormat: String, Codable {
	case basic = "basic"
	case linkthing = "linkthing"
}

struct ExternalSharingEncrypted: Equatable, Hashable, Codable {
	var url: String
	var password: String
	var format: EncryptedLinkFormat = .basic
	var blobURL: String = ""

	func urlForFile(_ entry: SushitrainEntry) -> URL? {
		if let root = URL(string: url) {
			switch self.format {
			case .basic:
				let withPath = root.appending(
					path: entry.encryptedFilePath(password), directoryHint: .notDirectory)
				return URL(string: "#\(entry.fileKeyBase32(password))", relativeTo: withPath)
			case .linkthing:
				if let blobURLRoot = URL(string: self.blobURL) {
					let blobURLPath = blobURLRoot.appending(
						path: entry.encryptedFilePath(password), directoryHint: .notDirectory)
					let queryItems = [
						URLQueryItem(name: "url", value: blobURLPath.absoluteString),
						URLQueryItem(name: "key", value: entry.fileKeyBase32(password)),
					]
					var fauxURLComponents = URLComponents()
					fauxURLComponents.queryItems = queryItems
					return URL(
						string: "#\(fauxURLComponents.percentEncodedQuery!)", relativeTo: root)
				}
			}
		}
		return nil
	}

	var hasURLForFile: Bool {
		return URL(string: url) != nil && !password.isEmpty
	}

	var exampleURL: URL? {
		if let root = URL(string: url) {
			switch self.format {
			case .basic:
				let withPath = root.appending(
					path: "E.syncthing-enc/NC/RYPTED", directoryHint: .notDirectory)
				return URL(string: "#FILEKEY", relativeTo: withPath)
			case .linkthing:
				let queryItems = [
					URLQueryItem(
						name: "url",
						value: URL(string: blobURL)?.appending(
							path: "E.syncthing-enc/NC/RYPTED"
						).absoluteString ?? ""),
					URLQueryItem(name: "key", value: "FILEKEY"),
				]
				var fauxURLComponents = URLComponents()
				fauxURLComponents.queryItems = queryItems
				return URL(string: "#\(fauxURLComponents.percentEncodedQuery!)", relativeTo: root)
			}
		}
		return nil
	}
}

struct ExternalSharingUnencrypted: Equatable, Hashable, Codable {
	var url: String
	var prefix: String

	func hasURLForFile(path: String, isDirectory: Bool) -> Bool {
		return URL(string: url) != nil && path.hasPrefix(self.prefix)
	}

	func urlForFile(path: String, isDirectory: Bool) -> URL? {
		if let root = URL(string: url) {
			if path.hasPrefix(self.prefix) {
				let strippedPath = path.dropFirst(self.prefix.count)
				return root.appending(
					path: strippedPath, directoryHint: isDirectory ? .isDirectory : .notDirectory)
			}
		}
		return nil
	}
}

class ExternalSharingManager {
	@MainActor static let shared = ExternalSharingManager()

	private static let defaultsKey = "externalSharingConfiguration"

	private var cachedConfiguration: [String: ExternalSharingType]? = nil

	private var configuration: [String: ExternalSharingType] {
		get {
			if let c = cachedConfiguration {
				return c
			}

			if let json = UserDefaults.standard.data(forKey: Self.defaultsKey) {
				return (try? JSONDecoder().decode([String: ExternalSharingType].self, from: json))
					?? [:]
			}
			return [:]
		}
		set {
			let json = try! JSONEncoder().encode(newValue)
			UserDefaults.standard.set(json, forKey: Self.defaultsKey)
			self.cachedConfiguration = newValue
		}
	}

	func externalSharingFor(folderID: String) -> ExternalSharingType {
		return self.configuration[folderID] ?? .none
	}

	func setExternalSharingFor(folderID: String, externalSharing: ExternalSharingType) {
		var c = self.configuration
		c[folderID] = externalSharing
		self.configuration = c
	}

	func removeExternalSharingFor(folderID: String) {
		var c = self.configuration
		c.removeValue(forKey: folderID)
		self.configuration = c
	}

	func removeExternalSharingForFoldersNotIn(_ folderIDs: Set<String>) {
		var c = self.configuration
		let toRemove = c.keys.filter({ !folderIDs.contains($0) })
		for toRemoveKey in toRemove {
			Log.warn("Removing stale external sharing settings for \(toRemoveKey)")
			c.removeValue(forKey: toRemoveKey)
		}
		self.configuration = c
	}
}

extension SushitrainEntry {
	@MainActor var hasExternalSharingURL: Bool {
		if self.isDeleted() {
			return false
		}

		let settings = ExternalSharingManager.shared.externalSharingFor(folderID: self.folder!.folderID)
		return settings.hasURLForFile(self)
	}

	@MainActor func externalSharingURLExpensive() -> URL? {
		if self.isDeleted() {
			return nil
		}
		let settings = ExternalSharingManager.shared.externalSharingFor(folderID: self.folder!.folderID)
		return settings.urlForFile(self)
	}
}
