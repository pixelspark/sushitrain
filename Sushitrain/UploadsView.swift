// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct UploadsView: View {
	@Environment(AppState.self) private var appState
	@State private var isLoading = false
	@State private var uploadingToPeers: [SushitrainPeer] = []

	private func update() async {
		self.isLoading = true
		if let utp = appState.client.uploadingToPeers() {
			self.uploadingToPeers = utp.asArray().compactMap { peerID in appState.client.peer(withID: peerID) }.sorted {
				$0.displayName < $1.displayName
			}
		}
		else {
			self.uploadingToPeers = []
		}
		self.isLoading = false
	}

	var body: some View {
		List {
			if uploadingToPeers.isEmpty {
				ContentUnavailableView(
					"Not uploading", systemImage: "pause.circle",
					description: Text("Currently no files are being sent to other devices.")
				).frame(maxWidth: .infinity, alignment: .center)
			}
			else {
				// Grouped by peers we are uploading to
				ForEach(uploadingToPeers, id: \.id) { peer in
					Section(peer.displayName) {
						if let uploadingFolders = appState.client.uploadingFolders(forPeer: peer.deviceID()) {
							// For each folder we are uploading files from to this peer
							ForEach(uploadingFolders.asArray().sorted(), id: \.self) { folderID in
								if let folder = appState.client.folder(withID: folderID) {
									if let uploadingFiles = appState.client.uploadingFiles(forPeerAndFolder: peer.deviceID(), folderID: folderID) {
										// For each file that is being uploaded...
										ForEach(uploadingFiles.asArray().sorted(), id: \.self) { filePath in
											if let progress = appState.client.uploadProgress(
												forPeerFolderPath: peer.deviceID(), folderID: folderID, path: filePath)
											{
												ProgressView(value: progress.percentage, total: 1.0) {
													Label("\(folder.displayName): \(filePath)", systemImage: "arrow.up").foregroundStyle(.green)
														.symbolEffect(.pulse, value: progress.percentage).frame(maxWidth: .infinity, alignment: .leading)
														.multilineTextAlignment(.leading)
												}.tint(.green)
											}
											else {
												Text("\(folder.displayName): \(filePath)")
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
		.navigationTitle("Sending files")
		.task {
			await self.update()
		}
		.onChange(of: appState.eventCounter) {
			Task {
				await self.update()
			}
		}
	}
}
