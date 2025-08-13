// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct TotalStatisticsView: View {
	@Environment(AppState.self) private var appState
	@State private var stats: SushitrainFolderStats? = nil

	var body: some View {
		let formatter = ByteCountFormatter()

		Form {
			if let stats = stats {
				if let global = stats.global {
					Section("All devices") {
						Text("Number of files").badge(global.files)
						Text("Number of directories").badge(global.directories)
						Text("File size").badge(formatter.string(fromByteCount: global.bytes))
					}
				}

				if let local = stats.local {
					Section("This device") {
						Text("Number of files").badge(local.files)
						Text("Number of directories").badge(local.directories)
						Text("File size").badge(formatter.string(fromByteCount: local.bytes))
					}
				}
			}
		}
		.task {
			if self.appState.startupState != .started {
				self.stats = nil
				return
			}
			self.stats = try? self.appState.client.statistics()
		}
		.navigationTitle("Statistics")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
	}
}

#if os(iOS)
	private struct ExportButtonView: View {
		@State private var error: Error? = nil
		@State private var showSuccess: Bool = false
		@Environment(AppState.self) private var appState

		var body: some View {
			Button("Export configuration file") {
				do {
					try self.appState.client.exportConfigurationFile()
					showSuccess = true
				}
				catch {
					self.error = error
				}
			}
			.disabled(self.appState.client.isUsingCustomConfiguration)
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
					message: Text(self.error!.localizedDescription),
					dismissButton: .default(Text("OK")))
			}
			.alert(isPresented: $showSuccess) {
				Alert(
					title: Text("Custom configuration saved"),
					message: Text(
						"The configuration file has been saved in the application folder."),
					dismissButton: .default(Text("OK")))
			}
		}
	}
#endif

#if os(macOS)
	struct ConfigurationSettingsView: View {
		@Environment(AppState.self) private var appState
		@State private var showHomeDirectorySelector = false
		@State private var currentPath: URL? = nil
		@State private var showRestartAlert: Bool = false

		var body: some View {
			Form {
				Section {
					HStack {
						if let p = currentPath {
							Text(p.path(percentEncoded: false))
								.frame(maxWidth: .infinity, alignment: .leading)
								.multilineTextAlignment(.leading)
							Button(
								openInFilesAppLabel,
								systemImage: "arrow.up.forward.app",
								action: {
									openURLInSystemFilesApp(url: p)
								}
							).labelStyle(.iconOnly)
						}
						else {
							Text("(Default location)")
								.frame(maxWidth: .infinity, alignment: .leading)
								.multilineTextAlignment(.leading)
							Button(
								openInFilesAppLabel,
								systemImage: "arrow.up.forward.app",
								action: {
									let url = URL(
										fileURLWithPath: self.appState.client
											.currentConfigDirectory())
									openURLInSystemFilesApp(url: url)
								}
							).labelStyle(.iconOnly)
						}
					}

					Button("Select configuration folder...") {
						self.showHomeDirectorySelector = true
					}
					.buttonStyle(.link)

					if currentPath != nil {
						Button("Use default configuration location") {
							self.setBookmark(nil)
						}
						.buttonStyle(.link)
					}
				} header: {
					Text("Configuration folder location")
				} footer: {
					Text(
						"The configuration folder contains the settings for the app, as well as the keys to communicate with other devices and bookkeeping of synchronized folders. By default, the configuration folder is managed by the app."
					)
				}
			}
			.formStyle(.grouped)
			.navigationTitle("Configuration settings")
			.fileImporter(isPresented: $showHomeDirectorySelector, allowedContentTypes: [.directory]) {
				result in
				switch result {
				case .success(let url):
					_ = url.startAccessingSecurityScopedResource()
					if let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) {
						self.setBookmark(bookmark)
					}
				case .failure(let err):
					Log.info("Failed to select home dir: \(err.localizedDescription)")
				}
			}
			.alert(
				"Configuration folder changed", isPresented: $showRestartAlert,
				actions: {
					Button("Close the app") {
						exit(0)
					}
				},
				message: {
					Text(
						"The path to the configuration folder was changed and will be used when the app is restarted. The app will now close."
					)
				}
			)
			.task {
				self.updatePath()
			}
		}

		private func setBookmark(_ data: Data?) {
			UserDefaults.standard.setValue(data, forKey: "configDirectoryBookmark")
			self.updatePath()
			self.showRestartAlert = true
		}

		private func updatePath() {
			var isStale: Bool = false
			if let bd = UserDefaults.standard.data(forKey: "configDirectoryBookmark"),
				let url = try? URL(
					resolvingBookmarkData: bd, options: [.withSecurityScope, .withoutUI],
					bookmarkDataIsStale: &isStale), !isStale
			{
				self.currentPath = url
			}
			else {
				self.currentPath = nil
			}
		}
	}
#endif

private struct DatabaseMaintenanceView: View {
	@Environment(AppState.self) private var appState
	@State private var hasMigratedLegacyDatabase = false
	@State private var hasLegacyDatabase = false
	@State private var performingDatabaseMaintenance = false

	var body: some View {
		Form {
			Section {
				LabeledContent("Database type") {
					if hasLegacyDatabase {
						// This shouldn't happen because either the migration fails or the app runs, but if it does happen
						// we want to know (and therefore indicate it in the UI).
						Text("v1").foregroundStyle(.red)
					}
					else {
						Text("v2")
					}
				}

				if appState.userSettings.migratedToV2At > 0.0 {
					LabeledContent("Upgraded at") {
						Text(
							Date(timeIntervalSinceReferenceDate: appState.userSettings.migratedToV2At).formatted(
								date: .abbreviated, time: .shortened))
					}
				}
			}

			if hasLegacyDatabase {
				Section {
					Button("Restart app to remove v1 database") {
						UserDefaults.standard.set(true, forKey: "clearV1Index")
						exit(0)
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				} footer: {
					Text(
						"A legacy database is still present. If the app is functioning correctly, it is safe to manually delete this database. In order to do this, the app needs to be restarted."
					)
				}.disabled(performingDatabaseMaintenance)
			}

			if hasMigratedLegacyDatabase {
				Section {
					Button("Remove v1 database back-up") {
						self.clearMigratedLegacyDatabase()
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				} footer: {
					Text(
						"After a database upgrade, a copy of the old version is retained for a while. This copy may take up a significant amount of storage space. If everything is working as expected, it is safe to remove this back-up."
					)
				}.disabled(performingDatabaseMaintenance)
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.task {
			self.updateDatabaseInfo()
		}
		.navigationTitle("Database maintenance")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}

	private func updateDatabaseInfo() {
		self.hasLegacyDatabase = appState.client.hasLegacyDatabase()
		self.hasMigratedLegacyDatabase = appState.client.hasMigratedLegacyDatabase()
	}

	private func clearMigratedLegacyDatabase() {
		if self.performingDatabaseMaintenance {
			return
		}
		Task {
			self.performingDatabaseMaintenance = true
			do {
				try appState.client.clearMigratedLegacyDatabase()
			}
			catch {
				print("Cannot clear migrated V1 index: \(error.localizedDescription)")
			}
			self.updateDatabaseInfo()
			self.performingDatabaseMaintenance = false
		}
	}
}

struct AdvancedSettingsView: View {
	@Environment(AppState.self) private var appState
	@ObservedObject var userSettings: AppUserSettings
	@State private var diskCacheSizeBytes: UInt? = nil
	@State private var showListeningAddresses = false
	@State private var showDiscoveryAddresses = false
	@State private var showSTUNAddresses = false
	@State private var folders: [SushitrainFolder] = []
	@State private var confirmClearThumbnailCache = false

	#if os(macOS)
		@State private var showConfigurationSettings = false
		@State private var showDatabaseMaintenance = false
	#endif

	var body: some View {
		Form {
			Section {
				Toggle(
					"Listen for incoming connections",
					isOn: Binding(
						get: {
							return appState.client.isListening()
						},
						set: { listening in
							try? appState.client.setListening(listening)
						}))

				// Listening addresses popup sheet
				Button("Listening addresses...", systemImage: "envelope.front") {
					showListeningAddresses = true
				}
				.disabled(!appState.client.isListening())
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.sheet(isPresented: $showListeningAddresses) {
					NavigationStack {
						AsyncAddressesView(addressType: .listening)
							.navigationTitle("Listening addresses")
							.toolbar(content: {
								ToolbarItem(
									placement: .confirmationAction,
									content: {
										Button("Done") {
											showListeningAddresses = false
										}
									})
							})
					}
				}
			} header: {
				Text("Connectivity")
			} footer: {
				if appState.client.isListening() {
					Text(
						"Added devices can connect to this device on their initiative, while the app is running. This may cause additional battery drain. It is advisable to enable this only if you experience difficulty connecting to other devices."
					)
				}
				else {
					Text(
						"Connections to other devices can only be initiated by this device, not by the other added devices."
					)
				}
			}

			Section {
				Toggle(
					"One connection is enough",
					isOn: Binding(
						get: {
							return appState.client.getEnoughConnections() == 1
						},
						set: { enough in
							try! appState.client.setEnoughConnections(enough ? 1 : 0)
						}))
			} footer: {
				Text(
					"When this setting is enabled, the app will not attempt to connect to more devices after one connection has been established."
				)
			}

			Section("Discovery") {
				Toggle(
					"Announce on local networks",
					isOn: Binding(
						get: {
							return appState.client.isLocalAnnounceEnabled()
						},
						set: { nv in
							try? appState.client.setLocalAnnounceEnabled(nv)
						}))

				Toggle(
					"Announce LAN addresses",
					isOn: Binding(
						get: {
							return appState.client.isAnnounceLANAddressesEnabled()
						},
						set: { nv in
							try? appState.client.setAnnounceLANAddresses(nv)
						}))

				Toggle(
					"Announce globally",
					isOn: Binding(
						get: {
							return appState.client.isGlobalAnnounceEnabled()
						},
						set: { nv in
							try? appState.client.setGlobalAnnounceEnabled(nv)
						}))

				// Global announce addresses popup sheet
				Button("Global announce servers...", systemImage: "megaphone.fill") {
					showDiscoveryAddresses = true
				}
				.sheet(isPresented: $showDiscoveryAddresses) {
					NavigationStack {
						AsyncAddressesView(addressType: .discovery)
							.navigationTitle("Global announce servers")
							.toolbar(content: {
								ToolbarItem(
									placement: .confirmationAction,
									content: {
										Button("Done") {
											showDiscoveryAddresses = false
										}
									})
							})
					}
				}
				.disabled(!appState.client.isGlobalAnnounceEnabled())
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			}

			Section("Network traversal") {
				Toggle(
					"Enable relaying",
					isOn: Binding(
						get: {
							return appState.client.isRelaysEnabled()
						},
						set: { nv in
							try? appState.client.setRelaysEnabled(nv)
						}))

				Toggle(
					"Enable NAT-PMP / UPnP",
					isOn: Binding(
						get: {
							return appState.client.isNATEnabled()
						},
						set: { nv in
							try? appState.client.setNATEnabled(nv)
						}))

				Toggle(
					"Enable STUN",
					isOn: Binding(
						get: {
							return appState.client.isSTUNEnabled()
						},
						set: { nv in
							try? appState.client.setSTUNEnabled(nv)
						}))

				// STUN server addresses popup sheet
				Button("STUN Servers...", systemImage: "arrow.trianglehead.swap") {
					showSTUNAddresses = true
				}
				.sheet(isPresented: $showSTUNAddresses) {
					NavigationStack {
						AsyncAddressesView(addressType: .stun)
							.navigationTitle("STUN servers")
							.toolbar(content: {
								ToolbarItem(
									placement: .confirmationAction,
									content: {
										Button("Done") {
											showSTUNAddresses = false
										}
									})
							})
					}
				}
				.disabled(!appState.client.isNATEnabled())
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			}

			Section {
				Toggle("Ignore certain system files", isOn: userSettings.$ignoreExtraneousDefaultFiles)
			} header: {
				Text("System files")
			} footer: {
				Text(
					"When enabled, certain files that are created by the system (such as .DS_Store) will not be noticed as 'new files' in folders that are selectively synced. These files will still be synced in folders that are fully synchronized and when they are created by other devices."
				)
			}

			Section {
				Toggle("Cache thumbnails on disk", isOn: userSettings.$cacheThumbnailsToDisk)

				// Select thumbnail folder
				Picker("Cache location", selection: userSettings.$cacheThumbnailsToFolderID) {
					Text("On this device").tag("")
					ForEach(folders, id: \.folderID) { folder in
						Text(folder.displayName).tag(folder.folderID)
					}
					if !folders.contains(where: {
						$0.folderID == userSettings.cacheThumbnailsToFolderID
					}) {
						Text(userSettings.cacheThumbnailsToFolderID).disabled(true)
					}
				}
				.pickerStyle(.menu).disabled(!userSettings.cacheThumbnailsToDisk)

				// Clear thumbnail cache button
				if userSettings.cacheThumbnailsToFolderID == "" {
					Button("Clear thumbnail cache") {
						confirmClearThumbnailCache = true

					}.confirmationDialog(
						"Are you sure you want to clear the thumbnail cache?",
						isPresented: $confirmClearThumbnailCache, titleVisibility: .visible
					) {
						Button("Clear thumbnail cache", role: .destructive) {
							ImageCache.shared.clear()
							self.diskCacheSizeBytes = nil
						}
					}
				}
			} header: {
				Text("File previews")
			} footer: {
				self.cacheText
			}

			Section {
				Toggle("Enable debug logging", isOn: userSettings.$loggingToFileEnabled)
			} header: {
				Text("Logging")
			} footer: {
				if appState.userSettings.loggingToFileEnabled {
					if appState.isLoggingToFile {
						Text(
							"The app is logging to a file in the application folder, which you can share with the developers."
						)
					}
					else {
						Text(
							"After restarting the app, the app will write a log file in the application folder, which you can then share with the developers."
						)
					}
				}
				else {
					if appState.isLoggingToFile {
						Text("Restart the app to stop logging.")
					}
					else {
						Text(
							"Logging slows down the app and uses more battery. Only enable it if you are experiencing problems."
						)
					}
				}
			}

			#if os(iOS)
				Section {
					ExportButtonView()
				} footer: {
					if self.appState.client.isUsingCustomConfiguration {
						Text(
							"The app is currently using a custom configuration from config.xml in the application directory. Remove it and restart the app to revert back to the default configuration."
						)
					}
				}
			#endif

			#if os(macOS)
				Section {
					Button("Database maintenance") {
						self.showDatabaseMaintenance = true
					}
				}.buttonStyle(.link)
					.sheet(isPresented: $showDatabaseMaintenance) {
						NavigationStack {
							DatabaseMaintenanceView()
								.toolbar(content: {
									ToolbarItem(
										placement: .confirmationAction,
										content: {
											Button("Close") {
												showDatabaseMaintenance = false
											}
										})
								})
						}
					}

				Section {
					Button("Configuration settings") {
						self.showConfigurationSettings = true
					}
				}.buttonStyle(.link)
					.sheet(isPresented: $showConfigurationSettings) {
						ConfigurationSettingsView()
							.toolbar(content: {
								ToolbarItem(
									placement: .confirmationAction,
									content: {
										Button("Close") {
											showConfigurationSettings = false
										}
									})
							})
					}
			#else
				NavigationLink(destination: DatabaseMaintenanceView()) {
					Text("Database maintenance")
				}
			#endif
		}
		.task {
			await self.update()
		}
		.onDisappear {
			appState.applySettings()
		}
		.navigationTitle("Advanced settings")
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}

	private func update() async {
		self.folders = await appState.folders().sorted()
		Task {
			do {
				self.diskCacheSizeBytes = try await ImageCache.shared.diskCacheSizeBytes()
			}
			catch {
				Log.warn("Could not determine thumbnail cache size: \(error.localizedDescription)")
			}
		}
	}

	private var cacheText: Text {
		let formatter = ByteCountFormatter()
		var text = Text(
			"When the cache is enabled, thumbnails will load quicker and use less data when viewed more than once."
		)

		if let bytes = self.diskCacheSizeBytes {
			text =
				text
				+ Text(
					"Currently the thumbnail cache is using \(formatter.string(fromByteCount: Int64(bytes))) of disk space."
				)
		}

		if appState.userSettings.cacheThumbnailsToFolderID == "" {
			text =
				text + Text(" ")
				+ Text(
					"When disk space is scarce, the system may decide to remove some thumbnails in order to free up space."
				)
		}

		return text
	}
}

#if os(iOS)
	struct BackgroundSettingsView: View {
		@Environment(AppState.self) private var appState
		@ObservedObject var userSettings: AppUserSettings

		private let durationFormatter = DateComponentsFormatter()
		@State private var alertShown = false
		@State private var alertMessage = ""
		@State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

		init(userSettings: AppUserSettings) {
			self.userSettings = userSettings
			durationFormatter.allowedUnits = [.day, .hour, .minute]
			durationFormatter.unitsStyle = .abbreviated
		}

		var body: some View {
			Form {
				Section {
					Toggle("While charging (long)", isOn: userSettings.$longBackgroundSyncEnabled)
					Toggle("While on battery (short)", isOn: userSettings.$shortBackgroundSyncEnabled)
					Toggle("Briefly after leaving app", isOn: userSettings.$lingeringEnabled)
				} header: {
					Text("Background synchronization")
				} footer: {
					Text(
						"The operating system will periodically grant the app a few minutes of time in the background, depending on network connectivity and battery status."
					)
				}

				Section {
					if self.authorizationStatus == .notDetermined {
						Button("Enable notifications") {
							AppState.requestNotificationPermissionIfNecessary()
							self.updateNotificationStatus()
						}
					}
					else {
						Toggle(
							"When background synchronization completes",
							isOn: userSettings.$notifyWhenBackgroundSyncCompletes
						)
						.disabled(
							(!userSettings.longBackgroundSyncEnabled
								&& !userSettings.shortBackgroundSyncEnabled)
								|| (authorizationStatus != .authorized
									&& authorizationStatus != .provisional)
						)
					}
				} header: {
					Text("Notifications")
				}

				Section {
					if self.authorizationStatus != .notDetermined {
						Toggle(
							"When last synchronization happened long ago",
							isOn: userSettings.$watchdogNotificationEnabled
						)
						.disabled(
							authorizationStatus != .authorized
								&& authorizationStatus != .provisional
						)
						.onChange(of: userSettings.watchdogNotificationEnabled) {
							self.updateNotificationStatus()
						}

						if userSettings.watchdogNotificationEnabled {
							Stepper(
								"After \(userSettings.watchdogIntervalHours) hours",
								value: userSettings.$watchdogIntervalHours, in: 1...(24 * 7)
							)
						}
					}
				} footer: {
					if self.authorizationStatus == .denied {
						Text("Go to the Settings app to alllow notifications.")
					}
				}

				Section("Last background synchronization") {
					if let lastSyncRun = self.appState.backgroundManager.lastBackgroundSyncRun {
						Text("Started").badge(
							lastSyncRun.started.formatted(
								date: .abbreviated, time: .shortened))

						if let lastSyncEnded = lastSyncRun.ended {
							Text("Ended").badge(
								lastSyncEnded.formatted(
									date: .abbreviated, time: .shortened))
							Text("Duration").badge(
								durationFormatter.string(
									from: lastSyncEnded.timeIntervalSince(
										lastSyncRun.started)))
						}
					}
					else {
						Text("Started").badge("Never")
					}
				}

				let backgroundSyncs = appState.backgroundManager.backgroundSyncRuns
				if !backgroundSyncs.isEmpty {
					Section(
						"During the last 24 hours (\(durationFormatter.string(from: self.totalBackgroundSyncTime24Hours) ?? "0s"))"
					) {
						ForEach(backgroundSyncs, id: \.started) { (log: BackgroundSyncRun) in
							Text(log.asString)
						}
					}
				}

				Section {
					Text("Uptime").badge(
						durationFormatter.string(
							from: Date.now.timeIntervalSince(appState.launchedAt)))
				}
			}
			.task {
				updateNotificationStatus()
			}
			.onDisappear {
				Task.detached {
					_ = await self.appState.backgroundManager.scheduleBackgroundSync()
					await self.appState.backgroundManager.rescheduleWatchdogNotification()
				}
			}
			.navigationTitle("Background synchronization")
			.navigationBarTitleDisplayMode(.inline)
			.alert(
				isPresented: $alertShown,
				content: {
					Alert(title: Text("Background synchronization"), message: Text(alertMessage))
				})
		}

		private var totalBackgroundSyncTime24Hours: TimeInterval {
			var totalDuration: TimeInterval = 0.0
			for run in appState.backgroundManager.backgroundSyncRuns {
				if let ended = run.ended {
					totalDuration += ended.timeIntervalSince(run.started)
				}
			}
			return totalDuration
		}

		private func updateNotificationStatus() {
			UNUserNotificationCenter.current().getNotificationSettings { settings in
				self.authorizationStatus = settings.authorizationStatus
			}
		}
	}
#endif

private struct BandwidthSettingsView: View {
	@Environment(AppState.self) private var appState
	@ObservedObject var userSettings: AppUserSettings

	@State private var downLimitMbitsPerSec: Int = 0
	@State private var upLimitMbitsPerSec: Int = 0

	private func update() {
		self.downLimitMbitsPerSec = appState.client.getBandwidthLimitDownMbitsPerSec()
		self.upLimitMbitsPerSec = appState.client.getBandwidthLimitUpMbitsPerSec()
	}

	private func save() {
		try! appState.client.setBandwidthLimitsMbitsPerSec(downLimitMbitsPerSec, up: upLimitMbitsPerSec)
	}

	var body: some View {
		Form {
			Section("Limit file transfer bandwidth") {
				// Global down
				Toggle(
					"Limit receiving bandwidth",
					isOn: Binding(
						get: {
							return self.downLimitMbitsPerSec > 0
						},
						set: { self.downLimitMbitsPerSec = $0 ? 10 : 0 }
					))

				if downLimitMbitsPerSec > 0 {
					Stepper(
						"\(downLimitMbitsPerSec) Mbit/s",
						value: $downLimitMbitsPerSec, in: 1...100)
				}

				// Global up
				Toggle(
					"Limit sending bandwidth",
					isOn: Binding(
						get: {
							return self.upLimitMbitsPerSec > 0
						},
						set: { self.upLimitMbitsPerSec = $0 ? 10 : 0 }
					))

				if upLimitMbitsPerSec > 0 {
					Stepper(
						"\(upLimitMbitsPerSec) Mbit/s",
						value: $upLimitMbitsPerSec, in: 1...100)
				}

				// LAN bandwidth limit
				if upLimitMbitsPerSec > 0 || downLimitMbitsPerSec > 0 {
					Toggle(
						"Also limit in local networks",
						isOn: Binding(
							get: {
								return appState.client.isBandwidthLimitedInLAN()
							},
							set: { nv in
								try? appState.client.setBandwidthLimitedInLAN(nv)
							}))
				}
			}.task {
				self.update()
			}
			.onChange(of: [self.downLimitMbitsPerSec, self.upLimitMbitsPerSec]) { _, _ in
				self.save()
			}

			Section("Limit streaming") {
				Toggle(
					"Limit streaming bandwidth",
					isOn: Binding(
						get: {
							userSettings.streamingLimitMbitsPerSec > 0
						},
						set: { nv in
							if nv {
								userSettings.streamingLimitMbitsPerSec = 15
							}
							else {
								userSettings.streamingLimitMbitsPerSec = 0
							}
						}))

				if userSettings.streamingLimitMbitsPerSec > 0 {
					Stepper(
						"\(userSettings.streamingLimitMbitsPerSec) Mbit/s",
						value: userSettings.$streamingLimitMbitsPerSec, in: 1...100)
				}
			}

			// Thumbnail settings
			Section("Previews") {
				Toggle(
					"Show image previews",
					isOn: Binding(
						get: {
							return userSettings.maxBytesForPreview > 0
						},
						set: { nv in
							if nv {
								userSettings.maxBytesForPreview = 3 * 1024 * 1024  // 3 MiB
							}
							else {
								userSettings.maxBytesForPreview = 0
							}
						}))

				if userSettings.maxBytesForPreview > 0 {
					Stepper(
						"\(userSettings.maxBytesForPreview / 1024 / 1024) MB",
						value: Binding(
							get: {
								userSettings.maxBytesForPreview / 1024 / 1024
							},
							set: { nv in
								userSettings.maxBytesForPreview = nv * 1024 * 1024
							}), in: 1...100)
				}
			}

			Section {
				Toggle("Show video previews", isOn: userSettings.$previewVideos)
			}
		}
		.navigationTitle("Bandwidth limitations")
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}

#if os(macOS)
	struct TabbedSettingsView: View {
		@Environment(AppState.self) private var appState
		@Binding var hideInDock: Bool
		@State private var selection: String = "general"

		var body: some View {
			TabView(selection: $selection) {
				if appState.startupState == .started {
					Tab(
						value: "general",
						content: {
							GeneralSettingsView(userSettings: appState.userSettings, hideInDock: $hideInDock)
						},
						label: {
							Label("General", systemImage: "app.badge.checkmark.fill")
						})

					Tab(
						value: "bandwidth",
						content: {
							BandwidthSettingsView(userSettings: appState.userSettings)
						},
						label: {
							Label("Bandwidth", systemImage: "tachometer")
						})

					Tab(
						value: "photo",
						content: {
							PhotoBackupSettingsView(photoBackup: appState.photoBackup)
						},
						label: {
							Label("Photo back-up", systemImage: "photo")
						})

					Tab(
						value: "advanced",
						content: {
							AdvancedSettingsView(userSettings: appState.userSettings)
						},
						label: {
							Label("Advanced", systemImage: "gear")
						})
				}
			}
			.frame(minWidth: 500, minHeight: 450)
			.windowResizeBehavior(.automatic)
			.formStyle(.grouped)
		}
	}

	struct GeneralSettingsView: View {
		@Environment(AppState.self) private var appState
		@ObservedObject var userSettings: AppUserSettings
		@Binding var hideInDock: Bool

		var body: some View {
			Form {
				Section {
					TextField(
						"Device name",
						text: Binding(
							get: {
								var err: NSError? = nil
								return appState.client.getName(&err)
							},
							set: { nn in
								try? appState.client.setName(nn)
							}))
				}

				Section {
					Toggle(isOn: $hideInDock) {
						Label("Hide dock menu icon", systemImage: "eye.slash")
					}
				}

				Section {
					Picker("Folder access from menu", selection: userSettings.$menuFolderAction) {
						Text("Do not show folders").tag(MenuFolderAction.hide)
						Text("Open in Finder").tag(MenuFolderAction.finder)
						Text("Open in the app").tag(MenuFolderAction.browser)
						Text("Open in Finder, except selectively synced folders").tag(
							MenuFolderAction.finderExceptSelective)
					}.disabled(!hideInDock)
				}

				Section("View settings") {
					ViewSettingsView(userSettings: appState.userSettings)
				}
			}
		}
	}
#endif

#if os(iOS)
	struct SettingsView: View {
		@Environment(AppState.self) private var appState
		@ObservedObject var userSettings: AppUserSettings

		var limitsEnabled: Bool {
			return self.appState.userSettings.streamingLimitMbitsPerSec > 0
				|| self.appState.client.getBandwidthLimitUpMbitsPerSec() > 0
				|| self.appState.client.getBandwidthLimitDownMbitsPerSec() > 0
		}

		var body: some View {
			Form {
				Section("Device name") {
					TextField(
						"Host name",
						text: Binding(
							get: {
								var err: NSError? = nil
								return appState.client.getName(&err)
							},
							set: { nn in
								try? appState.client.setName(nn)
							})
					)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
					.keyboardType(.asciiCapable)
				}

				Section {
					NavigationLink("View settings") {
						ViewSettingsView(userSettings: userSettings)
					}

					NavigationLink(destination: BandwidthSettingsView(userSettings: userSettings)) {
						Text("Bandwidth limitations").badge(limitsEnabled ? "On" : "Off")
					}

					#if os(iOS)
						NavigationLink(destination: BackgroundSettingsView(userSettings: userSettings)) {
							Text("Background synchronization").badge(
								userSettings.longBackgroundSyncEnabled || userSettings.shortBackgroundSyncEnabled ? "On" : "Off")
						}
					#endif

					NavigationLink(destination: PhotoBackupSettingsView(photoBackup: appState.photoBackup)) {
						Text("Photo back-up")
							.badge(appState.photoBackup.isReady && appState.photoBackup.enableBackgroundCopy ? "On" : "Off")
					}

					NavigationLink("Advanced settings") {
						AdvancedSettingsView(userSettings: userSettings)
					}
				}

				Section {
					NavigationLink("Statistics") {
						TotalStatisticsView()
					}
				}

				Section {
					NavigationLink("About this app") {
						AboutView()
					}
				}
			}
			.navigationTitle("Settings")
			#if os(macOS)
				.formStyle(.grouped)
			#endif
		}
	}
#endif

struct ViewSettingsView: View {
	@ObservedObject var userSettings: AppUserSettings

	var body: some View {
		Form {
			Section {
				Toggle("Preview files on tap", isOn: userSettings.$tapFileToPreview)
			}

			Section {
				Toggle("Automatically switch to grid view", isOn: userSettings.$automaticallySwitchViewStyle)
			} footer: {
				Text("When a folder contains only images, it will automatically be shown as a grid instead of a list.")
			}

			Section {
				Toggle("Hide dotfiles", isOn: userSettings.$dotFilesHidden)
			} footer: {
				Text(
					"When enabled, files and directories whose name start with a dot will not be shown when browsing a folder. These files and directories will remain visible in search results."
				)
			}

			#if os(iOS)
				Section {
					Toggle(
						"Swipe between files when viewing",
						isOn: userSettings.$enableSwipeFilesInPreview)
				}
			#endif
		}
		.navigationTitle("View settings")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}

private struct AsyncAddressesView: View {
	@Environment(AppState.self) var appState

	let addressType: AddressType

	@State private var addresses: [String] = []

	var body: some View {
		AddressesView(
			addresses: $addresses,
			addressType: self.addressType
		)
		.task {
			await self.update()
		}
		.onChange(of: self.addresses) { _, _ in
			self.write()
		}
		.onDisappear {
			self.write()
		}
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}

	private func update() async {
		let client = self.appState.client
		let addressType = self.addressType
		self.addresses = await Task.detached {
			switch addressType {
			case .discovery:
				return client.discoveryAddresses()?.asArray() ?? []
			case .listening:
				return client.listenAddresses()?.asArray() ?? []
			case .device:
				// not supported
				return []
			case .stun:
				return client.stunAddresses()?.asArray() ?? []
			}
		}.value
	}

	private func write() {
		let addresses = self.addresses
		let appState = self.appState
		Task.detached {
			switch addressType {
			case .discovery:
				try appState.client.setDiscoveryAddresses(
					SushitrainListOfStrings.from(addresses))
			case .listening:
				try appState.client.setListenAddresses(SushitrainListOfStrings.from(addresses))
			case .device:
				// not supported
				abort()
			case .stun:
				try appState.client.setStunAddresses(
					SushitrainListOfStrings.from(addresses))
			}
		}
	}
}
