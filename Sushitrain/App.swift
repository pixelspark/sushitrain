// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import BackgroundTasks
import Combine
import AppIntents

@main
struct SushitrainApp: App {
	static var viewRouteActivityID = "nl.t-shaped.Sushitrain.view-route"

	@State fileprivate var appState: AppState

	fileprivate var delegate: SushitrainDelegate?
	private let qaService = QuickActionService.shared

	#if os(iOS)
		@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
		@State private var memoryWarningPublisher = NotificationCenter.default.publisher(
			for: UIApplication.didReceiveMemoryWarningNotification)
	#endif

	#if os(macOS)
		@Environment(\.openWindow) private var openWindow
		@AppStorage("hideInDock") var hideInDock: Bool = false
	#endif

	init() {
		let configDirectory = Self.configDirectoryURL()

		let documentsDirectory = try! FileManager.default.url(
			for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		let documentsPath = documentsDirectory.path(percentEncoded: false)
		let configPath = configDirectory.path(percentEncoded: false)
		let enableLoggingToFile = UserDefaults.standard.bool(forKey: "loggingEnabled")
		registerPhotoFilesystem()
		let client = SushitrainNewClient(configPath, documentsPath, enableLoggingToFile)!

		// Optionally clear v1 and/or v2 index
		let clearV1Index = UserDefaults.standard.bool(forKey: "clearV1Index")
		let clearV2Index = UserDefaults.standard.bool(forKey: "clearV2Index")
		if clearV1Index {
			Log.info("Deleting v1 index...")
			do {
				try client.clearLegacyDatabase()
				UserDefaults.standard.setValue(false, forKey: "clearV1Index")
			}
			catch {
				Log.warn("Failed to delete v1 index: " + error.localizedDescription)
			}
		}
		if clearV2Index {
			Log.info("Deleting v2 index...")
			do {
				try client.clearDatabase()
				UserDefaults.standard.setValue(false, forKey: "clearV2Index")
			}
			catch {
				Log.warn("Failed to delete v2 index: " + error.localizedDescription)
			}
		}

		let appState = AppState(client: client, documentsDirectory: documentsDirectory, configDirectory: configDirectory)
		self.appState = appState

		AppDependencyManager.shared.add(dependency: appState)
		appState.isLoggingToFile = enableLoggingToFile
		self.delegate = SushitrainDelegate(appState: appState)
		client.delegate = self.delegate
		client.server?.delegate = self.delegate

		// Start Syncthing node in the background
		#if os(macOS)
			let hideInDock = self.hideInDock
		#endif

		// Check if we need to show onboarding
		Task {
			await appState.start()
		}

		#if os(macOS)
			DispatchQueue.main.async {
				NSApp.setActivationPolicy(hideInDock ? .accessory : .regular)
			}
		#endif
	}

	static func configDirectoryURL() -> URL {
		// Determine the config directory (on macOS the user can choose a directory)
		var isCustom = false
		#if os(macOS)
			var configDirectory: URL
			var isStale = false
			if let configDirectoryBookmark = UserDefaults.standard.data(forKey: "configDirectoryBookmark"),
				let cd = try? URL(
					resolvingBookmarkData: configDirectoryBookmark, options: [.withSecurityScope],
					bookmarkDataIsStale: &isStale),
				cd.startAccessingSecurityScopedResource()
			{
				configDirectory = cd
				Log.info("Using custom config directory: \(configDirectory)")
				isCustom = true

				if isStale {
					Log.info("Config directory bookmark is stale, recreating bookmark")
					if let bookmarkData = try? cd.bookmarkData(options: [.withSecurityScope]) {
						UserDefaults.standard.setValue(
							bookmarkData, forKey: "configDirectoryBookmark")
					}
				}
			}
			else {
				configDirectory = try! FileManager.default.url(
					for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
					create: true)
			}
		#else
			var configDirectory = try! FileManager.default.url(
				for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
				create: true)
		#endif

		if !isCustom {
			// Exclude config and database directory from device back-up
			var excludeFromBackup = URLResourceValues()
			excludeFromBackup.isExcludedFromBackup = true
			do {
				try configDirectory.setResourceValues(excludeFromBackup)
			}
			catch {
				Log.warn(
					"Error excluding \(configDirectory.path) from backup: \(error.localizedDescription)"
				)
			}
		}

		return configDirectory
	}

	private func onReceiveMemoryWarning() {
		Log.info("Received memory pressure warning")
		self.appState.reduceMemoryUsage()
	}

	var body: some Scene {
		#if os(macOS)
			WindowGroup(id: "folder", for: String.self) { [appState] folderID in
				MainView(
					topLevelRoute: folderID.wrappedValue == nil ? .start : .folder(folderID: folderID.wrappedValue!, prefix: nil)
				).environment(appState)
			}

			WindowGroup(id: "preview", for: Preview.self) { [appState] preview in
				if appState.startupState == .started {
					if let p = preview.wrappedValue {
						PreviewWindow(preview: p)
							.environment(appState)
					}
				}
			}
			.windowManagerRole(.associated)

			WindowGroup(id: "decrypter") {
				DecrypterView()
			}
		#endif

		WindowGroup(id: "main") { [appState] in
			MainView()
				.environment(appState)
				#if os(iOS)
					.onReceive(memoryWarningPublisher) { _ in
						self.onReceiveMemoryWarning()
					}
				#endif

				#if os(macOS)
					.onContinueUserActivity(SushitrainApp.viewRouteActivityID) { ua in
						Log.info("Receive view-route handoff at app level: \(String(describing: ua.userInfo))")
					}
				#endif
		}
		.commands {
			self.commands()
		}
		#if os(macOS)
			.handlesExternalEvents(matching: ["*"])

			.onChange(of: hideInDock, initial: true) { _ov, nv in
				NSApp.setActivationPolicy(nv ? .accessory : .regular)
				NSApp.activate(ignoringOtherApps: true)
			}

			.defaultLaunchBehavior(hideInDock ? .suppressed : .presented)
			.restorationBehavior(hideInDock ? .disabled : .automatic)

		#endif

		#if os(macOS)
			// About window
			Window("About Synctrain", id: "about") {
				AboutView().environment(appState)
			}
			.windowResizability(.contentSize)

			// Support window
			Window("Questions, support & feedback", id: "support") {
				NavigationStack {
					SupportView()
				}.environment(appState)
			}
			.windowResizability(.contentSize)

			// Pass app state object explicitly, as sometimes Environment fails to resolve
			// for some reason...
			MenuBarExtraView(appState: appState, hideInDock: $hideInDock)

			Settings {
				NavigationStack {
					TabbedSettingsView(hideInDock: $hideInDock)
				}.environment(appState)
			}
			.windowResizability(.contentSize)

			Window("Statistics", id: "stats") {
				TotalStatisticsView()
					.environment(appState)
					.frame(minWidth: 320, maxWidth: 320, minHeight: 320)
			}
			.windowResizability(.contentSize)

			Window("Synctrain", id: "singleMain") {
				if appState.startupState == .started {
					MainView().environment(appState)
				}
			}
			.windowResizability(.contentSize)
		#endif
	}

	@CommandsBuilder private func commands() -> some Commands {
		CommandGroup(after: .sidebar) {
			Toggle("Hide dotfiles", isOn: appState.userSettings.$dotFilesHidden)

			Toggle("Hide hidden folders", isOn: appState.userSettings.$hideHiddenFolders)
		}

		#if os(macOS)
			CommandGroup(replacing: CommandGroupPlacement.help) {
				Button("Questions, support & feedback...") {
					openWindow(id: "support")
				}
			}

			CommandGroup(replacing: CommandGroupPlacement.appInfo) {
				Button("About Synctrain") {
					// Open the "about" window
					openWindow(id: "about")
				}

				Button("Statistics...") {
					openWindow(id: "stats")
				}

				Button("Decrypt a folder...") {
					openWindow(id: "decrypter")
				}
			}
		#endif
	}
}

#if os(macOS)
	struct MenuBarExtraView: Scene {
		let appState: AppState
		@Binding var hideInDock: Bool
		@Environment(\.openWindow) private var openWindow

		@State private var folders: [SushitrainFolder] = []

		var body: some Scene {
			Window("Settings...", id: "appSettings") {
				NavigationStack {
					TabbedSettingsView(hideInDock: $hideInDock)
				}
			}.environment(appState)

			MenuBarExtra("Synctrain", systemImage: self.menuIcon, isInserted: $hideInDock) {
				if appState.startupState == .started {
					OverallStatusView()
						.environment(appState)
						.task {
							await self.update()
						}

					Button("Open file browser...", systemImage: "macwindow") {
						openWindow(id: "singleMain")
						NSApplication.shared.activate()
					}

					// List of folders
					if appState.userSettings.menuFolderAction != .hide {
						if !folders.isEmpty {
							Divider()
							ForEach(folders, id: \.folderID) { fld in
								Button("\(fld.displayName)") {
									self.openFolder(fld)
								}
							}
						}
					}

					Divider()

					Button("Settings", systemImage: "gear") {
						// Open the "about" window
						openWindow(id: "appSettings")
						NSApplication.shared.activate()
					}

					Button("Statistics", systemImage: "chart.pie") {
						openWindow(id: "stats")
						NSApplication.shared.activate()
					}
				}

				Button("About...", systemImage: "info.circle") {
					// Open the "about" window
					openWindow(id: "about")
					NSApplication.shared.activate()
				}

				Divider()

				Toggle(isOn: $hideInDock) {
					Label("Hide in dock", systemImage: "eye.slash")
				}

				Button("Quit Synctrain", systemImage: "multiply.circle") {
					NSApplication.shared.terminate(nil)
				}
			}
		}

		private func openFolder(_ fld: SushitrainFolder) {
			switch appState.userSettings.menuFolderAction {
			case .hide:
				break  // Should not be reached

			case .finder:
				if let lnu = fld.localNativeURL {
					openURLInSystemFilesApp(url: lnu)
				}
				else {
					openWindow(
						id: "folder",
						value: fld.folderID)
					NSApplication.shared.activate()
				}

			case .browser:
				openWindow(id: "folder", value: fld.folderID)
				NSApplication.shared.activate()

			case .finderExceptSelective:
				if fld.isSelective() {
					openWindow(
						id: "folder",
						value: fld.folderID)
					NSApplication.shared.activate()
				}
				else if let lnu = fld.localNativeURL {
					openURLInSystemFilesApp(url: lnu)
				}
				else {
					openWindow(
						id: "folder",
						value: fld.folderID)
					NSApplication.shared.activate()
				}
			}
		}

		private func update() async {
			self.folders = await appState.folders().filter { $0.isHidden == false }.sorted()
		}

		private var menuIcon: String {
			if appState.startupState == .started {
				if appState.client.connectedPeerCount() > 0 {
					if appState.client.isDownloading() || appState.client.isUploading() {
						return "folder.fill.badge.gearshape"
					}
					return "folder.fill"
				}
				else {
					return "folder"
				}
			}
			else {
				return "exclamationmark.triangle.fill"
			}
		}
	}
#endif
