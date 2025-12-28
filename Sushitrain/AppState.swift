// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import Combine
import UserNotifications
import Network

struct StreamingProgress: Hashable, Equatable {
	var folder: String
	var path: String
	var bytesSent: Int64
	var bytesTotal: Int64
}

enum FolderMetric: String {
	case none = ""
	case localFileCount = "localFileCount"
	case localSize = "localSize"
	case globalFileCount = "globalFileCount"
	case globalSize = "globalSize"
	case localPercentage = "localPercentage"
}

enum DeviceMetric: String {
	case none = ""
	case latency = "latency"
	case needBytes = "needBytes"
	case needItems = "needItems"
	case completionPercentage = "completionPercentage"
	case shortID = "shortID"
	case lastSeenAgo = "lastSeenAgo"
	case lastAddress = "lastAddress"
}

#if os(macOS)
	enum MenuFolderAction: String, Hashable, Equatable {
		// Do not show folder shortcuts in menu
		case hide = "hide"

		// Always open the folder in the Finder
		case finder = "finder"

		// Always open the folder in the app
		case browser = "browser"

		// Open the folder in the Finder except when it is selectively synced
		case finderExceptSelective = "finderExceptSelective"
	}
#endif

enum AppStartupState: Equatable {
	case notStarted
	case onboarding
	case error(String)
	case started
}

class SushitrainDelegate: NSObject {
	fileprivate var appState: AppState

	required init(appState: AppState) {
		self.appState = appState
	}
}

@MainActor class AppUserSettings: ObservableObject {
	@AppStorage("backgroundSyncEnabled") var longBackgroundSyncEnabled: Bool = true
	@AppStorage("shortBackgroundSyncEnabled") var shortBackgroundSyncEnabled: Bool = false
	@AppStorage("notifyWhenBackgroundSyncCompletes") var notifyWhenBackgroundSyncCompletes: Bool = false
	@AppStorage("watchdogNotificationEnabled") var watchdogNotificationEnabled: Bool = false
	@AppStorage("watchdogIntervalHours") var watchdogIntervalHours: Int = 2 * 24  // 2 days
	@AppStorage("streamingLimitMbitsPerSec") var streamingLimitMbitsPerSec: Int = 0
	@AppStorage("maxBytesForPreview") var maxBytesForPreview: Int = 2 * 1024 * 1024  // 2 MiB
	@AppStorage("browserViewStyle") var defaultBrowserViewStyle: BrowserViewStyle = .list
	@AppStorage("browserViewFilter") var defaultBrowserViewFilterAvailability: BrowserViewFilterAvailability = .all
	@AppStorage("browserGridColumns") var browserGridColumns: Int = 3
	@AppStorage("loggingEnabled") var loggingToFileEnabled: Bool = false
	@AppStorage("dotFilesHidden") var dotFilesHidden: Bool = true
	@AppStorage("hideHiddenFolders") var hideHiddenFolders: Bool = false
	@AppStorage("lingeringEnabled") var lingeringEnabled: Bool = true
	@AppStorage("foldersViewMetric") var viewMetric: FolderMetric = .none
	@AppStorage("devicesViewMetric") var devicesViewMetric: DeviceMetric = .none
	@AppStorage("previewVideos") var previewVideos: Bool = false
	@AppStorage("tapFileToPreview") var tapFileToPreview: Bool = false
	@AppStorage("cacheThumbnailsToDisk") var cacheThumbnailsToDisk: Bool = true
	@AppStorage("cacheThumbnailsToFolderID") var cacheThumbnailsToFolderID: String = ""
	@AppStorage("showThumbnailsInSearchResults") var showThumbnailsInSearchResults: Bool = true
	@AppStorage("automaticallySwitchViewStyle") var automaticallySwitchViewStyle: Bool = true
	@AppStorage("automaticallyShowWebpages") var automaticallyShowWebpages: Bool = true
	@AppStorage("migratedToV2At") var migratedToV2At: Double = 0.0
	@AppStorage("userPausedDevices") var userPausedDevices = Set<String>()
	@AppStorage("ignoreLongTimeNoSeeDevices") var ignoreLongTimeNoSeeDevices = Set<String>()
	@AppStorage("ignoreDiscoveredDevices") var ignoreDiscoveredDevices = Set<String>()

	@AppStorage("onboardingVersionShown") var onboardingVersionShown = 0

	// Number of seconds after which we remind the user that a device hasn't connected in a while
	@AppStorage("longTimeNoSeeInterval") var longTimeNoSeeInterval = 86400.0 * 2.0  // two days

	// Whether to ignore certain files by default when scanning for extraneous files (i.e. .DS_Store)
	@AppStorage("ignoreExtraneousDefaultFiles") var ignoreExtraneousDefaultFiles: Bool = true

	// When did we apply privacy choices from the onboarding?
	@AppStorage("appliedOnboardingPrivacyChoicesAt") var appliedOnboardingPrivacyChoicesAt: Double = 0.0

	// Whether to show the onboarding on the next startup, regardless of whether it has been shown before
	@AppStorage("forceOnboardingOnNextStartup") var forceOnboardingOnNextStartup = false

	#if os(iOS)
		// Whether to re-enable hideHiddenFolders when app comes to the foreground
		@AppStorage("rehideHiddenFoldersOnActivate") var rehideHiddenFoldersOnActivate: Bool = false

		// Bookmarked places in the app
		@AppStorage("bookmarkedRoutes") var bookmarkedRoutes: [URL] = []
	#endif

	#if os(macOS)
		// The action to perform when a user clicks a folder in the dock menu
		@AppStorage("menuFolderAction") var menuFolderAction: MenuFolderAction = .finderExceptSelective
	#endif
}

struct SyncState {
	let isDownloading: Bool
	let isUploading: Bool
	let connectedPeerCount: Int

	var systemImage: String {
		if isDownloading && isUploading {
			return "arrow.up.arrow.down.circle.fill"
		}
		else if isDownloading {
			return "arrow.down.circle.fill"
		}
		else if isUploading {
			return "arrow.up.circle.fill"
		}
		else if connectedPeerCount > 0 {
			return "checkmark.circle.fill"
		}
		return "network.slash"
	}
}

@Observable @MainActor class AppState {
	private static let currentOnboardingVersion = 1

	@ObservationIgnored nonisolated let client: SushitrainClient
	@ObservationIgnored var photoBackup = PhotoBackup()
	@ObservationIgnored var changePublisher = PassthroughSubject<Void, Never>()
	@ObservationIgnored var pathMonitor: NWPathMonitor? = nil
	@ObservationIgnored var pingTimer: Timer? = nil

	var isLoggingToFile: Bool = false

	private(set) var userSettings = AppUserSettings()
	private(set) var localDeviceID: String = ""
	private(set) var eventCounter: Int = 0
	private(set) var foldersWithExtraFiles: [String] = []
	private(set) var startupState: AppStartupState = .notStarted
	private(set) var isMigratedToNewDatabase: Bool = false
	private(set) var syncState: SyncState = SyncState(isDownloading: false, isUploading: false, connectedPeerCount: 0)
	private(set) var launchedAt = Date.now

	fileprivate(set) var discoveredDevices: [String: [String]] = [:]
	fileprivate(set) var resolvedListenAddresses = Set<String>()
	fileprivate(set) var streamingProgress: StreamingProgress? = nil
	fileprivate(set) var lastChanges: [SushitrainChange] = []
	fileprivate(set) var currentNetworkPath: NWPath? = nil

	private let documentsDirectory: URL
	private let configDirectory: URL
	private var changeCancellable: AnyCancellable? = nil

	#if os(iOS)
		@ObservationIgnored var backgroundManager: BackgroundManager!
		@ObservationIgnored private var lingerManager: LingerManager!
		private(set) var isSuspended = false
	#endif

	static private var defaultIgnoredExtraneousFiles = [
		".DS_Store", "Thumbs.db", "desktop.ini", ".Trashes", ".Spotlight-V100",
		".DocumentRevisions-V100", ".TemporaryItems", "$RECYCLE.BIN", "@eaDir",
	]
	static let removeMigratedV1DatabaseAfterSeconds: TimeInterval = 7 * 86400.0  // 7 days
	static let maxChanges = 25

	init(client: SushitrainClient, documentsDirectory: URL, configDirectory: URL) {
		self.client = client
		self.documentsDirectory = documentsDirectory
		self.configDirectory = configDirectory

		#if os(iOS)
			self.backgroundManager = BackgroundManager(appState: self)
			self.lingerManager = LingerManager(appState: self)
		#endif

		self.changeCancellable = self.changePublisher.throttle(
			for: .seconds(0.5), scheduler: RunLoop.main, latest: true
		).sink { [weak self] _ in
			if let s = self {
				s.eventCounter += 1
				s.update()
			}
		}
	}

	private func resolveBookmarks() {
		let folderIDs = client.folders()?.asArray() ?? []
		for folderID in folderIDs {
			do {
				if let bm = try BookmarkManager.shared.resolveBookmark(folderID: folderID) {
					Log.info("We have a bookmark for folder \(folderID): \(bm)")
					if let folder = client.folder(withID: folderID) {
						let resolvedPath = bm.path(percentEncoded: false)
						let oldPath = folder.path()
						if oldPath != resolvedPath {
							Log.info(
								"Changing the path for folder '\(folderID)' after resolving bookmark: \(resolvedPath) (old path was \(oldPath)")
							try folder.setPath(resolvedPath)
						}
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
	}

	@MainActor func start() async {
		if self.startupState != .notStarted || self.startupState != .onboarding {
			assertionFailure("cannot start again")
		}

		let client = self.client

		// If we are called again from onboarding, skip the stuff we already did
		if self.startupState == .notStarted {
			self.isMigratedToNewDatabase = !client.hasLegacyDatabase()

			#if os(iOS)
				// If we are not migrated and we are in the background, bail out. We want to migrate in the foreground only
				if !self.isMigratedToNewDatabase && UIApplication.shared.applicationState == .background {
					Log.warn(
						"The app is started in the background but it still has a legacy database. Please open it in the foreground to upgrade the database."
					)
					self.startupState = .error(
						String(localized: "The app needs to be opened in the foreground at least once to upgrade the database."))
					return
				}
			#endif

			let resetDeltas = UserDefaults.standard.bool(forKey: "resetDeltas")
			if resetDeltas {
				Log.info("Reset deltas requested from settings")
			}

			do {
				// Load the client
				try await Task.detached(priority: .userInitiated) {
					// This one opens the database, migrates stuff, etc. and may take a while
					Log.info("Loading the client...")
					try client.load(resetDeltas)
					if resetDeltas {
						UserDefaults.standard.setValue(false, forKey: "resetDeltas")
					}
					Log.info("Client loaded")
				}.value

				// Resolve bookmarks
				self.resolveBookmarks()

				await self.updateDeviceSuspension()

				let folderIDs = client.folders()?.asArray() ?? []

				// Do we need to pause all folders?
				let pauseAllFolders = UserDefaults.standard.bool(forKey: "pauseAllFolders")
				if pauseAllFolders {
					Log.info("Pausing all folders at the user's request...")
					UserDefaults.standard.setValue(false, forKey: "pauseAllFolders")
					for folder in folderIDs {
						do {
							let folder = client.folder(withID: folder)
							try folder?.setPaused(true)
						}
						catch {
							Log.warn("Failed to pause folder '\(folder)' on startup: " + error.localizedDescription)
						}
					}
				}

				// Other housekeeping
				FolderSettingsManager.shared.removeSettingsForFoldersNotIn(Set(folderIDs))
			}
			catch let error {
				Log.warn("Could not start: \(error.localizedDescription)")
				self.startupState = .error(error.localizedDescription)

				#if os(macOS)
					self.alert(message: error.localizedDescription)
				#endif
			}
		}

		if case .error(_) = self.startupState {
			Log.warn("Not starting up as client load failed earlier.")
			return
		}

		// Check if we need to show onboarding; if so, we interrupt the startup process here and come back later
		if self.startupState == .notStarted {
			Log.info(
				"Current onboarding version is \(Self.currentOnboardingVersion), user last saw \(self.userSettings.onboardingVersionShown)"
			)

			if userSettings.onboardingVersionShown < Self.currentOnboardingVersion || userSettings.forceOnboardingOnNextStartup {
				Log.info("Showing onboarding")
				self.startupState = .onboarding
				// OnboardingView will call start() again after finishing
				return
			}
		}
		else if self.startupState == .onboarding {
			// We just came out of onboarding, update the version so it is not shown again
			userSettings.forceOnboardingOnNextStartup = false
			userSettings.onboardingVersionShown = Self.currentOnboardingVersion
			try? await Task.sleep(for: .seconds(1))
		}

		do {
			// Start the client
			try await Task.detached(priority: .userInitiated) {
				// Showtime!
				Log.info("Starting client...")
				try client.start()
				Log.info("Client started")
			}.value

			// Check to see if we have migrated
			self.isMigratedToNewDatabase = !client.hasLegacyDatabase()
			Log.info("Performing app migrations...")
			self.performMigrations()

			Log.info("Configuring the user interface...")
			self.applySettings()
			self.update()
			Task {
				await self.updateBadge()
			}
			self.protectFiles()
			self.startNetworkMonitor()
			self.startupState = .started
			Log.info("Ready to go")
		}
		catch let error {
			Log.warn("Could not start: \(error.localizedDescription)")
			self.startupState = .error(error.localizedDescription)

			#if os(macOS)
				self.alert(message: error.localizedDescription)
			#endif
		}
	}

	@MainActor private func stopNetworkMonitor() {
		if let pm = self.pathMonitor {
			pm.cancel()
			self.pathMonitor = nil
		}
		if let t = self.pingTimer {
			t.invalidate()
			self.pingTimer = nil
		}
	}

	@MainActor private func startNetworkMonitor() {
		self.stopNetworkMonitor()

		let pm = NWPathMonitor()
		pm.pathUpdateHandler = { [weak client] path in
			Task { @MainActor in
				Log.info("Network path change: \(path)")
				self.currentNetworkPath = path
				await self.updateDeviceSuspension()
			}

			if let measurement = client?.measurements {
				Task {
					try? await goTask {
						measurement.measure()
					}
				}
			}
		}

		pm.start(queue: .main)
		self.currentNetworkPath = pm.currentPath
		Task {
			await self.updateDeviceSuspension()
		}
		self.pathMonitor = pm

		self.pingTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak client] timer in
			if let measurement = client?.measurements {
				Task {
					try? await goTask {
						measurement.measure()
					}
				}
			}
		}
	}

	func protectFiles() {
		// Set data protection for config file and keys
		let configDirectoryURL = self.configDirectory
		let files = [SushitrainConfigFileName, SushitrainKeyFileName, SushitrainCertFileName]
		for file in files {
			do {
				let fileURL = configDirectoryURL.appendingPathComponent(file, isDirectory: false)
				try (fileURL as NSURL).setResourceValue(
					URLFileProtection.completeUntilFirstUserAuthentication,
					forKey: .fileProtectionKey)
				Log.info("Data protection class set for \(fileURL)")
			}
			catch {
				Log.warn(
					"Error setting data protection class for \(file): \(error.localizedDescription)"
				)
			}
		}
	}

	func applySettings() {
		ImageCache.shared.diskCacheEnabled = self.userSettings.cacheThumbnailsToDisk
		if !self.userSettings.cacheThumbnailsToFolderID.isEmpty,
			let folder = self.client.folder(withID: self.userSettings.cacheThumbnailsToFolderID)
		{
			// Check if we have this folder
			ImageCache.shared.customCacheDirectory = folder.localNativeURL
		}
		else {
			ImageCache.shared.customCacheDirectory = nil
		}
		Log.info(
			"Apply settings: image cache enabled \(ImageCache.shared.diskCacheEnabled) dir: \(ImageCache.shared.customCacheDirectory.debugDescription)"
		)

		self.client.server?.maxMbitsPerSecondsStreaming = Int64(self.userSettings.streamingLimitMbitsPerSec)
		Log.info("Apply settings: streaming limit=\(self.userSettings.streamingLimitMbitsPerSec) mbits/s")

		do {
			if self.userSettings.ignoreExtraneousDefaultFiles {
				let json = try JSONEncoder().encode(Self.defaultIgnoredExtraneousFiles)
				try self.client.setExtraneousIgnoredJSON(json)
				Log.info("Applied setting: default ignore extraneous files \(json)")
			}
			else {
				let json = try JSONEncoder().encode([] as [String])
				try self.client.setExtraneousIgnoredJSON(json)
				Log.info("Applied setting: default ignore extraneous files \(json)")
			}
		}
		catch {
			Log.warn("Could not set default ignored extraneous files: \(error.localizedDescription)")
		}
	}

	private func updateExtraneousFiles() async {
		// List folders that have extra files
		let folders = await self.folders()
		self.foldersWithExtraFiles = await
			(Task.detached {
				var myFoldersWithExtraFiles: [String] = []
				for folder in folders {
					if Task.isCancelled {
						break
					}
					if folder.isIdle {
						var hasExtra: ObjCBool = false
						let _ = try? folder.hasExtraneousFiles(&hasExtra)
						if hasExtra.boolValue {
							myFoldersWithExtraFiles.append(folder.folderID)
						}
					}
				}
				return myFoldersWithExtraFiles
			}).value
	}

	var isFinished: Bool {
		return !self.client.isDownloading() && !self.client.isUploading() && !self.photoBackup.isBackingUp
	}

	func alert(message: String) {
		Self.modalAlert(message: message)
	}

	@MainActor
	static func modalAlert(message: String) {
		#if os(macOS)
			let nsa = NSAlert()
			nsa.messageText = message
			nsa.runModal()
		#else
			// Error message may end up on the wrong window on the iPad
			if let twnd = UIApplication
				.shared
				.connectedScenes
				.flatMap({ ($0 as? UIWindowScene)?.windows ?? [] })
				.last(where: { $0.isKeyWindow })
			{
				if let trc = twnd.rootViewController {
					let uac = UIAlertController(
						title: String(localized: "An error has occurred"), message: message,
						preferredStyle: .alert)
					uac.addAction(
						UIAlertAction(title: String(localized: "Dismiss"), style: .default))
					trc.present(uac, animated: true)
				}
			}
		#endif
	}

	func update() {
		self.localDeviceID = self.client.deviceID()
		self.syncState = SyncState(
			isDownloading: self.client.isDownloading(),
			isUploading: self.client.isUploading(),
			connectedPeerCount: self.client.connectedPeerCount()
		)

		Task {
			await self.updateBadge()
		}
	}

	nonisolated func getPeersNotSeenForALongTime() async -> [SushitrainPeer] {
		let interval = await self.userSettings.longTimeNoSeeInterval
		let ignored = await self.userSettings.ignoreLongTimeNoSeeDevices

		let p = await self.peers()
		return p.filter {
			if ignored.contains($0.deviceID()) {
				return false
			}

			if $0.isPaused() {
				return false
			}

			if let d = $0.lastSeen()?.date() {
				return -d.timeIntervalSinceNow > interval
			}
			return false
		}
	}

	nonisolated func folders() async -> [SushitrainFolder] {
		let client = self.client
		let folderIDs = client.folders()?.asArray() ?? []
		var folderInfos: [SushitrainFolder] = []
		for fid in folderIDs {
			let folderInfo = client.folder(withID: fid)!
			folderInfos.append(folderInfo)
		}
		return folderInfos
	}

	// Perform several changes we need to do between versions
	private func performMigrations() {
		// Perform build-specific migrations
		let lastRunBuild = UserDefaults.standard.integer(forKey: "lastRunBuild")
		let currentBuild = Int(Bundle.main.buildVersionNumber ?? "0") ?? 0
		Log.info("Migrations: current build is \(currentBuild), last run build \(lastRunBuild)")

		if lastRunBuild < currentBuild {
			#if os(macOS)
				// From build 19 onwards, enable fs watching for all folders by default. It can later be disabled
				if lastRunBuild <= 18 {
					Log.info("Enabling FS watching for all folders")
					self.client.setFSWatchingEnabledForAllFolders(true)
				}
			#endif

			#if os(iOS)
				// From build 26 onwards, FS watching is supported on iOS, but it should not be enabled by default
				if lastRunBuild <= 26 {
					Log.info("Disabling FS watching for all folders")
					self.client.setFSWatchingEnabledForAllFolders(false)
				}
			#endif
		}
		UserDefaults.standard.set(currentBuild, forKey: "lastRunBuild")

		// Fix up invalid settings
		if self.userSettings.defaultBrowserViewStyle == .web {
			self.userSettings.defaultBrowserViewStyle = .thumbnailList
		}

		// See if we should remove the old index
		if client.hasLegacyDatabase() {
			// This shouldn't happen...
			self.userSettings.migratedToV2At = -1.0
		}
		else {
			if self.userSettings.migratedToV2At.isZero || self.userSettings.migratedToV2At < 0 {
				self.userSettings.migratedToV2At = Date().timeIntervalSinceReferenceDate
			}

			let migratedAgo = Date.timeIntervalSinceReferenceDate - self.userSettings.migratedToV2At
			Log.info(
				"Migrated to v2 since \(self.userSettings.migratedToV2At), which is \(migratedAgo)s ago, hasMigratedLegacyDatabase=\(client.hasMigratedLegacyDatabase())"
			)
			if self.client.hasMigratedLegacyDatabase() && migratedAgo > Self.removeMigratedV1DatabaseAfterSeconds {
				Log.info("Removing migrated legacy database")
				Task {
					try? self.client.clearMigratedLegacyDatabase()
				}
			}
		}
	}

	func isDevicePausedByUser(_ device: SushitrainPeer) -> Bool {
		return self.userSettings.userPausedDevices.contains(device.id)
	}

	func setDevice(_ device: SushitrainPeer, pausedByUser: Bool) {
		self.userSettings.userPausedDevices.toggle(device.id, pausedByUser)
		Task {
			await self.updateDeviceSuspension()
		}
	}

	nonisolated func peers() async -> [SushitrainPeer] {
		let client = self.client
		let peerIDs = client.peers()!.asArray()

		var peers: [SushitrainPeer] = []
		for peerID in peerIDs {
			let peerInfo = client.peer(withID: peerID)!
			peers.append(peerInfo)
		}
		return peers
	}

	func updateBadge() async {
		await self.updateExtraneousFiles()
		let numExtra = self.foldersWithExtraFiles.count
		let numLongTimeNoSee = (await getPeersNotSeenForALongTime()).count
		let numTotal = numExtra + numLongTimeNoSee

		#if os(iOS)
			DispatchQueue.main.async {
				UNUserNotificationCenter.current().setBadgeCount(numTotal)
			}
		#elseif os(macOS)
			let newBadge = numTotal > 0 ? String(numTotal) : ""
			if NSApplication.shared.dockTile.badgeLabel != newBadge {
				Log.info("Set dock tile badgeLabel \(numTotal)")
			}
			NSApplication.shared.dockTile.showsApplicationBadge = numTotal > 0
			NSApplication.shared.dockTile.badgeLabel = newBadge
			NSApplication.shared.dockTile.display()
		#endif
	}

	private nonisolated func rebindServer() async {
		let client = self.client
		Log.info("(Re-)activate streaming server")
		do {
			try client.server?.listen()
		}
		catch let error {
			Log.warn("Error activating streaming server: " + error.localizedDescription)
		}
	}

	#if os(iOS)
		func suspend(_ suspended: Bool) async {
			self.isSuspended = suspended
			await self.updateDeviceSuspension()
		}
	#endif

	nonisolated func updateDeviceSuspension() async {
		do {
			let client = self.client
			// On iOS, all devices are paused when the app is suspended (and unpaused when we get back to the foreground)
			// This is a trick to force Syncthing to start connecting immediately when we are foregrounded
			#if os(iOS)
				if await self.isSuspended {
					try client.setDevicesPaused(SushitrainListOfStrings.from(Array()), pause: false)
					return
				}
			#endif

			// On macOS and when the app is in the foreground, we unpause any device that is not explicitly suspended
			// by the user
			if let peers = self.client.peers() {
				let devicesEnabled = Set(peers.asArray()).subtracting(await self.userSettings.userPausedDevices)
				try client.setDevicesPaused(SushitrainListOfStrings.from(Array(devicesEnabled)), pause: false)
			}
		}
		catch {
			#if os(iOS)
				Log.warn("Failed to update device suspension (isSuspended=\(await self.isSuspended): \(error.localizedDescription)")
			#else
				Log.warn("Failed to update device suspension: \(error.localizedDescription)")
			#endif
		}
	}

	func awake() async {
		self.startNetworkMonitor()

		#if os(iOS)
			if self.userSettings.rehideHiddenFoldersOnActivate {
				self.userSettings.hideHiddenFolders = true
			}
		#endif

		// Re-resolve bookmarks, in some cases apps may have updated and their paths changed
		self.resolveBookmarks()

		#if os(iOS)
			self.lingerManager.cancelLingering()
			Task.detached {
				dispatchPrecondition(condition: .notOnQueue(.main))
				try? self.client.setReconnectIntervalS(1)
				await self.suspend(false)
				await self.backgroundManager.rescheduleWatchdogNotification()
				await self.rebindServer()
			}
			self.client.ignoreEvents = false
		#endif
	}

	#if os(iOS)
		private var bookmarkedRoutesAsRoute: [Route] {
			return self.userSettings.bookmarkedRoutes.compactMap { url in
				return Route(url: url)
			}
		}
	#endif

	func sleep() async {
		self.stopNetworkMonitor()

		#if os(iOS)
			QuickActionService.provideActions(bookmarks: self.bookmarkedRoutesAsRoute)

			if userSettings.lingeringEnabled {
				Log.info("Background time remaining: \(UIApplication.shared.backgroundTimeRemaining)")
				await self.lingerManager.lingerThenSuspend()
				Log.info(
					"Background time remaining (2): \(UIApplication.shared.backgroundTimeRemaining)"
				)
			}
			else {
				await self.suspend(true)
			}
			try? self.client.setReconnectIntervalS(60)
			self.client.ignoreEvents = true

			Task {
				try? await goTask {
					SushitrainClearBlockCache()
				}
			}
		#endif

		Task {
			await self.updateBadge()
		}
	}

	func reduceMemoryUsage() {
		ImageCache.clearMemoryCache()

		Task {
			try? await goTask {
				SushitrainClearBlockCache()
				SushitrainTriggerGC()
			}
		}
	}

	func onScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
		Log.info("Phase change from \(oldPhase) to \(newPhase) lingeringEnabled=\(self.userSettings.lingeringEnabled)")

		switch newPhase {
		case .background:
			#if os(iOS)
				if self.backgroundManager.runningContinuedTask != nil {
					Log.info("Going to background, but not sleeping or lingering, as we are running a continued task")
					return
				}
			#endif

			Task {
				await self.sleep()
			}
			break

		case .inactive:
			Task {
				await self.updateBadge()
				#if os(iOS)
					self.backgroundManager.inactivate()
					self.reduceMemoryUsage()
					QuickActionService.provideActions(bookmarks: self.bookmarkedRoutesAsRoute)
				#endif
			}
			#if os(iOS)
				self.client.ignoreEvents = true
			#endif
			break

		case .active:
			Task {
				await self.awake()
			}
			break

		@unknown default:
			break
		}
	}

	func isInsideDocumentsFolder(_ url: URL) -> Bool {
		return url.resolvingSymlinksInPath().path(percentEncoded: false)
			.hasPrefix(documentsDirectory.resolvingSymlinksInPath().path(percentEncoded: false))
	}

	static func requestNotificationPermissionIfNecessary() {
		UNUserNotificationCenter.current().getNotificationSettings { settings in
			Log.info("Notification auth status: \(settings.authorizationStatus)")
			if settings.authorizationStatus == .notDetermined {
				let options: UNAuthorizationOptions = [.alert, .badge, .provisional]
				UNUserNotificationCenter.current().requestAuthorization(options: options) {
					(status, error) in
					Log.info(
						"Notifications requested: \(status) \(error?.localizedDescription ?? "")"
					)
				}
			}
		}
	}
}

#if os(iOS)
	@MainActor
	private class LingerManager {
		unowned var appState: AppState
		private var wantsSuspendAfterLinger = false
		private var lingerTask: UIBackgroundTaskIdentifier? = nil
		private var lingerTimer: Timer? = nil

		init(appState: AppState) {
			self.appState = appState
		}

		func cancelLingering() {
			if let lt = self.lingerTask {
				Log.info("Cancel lingering lingerTask=\(lt)")
				UIApplication.shared.endBackgroundTask(lt)
				self.lingerTask = nil
			}

			if let lt = self.lingerTimer {
				Log.info("Invalidate lingering timer=\(lt)")
				lt.invalidate()
				self.lingerTimer = nil
			}

			self.wantsSuspendAfterLinger = false
		}

		// Called when we end our lingering task by ourselves. This should perform the same duties as lingeringExpired
		// but in a more orderly way.
		private func afterLingering() async {
			Log.info("After lingering: suspend=\(self.wantsSuspendAfterLinger)")
			if self.wantsSuspendAfterLinger {
				self.wantsSuspendAfterLinger = false
				await self.appState.suspend(true)
			}
			self.cancelLingering()
		}

		// Called when the system expires our lingering background task. This should perform the same tasks as afterLingering,
		// but it should prioritize calling endBackgroundTask (synchronously).
		private func lingeringExpired() {
			Log.info("Suspend after expiration of linger time")
			let wantsSuspend = self.wantsSuspendAfterLinger
			self.cancelLingering()

			if wantsSuspend {
				self.wantsSuspendAfterLinger = false
				// This task may or may not be executed in time...
				Task {
					await self.appState.suspend(true)
				}
			}
		}

		func lingerThenSuspend() async {
			Log.info("Linger then suspend")

			if self.appState.isSuspended {
				// Already suspended?
				Log.info("Already suspended (suspended peer list is not empty), not lingering")
				await self.afterLingering()
				return
			}

			self.wantsSuspendAfterLinger = true
			if self.lingerTask == nil {
				self.lingerTask = UIApplication.shared.beginBackgroundTask(
					withName: "Short-term connection persistence",
					expirationHandler: {
						self.lingeringExpired()
					})
				Log.info(
					"Lingering before suspend: \(UIApplication.shared.backgroundTimeRemaining) remaining"
				)
			}

			// Try to stay awake for 3/4th of the estimated background time remaining, at most 29s
			// (at 30s the system appears to terminate)
			let lingerTime = min(29.0, UIApplication.shared.backgroundTimeRemaining * 3.0 / 4.0)
			let minimumLingerTime: TimeInterval = 1.0  // Don't bother if we get less than one second
			if lingerTime < minimumLingerTime {
				Log.info("Lingering time allotted by the system is too short, suspending immediately")
				return await afterLingering()
			}

			if self.lingerTimer?.isValid != true {
				Log.info("Start lingering timer for \(lingerTime)")
				self.lingerTimer = Timer.scheduledTimer(withTimeInterval: lingerTime, repeats: false) {
					_ in
					Task { @MainActor in
						Log.info("Suspend after linger")
						await self.afterLingering()
					}
				}
			}
		}
	}
#endif

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
			appState.update()
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

	func onMeasurementsUpdated() {
		// For now just trigger an event update
		let appState = self.appState
		DispatchQueue.main.async {
			appState.changePublisher.send()
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
