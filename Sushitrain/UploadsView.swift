// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct UploadsView: View {
	@Environment(AppState.self) private var appState
	@State private var uploads: [UploadingPeer] = []

	private struct UploadingPeer: Identifiable {
		let peer: SushitrainPeer
		let folders: [UploadingFolder]

		var id: SushitrainPeer.ID { peer.id }
	}

	private struct UploadingFolder: Identifiable {
		let folder: SushitrainFolder
		let files: [UploadingFile]

		var id: SushitrainFolder.ID { folder.id }
	}

	private struct UploadingFile: Identifiable {
		let path: String
		let progress: SushitrainProgress?

		var id: String { path }
	}

	private func update() {
		let peers = (appState.client.uploadingToPeers()?.asArray() ?? []).compactMap {
			appState.client.peer(withID: $0)
		}.sorted()

		self.uploads = peers.compactMap { peer in
			let folders = (appState.client.uploadingFolders(forPeer: peer.deviceID())?.asArray() ?? []).compactMap {
				appState.client.folder(withID: $0)
			}.sorted()

			let uploadingFolders = folders.compactMap { folder in
				let files =
					(appState.client.uploadingFiles(forPeerAndFolder: peer.deviceID(), folderID: folder.folderID)?.asArray() ?? [])
					.sorted()
					.map { filePath in
						UploadingFile(
							path: filePath,
							progress: appState.client.uploadProgress(
								forPeerFolderPath: peer.deviceID(), folderID: folder.folderID, path: filePath)
						)
					}
				return files.isEmpty ? nil : UploadingFolder(folder: folder, files: files)
			}

			return uploadingFolders.isEmpty ? nil : UploadingPeer(peer: peer, folders: uploadingFolders)
		}
	}

	var body: some View {
		List {
			if uploads.isEmpty {
				ContentUnavailableView(
					"Not uploading", systemImage: "pause.circle",
					description: Text("Currently no files are being sent to other devices.")
				).frame(maxWidth: .infinity, alignment: .center)
			}
			else {
				// Grouped by peers we are uploading to
				ForEach(uploads) { peer in
					Section(peer.peer.displayName) {
						ForEach(peer.folders) { folder in
							ForEach(folder.files) { file in
								if let progress = file.progress {
									ProgressView(value: progress.percentage, total: 1.0) {
										Label("\(folder.folder.displayName): \(file.path)", systemImage: "arrow.up").foregroundStyle(.green)
											.symbolEffect(.pulse, value: progress.percentage).frame(maxWidth: .infinity, alignment: .leading)
											.multilineTextAlignment(.leading)
									}.tint(.green)
								}
								else {
									Text("\(folder.folder.displayName): \(file.path)")
								}
							}
						}
					}
				}
			}
		}
		.navigationTitle("Sending files")
		.task {
			self.update()
		}
		.onChange(of: appState.eventCounter) {
			self.update()
		}
	}
}
