// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import AppKit
import UniformTypeIdentifiers
import OSLog

/// macOS sharing hands files to the main app, which owns the destination picker and sync engine.
final class ShareViewController: NSViewController {
	private var started = false
	private static let logger = Logger(subsystem: "nl.t-shaped.Sushitrain.Share", category: "Share")

	override func loadView() {
		let label = NSTextField(labelWithString: String(localized: "Opening Synctrain…"))
		label.alignment = .center
		label.frame = NSRect(x: 20, y: 30, width: 280, height: 24)
		view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
		view.addSubview(label)
	}

	override func viewDidAppear() {
		super.viewDidAppear()
		guard !started else { return }
		started = true
		Task {
			var phase = "Reading shared files"
			do {
				let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
				let providers = items.flatMap { $0.attachments ?? [] }
				var urls: [URL] = []
				Self.logger.notice("Share request received with \(providers.count) attachments")
				phase = "Preparing shared files"
				for provider in providers {
					urls.append(try await Self.stage(provider))
				}
				guard !urls.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
				// Extensions live inside App.app/Contents/PlugIns/Extension.appex.
				let appURL = Bundle.main.bundleURL.deletingLastPathComponent()
					.deletingLastPathComponent().deletingLastPathComponent()
				let configuration = NSWorkspace.OpenConfiguration()
				configuration.activates = true
				phase = "Opening Synctrain"
				Self.logger.notice("Opening app with \(urls.count) staged files")
				_ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
				extensionContext?.completeRequest(returningItems: nil)
			}
			catch {
				let detail = "\(phase): \(error.localizedDescription) (\((error as NSError).domain), \((error as NSError).code))"
				Self.logger.error("Share failed: \(detail, privacy: .public)")
				let alert = NSAlert()
				alert.messageText = String(localized: "Cannot import files")
				alert.informativeText = detail
				alert.runModal()
				extensionContext?.cancelRequest(withError: error)
			}
		}
	}

	@MainActor private static func stage(_ provider: NSItemProvider) async throws -> URL {
		// File representations may cease to exist when their callback returns. Copy there, not after awaiting it.
		if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
			return try await withCheckedThrowingContinuation { continuation in
				provider.loadObject(ofClass: NSURL.self) { item, error in
					do {
						if let error { throw error }
						guard let url = item as? URL, url.isFileURL else {
							throw CocoaError(.fileReadUnsupportedScheme)
						}
						continuation.resume(returning: try copyToTemporaryDirectory(url))
					}
					catch { continuation.resume(throwing: error) }
				}
			}
		}
		guard
			let type = provider.registeredTypeIdentifiers.first(where: {
				UTType($0)?.conforms(to: .data) == true
			})
		else { throw CocoaError(.fileReadUnsupportedScheme) }
		return try await withCheckedThrowingContinuation { continuation in
			provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
				do {
					if let error { throw error }
					guard let url else { throw CocoaError(.fileNoSuchFile) }
					continuation.resume(returning: try copyToTemporaryDirectory(url))
				}
				catch { continuation.resume(throwing: error) }
			}
		}
	}

	nonisolated private static func copyToTemporaryDirectory(_ source: URL) throws -> URL {
		guard
			let appGroup = Bundle.main.object(forInfoDictionaryKey: "SynctrainAppGroup") as? String,
			let sharedCacheDirectory = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: appGroup)?
				.appendingPathComponent("Library/Caches", isDirectory: true)
		else {
			throw CocoaError(.fileNoSuchFile)
		}
		let directory = sharedCacheDirectory.appendingPathComponent("SynctrainShare-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let destination = directory.appendingPathComponent(source.lastPathComponent)
		try FileImportCopy.copy(source, to: destination)
		return destination
	}
}
