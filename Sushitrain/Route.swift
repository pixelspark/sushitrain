// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SushitrainCore

enum Route: Hashable, Equatable {
	case start
	case folders
	case folder(folderID: String, prefix: String?)
	case file(folderID: String, path: String)
	case devices
	case search(for: String)

	static let urlScheme: String = "sushitrain"

	private static func urlFrom(scheme: String, path: String, parameters: [String: String?]? = nil) -> URL {
		var url = URLComponents()
		url.scheme = scheme
		url.path = path
		if let p = parameters {
			url.queryItems = p.compactMap { k, v in
				if let v = v {
					return URLQueryItem(name: k, value: v)
				}
				return nil
			}
		}
		return url.url!
	}

	init?(url: URL) {
		if url.scheme != Self.urlScheme {
			return nil
		}

		switch url.path {
		case "start":
			self = Route.start
		case "devices":
			self = Route.devices
		case "folders":
			self = Route.folders
		default:
			guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
				return nil
			}
			let params =
				components.queryItems?.reduce(into: [String: String]()) { (result, item) in
					result[item.name] = item.value
				} ?? [:]

			switch url.path {
			case "search":
				self = .search(for: params["for"] ?? "")

			case "folder":
				guard let folderID = params["folderID"] else {
					return nil
				}
				self = .folder(folderID: folderID, prefix: params["prefix"])

			case "file":
				guard let folderID = params["folderID"], let path = params["path"] else {
					return nil
				}

				self = .file(folderID: folderID, path: path)
			default:
				return nil
			}

		}
	}

	var url: URL {
		switch self {
		case .start:
			return Self.urlFrom(scheme: Self.urlScheme, path: "start")
		case .folders:
			return Self.urlFrom(scheme: Self.urlScheme, path: "folders")
		case .folder(let folderID, let prefix):
			return Self.urlFrom(scheme: Self.urlScheme, path: "folder", parameters: ["folderID": folderID, "prefix": prefix])
		case .file(let folderID, let path):
			return Self.urlFrom(scheme: Self.urlScheme, path: "file", parameters: ["folderID": folderID, "path": path])
		case .devices:
			return Self.urlFrom(scheme: Self.urlScheme, path: "devices")
		case .search(for: let q):
			return Self.urlFrom(scheme: Self.urlScheme, path: "search", parameters: ["for": q])
		}
	}

	var splitted: [Route] {
		switch self {
		case .start, .folders, .devices, .search:
			return [self]

		case .file(let folderID, let path):
			var parts = path.withoutStartingSlash.withoutEndingSlash.split(separator: "/")
			if parts.isEmpty {
				return [self]
			}
			parts = parts.dropLast()

			var routes: [Route] = [Route.folder(folderID: folderID, prefix: "")]
			var cumulativePrefix = ""
			for part in parts {
				cumulativePrefix = cumulativePrefix + part + "/"
				routes.append(Route.folder(folderID: folderID, prefix: cumulativePrefix))
			}
			routes.append(self)
			return routes

		case .folder(let folderID, let prefix):
			if let prefix = prefix {
				let parts = prefix.withoutStartingSlash.withoutEndingSlash.split(separator: "/")
				var routes: [Route] = [Route.folder(folderID: folderID, prefix: "")]
				var cumulativePrefix = ""
				for part in parts {
					cumulativePrefix = cumulativePrefix + part + "/"
					routes.append(Route.folder(folderID: folderID, prefix: cumulativePrefix))
				}
				return routes
			}
			else {
				return [self]
			}
		}
	}

	var localizedSubtitle: String? {
		switch self {
		case .start, .folders, .devices, .search(for: _):
			return nil
		case .folder(let folderID, let prefix):
			if let p = prefix, !p.isEmpty && p != "/" {
				// FIXME: get the folder display name somehow
				return String(localized: "In folder '\(folderID)'")
			}
			else {
				return nil
			}
		case .file(let folderID, path: _):
			// FIXME: get the folder display name somehow
			return String(localized: "In folder '\(folderID)'")
		}
	}

	var localizedTitle: String {
		switch self {
		case .search(for: let q):
			if q.isEmpty {
				return String(localized: "Search files/folders")
			}
			else {
				return String(localized: "Search for '\(q)'")
			}
		case .start:
			return String(localized: "Start")
		case .folders:
			return String(localized: "Folders")
		case .folder(let folderID, let prefix):
			if let p = prefix, !p.isEmpty && p != "/" {
				return p.withoutEndingSlash
			}
			else {
				return folderID
			}
		case .file(let folderID, let path):
			// FIXME: only show file name
			return String(localized: "'\(path)' in folder '\(folderID)'")
		case .devices:
			return String(localized: "Devices")
		}
	}
}
