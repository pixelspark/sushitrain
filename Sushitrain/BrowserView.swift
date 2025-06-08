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
	case web = "web"
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
	@State private var webViewAvailable = false

	@State private var viewStyle: BrowserViewStyle? = nil

	#if os(macOS)
		@State private var showIgnores = false
		@State private var showStatusPopover = false
	#endif

	private func currentViewStyle() -> Binding<BrowserViewStyle> {
		return Binding(
			get: { self.viewStyle ?? appState.defaultBrowserViewStyle },
			set: {
				self.viewStyle = $0
				appState.defaultBrowserViewStyle = $0
			})
	}

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
			folder: folder,
			prefix: prefix,
			// Note: this binding does *not* set appState.defaultBrowserViewStyle, because this one is primarily set programmatically
			viewStyle: Binding(get: { self.viewStyle }, set: { self.viewStyle = $0 }),
			searchText: $searchText,
			showSettings: $showSettings
		)

		#if os(iOS)
			.navigationTitle(folderName)
			.navigationBarTitleDisplayMode(.inline)
		#endif

		#if os(macOS)
			.searchable(
				text: $searchText, placement: SearchFieldPlacement.toolbar,
				prompt: "Search files in this folder...")
		#endif

		#if os(iOS)
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

		#if os(macOS)
			.navigationTitle("")
		#endif

		.toolbar {
			#if os(macOS)
				// On iOS, this is done with .navigationTitle() and the sync status is shown in the view
				ToolbarItem(placement: .navigation) {
					let fsd = FolderStatusDescription(folder)
					HStack(alignment: .center) {
						Button(fsd.text, systemImage: fsd.systemImage) {
							showStatusPopover = true
						}
						.animation(.spring(), value: fsd.systemImage)
						.labelStyle(.iconOnly)
						.foregroundStyle(fsd.color)
						.accessibilityLabel(fsd.text)
						.popover(isPresented: $showStatusPopover, arrowEdge: .bottom) {
							FolderStatusView(folder: folder)
								.padding()
								.frame(minWidth: 120)
						}
						Text(folderName).font(.headline)
					}
				}

				ToolbarItemGroup(placement: .status) {
					Picker("View as", selection: self.currentViewStyle()) {
						Image(systemName: "list.bullet").tag(BrowserViewStyle.list)
							.accessibilityLabel(Text("List"))
						Image(systemName: "checklist.unchecked").tag(BrowserViewStyle.thumbnailList)
							.accessibilityLabel(Text("List with previews"))
						Image(systemName: "square.grid.2x2").tag(BrowserViewStyle.grid)
							.accessibilityLabel(Text("Grid"))
						
						if webViewAvailable {
							Image(systemName: "doc.text.image")
								.tag(BrowserViewStyle.web)
								.accessibilityLabel(Text("Web page"))
						}
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
						if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
							if entry.isDirectory() && !entry.isLocallyPresent() && entry.canShowInFinder {
								Button(
									openInFilesAppLabel, systemImage: "arrow.up.forward.app",
									action: {
										try? entry.showInFinder()
									})
							}
						}
					}
				}
			#endif

			ToolbarItem {
				self.folderMenu()
			}
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
			self.update()
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
	
	private func update() {
		self.folderExists = folder.exists()
		self.updateLocalURL()
		self.folderIsSelective = folder.isSelective()
		
		// Check for presence of index.html to enable web view
		if let entry = try? folder.getFileInformation(self.prefix + "index.html"), !entry.isDirectory() && !entry.isDeleted() {
			self.webViewAvailable = true
		}
		else {
			self.webViewAvailable = false
		}
	}

	@ViewBuilder private func folderMenu() -> some View {
		Menu {
			#if os(iOS)
			BrowserViewStylePickerView(webViewAvailable: self.webViewAvailable, viewStyle: self.currentViewStyle())
					.pickerStyle(.inline)

				Toggle(
					"Search here...",
					systemImage: "magnifyingglass",
					isOn: $showSearch
				).disabled(!folderExists)
			#endif

			if folderExists && !self.prefix.isEmpty {
				if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
					NavigationLink(destination: FileView(file: entry)) {
						Label("Subdirectory properties...", systemImage: "folder.badge.gearshape")
					}

					Divider()
				}
			}

			if folderExists {
				#if os(iOS)
					// Open in Finder/Files (and possibly materialize empty folder)
					// On macOS this has its own toolbar button
					if let localNativeURL = self.localNativeURL {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								openURLInSystemFilesApp(url: localNativeURL)
							})
					}
					else {
						if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash),
							entry.isDirectory() && !entry.isLocallyPresent()
						{
							Button(
								openInFilesAppLabel, systemImage: "arrow.up.forward.app",
								action: {
									try? entry.showInFinder()
								})
						}
					}
				#endif

				Button("Folder statistics...", systemImage: "scalemass") {
					showFolderStatistics = true
				}

				if folderIsSelective && folder.isRegularFolder {
					NavigationLink(destination: SelectiveFolderView(folder: folder)) {
						Label("Files kept on this device...", systemImage: "pin")
					}
				}

				Divider()
			}

			Button("Folder settings...", systemImage: "folder.badge.gearshape") {
				showSettings = true
			}

			#if os(macOS)
				if !folder.isSelective() && folder.isRegularFolder {
					// On iOS this is in the folder settings screen
					Button("Files to ignore...", systemImage: "rectangle.dashed") {
						showIgnores = true
					}
				}
			#endif
		} label: {
			#if os(macOS)
				Label("Folder settings", systemImage: "folder.badge.gearshape")
			#else
				Label("Actions", systemImage: "ellipsis.circle")
			#endif
		}.disabled(!folderExists)
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
	@Binding var viewStyle: BrowserViewStyle?

	@Binding var searchText: String
	@Binding var showSettings: Bool

	@State private var subdirectories: [SushitrainEntry] = []
	@State private var files: [SushitrainEntry] = []
	@State private var hasExtraneousFiles = false
	@State private var isLoading = true
	@State private var showSpinner = false

	@Environment(\.isSearching) private var isSearching

	var body: some View {
		Group {
			if self.folder.exists() {
				if !isSearching {
					switch self.viewStyle ?? appState.defaultBrowserViewStyle {
					case .grid:
						self.gridView()

					case .list, .thumbnailList:
						self.listView()
						
					case .web:
						BrowserWebView(folderID: folder.folderID, path: self.prefix)
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
			else {
				EmptyView()
			}
		}
		.overlay {
			self.overlayView()
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

	private var isEmpty: Bool {
		return subdirectories.isEmpty && files.isEmpty
	}

	@ViewBuilder private func gridView() -> some View {
		VStack {
			ScrollView {
				HStack {
					#if os(iOS)
						FolderStatusView(folder: folder).padding(.all, 10)
					#endif

					Spacer()

					Slider(
						value: Binding(
							get: {
								return Double(appState.browserGridColumns)
							},
							set: { nv in
								appState.browserGridColumns = Int(nv)
							}
						),
						in: 1.0...10.0, step: 1.0
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
			}
		}
	}

	@ViewBuilder private func listView() -> some View {
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
					subdirectories: subdirectories,
					viewStyle: viewStyle ?? appState.defaultBrowserViewStyle
				)
			}
		#else
			BrowserListView(
				folder: folder,
				prefix: prefix,
				hasExtraneousFiles: hasExtraneousFiles,
				files: files,
				subdirectories: subdirectories,
				viewStyle: viewStyle ?? appState.defaultBrowserViewStyle
			)
		#endif
	}

	@ViewBuilder private func overlayView() -> some View {
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

		self.autoSelectViewStyle()

		await self.updateExtraneousFiles()

		self.isLoading = false
		loadingSpinnerTask.cancel()
	}

	private func autoSelectViewStyle() {
		// These files are ignored when deciding whether to switch to a grid view or not
		let extensionsIgnored = Set([".aae", ".ds_store", ".db", ".gitignore", ".stignore", ".ini"])

		if self.viewStyle == nil {
			if appState.automaticallySwitchViewStyle {
				// Do we have an index.html? If so switch to web view
				if self.files.contains(where: { $0.fileName() == "index.html" }) {
					self.viewStyle = .web
				}
				else {
					// Check if we only have thumbnailable files; if so, switch to thumbnail mode
					let dotFilesHidden = appState.dotFilesHidden
					let filtered = self.files.filter({
						!extensionsIgnored.contains($0.extension().lowercased()) && (!dotFilesHidden || !$0.fileName().starts(with: "."))
					})
					
					if !filtered.isEmpty && filtered.allSatisfy({ $0.canThumbnail && ($0.isImage || $0.isVideo) }) {
						self.viewStyle = .grid
					}
					else {
						self.viewStyle = .thumbnailList
					}
				}
			}
			else {
				self.viewStyle = appState.defaultBrowserViewStyle
			}
		}
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
	let webViewAvailable: Bool
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
			
			if webViewAvailable {
				HStack {
					Image(systemName: "doc.text.image")
					Text("Web page")
				}.tag(BrowserViewStyle.web)
			}
		}
		.pickerStyle(.inline)
	}
}
