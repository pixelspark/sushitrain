// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

enum BrowserViewStyle: String {
	case grid = "grid"
	case list = "list"
	case thumbnailList = "thumbnailList"
}

struct FileEntryLink<Content: View>: View {
	let appState: AppState
	let entry: SushitrainEntry
	let siblings: [SushitrainEntry]
	@ViewBuilder var content: () -> Content

	@State private var quickLookURL: URL? = nil
	@State private var showPreviewSheet: Bool = false

	private var inner: some View {
		Group {
			if appState.tapFileToPreview && entry.isLocallyPresent(),
				let url = entry.localNativeFileURL
			{
				// Tap to preview local file in QuicLook
				Button(action: {
					self.quickLookURL = url
				}) {
					self.content()
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.foregroundStyle(.primary)
				.frame(maxWidth: .infinity)
				.quickLookPreview(self.$quickLookURL)
			}
			else if appState.tapFileToPreview && entry.isStreamable {
				// Tap to preview in full-screen viewer
				Button(action: {
					self.showPreviewSheet = true
				}) {
					self.content()
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.foregroundStyle(.primary)
				.frame(maxWidth: .infinity)
				#if os(macOS)
					.sheet(isPresented: $showPreviewSheet) {
						FileViewerView(
							appState: appState, file: entry, siblings: siblings,
							isShown: $showPreviewSheet
						)
						.presentationSizing(.fitted)
						.frame(minWidth: 640, minHeight: 480)
						.navigationTitle(entry.fileName())
						.toolbar {
							ToolbarItem(placement: .confirmationAction) {
								Button("Done") { showPreviewSheet = false }
							}
						}
					}
				#else
					.fullScreenCover(isPresented: $showPreviewSheet) {
						FileViewerView(
							appState: appState, file: entry, siblings: siblings,
							isShown: $showPreviewSheet)
					}
				#endif
			}
			else {
				// Tap to go to file view
				NavigationLink(
					destination: FileView(file: entry, appState: self.appState, siblings: siblings)
				) {
					self.content()
				}
			}
		}
	}

	var body: some View {
		self.inner
			.draggable(entry)
			.contextMenu {
				#if os(iOS)
					NavigationLink(
						destination: FileView(
							file: entry, appState: self.appState, siblings: siblings)
					) {
						Label(entry.fileName(), systemImage: entry.systemImage)
					}
				#endif

				ItemSelectToggleView(appState: appState, file: entry)

				if let sharingLink = entry.externalSharingURL() {
					ShareLink(item: sharingLink) {
						Label("Share external link", systemImage: "link.circle.fill")
					}

					Button("Copy external link", systemImage: "link.circle") {
						writeURLToPasteboard(url: sharingLink)
					}
				}

				#if os(macOS)
					Button("Copy", systemImage: "document.on.document") {
						self.copy()
					}.disabled(!entry.isLocallyPresent())
				#endif
			} preview: {
				NavigationStack {  // to force the image to take up all available space
					VStack {
						ThumbnailView(
							file: entry, appState: appState, showFileName: false,
							showErrorMessages: false
						)
						.frame(
							minWidth: 240, maxWidth: .infinity, minHeight: 320,
							maxHeight: .infinity
						)
						.id(entry.id)
					}
				}
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

private struct EntryView: View {
	let appState: AppState
	let entry: SushitrainEntry
	let folder: SushitrainFolder
	let siblings: [SushitrainEntry]
	let showThumbnail: Bool

	static let remoteFileOpacity = 0.7

	private func entryView(entry: SushitrainEntry) -> some View {
		ItemSelectSwipeView(file: entry) {
			if self.showThumbnail {
				// Thubmnail view shows thumbnail image next to the file name
				HStack(alignment: .center, spacing: 9.0) {
					ThumbnailView(
						file: entry, appState: appState, showFileName: false,
						showErrorMessages: false
					)
					.frame(width: 60, height: 40)
					.cornerRadius(6.0)
					.id(entry.id)
					.help(entry.fileName())

					// The entry name (grey when not locally present)
					Text(entry.fileName())
						.multilineTextAlignment(.leading)
						.foregroundStyle(Color.primary)
						.opacity(entry.isLocallyPresent() ? 1.0 : Self.remoteFileOpacity)
					Spacer()
				}
				.frame(maxWidth: .infinity)
				.padding(0)
			}
			else {
				HStack {
					Image(systemName: entry.systemImage)
						.foregroundStyle(entry.color ?? Color.accentColor)
					Text(entry.fileName())
						.multilineTextAlignment(.leading)
						.foregroundStyle(Color.primary)
						.opacity(entry.isLocallyPresent() ? 1.0 : Self.remoteFileOpacity)
					Spacer()
				}
				.frame(maxWidth: .infinity)
			}
		}
	}

	var body: some View {
		if entry.isSymlink() {
			// Find the destination
			let targetEntry = try? entry.symlinkTargetEntry()
			if let targetEntry = targetEntry {
				if targetEntry.isDirectory() {
					NavigationLink(
						destination: BrowserView(
							appState: appState,
							folder: folder,
							prefix: targetEntry.path() + "/"
						)
					) {
						self.entryView(entry: entry)
					}
					.contextMenu {
						NavigationLink(
							destination: FileView(
								file: targetEntry, appState: self.appState, siblings: []
							)
						) {
							Label(
								targetEntry.fileName(),
								systemImage: targetEntry.systemImage)
						}
						NavigationLink(
							destination: FileView(
								file: entry, appState: self.appState, siblings: siblings
							)
						) {
							Label(entry.fileName(), systemImage: entry.systemImage)
						}
					}
				}
				else {
					FileEntryLink(appState: appState, entry: targetEntry, siblings: []) {
						self.entryView(entry: targetEntry)
					}
					.contextMenu {
						NavigationLink(
							destination: FileView(
								file: targetEntry, appState: self.appState, siblings: []
							)
						) {
							Label(
								targetEntry.fileName(),
								systemImage: targetEntry.systemImage)
						}
						NavigationLink(
							destination: FileView(
								file: entry, appState: self.appState, siblings: siblings
							)
						) {
							Label(entry.fileName(), systemImage: entry.systemImage)
						}
					} preview: {
						NavigationStack {  // to force the image to take up all available space
							VStack {
								ThumbnailView(
									file: targetEntry, appState: appState,
									showFileName: false,
									showErrorMessages: false
								)
								.frame(
									minWidth: 240, maxWidth: .infinity,
									minHeight: 320,
									maxHeight: .infinity
								)
								.id(targetEntry.id)
							}
						}
					}
				}
			}
			else if let targetURL = URL(string: entry.symlinkTarget()),
				targetURL.scheme == "https" || targetURL.scheme == "http"
			{
				Link(destination: targetURL) {
					self.entryView(entry: entry)
				}
				.contextMenu {
					Link(destination: targetURL) {
						Label(targetURL.absoluteString, systemImage: "globe")
					}
					NavigationLink(
						destination: FileView(
							file: entry, appState: self.appState, siblings: siblings)
					) {
						Label(entry.fileName(), systemImage: entry.systemImage)
					}
				}
			}
			else {
				Label(entry.fileName(), systemImage: "questionmark.app.dashed")
			}
		}
		else {
			FileEntryLink(appState: appState, entry: entry, siblings: siblings) {
				self.entryView(entry: entry)
			}
		}
	}
}

private struct BrowserListView: View {
	@ObservedObject var appState: AppState
	var folder: SushitrainFolder
	var prefix: String
	@Binding var searchText: String
	@Binding var showSettings: Bool
	@Binding var viewStyle: BrowserViewStyle

	@State private var subdirectories: [SushitrainEntry] = []
	@State private var files: [SushitrainEntry] = []
	@State private var hasExtraneousFiles = false
	@State private var isLoading = true
	@State private var showSpinner = false

	@Environment(\.isSearching) private var isSearching

	var body: some View {
		let isEmpty = subdirectories.isEmpty && files.isEmpty

		Group {
			if self.folder.exists() {
				if !isSearching {
					switch self.viewStyle {
					case .grid:
						VStack {
							ScrollView {
								HStack {
									FolderStatusView(
										appState: appState, folder: folder
									).padding(
										.all, 10)

									Spacer()

									Slider(
										value: Binding(
											get: {
												return Double(
													appState
														.browserGridColumns
												)
											},
											set: { nv in
												appState
													.browserGridColumns =
													Int(nv)
											}), in: 1.0...10.0, step: 1.0
									)
									.frame(minWidth: 50, maxWidth: 150)
									.padding(.horizontal, 20)
									.padding(.vertical, 15)
								}

								if hasExtraneousFiles {
									NavigationLink(destination: {
										ExtraFilesView(
											folder: self.folder,
											appState: self.appState)
									}) {
										Label(
											"This folder has new files",
											systemImage:
												"exclamationmark.triangle.fill"
										).foregroundColor(.orange)
									}
									.frame(maxWidth: .infinity)
								}

								GridFilesView(
									appState: appState, prefix: self.prefix,
									files: files,
									subdirectories: subdirectories, folder: folder
								)
								.padding(.horizontal, 15)
							}
						}
					case .list, .thumbnailList:
						List {
							Section {
								FolderStatusView(appState: appState, folder: folder)

								if hasExtraneousFiles {
									NavigationLink(destination: {
										ExtraFilesView(
											folder: self.folder,
											appState: self.appState)
									}) {
										Label(
											"This folder has new files",
											systemImage:
												"exclamationmark.triangle.fill"
										).foregroundColor(.orange)
									}
								}
							}

							// List subdirectories
							Section {
								ForEach(subdirectories, id: \.self) {
									(subDirEntry: SushitrainEntry) in
									let fileName = subDirEntry.fileName()
									NavigationLink(
										destination: BrowserView(
											appState: appState,
											folder: folder,
											prefix: "\(prefix)\(fileName)/"
										)
									) {
										ItemSelectSwipeView(file: subDirEntry) {
											// Subdirectory name
											HStack(spacing: 9.0) {
												Image(
													systemName:
														subDirEntry
														.systemImage
												)
												.foregroundStyle(
													subDirEntry
														.color
														?? Color
														.accentColor
												)
												Text(
													subDirEntry
														.fileName()
												)
												.multilineTextAlignment(
													.leading
												)
												.foregroundStyle(
													Color.primary
												)
												.opacity(
													subDirEntry
														.isLocallyPresent()
														? 1.0
														: EntryView
															.remoteFileOpacity
												)
												Spacer()
											}
											.frame(maxWidth: .infinity)
											.padding(0)
										}
									}
									.contextMenu(
										ContextMenu(menuItems: {
											if let file =
												try? folder
												.getFileInformation(
													self.prefix
														+ fileName
												)
											{
												NavigationLink(
													destination:
														FileView(
															file:
																file,
															appState:
																self
																.appState
														)
												) {
													Label(
														"Subdirectory properties",
														systemImage:
															"folder.badge.gearshape"
													)
												}

												ItemSelectToggleView(
													appState:
														appState,
													file: file)

												if let sharingLink =
													file
													.externalSharingURL()
												{
													ShareLink(
														item:
															sharingLink
													) {
														Label(
															"Share external link",
															systemImage:
																"link.circle.fill"
														)
													}

													Button(
														"Copy external link",
														systemImage:
															"link.circle"
													) {
														writeURLToPasteboard(
															url:
																sharingLink
														)
													}
												}
											}
										}))
								}
							}

							// List files
							Section {
								ForEach(files, id: \.self) { file in
									EntryView(
										appState: appState, entry: file,
										folder: folder,
										siblings: files,
										showThumbnail: self.viewStyle
											== .thumbnailList
									)
									.id(file.id)
								}
							}

							// Show number of items
							Group {
								if !self.subdirectories.isEmpty && self.files.isEmpty {
									Text(
										"\(self.subdirectories.count) subdirectories"
									)
								}
								else if !self.files.isEmpty
									&& self.subdirectories.isEmpty
								{
									Text("\(self.files.count) files")
								}
								else if !self.files.isEmpty
									&& !self.subdirectories.isEmpty
								{
									Text(
										"\(self.files.count) files and \(self.subdirectories.count) subdirectories"
									)
								}
							}
							.font(.footnote)
							.foregroundColor(.secondary)
							.frame(maxWidth: .infinity)
							#if os(iOS)
								.listRowBackground(Color(.systemGroupedBackground))
							#endif
						}
						#if os(macOS)
							.listStyle(.inset(alternatesRowBackgrounds: true))
						#endif
					}
				}
				else {
					// Search
					SearchResultsView(
						appState: self.appState,
						searchText: $searchText,
						folderID: .constant(self.folder.folderID),
						prefix: Binding(get: { prefix }, set: { _ in () })
					)
				}
			}
		}
		.overlay {
			if !folder.exists() {
				ContentUnavailableView(
					"Folder removed", systemImage: "trash",
					description: Text("This folder was removed."))
			}
			else if isLoading {
				if isEmpty && showSpinner {
					ProgressView()
				}
				// Load the rest while already showing a part of the results
			}
			else if isEmpty {
				if self.prefix == "" {
					if self.folder.isPaused() {
						ContentUnavailableView(
							"Synchronization disabled", systemImage: "pause.fill",
							description: Text(
								"Synchronization has been disabled for this folder. Enable it in folder settings to access files."
							)
						).onTapGesture {
							showSettings = true
						}
					}
					else if self.folder.connectedPeerCount() == 0 {
						ContentUnavailableView(
							"Not connected", systemImage: "network.slash",
							description: Text(
								"Share this folder with other devices to start synchronizing files."
							)
						).onTapGesture {
							showSettings = true
						}
					}
					else {
						ContentUnavailableView(
							"There are currently no files in this folder.",
							systemImage: "questionmark.folder",
							description: Text(
								"If this is unexpected, ensure that the other devices have accepted syncing this folder with your device."
							)
						).onTapGesture {
							showSettings = true
						}
					}

				}
				else {
					ContentUnavailableView(
						"There are currently no files in this folder.",
						systemImage: "questionmark.folder")
				}
			}
		}
		.refreshable {
			await self.refresh()
		}
		.task(id: self.folder.folderStateForUpdating) {
			await self.reload()
		}
		.onChange(of: self.folder.folderStateForUpdating) {
			Task {
				await self.reload()
			}
		}
	}

	private func refresh() async {
		Log.info("Rescan subdir \(self.prefix)")
		try? self.folder.rescanSubdirectory(self.prefix)
		await self.reload()
	}

	private func reload() async {
		self.isLoading = true
		self.showSpinner = false
		let loadingSpinnerTask = Task {
			try await Task.sleep(nanoseconds: 300_000_000)
			if !Task.isCancelled && self.isLoading {
				self.showSpinner = true
			}
		}

		let folder = self.folder
		let prefix = self.prefix
		let dotFilesHidden = self.appState.dotFilesHidden

		subdirectories = await Task.detached {
			if !folder.exists() {
				return []
			}
			do {
				var dirNames = try folder.list(prefix, directories: true, recurse: false).asArray()
					.sorted()
				if dotFilesHidden {
					dirNames = dirNames.filter({ !$0.starts(with: ".") })
				}
				return try dirNames.map({ dirName in
					return try folder.getFileInformation(prefix + dirName)
				})
			}
			catch let error {
				Log.warn("Error listing: \(error.localizedDescription)")
			}
			return []
		}.value

		files = await Task.detached {
			if !folder.exists() {
				return []
			}
			do {
				let list = try folder.list(self.prefix, directories: false, recurse: false)
				var entries: [SushitrainEntry] = []
				for i in 0..<list.count() {
					let path = list.item(at: i)
					if dotFilesHidden && path.starts(with: ".") {
						continue
					}
					if let fileInfo = try? folder.getFileInformation(self.prefix + path) {
						if fileInfo.isDirectory() || fileInfo.isDeleted() {
							continue
						}
						entries.append(fileInfo)
					}
				}
				return entries.sorted()
			}
			catch let error {
				Log.warn("Error listing: \(error.localizedDescription)")
			}
			return []
		}.value

		if self.folder.isIdle {
			hasExtraneousFiles = await Task.detached {
				var hasExtra: ObjCBool = false
				do {
					try folder.hasExtraneousFiles(&hasExtra)
					return hasExtra.boolValue
				}
				catch let error {
					Log.warn("error checking for extraneous files: \(error.localizedDescription)")
				}
				return false
			}.value
		}
		else {
			hasExtraneousFiles = false
		}

		self.isLoading = false
		loadingSpinnerTask.cancel()
	}
}

struct BrowserView: View {
	@ObservedObject var appState: AppState
	var folder: SushitrainFolder
	var prefix: String

	@State private var showSettings = false
	@State private var showFolderStatistics = false
	@State private var searchText = ""
	@State private var localNativeURL: URL? = nil
	@State private var folderExists = false
	@State private var folderIsSelective = false
	@State private var showSearch = false
	@State private var error: Error? = nil

	#if os(macOS)
		@State private var showIgnores = false
	#endif

	private var folderName: String {
		if prefix.isEmpty {
			return self.folder.label()
		}
		let parts = prefix.split(separator: "/")
		if parts.count > 0 {
			return String(parts[parts.count - 1])
		}
		return prefix
	}

	var body: some View {
		BrowserListView(
			appState: appState, folder: folder, prefix: prefix, searchText: $searchText,
			showSettings: $showSettings, viewStyle: appState.$browserViewStyle
		)
		.navigationTitle(folderName)
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.searchable(
				text: $searchText, placement: SearchFieldPlacement.toolbar,
				prompt: "Search files in this folder...")
		#elseif os(iOS)
			.sheet(isPresented: $showSearch) {
				NavigationStack {
					SearchView(appState: self.appState, prefix: self.prefix, folder: self.folder)
					.navigationTitle("Search in this folder")
					.navigationBarTitleDisplayMode(.inline)
					.toolbar(content: {
						ToolbarItem(
							placement: .cancellationAction,
							content: {
								Button("Cancel") {
									showSearch = false
								}
							})
					})
				}
			}
		#endif
		.toolbar {
			#if os(macOS)
				ToolbarItemGroup(placement: .status) {
					Picker("View as", selection: appState.$browserViewStyle) {
						Image(systemName: "list.bullet").tag(BrowserViewStyle.list)
							.accessibilityLabel(Text("List"))
						Image(systemName: "checklist.unchecked").tag(
							BrowserViewStyle.thumbnailList
						)
						.accessibilityLabel(Text("List with previews"))
						Image(systemName: "square.grid.2x2").tag(BrowserViewStyle.grid)
							.accessibilityLabel(Text("Grid"))
					}
					.pickerStyle(.segmented)
				}
			#endif

			#if os(macOS)
				ToolbarItem {
					// Open in Finder/Files (and possibly materialize empty folder)
					if let localNativeURL = self.localNativeURL {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								openURLInSystemFilesApp(url: localNativeURL)
							}
						).disabled(!folderExists)
					}
					else if folderExists {
						if let entry = try? self.folder.getFileInformation(
							self.prefix.withoutEndingSlash)
						{
							if entry.isDirectory() && !entry.isLocallyPresent() {
								Button(
									openInFilesAppLabel,
									systemImage: "arrow.up.forward.app",
									action: {
										try? entry.materializeSubdirectory()
										self.updateLocalURL()

										if let localNativeURL = self
											.localNativeURL
										{
											openURLInSystemFilesApp(
												url: localNativeURL)
										}
									})
							}
						}
					}
				}

				ToolbarItem {
					Menu {
						if folderExists {
							Button {
								showFolderStatistics = true
							} label: {
								Label("Folder statistics...", systemImage: "scalemass")
							}
						}

						if folderExists && folderIsSelective {
							NavigationLink(
								destination: SelectiveFolderView(
									appState: appState, folder: folder)
							) {
								Label(
									"Files kept on this device...",
									systemImage: "pin")
							}
						}

						Button {
							showSettings = true
						} label: {
							Label(
								"Folder settings...",
								systemImage: "folder.badge.gearshape")
						}

						#if os(macOS)
							if !folder.isSelective() {
								// On iOS this is in the folder settings screen
								Button {
									showIgnores = true
								} label: {
									Label(
										"Files to ignore...",
										systemImage: "rectangle.dashed")
								}
							}
						#endif
					} label: {
						Label("Folder settings", systemImage: "folder.badge.gearshape")
					}.disabled(!folderExists)
				}
			#elseif os(iOS)
				ToolbarItem {
					Menu(
						content: {
							Picker("View as", selection: appState.$browserViewStyle) {
								HStack {
									Image(systemName: "list.bullet")
									Text("List")
								}.tag(BrowserViewStyle.list)
								HStack {
									Image(systemName: "checklist.unchecked")
									Text("List with previews")
								}.tag(BrowserViewStyle.thumbnailList)
								HStack {
									Image(systemName: "square.grid.2x2")
									Text("Grid with previews")
								}.tag(BrowserViewStyle.grid)
							}
							.pickerStyle(.inline)

							Toggle(
								"Search here...", systemImage: "magnifyingglass",
								isOn: $showSearch
							).disabled(!folderExists)

							if folderExists && !self.prefix.isEmpty {
								if let entry = try? self.folder.getFileInformation(
									self.prefix.withoutEndingSlash)
								{
									NavigationLink(
										destination: FileView(
											file: entry,
											appState: self.appState)
									) {
										Label(
											"Subdirectory properties...",
											systemImage:
												"folder.badge.gearshape"
										)
									}
								}
							}

							Divider()

							if folderExists {
								// Open in Finder/Files (and possibly materialize empty folder)
								if let localNativeURL = self.localNativeURL {
									Button(
										openInFilesAppLabel,
										systemImage: "arrow.up.forward.app",
										action: {
											openURLInSystemFilesApp(
												url: localNativeURL)
										})
								}
								else {
									if let entry = try? self.folder
										.getFileInformation(
											self.prefix.withoutEndingSlash)
									{
										if entry.isDirectory()
											&& !entry.isLocallyPresent()
										{
											Button(
												openInFilesAppLabel,
												systemImage:
													"arrow.up.forward.app",
												action: {
													try? entry
														.materializeSubdirectory()
													self
														.updateLocalURL()

													if let
														localNativeURL =
														self
														.localNativeURL
													{
														openURLInSystemFilesApp(
															url:
																localNativeURL
														)
													}
												})
										}
									}
								}

								Button {
									showFolderStatistics = true
								} label: {
									Label(
										"Folder statistics...",
										systemImage: "scalemass")
								}

								NavigationLink(
									destination: SelectiveFolderView(
										appState: appState, folder: folder)
								) {
									Label(
										"Files kept on this device...",
										systemImage: "pin")
								}.disabled(!folderIsSelective)
							}

							Button(
								"Folder settings...",
								systemImage: "folder.badge.gearshape",
								action: {
									showSettings = true
								}
							).disabled(!folderExists)

						},
						label: {
							Image(systemName: "ellipsis.circle").accessibilityLabel(
								Text("Menu"))
						})
				}
			#endif
		}
		.sheet(isPresented: $showFolderStatistics) {
			NavigationStack {
				FolderStatisticsView(appState: appState, folder: folder)
					.toolbar(content: {
						ToolbarItem(
							placement: .confirmationAction,
							content: {
								Button("Done") {
									showFolderStatistics = false
								}
							})
					})
			}
		}
		.sheet(isPresented: $showSettings) {
			NavigationStack {
				FolderView(folder: self.folder, appState: self.appState)
					.toolbar {
						ToolbarItem(
							placement: .confirmationAction,
							content: {
								Button("Done") {
									showSettings = false
								}
							})
					}
			}
		}
		#if os(macOS)
			.sheet(isPresented: $showIgnores) {
				NavigationStack {
					IgnoresView(appState: self.appState, folder: self.folder)
					.navigationTitle("Files to ignore")
					.presentationSizing(.fitted)
					.frame(minWidth: 640, minHeight: 480)
					.toolbar {
						ToolbarItem(
							placement: .confirmationAction,
							content: {
								Button("Done") {
									showIgnores = false
								}
							})
					}
				}
			}
		#endif
		.task {
			self.folderExists = folder.exists()
			self.updateLocalURL()
			self.folderIsSelective = folder.isSelective()
		}
		#if os(macOS)
			.contextMenu {
				if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
					NavigationLink(destination: FileView(file: entry, appState: self.appState)) {
						Label("Subdirectory properties...", systemImage: entry.systemImage)
					}

					ItemSelectToggleView(appState: appState, file: entry)
				}
			}
			.onDrop(
				of: ["public.file-url"], isTargeted: nil,
				perform: { providers, _ in
					Task {
						self.error = nil
						do {
							try await self.onDrop(providers)
						}
						catch {
							Log.warn("Failed to drop: \(error.localizedDescription)")
							self.error = error
						}
					}
					return true
				})
		#endif
		.alert(
			isPresented: Binding(
				get: { return self.error != nil },
				set: { nv in
					if !nv {
						self.error = nil
					}
				})
		) {
			Alert(
				title: Text("An error occurred"),
				message: self.error == nil ? nil : Text(self.error!.localizedDescription),
				dismissButton: .default(Text("OK")))
		}
	}

	#if os(macOS)
		private func onDrop(_ providers: [NSItemProvider]) async throws {
			var urls: [URL] = []

			for provider in providers {
				let data: Data? = try await withCheckedThrowingContinuation { cb in
					provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") {
						(data, error) in
						if let e = error {
							cb.resume(throwing: e)
						}
						else {
							cb.resume(returning: data)
						}
					}
				}

				if let data = data, let path = NSString(data: data, encoding: 4),
					let url = URL(string: path as String)
				{
					urls.append(url)
				}
			}

			try self.dropFiles(urls)
		}

		private func dropFiles(_ urls: [URL]) throws {
			// Find out the native location of our folder
			var error: NSError? = nil
			let localNativePath = self.folder.localNativePath(&error)
			if let error = error {
				throw error
			}

			// If we are in a subdirectory, and the folder is selective, ensure the folder is materialized
			if !self.prefix.isEmpty && self.folder.isSelective() {
				let entry = try self.folder.getFileInformation(self.prefix.withoutEndingSlash)
				if entry.isDirectory() && !entry.isDeleted() {
					try entry.materializeSubdirectory()
				}
				else {
					// Somehow not a directory...
					return
				}
			}

			let localNativeURL = URL(fileURLWithPath: localNativePath).appendingPathComponent(
				self.prefix)
			var pathsToSelect: [String] = []

			if FileManager.default.fileExists(atPath: localNativeURL.path) {
				for url in urls {
					// Copy source to folder
					let targetURL = localNativeURL.appendingPathComponent(
						url.lastPathComponent, isDirectory: false)
					try FileManager.default.copyItem(at: url, to: targetURL)

					// Select the dropped file
					if folder.isSelective() {
						let localURL = URL(fileURLWithPath: self.prefix).appendingPathComponent(
							url.lastPathComponent, isDirectory: false)
						// Soft fail because we may be scanning or syncing
						pathsToSelect.append(localURL.path(percentEncoded: false))
					}
				}

				if folder.isSelective() {
					try self.folder.setLocalPathsExplicitlySelected(
						SushitrainListOfStrings.from(pathsToSelect))
				}

				try self.folder.rescanSubdirectory(self.prefix)
			}
		}
	#endif

	private func updateLocalURL() {
		// Get local native URL
		self.localNativeURL = nil
		var error: NSError? = nil
		let localNativePath = self.folder.localNativePath(&error)

		if error == nil {
			let localNativeURL = URL(fileURLWithPath: localNativePath).appendingPathComponent(
				self.prefix)

			if FileManager.default.fileExists(atPath: localNativeURL.path) {
				self.localNativeURL = localNativeURL
			}
		}
	}
}

extension SushitrainFolder {
	fileprivate var folderStateForUpdating: Int {
		var error: NSError? = nil
		let state = self.state(&error)
		var hasher = Hasher()
		hasher.combine(state)
		hasher.combine(self.isPaused())
		return hasher.finalize()
	}
}

// Shared functionality for swipe and toggle selection views
extension SushitrainEntry {
	fileprivate var isSelectionToggleAvailable: Bool {
		if let folder = self.folder {
			return folder.isSelective()
		}
		return false
	}

	// First check to see if this action should be disabled
	fileprivate var isSelectionToggleShallowDisabled: Bool {
		if self.isSymlink() {
			return true
		}
		if let folder = self.folder {
			return !folder.isSelective() || !folder.isIdleOrSyncing
		}
		return true
	}

	// Returns error message on fail
	fileprivate func setSelectedFromToggle(s: Bool) async -> String? {
		do {
			if !self.isSelectionToggleShallowDisabled {
				// Check some additional things
				let isExplicitlySelected = self.isExplicitlySelected()
				if self.isSelected() && !isExplicitlySelected {
					// File is implicitly selected, do not allow changes
					return String(
						localized:
							"The synchronization setting for this item cannot be changed, because it is inside a subdirectory that is configured to be kept on this device."
					)
				}

				if !s {
					let isLocalOnlyCopy = try await self.isLocalOnlyCopy()
					if isLocalOnlyCopy {
						// We are the only remaining copy, can't deselect
						return String(
							localized:
								"The synchronization setting for this item cannot be changed, as the local copy is the only copy currently available."
						)
					}
				}

				// We can change the selection status
				try self.setExplicitlySelected(s)
			}
			else {
				if self.isSymlink() {
					return String(
						localized: "The synchronization setting for symlinks cannot be changed."
					)
				}
				else if let f = self.folder, !f.isSelective() {
					return String(
						localized: "The folder is not configured for selective synchronization."
					)
				}
				else {
					return String(
						localized: "Wait until the folder is done synchronizing and try again.")
				}

			}
		}
		catch {
			return String(
				localized:
					"The synchronization setting for this item could not be changed: \(error.localizedDescription)."
			)
		}

		return nil
	}
}

private struct ItemSelectSwipeView<Content: View>: View {
	let file: SushitrainEntry
	@ViewBuilder var content: Content

	@State private var errorMessage: String? = nil

	var body: some View {
		if self.file.isSelectionToggleAvailable {
			self.content
				.alert(
					isPresented: Binding(
						get: {
							errorMessage != nil
						},
						set: { s in
							errorMessage = s ? errorMessage : nil
						})
				) {
					Alert(
						title: Text("Could not change synchronization setting"),
						message: Text(errorMessage ?? ""), dismissButton: .default(Text("OK")))
				}
				.swipeActions(allowsFullSwipe: false) {
					if file.isExplicitlySelected() || file.isSelected() {
						// Unselect button
						Button {
							Task {
								self.errorMessage = await self.file
									.setSelectedFromToggle(s: false)
							}
						} label: {
							Label(
								"Do not synchronize with this device",
								systemImage: "pin.slash")
						}
						.tint(.red)
					}
					else {
						// Select button
						Button {
							Task {
								self.errorMessage = await self.file
									.setSelectedFromToggle(s: true)
							}
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

struct ItemSelectToggleView: View {
	let appState: AppState
	let file: SushitrainEntry

	var body: some View {
		if self.file.isSelectionToggleAvailable {
			Toggle(
				"Synchronize with this device", systemImage: "pin",
				isOn: Binding(
					get: {
						file.isExplicitlySelected() || file.isSelected()
					},
					set: { s in
						Task {
							if let em = await self.file.setSelectedFromToggle(s: s) {
								// We can't use our own alert since by the time we get here, the context menu is gone
								appState.alert(message: em)
							}
						}
					})
			)
			.disabled(self.file.isSelectionToggleShallowDisabled)
		}
	}
}
