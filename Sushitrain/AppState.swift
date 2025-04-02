// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore
import Combine
import UserNotifications

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
	case error(String)
	case started
}

@MainActor class AppState: ObservableObject {
	var client: SushitrainClient
	private let documentsDirectory: URL
	private let configDirectory: URL

	@Published var localDeviceID: String = ""
	@Published var eventCounter: Int = 0
	@Published var discoveredDevices: [String: [String]] = [:]
	@Published var resolvedListenAddresses = Set<String>()
	@Published var launchedAt = Date.now
	@Published var streamingProgress: StreamingProgress? = nil
	@Published var lastChanges: [SushitrainChange] = []
	@Published var isLogging: Bool = false
	@Published var foldersWithExtraFiles: [String] = []
	@Published var startupState: AppStartupState = .notStarted
	@Published var isMigratedToNewDatabase: Bool = false

	#if os(iOS)
		@Published var currentAction: QuickAction? = nil
	#endif

	@AppStorage("backgroundSyncEnabled") var longBackgroundSyncEnabled: Bool = true
	@AppStorage("shortBackgroundSyncEnabled") var shortBackgroundSyncEnabled: Bool = false
	@AppStorage("notifyWhenBackgroundSyncCompletes") var notifyWhenBackgroundSyncCompletes: Bool = false
	@AppStorage("watchdogNotificationEnabled") var watchdogNotificationEnabled: Bool = false
	@AppStorage("watchdogIntervalHours") var watchdogIntervalHours: Int = 2 * 24  // 2 days
	@AppStorage("streamingLimitMbitsPerSec") var streamingLimitMbitsPerSec: Int = 0
	@AppStorage("maxBytesForPreview") var maxBytesForPreview: Int = 2 * 1024 * 1024  // 2 MiB
	@AppStorage("browserViewStyle") var browserViewStyle: BrowserViewStyle = .list
	@AppStorage("browserGridColumns") var browserGridColumns: Int = 3
	@AppStorage("loggingEnabled") var loggingEnabled: Bool = false
	@AppStorage("dotFilesHidden") var dotFilesHidden: Bool = true
	@AppStorage("hideHiddenFolders") var hideHiddenFolders: Bool = false
	@AppStorage("lingeringEnabled") var lingeringEnabled: Bool = true
	@AppStorage("foldersViewMetric") var viewMetric: FolderMetric = .none
	@AppStorage("previewVideos") var previewVideos: Bool = false
	@AppStorage("tapFileToPreview") var tapFileToPreview: Bool = false
	@AppStorage("cacheThumbnailsToDisk") var cacheThumbnailsToDisk: Bool = true
	@AppStorage("cacheThumbnailsToFolderID") var cacheThumbnailsToFolderID: String = ""
	@AppStorage("showThumbnailsInSearchResults") var showThumbnailsInSearchResults: Bool = true
	@AppStorage("enableSwipeFilesInPreview") var enableSwipeFilesInPreview: Bool = true

	// Whether to ignore certain files by default when scanning for extraneous files (i.e. .DS_Store)
	@AppStorage("ignoreExtraneousDefaultFiles") var ignoreExtraneousDefaultFiles: Bool = true

	#if os(macOS)
		@AppStorage("menuFolderAction") var menuFolderAction: MenuFolderAction = .finderExceptSelective
	#endif

	static private var defaultIgnoredExtraneousFiles = [
		".DS_Store", "Thumbs.db", "desktop.ini", ".Trashes", ".Spotlight-V100",
		".DocumentRevisions-V100", ".TemporaryItems", "$RECYCLE.BIN", "@eaDir",
	]

	var photoSync = PhotoSynchronisation()

	var changePublisher = PassthroughSubject<Void, Never>()
	private var changeCancellable: AnyCancellable? = nil

	#if os(iOS)
		// The IDs of the peers that were suspended when the app last entered background, and should be re-enabled when the
		// app enters the foreground state.
		var suspendedPeerIds: [String] {
			get {
				return UserDefaults.standard.array(forKey: "suspendedPeerIds") as? [String] ?? []
			}
			set(newValue) {
				UserDefaults.standard.set(newValue, forKey: "suspendedPeerIds")
			}
		}

		var backgroundManager: BackgroundManager!
		private var lingerManager: LingerManager!

		var isSuspended: Bool {
			return !self.suspendedPeerIds.isEmpty
		}
	#endif

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

	@MainActor func start() {
		if self.startupState != .notStarted {
			assertionFailure("cannot start again")
		}

		self.isMigratedToNewDatabase = !client.hasOldDatabase()

		let client = self.client
		DispatchQueue.global(qos: .userInitiated).async {
			do {
				// This one opens the database, migrates stuff, etc. and may take a while
				Log.info("Starting the client...")
				try client.start()
				Log.info("Client started")

				DispatchQueue.main.async {
					// Check to see if we have migrated
					self.isMigratedToNewDatabase = !client.hasOldDatabase()
					Log.info("Performing app migrations...")
					self.performMigrations()
					
					Log.info("Configuring the user interface...")
					self.applySettings()
					self.update()
					Task {
						await self.updateBadge()
					}
					self.protectFiles()
					Log.info("Ready to go")
					self.startupState = .started
				}
			}
			catch let error {
				Log.warn("Could not start: \(error.localizedDescription)")

				DispatchQueue.main.async {
					self.startupState = .error(error.localizedDescription)

					#if os(macOS)
						self.alert(message: error.localizedDescription)
					#endif
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
		ImageCache.diskCacheEnabled = self.cacheThumbnailsToDisk
		if !self.cacheThumbnailsToFolderID.isEmpty,
			let folder = self.client.folder(withID: self.cacheThumbnailsToFolderID)
		{
			// Check if we have this folder
			ImageCache.customCacheDirectory = folder.localNativeURL
		}
		else {
			ImageCache.customCacheDirectory = nil
		}
		Log.info(
			"Apply settings: image cache enabled \(ImageCache.diskCacheEnabled) dir: \(ImageCache.customCacheDirectory.debugDescription)"
		)

		self.client.server?.maxMbitsPerSecondsStreaming = Int64(self.streamingLimitMbitsPerSec)
		Log.info("Apply settings: streaming limit=\(self.streamingLimitMbitsPerSec) mbits/s")

		do {
			if self.ignoreExtraneousDefaultFiles {
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
		let folders = self.folders()
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
		return !self.client.isDownloading() && !self.client.isUploading() && !self.photoSync.isSynchronizing
	}

	@MainActor
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

	@MainActor
	func update() {
		let devID = self.client.deviceID()
		DispatchQueue.main.async {
			self.localDeviceID = devID

			Task {
				await self.updateBadge()
			}
		}
	}

	func folders() -> [SushitrainFolder] {
		let folderIDs = self.client.folders()?.asArray() ?? []
		var folderInfos: [SushitrainFolder] = []
		for fid in folderIDs {
			let folderInfo = self.client.folder(withID: fid)!
			folderInfos.append(folderInfo)
		}
		return folderInfos
	}

	// Perform several changes we need to do between versions
	private func performMigrations() {
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
	}

	@MainActor
	func peerIDs() -> [String] {
		return self.client.peers()?.asArray() ?? []
	}

	@MainActor
	func peers() -> [SushitrainPeer] {
		let peerIDs = self.client.peers()!.asArray()

		var peers: [SushitrainPeer] = []
		for peerID in peerIDs {
			let peerInfo = self.client.peer(withID: peerID)!
			peers.append(peerInfo)
		}
		return peers
	}

	func updateBadge() async {
		await self.updateExtraneousFiles()
		let numExtra = self.foldersWithExtraFiles.count
		#if os(iOS)
			DispatchQueue.main.async {
				UNUserNotificationCenter.current().setBadgeCount(numExtra)
			}
		#elseif os(macOS)
			let newBadge = numExtra > 0 ? String(numExtra) : ""
			if NSApplication.shared.dockTile.badgeLabel != newBadge {
				Log.info("Set dock tile badgeLabel \(numExtra)")
			}
			NSApplication.shared.dockTile.showsApplicationBadge = numExtra > 0
			NSApplication.shared.dockTile.badgeLabel = newBadge
			NSApplication.shared.dockTile.display()
		#endif
	}

	private func rebindServer() {
		Log.info("(Re-)activate streaming server")
		do {
			try self.client.server?.listen()
		}
		catch let error {
			Log.warn("Error activating streaming server: " + error.localizedDescription)
		}
	}

	#if os(iOS)
		func suspend(_ suspend: Bool) {
			do {
				if suspend {
					if !self.suspendedPeerIds.isEmpty {
						Log.warn(
							"Suspending, but there are still suspended peers, this should not happen (working around it anyway)"
						)
					}
					let suspendedPeers = try self.client.suspendPeers()
					var suspendedIds = suspendedPeers.asArray()
					suspendedIds.append(contentsOf: self.suspendedPeerIds)
					self.suspendedPeerIds = suspendedIds
				}
				else {
					if self.suspendedPeerIds.isEmpty {
						Log.info("No peers to unsuspend")
					}
					else {
						Log.info(
							"Requesting unsuspend of devices:"
								+ self.suspendedPeerIds.debugDescription)
						try self.client.unsuspend(
							SushitrainListOfStrings.from(self.suspendedPeerIds))
						self.suspendedPeerIds = []
					}
				}
			}
			catch {
				Log.warn("Could not suspend \(suspend): \(error.localizedDescription)")
			}
		}
	#endif

	func awake() {
		#if os(iOS)
			self.lingerManager.cancelLingering()
			try? self.client.setReconnectIntervalS(1)
			self.suspend(false)
			Task {
				await self.backgroundManager.rescheduleWatchdogNotification()
			}
			self.rebindServer()
			self.client.ignoreEvents = false
		#endif
	}

	func sleep() {
		#if os(iOS)
			QuickActionService.provideActions()

			if self.lingeringEnabled {
				Log.info("Background time remaining: \(UIApplication.shared.backgroundTimeRemaining)")
				self.lingerManager.lingerThenSuspend()
				Log.info(
					"Background time remaining (2): \(UIApplication.shared.backgroundTimeRemaining)"
				)
			}
			else {
				self.suspend(true)
			}
			try? self.client.setReconnectIntervalS(60)
			self.client.ignoreEvents = true
		#endif

		Task {
			await self.updateBadge()
		}
	}

	func onScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
		Log.info("Phase change from \(oldPhase) to \(newPhase) lingeringEnabled=\(self.lingeringEnabled)")

		switch newPhase {
		case .background:
			self.sleep()
			break

		case .inactive:
			Task {
				await self.updateBadge()
			}
			#if os(iOS)
				self.client.ignoreEvents = true
			#endif
			break

		case .active:
			self.awake()
			break

		@unknown default:
			break
		}
	}

	func isInsideDocumentsFolder(_ url: URL) -> Bool {
		return url.resolvingSymlinksInPath().path(percentEncoded: false)
			.hasPrefix(documentsDirectory.resolvingSymlinksInPath().path(percentEncoded: false))
	}

	var systemImage: String {
		let isDownloading = self.client.isDownloading()
		let isUploading = self.client.isUploading()
		if isDownloading && isUploading {
			return "arrow.up.arrow.down.circle.fill"
		}
		else if isDownloading {
			return "arrow.down.circle.fill"
		}
		else if isUploading {
			return "arrow.up.circle.fill"
		}
		else if self.client.connectedPeerCount() > 0 {
			return "checkmark.circle.fill"
		}
		return "network.slash"
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
			Log.info("Cancel lingering")
			if let lt = self.lingerTask {
				UIApplication.shared.endBackgroundTask(lt)
			}
			self.lingerTask = nil
			self.lingerTimer?.invalidate()
			self.lingerTimer = nil
			self.wantsSuspendAfterLinger = false
		}

		private func afterLingering() {
			Log.info("After lingering: suspend=\(self.wantsSuspendAfterLinger)")
			if self.wantsSuspendAfterLinger {
				self.wantsSuspendAfterLinger = false
				self.appState.suspend(true)
			}
			self.cancelLingering()
		}

		func lingerThenSuspend() {
			Log.info("Linger then suspend")

			if self.appState.isSuspended {
				// Already suspended?
				Log.info("Already suspended (suspended peer list is not empty), not lingering")
				self.afterLingering()
			}

			self.wantsSuspendAfterLinger = true
			if self.lingerTask == nil {
				self.lingerTask = UIApplication.shared.beginBackgroundTask(
					withName: "Short-term connection persistence",
					expirationHandler: {
						Log.info("Suspend after expiration of linger time")
						self.afterLingering()
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
				return afterLingering()
			}

			if self.lingerTimer?.isValid != true {
				Log.info("Start lingering timer for \(lingerTime)")
				self.lingerTimer = Timer.scheduledTimer(withTimeInterval: lingerTime, repeats: false) {
					_ in
					DispatchQueue.main.async {
						Log.info("Suspend after linger")
						self.afterLingering()
					}
				}
			}
		}
	}
#endif
