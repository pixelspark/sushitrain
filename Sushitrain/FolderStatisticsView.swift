// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

private struct NeededFilesView: View {
	@EnvironmentObject var appState: AppState
	var folder: SushitrainFolder
	var device: SushitrainPeer?

	@State private var loading = false
	@State private var files: [SushitrainEntry] = []
	@State private var error: Error? = nil
	
	private static let fileLimit = 100
	
	private enum Errors: LocalizedError {
		case tooManyFiles(count: Int)
		
		var errorDescription: String? {
			switch self {
			case .tooManyFiles(let count):
				return String(localized: "Too many files (\(count)) to display.")
			}
		}
	}

	var body: some View {
		Group {
			if loading {
				HStack(alignment: .center) {
					VStack(alignment: .center) {
						ProgressView()
					}
				}
			}
			else if let e = error {
				ContentUnavailableView(e.localizedDescription, systemImage: "exclamationmark.triangle.fill").frame(minHeight: 300)
			}
			else if files.isEmpty {
				ContentUnavailableView(
					device == nil ? "This device has all the files it wants" : "\(device!.displayName) has all the files it wants",
					systemImage: "checkmark.circle.fill")
				.frame(minHeight: 300)
			}
			else {
				List {
					ForEach(self.files) { file in
						Text(file.name())
					}
				}.frame(minHeight: 300)
				.refreshable {
					await self.update()
				}
			}
		}
		.task {
			await self.update()
		}
		.navigationTitle(device == nil ? "Files needed by this device" : "Files needed by \(device!.displayName)")
	}

	private func update() async {
		if loading {
			return
		}

		do {
			self.loading = true

			self.files = try await Task {
				var paths: [String]
				if let device = self.device {
					let completion = try folder.completion(forDevice: device.deviceID())
					Log.info("CPN \(completion.needItems), \(Self.fileLimit)")
					if completion.needItems > Self.fileLimit {
						throw Errors.tooManyFiles(count: completion.needItems)
					}
					
					paths = (try folder.filesNeeded(by: device.deviceID())).asArray()
				}
				else {
					let stats = try folder.statistics()
					if let ln = stats.localNeed, ln.files > Self.fileLimit {
						throw Errors.tooManyFiles(count: ln.files)
					}
					paths = (try folder.filesNeeded()).asArray()
				}
				return paths.compactMap { try? folder.getFileInformation($0) }
			}.value
		}
		catch {
			self.error = error
			self.files = []
		}
		self.loading = false
	}
}

struct FolderStatisticsView: View {
	@EnvironmentObject var appState: AppState
	var folder: SushitrainFolder

	private var possiblePeers: [String: SushitrainPeer] {
		let peers = appState.peers().filter({ d in !d.isSelf() })
		var dict: [String: SushitrainPeer] = [:]
		for peer in peers {
			dict[peer.deviceID()] = peer
		}
		return dict
	}

	var body: some View {
		Form {
			let formatter = ByteCountFormatter()
			if let stats = try? self.folder.statistics() {
				if let g = stats.global {
					Section("Full folder") {
						// Use .formatted() here because zero is hidden in badges and that looks weird
						Text("Number of files").badge(g.files.formatted())
						Text("Number of directories").badge(g.directories.formatted())
						Text("File size").badge(formatter.string(fromByteCount: g.bytes))
					}
				}

				let totalLocal = Double(stats.global!.bytes)
				let myPercentage = Int(
					totalLocal > 0 ? (100.0 * Double(stats.local!.bytes) / totalLocal) : 100)

				if let local = stats.local {
					Section {
						NavigationLink(destination: NeededFilesView(folder: folder, device: nil)) {
							Text("Number of files").badge(local.files.formatted())
						}
						Text("Number of directories").badge(local.directories.formatted())
						Text("File size").badge(formatter.string(fromByteCount: local.bytes))
					} header: {
						HStack {
							Text("On this device: \(myPercentage)% of the full folder")
							#if os(macOS)
								Spacer()
								ProgressView(value: Double(myPercentage), total: 100.0)
									.progressViewStyle(.circular)
									.controlSize(.mini)
							#endif
						}
					}
				}

				let devices = self.folder.sharedWithDeviceIDs()?.asArray() ?? []
				let peers = self.possiblePeers

				if !devices.isEmpty {
					Section {
						ForEach(devices, id: \.self) { deviceID in
							if let completion = try? self.folder.completion(
								forDevice: deviceID)
							{
								if let device = peers[deviceID] {
									NavigationLink(destination: NeededFilesView(folder: folder, device: device)) {
										HStack {
											Label(
												device.name(),
												systemImage: "externaldrive"
											)
											Spacer()
										}.badge(
											Text(
												"\(Int(completion.completionPct))%"
											))
									}
								}
							}
						}
					} header: {
						Text("Other devices progress")
					} footer: {
						Text(
							"The percentage of the files a device has synchronized, relative to the part of the folder it wants to synchronize. Because devices may ignore certain files or not synchronize any files at all, the percentage does not indicate the percentage of the full folder actually present on the device."
						)
					}
				}
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
			.navigationTitle("Folder statistics: '\(self.folder.displayName)'")
		#endif

		#if os(iOS)
			.navigationTitle("Folder statistics")
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}
