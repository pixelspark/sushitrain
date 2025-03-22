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

class SushitrainDelegate: NSObject {
	fileprivate var appState: AppState

	required init(appState: AppState) {
		self.appState = appState
	}
}

@main
struct SushitrainApp: App {
	fileprivate var appState: AppState
	fileprivate var delegate: SushitrainDelegate?
	private let qaService = QuickActionService.shared

	#if os(iOS)
		@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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

		let client = SushitrainNewClient(configPath, documentsPath, enableLogging)!
		let appState = AppState(client: client, documentsDirectory: documentsDirectory, configDirectory: configDirectory)
		self.appState = appState

		AppDependencyManager.shared.add(dependency: appState)
		appState.isLogging = enableLogging
		self.delegate = SushitrainDelegate(appState: appState)
		client.delegate = self.delegate
		client.server?.delegate = self.delegate

		// Resolve bookmarks
		let folderIDs = client.folders()?.asArray() ?? []
		for folderID in folderIDs {
			do {
				if let bm = try BookmarkManager.shared.resolveBookmark(folderID: folderID) {
					Log.info("We have a bookmark for folder \(folderID): \(bm)")
					if let folder = client.folder(withID: folderID) {
						try folder.setPath(bm.path(percentEncoded: false))
					}
					else {
						Log.warn(
							"Cannot obtain folder configuration for \(folderID) for setting bookmark; skipping"
						)
					}
				}
			}
			catch {
				Log.warn("Error restoring bookmark for \(folderID): \(error.localizedDescription)")
			}
		}
		BookmarkManager.shared.removeBookmarksForFoldersNotIn(Set(folderIDs))

		// Other housekeeping
		ExternalSharingManager.shared.removeExternalSharingForFoldersNotIn(Set(folderIDs))

		// Start Syncthing node in the background
		#if os(macOS)
			let hideInDock = self.hideInDock
		#endif

		appState.start()

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

	var body: some Scene {
		#if os(macOS)
			WindowGroup(id: "folder", for: String.self) { [appState] folderID in
				MainView(
					appState: appState,
					route: folderID.wrappedValue == nil
						? .start : .folder(folderID: folderID.wrappedValue))
			}

			WindowGroup(id: "preview", for: Preview.self) { [appState] preview in
				if case .started = appState.startupState {
					if let p = preview.wrappedValue {
						PreviewWindow(preview: p, appState: appState)
					}
				}
			}
			.windowManagerRole(.associated)
		#endif

		WindowGroup(id: "main") { [appState] in
			MainView(appState: appState)
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
				AboutView()
			}
			.windowResizability(.contentSize)

			MenuBarExtraView(hideInDock: $hideInDock, appState: appState)

			Settings {
				if case .started = appState.startupState {
					NavigationStack {
						TabbedSettingsView(appState: appState, hideInDock: $hideInDock)
					}
				}
			}
			.windowResizability(.contentSize)

			Window("Statistics", id: "stats") {
				if case .started = appState.startupState {
					TotalStatisticsView(appState: appState)
						.frame(maxWidth: 320)
				}
			}
			.windowResizability(.contentSize)

			Window("Synctrain", id: "singleMain") {
				if case .started = appState.startupState {
					MainView(appState: appState)
				}
			}
			.windowResizability(.contentSize)
		#endif
	}
}

extension SushitrainDelegate: SushitrainClientDelegateProtocol {
	func onChange(_ change: SushitrainChange?) {
		if let change = change {
			let appState = self.appState
			DispatchQueue.main.async {
				// For example: 25 > 25, 100 > 25
				if appState.lastChanges.count > AppState.maxChanges - 1 {
					// Remove excess elements at the top
					// For example: 25 - 25 + 1 = 1, 100 - 25 + 1 = 76
					appState.lastChanges.removeFirst(
						appState.lastChanges.count - AppState.maxChanges + 1)
				}
				appState.lastChanges.append(change)
			}
		}
	}

	func onEvent(_ event: String?) {
		let appState = self.appState
		DispatchQueue.main.async {
			appState.changePublisher.send()
		}
	}

	func onListenAddressesChanged(_ addresses: SushitrainListOfStrings?) {
		let appState = self.appState
		let addressSet = Set(addresses?.asArray() ?? [])
		DispatchQueue.main.async {
			appState.resolvedListenAddresses = addressSet
		}
	}

	func onDeviceDiscovered(_ deviceID: String?, addresses: SushitrainListOfStrings?) {
		let appState = self.appState
		if let deviceID = deviceID, let addresses = addresses?.asArray() {
			DispatchQueue.main.async {
				appState.discoveredDevices[deviceID] = addresses
			}
		}
	}
}

extension SushitrainDelegate: SushitrainStreamingServerDelegateProtocol {
	func onStreamChunk(_ folder: String?, path: String?, bytesSent: Int64, bytesTotal: Int64) {
		if let folder = folder, let path = path {
			let appState = self.appState
			DispatchQueue.main.async {
				appState.streamingProgress = StreamingProgress(
					folder: folder,
					path: path,
					bytesSent: bytesSent,
					bytesTotal: bytesTotal
				)
			}
		}
	}
}

#if os(macOS)
	struct MenuBarExtraView: Scene {
		@Binding var hideInDock: Bool
		@ObservedObject var appState: AppState
		@Environment(\.openWindow) private var openWindow

		var body: some Scene {
			Window("Settings", id: "appSettings") {
				if case .started = appState.startupState {
					NavigationStack {
						TabbedSettingsView(appState: appState, hideInDock: $hideInDock)
					}
				}
			}

			MenuBarExtra("Synctrain", systemImage: self.menuIcon, isInserted: $hideInDock) {
				if case .started = appState.startupState {
					OverallStatusView(appState: appState)

					Button("Open file browser...") {
						openWindow(id: "singleMain")
						NSApplication.shared.activate()
					}

					// List of folders
					if appState.menuFolderAction != .hide {
						let folders = appState.folders().filter { $0.isHidden == false }.sorted()
						if !folders.isEmpty {
							Divider()
							ForEach(folders, id: \.folderID) { fld in
								Button("\(fld.displayName)") {
									switch appState.menuFolderAction {
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

		private var menuIcon: String {
			if case .started = appState.startupState {
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
