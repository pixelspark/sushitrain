// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

private struct GridItemView: View {
	@EnvironmentObject var appState: AppState
	let size: Double
	let file: SushitrainEntry

	var body: some View {
		ZStack(alignment: .topTrailing) {
			Rectangle()
				.frame(width: size, height: size)
				.backgroundStyle(Color.primary)
				.opacity(0.05)

			ThumbnailView(file: file, appState: appState, showFileName: true, showErrorMessages: false)
				.frame(width: size, height: size)
				.id(file.id)
		}
	}
}

struct GridFilesView: View {
	@EnvironmentObject var appState: AppState
	var prefix: String
	var files: [SushitrainEntry]
	var subdirectories: [SushitrainEntry]
	var folder: SushitrainFolder

	var body: some View {
		let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 1.0), count: appState.browserGridColumns)

		LazyVGrid(columns: gridColumns, spacing: 1.0) {
			// List subdirectories
			ForEach(subdirectories, id: \.self.id) { (subDirEntry: SushitrainEntry) in
				GeometryReader { geo in
					let fileName = subDirEntry.fileName()
					NavigationLink(
						destination: BrowserView(folder: folder, prefix: "\(self.prefix)\(fileName)/")
					) {
						GridItemView(size: geo.size.width, file: subDirEntry)
					}
					.buttonStyle(PlainButtonStyle())
					.contextMenu(
						ContextMenu(menuItems: {
							if let file = try? folder.getFileInformation(
								self.prefix + fileName)
							{
								NavigationLink(destination: FileView(file: file)) {
									Label("Subdirectory properties", systemImage: "folder.badge.gearshape")
								}
								ItemSelectToggleView(file: file)
							}
						}))
				}
				.aspectRatio(1, contentMode: .fit)
				.clipShape(.rect)
				.contentShape(.rect())
			}

			// List files
			ForEach(files, id: \.self) { file in
				GeometryReader { geo in
					FileEntryLink(
						appState: appState,
						entry: file, inFolder: self.folder, siblings: files, honorTapToPreview: true
					) {
						GridItemView(size: geo.size.width, file: file)
					}
					.buttonStyle(PlainButtonStyle())
				}
				.clipShape(.rect)
				.contentShape(.rect())
				.aspectRatio(1, contentMode: .fit)
			}
		}
	}
}
