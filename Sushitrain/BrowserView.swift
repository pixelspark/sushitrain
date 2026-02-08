// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
import UniformTypeIdentifiers
@preconcurrency import SushitrainCore

enum BrowserViewStyle: String {
	case grid = "grid"
	case list = "list"
	case thumbnailList = "thumbnailList"
	case web = "web"
}

enum BrowserViewFilterAvailability: String, Codable {
	case all = "all"
	case localOnly = "localOnly"
}

private struct FolderPopoverView: View {
	let folder: SushitrainFolder

	var body: some View {
		NavigationStack {
			FolderStatisticsView(folder: folder).frame(minWidth: 320, minHeight: 420, maxHeight: 400)
		}
	}
}

struct BrowserView: View {
	private enum ConfirmableAction {
		case unlinkFolder
		case removeFolder

		var message: String {
			switch self {
			case .removeFolder:
				return String(
					localized:
						"Are you sure you want to remove this folder? Please consider carefully. All files in this folder will be removed from this device. Files that have not been synchronized to other devices yet cannot be recovered."
				)
			case .unlinkFolder:
				return String(
					localized:
						"Are you sure you want to unlink this folder? The folder will not be synchronized any longer. Files currently on this device will not be deleted."
				)
			}
		}

		var buttonTitle: String {
			switch self {
			case .removeFolder: return String(localized: "Remove the folder and all files")
			case .unlinkFolder: return String(localized: "Unlink the folder")
			}
		}
	}

	private enum ShowAlert: Identifiable {
		case error(String)

		var id: String {
			switch self {
			case .error(let e): return e
			}
		}
	}

	@Environment(AppState.self) private var appState
	@Environment(\.showToast) private var showToast

	var folder: SushitrainFolder
	var prefix: String
	@ObservedObject var userSettings: AppUserSettings

	@State private var showSettings = false
	@State private var searchText = ""
	@State private var canShowInFinder = false
	@State private var localNativeURL: URL? = nil
	@State private var folderExists = false
	@State private var folderIsSelective = false
	@State private var showSearch = false
	@State private var showAddFilePicker = false
	@State private var webViewAvailable = false
	@State private var viewStyle: BrowserViewStyle? = nil
	@State private var filterAvailability: BrowserViewFilterAvailability? = nil
	@State private var showAlert: ShowAlert? = nil
	@State private var showConfirmable: ConfirmableAction? = nil
	@State private var isWorking = false
	@State private var isBookmarked = false
	@State private var showNewBookmarkInfo = false

	#if os(macOS)
		@State private var showIgnores = false
		@State private var showStatusPopover = false
		@State private var isSearching = false
	#endif

	#if os(iOS)
		@State private var showFolderStatistics = false
	#endif

	private func currentViewStyle() -> Binding<BrowserViewStyle> {
		return Binding(
			get: { self.viewStyle ?? appState.userSettings.defaultBrowserViewStyle },
			set: {
				self.viewStyle = $0
				if $0 != .web {
					appState.userSettings.defaultBrowserViewStyle = $0
				}
			})
	}

	private var currentFilterAvailability: BrowserViewFilterAvailability {
		return self.filterAvailability ?? appState.userSettings.defaultBrowserViewFilterAvailability
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
			viewStyle: $viewStyle,
			filterAvailability: currentFilterAvailability,
			searchText: $searchText,
			showSettings: $showSettings
		)

		#if os(iOS)
			.navigationTitle(folderName)
			.navigationBarTitleDisplayMode(.inline)
		#endif

		#if os(macOS)
			.searchable(
				text: $searchText,
				isPresented: $isSearching,
				placement: SearchFieldPlacement.toolbar,
				prompt: "Search files in this folder...")
		#endif

		#if os(iOS)
			.sheet(isPresented: $showSearch) {
				NavigationStack {
					SearchView(prefix: self.prefix, folder: self.folder)
					.navigationTitle("Search in this folder")
					.navigationBarTitleDisplayMode(.inline)
					.toolbar {
						SheetButton(role: .cancel) {
							showSearch = false
						}
					}
				}
			}
		#endif

		#if os(macOS)
			.navigationTitle("")
		#endif

		.toolbar {
			self.toolbarContent()
		}
		#if os(iOS)
			.sheet(isPresented: $showFolderStatistics) {
				NavigationStack {
					FolderStatisticsView(folder: folder)
					.toolbar {
						SheetButton(role: .done) {
							showFolderStatistics = false
						}
					}
				}
			}
		#endif
		.sheet(isPresented: $showSettings) {
			NavigationStack {
				FolderView(folder: self.folder)
					.toolbar {
						SheetButton(role: .save) {
							showSettings = false
						}
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
						SheetButton(role: .done) {
							showIgnores = false
						}
					}
				}
			}
		#endif
		
		#if os(macOS)
			.alert("This location has been added to your bookmarks. Bookmarked locations can be accessed quickly from the start page.", isPresented: $showNewBookmarkInfo) {
				Button("OK") {}
			}
		#else
			.alert("This location has been added to your bookmarks. Bookmarked locations can be accessed quickly from the start page, or by long-tapping the app icon om the home screen.", isPresented: $showNewBookmarkInfo) {
				Button("OK") {}
			}
		#endif
		
		.task {
			self.update()
		}

		.onChange(of: showSettings) { _, nv in
			// Needed to update the screen after removing a folder
			if !nv {
				Log.info("Update because of showSettings = \(nv)")
				self.folderExists = folder.exists()
				self.update()
			}
		}

		.fileImporter(
			isPresented: $showAddFilePicker,
			allowedContentTypes: [UTType.data],
			allowsMultipleSelection: true,
			onCompletion: self.addFilesFromImporter
		)

		#if os(macOS)
			.contextMenu {
				if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
					NavigationLink(destination: FileView(file: entry, showPath: false, siblings: nil)) {
						Label("Subdirectory properties...", systemImage: entry.systemImage)
					}

					ItemSelectToggleView(file: entry)

					NavigationLink(destination: SelectiveFolderView(folder: folder, prefix: self.prefix)) {
						Label("Files kept on this device", systemImage: "pin")
					}
				}
			}
			.onDrop(
				of: ["public.file-url"], isTargeted: nil,
				perform: { providers, _ in
					Task {
						self.showAlert = nil
						do {
							try await self.onDrop(providers)
						}
						catch {
							Log.warn("Failed to drop: \(error.localizedDescription)")
							self.showAlert = .error(error.localizedDescription)
						}
					}
					return true
				})
		#endif
		.alert(item: $showAlert) { alert in
			switch alert {
			case .error(let err):
				Alert(
					title: Text("An error occurred"),
					message: Text(err),
					dismissButton: .default(Text("OK"))
				)
			}
		}
		.confirmationDialog(
			showConfirmable?.message ?? "", isPresented: Binding.isNotNil($showConfirmable), titleVisibility: .visible
		) {
			if let sc = showConfirmable {
				Button(sc.buttonTitle, role: .destructive, action: self.confirmedAction)
			}
		}
		.userActivity(SushitrainApp.viewRouteActivityID) { ua in
			let routeURL = self.route.url
			ua.title = self.folderName
			ua.isEligibleForHandoff = true
			ua.targetContentIdentifier = routeURL.absoluteString
			ua.userInfo = [
				"version": 1,
				"url": routeURL.absoluteString,
			]
			ua.needsSave = true
		}
	}

	@ToolbarContentBuilder private func toolbarContent() -> some ToolbarContent {
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
						FolderPopoverView(folder: folder)
					}
					Text(folderName).font(.headline).padding(.trailing, 20)
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
				.disabled(isSearching)

				self.filterMenu()
			}
		#endif

		ToolbarItemGroup(placement: .primaryAction) {
			#if os(macOS)
				Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app") {
					self.showInFinder()
				}.disabled(!canShowInFinder || isSearching)
			#endif

			self.folderMenu()
		}
	}

	@ViewBuilder private func filterMenu() -> some View {
		Menu {
			Picker(
				"Show",
				selection: Binding(
					get: { self.currentFilterAvailability },
					set: {
						self.filterAvailability = $0
						userSettings.defaultBrowserViewFilterAvailability = $0
					})
			) {
				Label("All files and folders", systemImage: "folder").tag(BrowserViewFilterAvailability.all)
				Label("Only files on this device", systemImage: "folder.fill").tag(BrowserViewFilterAvailability.localOnly)
			}.pickerStyle(.inline)

			Divider()

			Toggle("Hide dotfiles", isOn: userSettings.$dotFilesHidden)

		} label: {
			Label("Filter", systemImage: "line.3.horizontal.decrease")
				.tint(self.currentFilterAvailability == .all ? nil : Color.accentColor)
		}
		.disabled(self.currentViewStyle().wrappedValue == .web)
	}

	private func addFilesFromImporter(result: Result<[URL], any Error>) {
		var numFilesAdded = 0
		switch result {
		case .success(let fu):
			for url in fu {
				if !url.startAccessingSecurityScopedResource() {
					Log.warn("failed to access security scoped URL from file importer: \(url)")
				}
			}
			do {
				try self.dropFiles(fu)
			}
			catch {
				Log.warn("failed to drop file: \(error)")
				self.showAlert = .error(error.localizedDescription)
			}
			numFilesAdded += 1
			for url in fu {
				url.stopAccessingSecurityScopedResource()
			}

		case .failure(_):
			break
		}

		self.showToast(Toast(title: "\(numFilesAdded) files added", image: "document.badge.plus.fill"))
	}

	private func showInFinder() {
		if !canShowInFinder {
			return
		}
		// Open in Finder/Files (and possibly materialize empty folder)
		if let localNativeURL = self.localNativeURL {
			openURLInSystemFilesApp(url: localNativeURL)
		}
		else {
			if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
				try? entry.showInFinder()
			}
		}
	}

	private func update() {
		self.folderExists = folder.exists()
		self.updateLocalURL()
		self.folderIsSelective = folderExists && folder.isSelective()

		// Determine whether this view is bookmarked
		let route = self.route
		self.isBookmarked = userSettings.bookmarkedRoutes.contains(where: {
			Route(url: $0) == route
		})

		// Check for presence of index.html to enable web view
		if folderExists, let entry = try? folder.getFileInformation(self.prefix + "index.html"),
			!entry.isDirectory() && !entry.isDeleted()
		{
			self.webViewAvailable = true
		}
		else {
			self.webViewAvailable = false
		}
	}

	@ViewBuilder private func addMenu() -> some View {
		Menu {
			self.addMenuContents()
		} label: {
			Label("Add...", systemImage: "plus")
		}.disabled(
			!folderExists || !self.folder.isRegularFolder || self.folder.isReceiveOnlyFolder)
	}

	@ViewBuilder private func addMenuContents() -> some View {
		Button("Add files...", systemImage: "plus") {
			showAddFilePicker = true
		}.disabled(
			!folderExists || !self.folder.isRegularFolder || self.folder.isReceiveOnlyFolder)

		#if os(iOS)
			Button("Paste files...", systemImage: "document.on.clipboard") {
				Task {
					await self.dropItemProviders(UIPasteboard.general.itemProviders)
				}
			}.disabled(UIPasteboard.general.itemProviders.isEmpty)
		#endif
	}

	@ViewBuilder private func folderOperationsMenu() -> some View {
		Menu {
			#if os(iOS)
				Button("Folder statistics...", systemImage: "chart.pie") {
					showFolderStatistics = true
				}
			#endif

			Button("Re-scan folder", systemImage: "sparkle.magnifyingglass", action: rescanFolder)
				#if os(macOS)
					.buttonStyle(.link)
				#endif

			Divider()

			if folder.isSelective() {
				Button(
					"Remove unsynchronized empty subdirectories",
					systemImage: "eraser", role: .destructive
				) {
					self.removeUnsynchronizedEmpty()
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.foregroundColor(.red)
				.disabled(isWorking)
			}

			Divider()

			Button("Unlink folder", systemImage: "folder.badge.minus", role: .destructive) {
				showConfirmable = .unlinkFolder
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif
			.foregroundColor(.red)

			// Only allow removing a full folder when we are sure it is in the area managed by us
			if folder.isRegularFolder && folder.isExternal == false {
				Button("Remove folder", systemImage: "trash", role: .destructive) {
					showConfirmable = .removeFolder
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.foregroundColor(.red)
			}
		} label: {
			Label("Folder actions", systemImage: "ellipsis.circle")
		}.labelStyle(.titleAndIcon)
	}

	@ViewBuilder private func folderMenu() -> some View {
		let isReceiveEncrypted = folder.isReceiveEncryptedFolder
		Menu {
			if folderExists {
				#if os(iOS)
					if !isReceiveEncrypted {
						BrowserViewStylePickerView(
							webViewAvailable: self.webViewAvailable,
							viewStyle: self.currentViewStyle()
						).pickerStyle(.inline)

						self.filterMenu()

						self.addMenu()
					}

					Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app") {
						self.showInFinder()
					}.disabled(!canShowInFinder)
				#else
					self.addMenuContents()
				#endif

				#if os(iOS)
					if !isReceiveEncrypted {
						Toggle(
							"Search here...",
							systemImage: "magnifyingglass",
							isOn: $showSearch
						).disabled(!folderExists)
					}
				#endif

				if folderExists && !self.prefix.isEmpty && !isReceiveEncrypted {
					if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
						NavigationLink(destination: FileView(file: entry, showPath: false, siblings: nil)) {
							Label("Subdirectory properties...", systemImage: "folder.badge.gearshape")
						}
					}
				}

				if !isReceiveEncrypted {
					Toggle(isOn: Binding(get: { self.isBookmarked }, set: { self.setBookmarked($0) })) {
						Label("Bookmark", systemImage: self.isBookmarked ? "bookmark.fill" : "bookmark")
					}
				}

				Divider()

				if folderIsSelective && folder.isRegularFolder {
					NavigationLink(destination: SelectiveFolderView(folder: folder, prefix: "")) {
						Label("Files kept on this device...", systemImage: "pin")
					}
				}
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

			self.folderOperationsMenu()
		} label: {
			#if os(macOS)
				Label("Folder settings", systemImage: "folder.badge.gearshape")
			#else
				Label("Actions", systemImage: "ellipsis.circle")
			#endif
		}.disabled(!folderExists)
	}

	private var route: Route {
		return Route.folder(folderID: self.folder.folderID, prefix: self.prefix)
	}

	private func setBookmarked(_ fav: Bool) {
		let newRoute = self.route

		userSettings.bookmarkedRoutes.removeAll(where: { bookmarkedURL in
			guard let bookmarkedRoute = Route(url: bookmarkedURL) else {
				return true
			}

			return bookmarkedRoute == newRoute
		})

		if fav {
			userSettings.bookmarkedRoutes.append(newRoute.url)
		}
		Log.info("New bookmarks: \(userSettings.bookmarkedRoutes)")
		self.update()
		
		if fav {
			self.showNewBookmarkInfo = true
		}
	}

	private func confirmedAction() {
		do {
			switch self.showConfirmable {
			case .none:
				return
			case .unlinkFolder:
				try folder.unlinkFolderAndRemoveSettings()
				self.update()
			case .removeFolder:
				try folder.removeFolderAndSettings()
				self.update()
			}
		}
		catch let error {
			self.showAlert = .error(error.localizedDescription)
		}
		self.showConfirmable = .none
	}

	private func rescanFolder() {
		showToast(Toast(title: "Folder re-scan started", image: "sparkle.magnifyingglass"))

		do {
			try folder.rescan()
		}
		catch let error {
			self.showAlert = .error(error.localizedDescription)
		}
	}

	private func removeUnsynchronizedEmpty() {
		Task {
			do {
				self.isWorking = true
				try await Task.detached {
					try folder.removeSuperfluousSubdirectories()
					try folder.removeSuperfluousSelectionEntries()
				}.value
				self.isWorking = false
				showToast(Toast(title: "Unsynchronized empty subdirectories removed", image: "eraser"))
			}
			catch {
				self.showAlert = .error(error.localizedDescription)
			}
		}
	}

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

	private func dropItemProviders(_ items: [NSItemProvider]) async {
		var urls: [URL] = []

		for item in items {
			do {
				let tempURL: URL? = try await withCheckedThrowingContinuation { cont in
					// TODO: add file coordination
					let _ = item.loadFileRepresentation(for: UTType.data, openInPlace: true) { tempURL, wasOpenedInPlace, err in
						if let err = err {
							cont.resume(throwing: err)
							return
						}
						else {
							cont.resume(returning: tempURL)
						}
					}
				}

				if let tempURL = tempURL {
					urls.append(tempURL)
				}
			}
			catch {
				Log.warn("failed to load file representation for item: \(error)")
			}
		}

		// Process the files
		do {
			try self.dropFiles(urls)
		}
		catch {
			Log.warn("failed to drop files: \(error)")
			self.showAlert = .error(error.localizedDescription)
		}
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
			var retainedError: Error? = nil
			var numFilesAdded = 0
			for url in urls {
				do {
					// Copy source to folder
					let targetURL = localNativeURL.appendingPathComponent(
						url.lastPathComponent, isDirectory: false)
					try FileManager.default.copyItem(at: url, to: targetURL)

					// Select the dropped file
					if folder.isSelective() {
						let localURL = (self.prefix.withoutEndingSlash + "/" + url.lastPathComponent).withoutStartingSlash
						pathsToSelect.append(localURL)
						numFilesAdded += 1
					}
				}
				catch {
					Log.warn("failed to copy a dropped file: \(error)")
					retainedError = error
				}
			}

			if folder.isSelective() {
				try self.folder.setLocalPathsExplicitlySelected(SushitrainListOfStrings.from(pathsToSelect))
			}

			try self.folder.rescanSubdirectory(self.prefix)

			DispatchQueue.main.async {
				showToast(Toast(title: "\(numFilesAdded) files added", image: "plus"))
			}

			if let re = retainedError {
				throw re
			}
		}
	}

	private func updateLocalURL() {
		if !self.folder.exists() {
			self.localNativeURL = nil
			self.canShowInFinder = false
			return
		}

		// Check if we can get a local native URL
		var error: NSError? = nil
		let localNativePath = self.folder.localNativePath(&error)

		if error == nil {
			let localNativeURL = URL(fileURLWithPath: localNativePath).appendingPathComponent(
				self.prefix)

			if FileManager.default.fileExists(atPath: localNativeURL.path) {
				self.localNativeURL = localNativeURL
				self.canShowInFinder = true
				return
			}
		}

		// Check if this entry supports lazy creation
		if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
			if entry.isDirectory() && !entry.isLocallyPresent() && entry.canShowInFinder {
				self.canShowInFinder = true
			}
		}
	}
}

private struct BrowserItemsView: View {
	@Environment(AppState.self) private var appState
	let folder: SushitrainFolder
	let prefix: String
	@Binding var viewStyle: BrowserViewStyle?
	let filterAvailability: BrowserViewFilterAvailability

	@Binding var searchText: String
	@Binding var showSettings: Bool

	@State private var subdirectories: [SushitrainEntry] = []
	@State private var files: [SushitrainEntry] = []
	@State private var hasExtraneousFiles = false
	@State private var isLoading = true
	@State private var showSpinner = false
	@State private var folderExists = false
	@State private var folderIsPaused = false
	@State private var showStatistics = false

	@Environment(\.isSearching) private var isSearching

	var body: some View {
		ZStack {
			if folderExists {
				if !isSearching {
					switch self.viewStyle ?? appState.userSettings.defaultBrowserViewStyle {
					case .grid:
						self.gridView()

					case .list, .thumbnailList:
						self.listView()

					case .web:
						#if os(macOS)
							if #available(macOS 26, *) {
								BrowserWebView(folderID: folder.folderID, path: self.prefix)
									.backgroundExtensionEffect()
							}
							else {
								BrowserWebView(folderID: folder.folderID, path: self.prefix)
							}
						#else
							BrowserWebView(folderID: folder.folderID, path: self.prefix)
						#endif
					}
				}
				else {
					// Search
					SearchResultsView(
						userSettings: appState.userSettings,
						searchText: $searchText,
						folderID: .constant(self.folder.folderID),
						prefix: Binding(get: { prefix }, set: { _ in () })
					)
				}
			}
			else {
				Rectangle()
					.fill(Color.clear)
					.frame(width: .infinity, height: .infinity)
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
			}.disabled(!folderExists)

			Button("Rescan subdirectory") {
				Task {
					await self.rescan()
				}
			}.disabled(!folderExists)
		}
		.task(id: self.folder.folderStateForUpdating) {
			await self.reload()
		}
		.onChange(of: appState.userSettings.dotFilesHidden) {
			Task {
				await self.reload()
			}
		}
		.onChange(of: self.folder.folderStateForUpdating) {
			Task {
				await self.reload()
			}
		}
		.onChange(of: filterAvailability) {
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
		GridScrollView(
			userSettings: appState.userSettings,
			header: {
				VStack {
					HStack {
						#if os(iOS)
							Button(action: {
								showStatistics = true
							}) {
								FolderStatusView(folder: folder).padding(.horizontal, 10).padding(.vertical, 15)
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
						#endif

						Spacer()

						#if os(macOS)
							// You can pinch on macOS using the touch pad, but it is handy to have a slider as well
							Slider(
								value: Binding(
									get: {
										return Double(appState.userSettings.browserGridColumns)
									},
									set: { nv in
										withAnimation(.spring(response: 0.8)) {
											appState.userSettings.browserGridColumns = Int(nv)
										}
									}
								),
								in: 1.0...10.0, step: 1.0
							)
							.frame(minWidth: 50, maxWidth: 150)
							.padding(.horizontal, 20)
							.padding(.vertical, 15)
						#endif
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
				}
			},
			content: { columns in
				GridFilesView(
					userSettings: appState.userSettings,
					prefix: self.prefix,
					files: files,
					subdirectories: subdirectories,
					folder: folder,
					columns: columns
				)
				#if os(macOS)
					.padding(.leading, 5.0)
				#endif
			})
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
					viewStyle: viewStyle ?? appState.userSettings.defaultBrowserViewStyle
				)
			}
		#else
			BrowserListView(
				folder: folder,
				prefix: prefix,
				hasExtraneousFiles: hasExtraneousFiles,
				files: files,
				subdirectories: subdirectories,
				viewStyle: viewStyle ?? appState.userSettings.defaultBrowserViewStyle
			)
		#endif
	}

	@ViewBuilder private func overlayView() -> some View {
		if isLoading {
			if isEmpty && showSpinner {
				ProgressView()
			}
			// Load the rest while already showing a part of the results
		}
		else if !folderExists {
			ContentUnavailableView(
				"Folder removed", systemImage: "trash",
				description: Text("This folder was removed."))
		}
		else if isEmpty {
			if self.prefix == "" {
				if folderIsPaused {
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
					if folder.isReceiveEncryptedFolder {
						ContentUnavailableView(
							"The files in this folder cannot be shown",
							systemImage: "lock.circle.dotted",
							description: Text(
								"This folder is receiving encrypted files. While these files are stored on this device, they cannot be accessed from this device."
							)
						)
					}
					else if filterAvailability != .all {
						ContentUnavailableView(
							"There are no files in this folder to show",
							systemImage: "line.3.horizontal.decrease",
							description: Text(
								"Only files that are on this device are displayed."
							)
						)
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
		let dotFilesHidden = self.appState.userSettings.dotFilesHidden

		let folderExists = folder.exists()

		var newSubdirectories: [SushitrainEntry] = await Task.detached {
			dispatchPrecondition(condition: .notOnQueue(.main))
			if !folder.exists() {
				return []
			}
			do {
				var dirNames = try folder.list(prefix, directories: true, recurse: false).asArray()
					.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending })
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

		var newFiles: [SushitrainEntry] = await Task.detached {
			dispatchPrecondition(condition: .notOnQueue(.main))
			if !folder.exists() {
				return []
			}
			do {
				var entries = try folder.listEntries(prefix: self.prefix, directories: false, hideDotFiles: dotFilesHidden)
				entries.sort(by: { $0.fileName().compare($1.fileName(), options: .numeric) == .orderedAscending })
				return entries
			}
			catch let error {
				Log.warn("Error listing: \(error.localizedDescription)")
			}
			return []
		}.value

		// Apply filters
		switch self.filterAvailability {
		case .all:
			break
		case .localOnly:
			newFiles = newFiles.filter { $0.isLocallyPresent() }
			newSubdirectories = newSubdirectories.filter { $0.isLocallyPresent() }
		}

		self.isLoading = false
		loadingSpinnerTask.cancel()
		let folderIsPaused = folder.isPaused()

		// Just update without animation when we are empty or not a grid
		if (self.files.isEmpty && self.subdirectories.isEmpty) || self.viewStyle != .grid {
			self.folderExists = folderExists
			self.files = newFiles
			self.subdirectories = newSubdirectories
			self.folderIsPaused = folderIsPaused
			self.autoSelectViewStyle()
		}
		else {
			withAnimation {
				self.folderExists = folderExists
				self.files = newFiles
				self.subdirectories = newSubdirectories
				self.folderIsPaused = folderIsPaused
				self.autoSelectViewStyle()
			}
		}

		await self.updateExtraneousFiles()
	}

	private func autoSelectViewStyle() {
		// These files are ignored when deciding whether to switch to a grid view or not
		let extensionsIgnored = Set([".aae", ".ds_store", ".db", ".gitignore", ".stignore", ".ini"])

		if self.viewStyle == nil {
			// Do we have an index.html? If so switch to web view
			if appState.userSettings.automaticallyShowWebpages && self.files.contains(where: { $0.fileName() == "index.html" }) {
				self.viewStyle = .web
			}
			else if appState.userSettings.automaticallySwitchViewStyle {
				// Check if we only have thumbnailable files; if so, switch to thumbnail mode
				let dotFilesHidden = appState.userSettings.dotFilesHidden
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
			else {
				self.viewStyle = appState.userSettings.defaultBrowserViewStyle
			}
		}
	}

	private func updateExtraneousFiles() async {
		if self.folder.isIdle {
			hasExtraneousFiles = await Task.detached {
				dispatchPrecondition(condition: .notOnQueue(.main))
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
		if !self.exists() {
			return -1
		}
		var error: NSError? = nil
		let state = self.state(&error)
		var hasher = Hasher()
		hasher.combine(state)
		hasher.combine(self.isPaused())
		return hasher.finalize()
	}
}

struct ItemSelectToggleView: View {
	@Environment(AppState.self) private var appState
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

struct FilesFooterView: View {
	let subdirectories: Int
	let files: Int

	var body: some View {
		// Show number of items
		Group {
			if self.subdirectories > 0 && self.files == 0 {
				Text("\(self.subdirectories) subdirectories")
			}
			else if self.files > 0 && self.subdirectories == 0 {
				Text("\(self.files) files")
			}
			else if self.files > 0 && self.subdirectories > 0 {
				Text("\(self.files) files and \(self.subdirectories) subdirectories")
			}
		}
		.font(.footnote)
		.foregroundColor(.secondary)
		.frame(maxWidth: .infinity)
	}
}
