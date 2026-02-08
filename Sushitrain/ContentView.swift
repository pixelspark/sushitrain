// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SushitrainCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
	@Environment(AppState.self) private var appState
	@State var topLevelRoute: Route? = .start
	@Environment(\.openURL) private var openURL

	var body: some View {
		switch appState.startupState {
		case .notStarted:
			LoadingMainView(appState: appState)

		case .onboarding:
			OnboardingView(allowSkip: false)

		case .error(let e):
			ContentUnavailableView {
				Label("Cannot start the app", systemImage: "exclamationmark.triangle.fill")
			} description: {
				Text(e)
				Button("What do I do now?") {
					openURL(URL(string: "https://t-shaped.nl/synctrain-support#cannot-start")!)
				}
			}
		case .started:
			ContentView(topLevelRoute: topLevelRoute)
				.showsToast()  // Back-up
				#if os(iOS)
					.handleOpenURLInApp()
				#endif
		}
	}
}

struct NavigateToAction {
	typealias Action = (Route) -> Void
	let action: Action

	func callAsFunction(_ route: Route) {
		action(route)
	}
}

extension EnvironmentValues {
	@Entry var navigateTo = NavigateToAction(action: { _ in })
}

private struct ContentView: View {
	@Environment(AppState.self) private var appState
	@Environment(\.scenePhase) var scenePhase
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	@State private var showCustomConfigWarning = false
	@State var topLevelRoute: Route? = .start
	@State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
	@State private var showSearchSheet = false
	@State private var searchSheetSearchTerm: String = ""
	@State private var error: String? = nil

	// Tracks the route within the folder tab; used to force navigating back
	@Observable class FoldersRouteManager {
		var route: [Route] = []
	}
	@State private var foldersTabRouteManager = FoldersRouteManager()

	#if os(iOS)
		@ViewBuilder private func foldersTab() -> some View {
			NavigationStack(path: $foldersTabRouteManager.route) {
				FoldersView()
					.toolbar {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								let documentsUrl = FileManager.default.urls(
									for: .documentDirectory, in: .userDomainMask
								).first!
								openURLInSystemFilesApp(url: documentsUrl)
							}
						).labelStyle(.iconOnly)
					}
			}
		}

		// Legacy one has search as toolbar option at the top
		// When changing this, also update LoadingMainView.legacyTabbedBody to match
		@ViewBuilder private func legacyTabbedBody() -> some View {
			TabView(selection: $topLevelRoute) {
				// Me
				NavigationStack {
					StartOrSearchView(topLevelRoute: $topLevelRoute)
				}
				.showsToast()
				.tabItem {
					Label("Start", systemImage: self.appState.syncState.systemImage)
				}.tag(Route.start)

				// Folders
				self.foldersTab().showsToast().tabItem {
					Label("Folders", systemImage: "folder.fill")
				}.tag(Route.folders)

				// Peers
				NavigationStack {
					DevicesView()
				}
				.showsToast()
				.tabItem {
					Label("Devices", systemImage: "externaldrive.fill")
				}.tag(Route.devices)
			}
		}

		// Modern one has the search as a tab
		// When changing this, also update LoadingMainView.modernTabbedBody to match
		@available(iOS 26.0, *)
		@ViewBuilder private func modernTabbedBody() -> some View {
			TabView(selection: $topLevelRoute) {
				Tab("Start", systemImage: self.appState.syncState.systemImage, value: Route.start) {
					// Me
					NavigationStack {
						#if os(iOS)
							StartView(
								topLevelRoute: $topLevelRoute, userSettings: appState.userSettings,
								backgroundManager: appState.backgroundManager)
						#else
							StartView(topLevelRoute: $topLevelRoute, userSettings: appState.userSettings)
						#endif
					}.showsToast()
				}

				// Folders
				Tab("Folders", systemImage: "folder.fill", value: Route.folders) {
					self.foldersTab().showsToast()
				}

				// Peers
				Tab("Devices", systemImage: "externaldrive.fill", value: Route.devices) {
					NavigationStack {
						DevicesView()
					}.showsToast()
				}

				// Search (iOS 26)
				Tab(value: Route.search(for: ""), role: .search) {
					self.searchView(inSheet: false).showsToast()
				}
			}
		}

		@ViewBuilder private func tabbedBody() -> some View {
			if #available(iOS 26, *) {
				self.modernTabbedBody()
			}
			else {
				self.legacyTabbedBody()
			}
		}
	#endif

	@ViewBuilder private func splitBody() -> some View {
		NavigationSplitView(
			columnVisibility: $columnVisibility,
			sidebar: {
				List(selection: $topLevelRoute) {
					if horizontalSizeClass != .compact {
						Section {
							NavigationLink(value: Route.start) {
								Label("Start", systemImage: self.appState.syncState.systemImage)
							}

							NavigationLink(value: Route.devices) {
								Label("Devices", systemImage: "externaldrive.fill")
							}
						}
					}

					FoldersSections(userSettings: appState.userSettings)
				}
				#if os(macOS)
					.contextMenu {
						FolderMetricPickerView(userSettings: appState.userSettings)
					}
				#endif
				#if os(iOS)
					.toolbar {
						ToolbarItem {
							Button(
								openInFilesAppLabel, systemImage: "arrow.up.forward.app",
								action: {
									let documentsUrl = FileManager.default.urls(
										for: .documentDirectory, in: .userDomainMask
									).first!
									openURLInSystemFilesApp(url: documentsUrl)
								}
							).labelStyle(.iconOnly)
						}

						ToolbarItem {
							Menu(
								content: {
									FolderMetricPickerView(userSettings: appState.userSettings)
								},
								label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Menu")) }
							).labelStyle(.iconOnly)
						}
					}
				#endif
			},
			detail: {
				switch self.topLevelRoute {
				case .start:
					NavigationStack {
						StartOrSearchView(topLevelRoute: $topLevelRoute)
					}.showsToast()

				case .search:
					NavigationStack {
						self.searchView(inSheet: false)
					}.showsToast()

				case .devices:
					NavigationStack {
						DevicesView()
					}.showsToast()

				case .folders:
					NavigationStack(path: $foldersTabRouteManager.route) {
						FoldersView()
					}.showsToast()

				case .folder(let folderID, let prefix):
					NavigationStack(path: $foldersTabRouteManager.route) {
						RouteView(route: self.topLevelRoute!)
							.navigationDestination(for: Route.self) { r in
								RouteView(route: r)
							}
					}.id(folderID + ":" + (prefix ?? "")).showsToast()

				case .file(let folderID, let path):
					NavigationStack(path: $foldersTabRouteManager.route) {
						RouteView(route: self.topLevelRoute!)
							.navigationDestination(for: Route.self) { r in
								RouteView(route: r)
							}
					}.id(folderID + ":" + path).showsToast()

				case nil:
					ContentUnavailableView("Select a folder", systemImage: "folder")
						.onTapGesture {
							columnVisibility = .doubleColumn
						}
						.showsToast()
				}
			}
		)
		.navigationSplitViewStyle(.balanced)
	}

	var body: some View {
		Group {
			#if os(iOS)
				if horizontalSizeClass == .compact {
					self.tabbedBody()
				}
				else {
					self.splitBody()
				}
			#else
				self.splitBody()
			#endif
		}
		#if os(iOS)
			.onChange(of: QuickActionService.shared.action, initial: true) { _, newAction in
				if let newAction = newAction {
					self.navigate(to: newAction)
					QuickActionService.shared.action = nil
				}
			}
		#endif
		.onChange(of: scenePhase) { oldPhase, newPhase in
			self.appState.onScenePhaseChange(from: oldPhase, to: newPhase)

			#if os(iOS)
				if newPhase != .active && self.appState.userSettings.rehideHiddenFoldersOnActivate {
					self.leaveHiddenFolder()
				}
			#endif
		}

		.alert(isPresented: Binding.isNotNil($error)) {
			Alert(
				title: Text("An error has occurred"),
				message: Text(error ?? ""),
				dismissButton: .default(Text("OK")) {
					self.error = nil
				})
		}

		.alert(isPresented: $showCustomConfigWarning) {
			Alert(
				title: Text("Custom configuration detected"),
				message: Text(
					"You are using a custom configuration. This may be used for testing only, and at your own risk. Not all configuration options may be supported. To disable the custom configuration, remove the configuration files from the app's folder and restart the app. The makers of the app cannot be held liable for any data loss that may occur!"
				),
				dismissButton: .default(Text("I understand and agree")) {
					// Further consent and warning stuff
					AppState.requestNotificationPermissionIfNecessary()
				})
		}
		.onAppear {
			// Consent and warning stuff
			if self.appState.client.isUsingCustomConfiguration {
				self.showCustomConfigWarning = true
			}
			else {
				AppState.requestNotificationPermissionIfNecessary()
			}
		}
		#if os(iOS)
			// Search sheet for quick action
			.sheet(isPresented: $showSearchSheet) {
				self.searchView(inSheet: true)
			}
		#endif

		.onContinueUserActivity(SushitrainApp.viewRouteActivityID) { ua in
			if let userInfo = ua.userInfo {
				Log.info("Receive view route handoff \(userInfo)")
				if let version = ua.userInfo?["version"] as? Int,
					version == 1,
					let urlString = ua.userInfo?["url"] as? String,
					let url = URL(string: urlString),
					let route = Route(url: url)
				{
					self.navigate(to: route)
				}
			}
		}
		.environment(\.navigateTo, NavigateToAction(action: { route in self.navigate(to: route) }))
	}

	private func exists(route: Route) -> Bool {
		switch route {
		case .devices, .start, .search(for: _), .folders:
			return true
		case .folder(let folderID, let prefix):
			guard appState.client.folder(withID: folderID) != nil else {
				return false
			}

			if let p = prefix {
				// TODO: check if prefix points to an actual folder
				return p.isEmpty || p.hasSuffix("/")
			}
			else {
				return true
			}
		case .file(let folderID, let path):
			guard let folder = appState.client.folder(withID: folderID) else {
				return false
			}

			guard let entry = try? folder.getFileInformation(path) else {
				return false
			}

			return !entry.isDeleted() && !entry.isSymlink()
		}
	}

	private func navigate(to route: Route) {
		Log.info("Navigate to route=\(route) splitted=\(route.splitted)")

		if !self.exists(route: route) {
			self.error = String(localized: "The requested item cannot be found on this device.")
			return
		}

		// The search route opens in a sheet, because on iOS 17 is is not a separate tab, and activating the special
		// search tab on iOS 26 doesn't seem to work properly as of writing this.
		if case .search(for: let searchFor) = route {
			self.topLevelRoute = .start
			self.searchSheetSearchTerm = searchFor
			showSearchSheet = true
			return
		}

		#if os(iOS)
			if horizontalSizeClass == .compact {
				switch route {
				case .folder(folderID: _, prefix: _), .file(folderID: _, path: _):
					self.topLevelRoute = Route.folders
					self.foldersTabRouteManager.route = route.splitted

				case .devices, .search, .start, .folders:
					self.topLevelRoute = route
					self.foldersTabRouteManager.route = []
				}
				return
			}
		#endif

		if case .folder(folderID: _, prefix: _) = route {
			let splitted = route.splitted
			self.topLevelRoute = splitted[0]
			self.foldersTabRouteManager.route = Array(splitted.dropFirst())
		}
		else {
			self.topLevelRoute = route
			self.foldersTabRouteManager.route = []
		}
	}

	@ViewBuilder private func searchView(inSheet: Bool) -> some View {
		NavigationStack {
			SearchView(
				prefix: "",
				initialSearchText: self.searchSheetSearchTerm
			)
			.navigationTitle("Search")
			#if os(iOS)
				.navigationBarTitleDisplayMode(.inline)
			#endif
			.toolbar {
				if inSheet {
					SheetButton(role: .done) {
						showSearchSheet = false
					}
				}
			}
		}
	}

	private func leaveHiddenFolder() {
		if case .folder(folderID: let folderID, prefix: _) = topLevelRoute {
			if let folder = self.appState.client.folder(withID: folderID) {
				if folder.isHidden == true {
					Log.info("we are currently in a hidden folder, move out of it")
					self.topLevelRoute = .start
				}
			}
		}

		#if os(iOS)
			for route in self.foldersTabRouteManager.route {
				// Is the folder tab inside a folder that is hidden? Then move out of it
				if case .folder(folderID: let folderID, prefix: _) = route {
					if let folder = self.appState.client.folder(withID: folderID) {
						if folder.isHidden == true {
							Log.info("we are currently in a hidden folder, move out of it")
							self.foldersTabRouteManager.route = []
						}
					}
				}
			}
		#endif
	}
}

struct RouteView: View {
	@Environment(AppState.self) private var appState
	let route: Route

	var body: some View {
		switch route {
		case .file(let folderID, let path):
			if let folder = self.appState.client.folder(withID: folderID) {
				if folder.exists() {
					if let entry = try? folder.getFileInformation(path) {
						FileView(file: entry, showPath: false, siblings: nil)
					}
					else {
						ContentUnavailableView("File not found", systemImage: "document")
					}
				}
				else {
					ContentUnavailableView(
						"Folder was deleted", systemImage: "trash",
						description: Text("This folder was deleted."))
				}
			}
			else {
				ContentUnavailableView("Folder not found", systemImage: "folder")
			}

		case .folder(let folderID, let prefix):
			if let folder = self.appState.client.folder(withID: folderID) {
				if folder.exists() {
					BrowserView(folder: folder, prefix: prefix ?? "", userSettings: appState.userSettings)
				}
				else {
					ContentUnavailableView(
						"Folder was deleted", systemImage: "trash",
						description: Text("This folder was deleted."))
				}
			}
			else {
				ContentUnavailableView("Select a folder", systemImage: "folder")
			}

		case .folders, .start, .devices, .search:
			EmptyView()
		}
	}
}

private struct LoadingMainView: View {
	@State var appState: AppState
	@State var topLevelRoute: Route? = .start

	#if os(iOS)
		// Mirrors ContentView.modernTabbedBody
		@available(iOS 26.0, *)
		@ViewBuilder private func modernTabbedBody() -> some View {
			TabView(selection: $topLevelRoute) {
				Tab("Start", systemImage: self.appState.syncState.systemImage, value: Route.start) {
					// Me
					NavigationStack {
						LoadingView(appState: appState)
					}
				}.disabled(true)

				// Folders
				Tab("Folders", systemImage: "folder.fill", value: Route.folders) {
					NavigationStack {
						LoadingView(appState: appState)
					}
				}.disabled(true)

				// Peers
				Tab("Devices", systemImage: "externaldrive.fill", value: Route.devices) {
					NavigationStack {
						LoadingView(appState: appState)
					}
				}.disabled(true)

				// Search (iOS 26)
				Tab(value: Route.search(for: ""), role: .search) {
					NavigationStack {
						LoadingView(appState: appState)
					}
				}.disabled(true)
			}
		}

		// Mirrors ContentView.legacyTabbedBody
		@ViewBuilder private func legacyTabbedBody() -> some View {
			TabView(selection: $topLevelRoute) {
				// Me
				NavigationStack {
					LoadingView(appState: appState)
				}.tabItem {
					Label("Start", systemImage: self.appState.syncState.systemImage)
				}.tag(Route.start)

				// Folders
				NavigationStack {
					LoadingView(appState: appState)
				}.tabItem {
					Label("Folders", systemImage: "folder.fill")
				}.tag(Route.folders)

				// Peers
				NavigationStack {
					LoadingView(appState: appState)
				}.tabItem {
					Label("Devices", systemImage: "externaldrive.fill")
				}.tag(Route.devices)
			}
		}
	#endif

	var body: some View {
		#if os(iOS)
			if #available(iOS 26, *) {
				self.modernTabbedBody()
			}
			else {
				self.legacyTabbedBody()
			}
		#else
			NavigationSplitView(
				sidebar: {
					EmptyView()
				},
				detail: {
					NavigationStack {
						LoadingView(appState: appState)
							.navigationTitle("Start")
							.searchable(text: .constant(""))
					}
				}
			)
			.navigationSplitViewStyle(.balanced)
		#endif
	}
}

private struct LoadingView: View {
	@State var appState: AppState

	var body: some View {
		VStack(spacing: 10) {
			ProgressView().progressViewStyle(.circular)
			if !appState.isMigratedToNewDatabase {
				// We are likely migrating now
				Text(
					"Upgrading the database. This may take a few minutes, depending on how many files you have. Please do not close the app until this is finished."
				)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 320)
			}
		}
		#if os(iOS)
			.onAppear {
				Log.info("Asserting idle timer disable")
				UIApplication.shared.isIdleTimerDisabled = true
			}
			.onDisappear {
				Log.info("Deasserting idle timer disable")
				UIApplication.shared.isIdleTimerDisabled = false
			}
		#endif
	}
}

private struct StartOrSearchView: View {
	@Environment(AppState.self) private var appState
	@Binding var topLevelRoute: Route?
	@State private var searchText: String = ""
	@FocusState private var isSearchFieldFocused

	// This is needed because isSearching is not available from the parent view
	struct InnerView: View {
		@Environment(AppState.self) private var appState
		@Binding var topLevelRoute: Route?
		@Binding var searchText: String
		@Environment(\.isSearching) private var isSearching

		var body: some View {
			if isSearching {
				SearchResultsView(
					userSettings: appState.userSettings,
					searchText: $searchText,
					folderID: .constant(""),
					prefix: .constant("")
				)
			}
			else {
				#if os(iOS)
					StartView(
						topLevelRoute: $topLevelRoute, userSettings: appState.userSettings, backgroundManager: appState.backgroundManager)
				#else
					StartView(topLevelRoute: $topLevelRoute, userSettings: appState.userSettings)
				#endif
			}
		}
	}

	@ViewBuilder private func view() -> some View {
		InnerView(topLevelRoute: $topLevelRoute, searchText: $searchText)
			.searchable(
				text: $searchText, placement: SearchFieldPlacement.toolbar,
				prompt: "Search all files and folders..."
			)
			#if os(iOS)
				.textInputAutocapitalization(.never)
			#endif
			.autocorrectionDisabled()
	}

	var body: some View {
		if #available(iOS 18, *) {
			self.view().searchFocused($isSearchFieldFocused)
		}
		else {
			self.view()
		}
	}
}
