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

		let enableLogging = UserDefaults.standard.bool(forKey: "loggingEnabled")
		Log.info("Logging enabled: \(enableLogging)")

		registerPhotoFilesystem()

		let client = SushitrainNewClient(configPath, documentsPath, enableLogging)!

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
		appState.isLogging = enableLogging
		self.delegate = SushitrainDelegate(appState: appState)
		client.delegate = self.delegate
		client.server?.delegate = self.delegate

		// Start Syncthing node in the background
		#if os(macOS)
			let hideInDock = self.hideInDock
		#endif

		Task {
			await appState.start()
		}

		#if os(macOS)
			DispatchQueue.main.async {
				NSApp.setActivationPolicy(hideInDock ? .accessory : .regular)
			}
		#endif
	}

	private static func configDirectoryURL() -> URL {
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
		ImageCache.clearMemoryCache()

		Task {
			try? await goTask {
				SushitrainClearBlockCache()
			}
		}
	}

	var body: some Scene {
		#if os(macOS)
			WindowGroup(id: "folder", for: String.self) { [appState] folderID in
				MainView(
					route: folderID.wrappedValue == nil ? .start : .folder(folderID: folderID.wrappedValue)
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
		#endif

		WindowGroup(id: "main") { [appState] in
			MainView()
				.environment(appState)
				#if os(iOS)
					.onReceive(memoryWarningPublisher) { _ in
						self.onReceiveMemoryWarning()
					}
				#endif
		}
		#if os(macOS)
			.onChange(of: hideInDock, initial: true) { _ov, nv in
				NSApp.setActivationPolicy(nv ? .accessory : .regular)
				NSApp.activate(ignoringOtherApps: true)
			}
			.commands {
				CommandGroup(replacing: CommandGroupPlacement.appInfo) {
					Button(
						action: {
							// Open the "about" window
							openWindow(id: "about")
						},
						label: {
							Text("About Synctrain")
						})

					Button(
						action: {
							openWindow(id: "stats")
						},
						label: {
							Text("Statistics...")
						})
				}
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

			MenuBarExtraView(hideInDock: $hideInDock)
				.environment(appState)

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
}

#if os(macOS)
	struct MenuBarExtraView: Scene {
		@Binding var hideInDock: Bool
		@Environment(\.openWindow) private var openWindow
		@Environment(AppState.self) private var appState

		@State private var folders: [SushitrainFolder] = []

		var body: some Scene {
			Window("Settings", id: "appSettings") {
				NavigationStack {
					TabbedSettingsView(hideInDock: $hideInDock)
				}
			}

			MenuBarExtra("Synctrain", systemImage: self.menuIcon, isInserted: $hideInDock) {
				if appState.startupState == .started {
					OverallStatusView()
						.task {
							await self.update()
						}

					Button("Open file browser...") {
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

					Button(
						action: {
							// Open the "about" window
							openWindow(id: "appSettings")
							NSApplication.shared.activate()
						},
						label: {
							Text("Settings...")
						})

					Button(
						action: {
							openWindow(id: "stats")
							NSApplication.shared.activate()
						},
						label: {
							Text("Statistics...")
						})
				}

				Button(
					action: {
						// Open the "about" window
						openWindow(id: "about")
						NSApplication.shared.activate()
					},
					label: {
						Text("About...")
					})

				Divider()

				Toggle(isOn: $hideInDock) {
					Label("Hide in dock", systemImage: "eye.slash")
				}

				Button("Quit Synctrain") {
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
