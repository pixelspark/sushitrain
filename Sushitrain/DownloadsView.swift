// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct DownloadsView: View {
	@Environment(AppState.self) private var appState
	@State private var downloading: [DownloadingFolder] = []

	private struct DownloadingFolder: Identifiable {
		let folder: SushitrainFolder
		let files: [DownloadingFile]

		var id: SushitrainFolder.ID { folder.id }
	}

	private struct DownloadingFile: Identifiable {
		let path: String
		let progress: SushitrainProgress

		var id: String { path }
	}

	var body: some View {
		List {
			if downloading.isEmpty {
				ContentUnavailableView(
					"Not downloading", systemImage: "pause.circle",
					description: Text("Currently no files are being downloaded from other devices.")
				).frame(maxWidth: .infinity, alignment: .center)
			}
			else {
				// Grouped by folder.
				ForEach(downloading) { folder in
					Section(folder.folder.displayName) {
						ForEach(folder.files) { file in
							ProgressView(value: file.progress.percentage, total: 1.0) {
								Label("\(file.path)", systemImage: "arrow.down").foregroundStyle(.green)
									.symbolEffect(.pulse, value: file.progress.percentage).frame(maxWidth: .infinity, alignment: .leading)
									.multilineTextAlignment(.leading)
							}.tint(.green)
						}
					}
				}
			}
		}
		.navigationTitle("Receiving files")
		.task {
			self.update()
		}
		.onChange(of: appState.eventCounter) { _, _ in
			self.update()
		}
	}

	private func update() {
		let folders = (appState.client.downloadingFolders()?.asArray() ?? []).compactMap {
			appState.client.folder(withID: $0)
		}.sorted()

		self.downloading = folders.compactMap { folder in
			let paths = (appState.client.downloadingPaths(forFolder: folder.folderID)?.asArray() ?? []).sorted()
			let files: [DownloadingFile] = paths.compactMap { path in
				guard let progress = appState.client.getDownloadProgress(forFile: path, folder: folder.folderID) else {
					return nil
				}
				return DownloadingFile(path: path, progress: progress)
			}
			return files.isEmpty ? nil : DownloadingFolder(folder: folder, files: files)
		}
	}
}
