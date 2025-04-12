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

struct BrowserView: View {
	@EnvironmentObject var appState: AppState
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
		BrowserItemsView(
			folder: folder, prefix: prefix, searchText: $searchText,
			showSettings: $showSettings
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
					SearchView(prefix: self.prefix, folder: self.folder)
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
										try? entry.showInFinder()
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
									folder: folder)
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
							BrowserViewStylePickerView(
								viewStyle: appState.$browserViewStyle
							)
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
										destination: FileView(file: entry)
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
														.showInFinder()
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
										folder: folder)
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
				FolderStatisticsView(folder: folder)
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
				FolderView(folder: self.folder)
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
					IgnoresView(folder: self.folder)
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
					NavigationLink(destination: FileView(file: entry)) {
						Label("Subdirectory properties...", systemImage: entry.systemImage)
					}

					ItemSelectToggleView(file: entry)
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

private struct BrowserItemsView: View {
	@EnvironmentObject var appState: AppState
	var folder: SushitrainFolder
	var prefix: String
	@Binding var searchText: String
	@Binding var showSettings: Bool

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
					switch self.appState.browserViewStyle {
					case .grid:
						VStack {
							ScrollView {
								HStack {
									FolderStatusView(
										folder: folder
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
										ExtraFilesView(folder: self.folder)
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
									prefix: self.prefix,
									files: files,
									subdirectories: subdirectories, folder: folder
								)
								.padding(.horizontal, 15)
							}
						}
					case .list, .thumbnailList:
						#if os(macOS)
							VStack {
								// Show extraneous files banner when necessary
								if hasExtraneousFiles {
									HStack(alignment: .center) {
										Label(
											"This folder has new files",
											systemImage:
												"exclamationmark.triangle.fill"
										).foregroundColor(.orange)

										Spacer()

										NavigationLink(destination: {
											ExtraFilesView(folder: self.folder)
										}) {
											Text("Review...")
										}
									}
									.padding(
										EdgeInsets(
											top: 10.0, leading: 10.0,
											bottom: 5.0, trailing: 10.0))
								}

								BrowserTableView(
									folder: folder,
									files: files,
									subdirectories: subdirectories)
							}
						#else
							BrowserListView(
								folder: folder, prefix: prefix,
								hasExtraneousFiles: hasExtraneousFiles, files: files,
								subdirectories: subdirectories)
						#endif
					}
				}
				else {
					// Search
					SearchResultsView(
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
			await self.rescan()
		}
		.contextMenu {
			Button("Refresh") {
				Task {
					await self.reload()
				}
			}
			Button("Rescan subdirectory") {
				Task {
					await self.rescan()
				}
			}
		}
		.task(id: self.folder.folderStateForUpdating) {
			await self.reload()
		}
		.onChange(of: self.folder.folderStateForUpdating) {
			Task {
				await self.reload()
			}
		}
		.onChange(of: appState.eventCounter) {
			Task {
				await self.updateExtraneousFiles()
			}
		}
	}

	private func rescan() async {
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
				return try folder.listEntries(
					prefix: self.prefix, directories: false, hideDotFiles: dotFilesHidden)
			}
			catch let error {
				Log.warn("Error listing: \(error.localizedDescription)")
			}
			return []
		}.value

		await self.updateExtraneousFiles()

		self.isLoading = false
		loadingSpinnerTask.cancel()
	}

	private func updateExtraneousFiles() async {
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

struct ItemSelectToggleView: View {
	@EnvironmentObject var appState: AppState
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

private struct BrowserViewStylePickerView: View {
	@Binding var viewStyle: BrowserViewStyle

	var body: some View {
		Picker("View as", selection: $viewStyle) {
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
	}
}
