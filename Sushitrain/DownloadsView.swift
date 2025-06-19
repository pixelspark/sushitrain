// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct DownloadsView: View {
	@Environment(AppState.self) private var appState
	@State private var downloading: [SushitrainFolder: [String: SushitrainProgress]] = [:]

	var body: some View {
		List {
			if downloading.isEmpty {
				ContentUnavailableView(
					"Not downloading", systemImage: "pause.circle",
					description: Text("Currently no files are being downloaded from other devices.")
				).frame(maxWidth: .infinity, alignment: .center)
			}
			else {
				// Grouped by peers we are uploading to
				ForEach(Array(downloading.keys.sorted()), id: \.self) { folder in
					let paths = downloading[folder]!
					Section(folder.displayName) {
						ForEach(Array(paths.keys.sorted()), id: \.self) { path in
							let progress = paths[path]!
							ProgressView(value: progress.percentage, total: 1.0) {
								Label("\(path)", systemImage: "arrow.down").foregroundStyle(.green)
									.symbolEffect(.pulse, value: progress.percentage).frame(maxWidth: .infinity, alignment: .leading)
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
		var filesByFolder: [SushitrainFolder: [String: SushitrainProgress]] = [:]
		let folders = appState.client.downloadingFolders()?.asArray() ?? []

		for folderID in folders {
			let folder = appState.client.folder(withID: folderID)!
			let paths = appState.client.downloadingPaths(forFolder: folderID)?.asArray() ?? []
			var progress: [String: SushitrainProgress] = [:]

			for path in paths {
				if let p = appState.client.getDownloadProgress(forFile: path, folder: folderID) {
					progress[path] = p
				}
			}
			filesByFolder[folder] = progress
		}
		self.downloading = filesByFolder
	}
}
