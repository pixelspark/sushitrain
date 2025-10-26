// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

struct BrowserListView: View {
	@Environment(AppState.self) private var appState
	let folder: SushitrainFolder
	let prefix: String
	let hasExtraneousFiles: Bool
	let files: [SushitrainEntry]
	let subdirectories: [SushitrainEntry]
	let viewStyle: BrowserViewStyle

	@State private var showStatistics = false

	var body: some View {
		List {
			Section {
				Button(action: {
					showStatistics = true
				}) {
					FolderStatusView(folder: folder)
				}.sheet(isPresented: $showStatistics) {
					NavigationStack {
						FolderStatisticsView(folder: folder)
							.toolbar {
								SheetButton(role: .done) {
									showStatistics = false
								}
							}
					}
				}

				if hasExtraneousFiles {
					NavigationLink(destination: { ExtraFilesView(folder: self.folder) }) {
						Label("This folder has new files", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
					}
				}
			}

			// List subdirectories
			Section {
				ForEach(subdirectories, id: \.self) { (subDirEntry: SushitrainEntry) in
					let fileName = subDirEntry.fileName()
					NavigationLink(
						destination: BrowserView(folder: folder, prefix: "\(prefix)\(fileName)/", userSettings: appState.userSettings)
					) {
						ItemSelectSwipeView(file: subDirEntry) {
							// Subdirectory name
							HStack(spacing: 9.0) {
								Image(systemName: subDirEntry.systemImage).foregroundStyle(subDirEntry.color ?? Color.accentColor)
								Text(subDirEntry.fileName()).multilineTextAlignment(.leading).foregroundStyle(Color.primary).opacity(
									subDirEntry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
								Spacer()
							}.frame(maxWidth: .infinity).padding(0)
						}
					}.contextMenu(
						ContextMenu(menuItems: {
							if let file = try? folder.getFileInformation(self.prefix + fileName) {
								NavigationLink(destination: FileView(file: file, showPath: false, siblings: nil)) {
									Label("Subdirectory properties", systemImage: "folder.badge.gearshape")
								}

								ItemSelectToggleView(file: file)

								NavigationLink(destination: SelectiveFolderView(folder: folder, prefix: "\(self.prefix)\(fileName)/")) {
									Label("Files kept on this device", systemImage: "pin")
								}

								if file.hasExternalSharingURL { FileSharingLinksView(entry: file, sync: true) }
							}
						}))
				}
			}

			// List files
			Section {
				ForEach(files, id: \.self) { file in
					EntryView(
						entry: file,
						folder: folder,
						siblings: files,
						showThumbnail: self.viewStyle == .thumbnailList
					)
				}
			}

			// Show number of items
			FilesFooterView(subdirectories: self.subdirectories.count, files: self.files.count)
				#if os(iOS)
					.listRowBackground(Color(.systemGroupedBackground))
				#endif
		}
		#if os(macOS)
			.listStyle(.inset(alternatesRowBackgrounds: true))
		#endif
	}
}

struct EntryView: View {
	@Environment(AppState.self) private var appState
	let entry: SushitrainEntry
	let folder: SushitrainFolder?
	let siblings: [SushitrainEntry]
	let showThumbnail: Bool

	static let remoteFileOpacity = 0.7

	private func entryView(entry: SushitrainEntry) -> some View {
		ItemSelectSwipeView(file: entry) {
			if self.showThumbnail {
				// Thubmnail view shows thumbnail image next to the file name
				HStack(alignment: .center, spacing: 9.0) {
					ThumbnailView(file: entry, showFileName: false, showErrorMessages: false)
						.frame(width: 60, height: 40)
						.cornerRadius(6.0).help(entry.fileName())

					// The entry name (grey when not locally present)
					Text(entry.fileName()).multilineTextAlignment(.leading).foregroundStyle(
						entry.isConflictCopy() ? Color.red : Color.primary
					).opacity(entry.isLocallyPresent() ? 1.0 : Self.remoteFileOpacity)
					Spacer()
				}.frame(maxWidth: .infinity).padding(0)
			}
			else {
				HStack {
					Image(systemName: entry.systemImage).foregroundStyle(entry.color ?? Color.accentColor)
					Text(entry.fileName()).multilineTextAlignment(.leading).foregroundStyle(
						entry.isConflictCopy() ? Color.red : Color.primary
					).opacity(entry.isLocallyPresent() ? 1.0 : Self.remoteFileOpacity)
					Spacer()
				}.frame(maxWidth: .infinity)
			}
		}
	}

	var body: some View {
		if entry.isSymlink() {
			// Find the destination
			let targetEntry = try? entry.symlinkTargetEntry()
			if let targetEntry = targetEntry {
				if targetEntry.isDirectory() {
					if let targetFolder = targetEntry.folder {
						NavigationLink(
							destination: BrowserView(
								folder: targetFolder, prefix: targetEntry.path() + "/", userSettings: appState.userSettings)
						) { self.entryView(entry: entry) }.contextMenu {
							NavigationLink(
								destination: FileView(file: targetEntry, showPath: self.folder == nil, siblings: nil)
							) { Label(targetEntry.fileName(), systemImage: targetEntry.systemImage) }
							NavigationLink(
								destination: FileView(file: entry, showPath: self.folder == nil, siblings: siblings)
							) { Label(entry.fileName(), systemImage: entry.systemImage) }
						}
					}
				}
				else {
					FileEntryLink(appState: appState, entry: targetEntry, inFolder: self.folder, siblings: [], honorTapToPreview: true)
					{
						self.entryView(entry: targetEntry)
					}.contextMenu {
						NavigationLink(
							destination: FileView(file: targetEntry, showPath: self.folder == nil, siblings: nil)
						) { Label(targetEntry.fileName(), systemImage: targetEntry.systemImage) }
						NavigationLink(
							destination: FileView(file: entry, showPath: self.folder == nil, siblings: siblings)
						) { Label(entry.fileName(), systemImage: entry.systemImage) }
					} preview: {
						NavigationStack {  // to force the image to take up all available space
							VStack {
								ThumbnailView(file: targetEntry, showFileName: false, showErrorMessages: false)
									.frame(minWidth: 240, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
									.environment(appState)  // Necessary because for some reason environment is not inherited
							}
						}
					}
				}
			}
			else if let targetURL = entry.symlinkTargetURL {
				Link(destination: targetURL) { self.entryView(entry: entry) }.contextMenu {
					Link(destination: targetURL) { Label(targetURL.absoluteString, systemImage: "globe") }
					NavigationLink(
						destination: FileView(file: entry, showPath: self.folder == nil, siblings: siblings)
					) { Label(entry.fileName(), systemImage: entry.systemImage) }
				}
			}
			else {
				Label(entry.fileName(), systemImage: "questionmark.app.dashed")
			}
		}
		else {
			FileEntryLink(appState: appState, entry: entry, inFolder: self.folder, siblings: siblings, honorTapToPreview: true) {
				self.entryView(entry: entry)
			}
		}
	}
}

struct FileEntryLink<Content: View>: View {
	let appState: AppState
	let entry: SushitrainEntry
	let inFolder: SushitrainFolder?
	let siblings: [SushitrainEntry]
	let honorTapToPreview: Bool
	@ViewBuilder var content: () -> Content

	@State private var quickLookURL: URL? = nil
	@State private var showPreviewSheet: Bool = false
	@State private var canPreview: Bool = false

	#if os(macOS)
		@Environment(\.openWindow) private var openWindow
	#endif

	private func previewFile() {
		#if os(macOS)
			openWindow(id: "preview", value: Preview(folderID: entry.folder!.folderID, path: entry.path()))
		#else
			// Tap to preview local file in QuickLook
			if entry.isLocallyPresent(), let url = entry.localNativeFileURL {
				self.quickLookURL = url
			}
			else if entry.isStreamable {
				self.showPreviewSheet = true
			}
		#endif
	}

	private var inner: some View {
		Group {
			if canPreview && honorTapToPreview && appState.userSettings.tapFileToPreview {
				Button(action: { self.previewFile() }) { self.content() }
					#if os(macOS)
						.buttonStyle(.link)
					#endif
					.foregroundStyle(.primary)
					.frame(maxWidth: .infinity)
					.quickLookPreview(self.$quickLookURL)
			}
			else {
				// Tap to go to file view
				NavigationLink(
					destination: FileView(file: entry, showPath: self.inFolder == nil, siblings: siblings)
				) { self.content() }
			}
		}
		#if os(macOS)
			.sheet(isPresented: $showPreviewSheet) {
				FileViewerView(file: entry, siblings: siblings, inSheet: true, isShown: $showPreviewSheet)
				.presentationSizing(.fitted)
				.frame(minWidth: 640, minHeight: 480)
				.navigationTitle(entry.fileName())
				.toolbar {
					ToolbarItem(placement: .confirmationAction) { Button("Done") { showPreviewSheet = false } }
				}
			}
		#else
			.fullScreenCover(isPresented: $showPreviewSheet) {
				FileViewerView(file: entry, siblings: siblings, inSheet: true, isShown: $showPreviewSheet)
			}
		#endif
	}

	var body: some View {
		self.inner.draggable(entry).contextMenu {
			#if os(iOS)
				NavigationLink(
					destination: FileView(file: entry, showPath: self.inFolder == nil, siblings: siblings)
				) { Label(entry.fileName(), systemImage: entry.systemImage) }
			#else
				if appState.userSettings.tapFileToPreview {
					NavigationLink(
						destination: FileView(file: entry, showPath: self.inFolder == nil, siblings: siblings)
					) { Label("Show info", systemImage: entry.systemImage) }
				}
			#endif

			if !appState.userSettings.tapFileToPreview {
				Button("Show preview", systemImage: "doc.text.magnifyingglass") { self.previewFile() }.disabled(!canPreview)
			}

			// Show file in Finder
			if entry.canShowInFinder {
				Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app") {
					try? entry.showInFinder()
				}
			}

			#if os(macOS)
				Button("Copy", systemImage: "document.on.document") {
					self.copy()
				}.disabled(!entry.isLocallyPresent())
			#endif

			// Show 'go to location' in list if we are not in the file's folder already
			if self.inFolder == nil {
				if let folder = entry.folder {
					NavigationLink(
						destination: BrowserView(folder: folder, prefix: entry.parentPath(), userSettings: appState.userSettings)
					) {
						let parentFolderName = entry.parentFolderName
						if parentFolderName.isEmpty {
							Label("Go to location", systemImage: "document.circle")
						}
						else {
							Label("Go to directory '\(parentFolderName)'", systemImage: "document.circle")
						}
					}
				}
			}

			if entry.hasExternalSharingURL {
				Divider()
				FileSharingLinksView(entry: entry, sync: true)
			}

			Divider()

			ItemSelectToggleView(file: entry)
		} preview: {
			NavigationStack {  // to force the image to take up all available space
				VStack {
					ThumbnailView(file: entry, showFileName: false, showErrorMessages: false)
						.frame(minWidth: 240, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
						.environment(appState)  // Necessary because for some reason environment is not inherited
				}
			}
		}
		.task {
			self.canPreview = entry.canPreview
		}
	}

	private func copy() {
		if let url = entry.localNativeFileURL as? NSURL, let refURL = url.fileReferenceURL() {
			writeURLToPasteboard(url: refURL)
		}
		else if let url = URL(string: entry.onDemandURL()) {
			writeURLToPasteboard(url: url)
		}
	}
}

private struct ItemSelectSwipeView<Content: View>: View {
	let file: SushitrainEntry
	@ViewBuilder var content: Content

	@State private var errorMessage: String? = nil

	var body: some View {
		if self.file.isSelectionToggleAvailable {
			self.content
				.alert(isPresented: Binding.isNotNil($errorMessage)) {
					Alert(
						title: Text("Could not change synchronization setting"), message: Text(errorMessage ?? ""),
						dismissButton: .default(Text("OK")))
				}
				.swipeActions(allowsFullSwipe: false) {
					if file.isExplicitlySelected() || file.isSelected() {
						// Unselect button
						Button {
							Task { self.errorMessage = await self.file.setSelectedFromToggle(s: false) }
						} label: {
							Label("Do not synchronize with this device", systemImage: "pin.slash")
						}.tint(.red)
					}
					else {
						// Select button
						Button {
							Task { self.errorMessage = await self.file.setSelectedFromToggle(s: true) }
						} label: {
							Label("Synchronize with this device", systemImage: "pin")
						}
					}
				}
		}
		else {
			self.content
		}
	}
}
