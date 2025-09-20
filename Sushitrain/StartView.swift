// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

#if os(iOS)
	private struct WaitView: View {
		@Environment(AppState.self) private var appState
		@Binding var isPresented: Bool

		@State private var position: CGPoint = .zero
		@State private var velocity: CGSize = CGSize(width: 1, height: 1)
		@State private var timer: Timer? = nil

		let spinnerSize = CGSize(width: 240, height: 70)

		var body: some View {
			GeometryReader { geometry in
				ZStack {
					Color.black
						.edgesIgnoringSafeArea(.all)

					if !appState.isFinished {
						VStack(alignment: .leading, spacing: 10) {
							OverallStatusView().frame(maxWidth: .infinity)

							if appState.photoBackup.isSynchronizing {
								PhotoBackupProgressView(photoBackup: appState.photoBackup)
							}

							Text(
								velocity.height > 0
									? "Tap to close"
									: "The screen will stay on until finished"
							)
							.dynamicTypeSize(.xSmall)
							.foregroundStyle(.gray)
							.multilineTextAlignment(.center)
							.frame(maxWidth: .infinity)
						}
						.frame(width: spinnerSize.width, height: spinnerSize.height)
						.position(position)
					}
				}
				.statusBar(hidden: true)
				.persistentSystemOverlays(.hidden)
				.onTapGesture {
					isPresented = false
				}
				.onAppear {
					UIApplication.shared.isIdleTimerDisabled = true
					position = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
					startTimer(in: geometry.size)
				}
				.onDisappear {
					UIApplication.shared.isIdleTimerDisabled = false
					timer?.invalidate()
				}
			}
		}

		private func startTimer(in size: CGSize) {
			timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
				DispatchQueue.main.async {
					if appState.isFinished {
						self.isPresented = false
						return
					}

					// Update position
					position.x += velocity.width
					position.y += velocity.height

					// Bounce off walls
					if position.x - spinnerSize.width / 2 <= 0
						|| position.x + spinnerSize.width / 2 >= size.width
					{
						velocity.width *= -1
					}
					if position.y - spinnerSize.height / 2 <= 0
						|| position.y + spinnerSize.height / 2 >= size.height
					{
						velocity.height *= -1
					}
				}
			}
		}
	}
#endif

private struct OverallDownloadProgressView: View {
	@Environment(AppState.self) private var appState
	@State private var lastProgress: (Date, SushitrainProgress)? = nil
	@State private var progress: (Date, SushitrainProgress)? = nil
	@State private var peerStatusText: String = ""

	var body: some View {
		Group {
			if let (date, progress) = progress {
				NavigationLink(destination: DownloadsView()) {
					ProgressView(value: progress.percentage, total: 1.0) {
						VStack {
							HStack {
								Label(
									"Receiving \(progress.filesTotal) files...",
									systemImage: "arrow.down"
								)
								.foregroundStyle(.green)
								.symbolEffect(.pulse, value: date)
								.badge("\(Int(progress.percentage * 100))%")
								.frame(maxWidth: .infinity)
								Spacer()
							}

							self.speeds
						}
					}
					.tint(.green)
				}
			}
			else {
				Label("Receiving files...", systemImage: "arrow.down")
					.foregroundStyle(.green)
					.badge(self.peerStatusText)
					.frame(maxWidth: .infinity)
			}
		}
		.task {
			await self.updateProgress()
		}
		.onChange(of: self.appState.eventCounter) {
			Task {
				await self.updateProgress()
			}
		}
	}

	@ViewBuilder private var speeds: some View {
		// Download speed
		HStack {
			Spacer()
			if let (date, progress) = progress, let (lastDate, lastProgress) = self.lastProgress {
				let diffBytes = progress.bytesDone - lastProgress.bytesDone
				let diffTime = date.timeIntervalSince(lastDate)
				let speed = Int64(Double(diffBytes) / Double(diffTime))
				let formatter = ByteCountFormatter()

				if speed > 0 && diffTime > 0 {
					Text("\(formatter.string(fromByteCount: speed))/s")
						.foregroundStyle(.green)
					let secondsToGo = Duration(
						secondsComponent: (progress.bytesTotal - progress.bytesDone) / speed, attosecondsComponent: 0)
					let secondsToGoFormatted: String = secondsToGo.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 0)))
					Text(secondsToGoFormatted).foregroundStyle(.green)
				}
				else {
					Text("(Transfer speed unknown)").foregroundStyle(.gray)
				}
			}
		}
	}

	private func updateProgress() async {
		self.peerStatusText = "\(self.appState.client.connectedPeerCount())/\(await self.appState.peers().count - 1)"

		self.lastProgress = self.progress
		if let p = self.appState.client.getTotalDownloadProgress() {
			self.progress = (Date.now, p)
		}
		else {
			self.progress = nil
		}
	}
}

struct OverallStatusView: View {
	@Environment(AppState.self) private var appState
	@State private var connectedPeerCount = 0
	@State private var peerCount = 0
	@State private var isDownloading = false
	@State private var isUploading = false

	var body: some View {
		Group {
			if self.connectedPeerCount > 0 {
				if isDownloading || isUploading {
					if isDownloading {
						OverallDownloadProgressView()
					}

					// Uploads
					if isUploading {
						NavigationLink(destination: UploadsView()) {
							OverallUploadStatusView()
						}
					}
				}
				else {
					Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
						.badge(Text(peerStatusText))
				}
			}
			else {
				Label("Not connected", systemImage: "network.slash")
					.badge(Text(self.peerStatusText))
					.foregroundColor(.gray)
			}
		}
		.task {
			await self.update()
		}
		.onChange(of: appState.eventCounter) { _, _ in
			Task {
				await self.update()
			}
		}
	}

	private var peerStatusText: String {
		if peerCount > 0 {
			return "\(connectedPeerCount)/\(peerCount - 1)"
		}
		return ""
	}

	private func update() async {
		self.isDownloading = self.appState.client.isDownloading()
		self.isUploading = self.appState.client.isUploading()
		self.connectedPeerCount = self.appState.client.connectedPeerCount()
		self.peerCount = await self.appState.peers().count
	}
}

private struct OverallUploadStatusView: View {
	@Environment(AppState.self) private var appState

	@State private var progress: SushitrainProgress? = nil

	var body: some View {
		ZStack {
			if let progress = progress {
				ProgressView(value: progress.percentage, total: 1.0) {
					Label(
						"Sending \(progress.filesTotal) files...",
						systemImage: "arrow.up"
					)
					.foregroundStyle(.green)
					.symbolEffect(.pulse, value: progress.percentage)
					.badge("\(Int(progress.percentage * 100))%")
					.frame(maxWidth: .infinity)
				}.tint(.green)
			}
			else {
				Label("Sending files...", systemImage: "arrow.up")
					.foregroundStyle(.green)
					.frame(maxWidth: .infinity)
			}
		}.task {
			await self.update()
		}
	}

	private func update() async {
		let client = appState.client
		self.progress = await Task.detached {
			return client.getTotalUploadProgress()
		}.value
	}
}

struct StartView: View {
	@Environment(AppState.self) private var appState
	@Binding var route: Route?

	#if os(iOS)
		let backgroundManager: BackgroundManager
	#endif

	@State private var qrCodeShown = false
	@State private var showWaitScreen: Bool = false
	@State private var showAddresses = false
	@State private var showAddFolderSheet = false
	@State private var addFolderID = ""
	@State private var showNoPeersEnabledWarning = false
	@State private var peers: [SushitrainPeer]? = nil
	@State private var folders: [SushitrainFolder]? = nil

	@State private var inaccessibleExternalFolders: [SushitrainFolder] = []
	@State private var foldersWithIssues: [SushitrainFolder] = []
	@State private var fixingInaccessibleExternalFolder: SushitrainFolder? = nil
	@State private var isDiskSpaceSufficient = true
	@State private var longTimeNotSeenDevices: [SushitrainPeer] = []

	@State private var showError: Error? = nil

	var body: some View {
		Form {
			Section {
				OverallStatusView()
					#if os(iOS)
						.contextMenu {
							if !self.appState.isFinished {
								Button("Wait for completion", systemImage: "hourglass.circle") {
									self.showWaitScreen = true
								}
							}

							if #available(iOS 26, *) {
								self.continueInBackgroundMenu()
							}
						}
					#endif

				#if os(iOS)
					if backgroundManager.runningContinuedTask != nil {
						Label("Will continue in the background", systemImage: "gearshape.2.fill")
					}
				#endif
			}

			Section(header: Text("This device's identifier")) {
				DeviceIDView(device: self.appState.client.peer(withID: self.appState.localDeviceID)!)
			}

			// Disk space warning
			if !isDiskSpaceSufficient {
				Section {
					DiskSpaceWarningView()
				}
			}

			// Getting started, device issues
			if let p = peers, p.isEmpty {
				self.gettingStartedDevices()
			}
			self.deviceIssuesSection()

			// Getting started, folder issues
			if let f = folders, f.isEmpty {
				self.gettingStartedFolders()
			}
			self.folderIssuesSection()

			Section("Manage files and folders") {
				NavigationLink(destination: ChangesView()) {
					Label("Recent changes", systemImage: "clock.arrow.2.circlepath").badge(
						appState.lastChanges.count)
				}.disabled(appState.lastChanges.isEmpty)
			}

			if appState.photoBackup.isReady {
				#if os(iOS)
					Section {
						PhotoBackupButton(photoBackup: appState.photoBackup)
					} footer: {
						PhotoBackupStatusView(photoBackup: appState.photoBackup)
					}
				#else
					Section {
						PhotoBackupButton(photoBackup: appState.photoBackup)
						PhotoBackupStatusView(photoBackup: appState.photoBackup)
					}
				#endif
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.navigationTitle("Start")
		#if os(iOS)
			.toolbar {
				ToolbarItem {
					NavigationLink(destination: SettingsView(userSettings: appState.userSettings)) {
						Image(systemName: "gear").accessibilityLabel("Settings")
					}
				}
			}
		#endif
		#if os(iOS)
			.fullScreenCover(isPresented: $showWaitScreen) {
				WaitView(isPresented: $showWaitScreen)
			}
		#endif
		.sheet(isPresented: Binding.isNotNil($fixingInaccessibleExternalFolder)) {
			if let fe = self.fixingInaccessibleExternalFolder {
				NavigationStack {
					ExternalFolderInaccessibleView(folder: fe)
						.navigationTitle(fe.displayName)
						.frame(minHeight: 300)
						.toolbar {
							SheetButton(role: .cancel) {
								self.fixingInaccessibleExternalFolder = nil
							}
						}
				}
			}
		}
		.alert(
			"An error has occurred", isPresented: Binding.isNotNil($showError),
			actions: {
				Button("OK") {
					showError = nil
				}
			},
			message: {
				Text(showError?.localizedDescription ?? "")
			}
		)
		.task {
			await self.update()
		}
		.onChange(of: appState.userSettings.ignoreLongTimeNoSeeDevices.count) { _, _ in
			Task {
				await self.update()
			}
		}
		.onChange(of: appState.eventCounter) { _, _ in
			Task {
				await self.update()
			}
		}
	}

	@ViewBuilder @available(iOS 26, *) private func continueInBackgroundMenu() -> some View {
		Menu("Synchronize in the background", systemImage: "gearshape.2.fill") {
			Button("For 10 seconds") {
				self.startBackgroundSyncFor(.time(seconds: 10))
			}.disabled(backgroundManager.runningContinuedTask != nil)

			Button("For 1 minute") {
				self.startBackgroundSyncFor(.time(seconds: 60))
			}.disabled(backgroundManager.runningContinuedTask != nil)

			Button("For 10 minutes") {
				self.startBackgroundSyncFor(.time(seconds: 10 * 60))
			}.disabled(backgroundManager.runningContinuedTask != nil)

			Button("For 1 hour") {
				self.startBackgroundSyncFor(.time(seconds: 3600))
			}.disabled(backgroundManager.runningContinuedTask != nil)
		}
	}

	@available(iOS 26, *) private func startBackgroundSyncFor(_ type: ContinuedTaskType) {
		do {
			try backgroundManager.startContinuedSync(type)
		}
		catch {
			self.showError = error
		}
	}

	@ViewBuilder private func gettingStartedFolders() -> some View {
		Section("Getting started") {
			VStack(alignment: .leading, spacing: 5) {
				Label("Add your first folder", systemImage: "folder.badge.plus").bold()
				Text(
					"To synchronize files, add a folder. Folders that have the same folder ID on multiple devices will be synchronized with eachother."
				)
			}
			.onTapGesture {
				showAddFolderSheet = true
			}
			.sheet(
				isPresented: $showAddFolderSheet,
				content: {
					AddFolderView(folderID: $addFolderID)
				})
		}
	}

	@ViewBuilder private func gettingStartedDevices() -> some View {
		Section("Getting started") {
			VStack(alignment: .leading, spacing: 5) {
				Label("Add your first device", systemImage: "externaldrive.badge.plus")
					.bold()
				Text(
					"To synchronize files, first add a remote device. Either select a device from the list below, or add manually using the device ID."
				)
			}.onTapGesture {
				route = .devices
			}
		}
	}

	@ViewBuilder private func deviceIssuesSection() -> some View {
		if showNoPeersEnabledWarning || !longTimeNotSeenDevices.isEmpty {
			Section("Devices that need your attention") {
				// All devices are disabled
				if showNoPeersEnabledWarning {
					VStack(alignment: .leading, spacing: 5) {
						Label(
							"All devices are paused",
							systemImage: "exclamationmark.triangle.fill"
						)
						.bold()
						.foregroundStyle(.orange)
						Text(
							"Synchronization is disabled for all associated devices. This may occur after updating or restarting the app. To restart synchronization, re-enable synchronization on the 'devices' page, or tap here to enable all devices."
						)
						.foregroundStyle(.orange)
					}
					.onTapGesture {
						Task {
							self.appState.userSettings.userPausedDevices.removeAll()
							await self.appState.updateDeviceSuspension()
							showNoPeersEnabledWarning = false
						}
					}
				}

				// Devices not seen for a while
				if !longTimeNotSeenDevices.isEmpty {
					ForEach(longTimeNotSeenDevices, id: \.id) { device in
						if let lastSeen = device.lastSeen()?.date() {
							NavigationLink(destination: DeviceView(device: device)) {
								Label(
									"Device '\(device.displayName)' has not connected since \(lastSeen.formatted())",
									systemImage: "exclamationmark.triangle.fill"
								)
								.foregroundStyle(.orange)
							}
						}
					}
				}
			}
		}
	}

	@ViewBuilder private func folderIssuesSection() -> some View {
		if !appState.foldersWithExtraFiles.isEmpty || !foldersWithIssues.isEmpty || !inaccessibleExternalFolders.isEmpty {
			Section("Folders that need your attention") {
				// External folders that have become inaccessible
				ForEach(inaccessibleExternalFolders, id: \.folderID) { folder in
					Button(action: {
						self.fixingInaccessibleExternalFolder = folder
					}) {
						Label(
							"Folder '\(folder.displayName)' is not accessible anymore",
							systemImage: "xmark.app"
						)
						.foregroundStyle(.red)
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				}

				// Folders with other configuration issues
				ForEach(foldersWithIssues, id: \.folderID) { folder in
					NavigationLink(destination: {
						FolderView(folder: folder)
					}) {
						let issue = folder.issue ?? String(localized: "unknown error")
						Label(
							"Folder '\(folder.displayName)' has an issue: \(issue)",
							systemImage: "exclamationmark.triangle.fill"
						)
						.foregroundStyle(.red)
					}
				}

				// Folders with extra files
				ForEach(appState.foldersWithExtraFiles, id: \.self) { folderID in
					if let folder = appState.client.folder(withID: folderID) {
						NavigationLink(destination: {
							ExtraFilesView(folder: folder)
						}) {
							Label(
								"Folder '\(folder.displayName)' has extra files",
								systemImage: "exclamationmark.triangle.fill"
							)
							.foregroundStyle(.orange)
						}
					}
					// Folder may have been recently deleted; in that case it cannot be accessed anymore
				}
			}
		}
	}

	private func update() async {
		showNoPeersEnabledWarning = false
		await self.updateFoldersWithIssues()

		// Check to see if there are peers connected
		let p = await self.appState.peers()
		self.peers = p
		self.folders = await self.appState.folders().sorted()
		self.longTimeNotSeenDevices = await self.appState.getPeersNotSeenForALongTime()

		isDiskSpaceSufficient = appState.client.isDiskSpaceSufficient()

		await self.appState.updateBadge()  // Updates extraneous files list
		do {
			try await Task.sleep(nanoseconds: 3 * 1_000_000_000)  // 3 seconds
			let enabledPeerCount = p.count { !$0.isPaused() && !$0.isSelf() }
			showNoPeersEnabledWarning = p.count > 1 && enabledPeerCount == 0
		}
		catch {
			// Ignored
		}
	}

	private func updateFoldersWithIssues() async {
		let folders = await self.appState.folders()

		// Find external folders that have become inaccessible
		self.inaccessibleExternalFolders = folders.filter { folder in
			if folder.isPaused() {
				return false
			}

			return folder.isExternal == true && !folder.isPhotoFolder
				&& !BookmarkManager.shared.hasBookmarkFor(folderID: folder.folderID)
		}

		// Find folders with other issues
		self.foldersWithIssues = folders.filter { folder in
			if folder.isPaused() {
				return false
			}
			var error: NSError? = nil
			let state = folder.state(&error)
			if !SushitrainFolder.knownGoodStates.contains(state) {
				// Do not list inaccessible external folders twice
				return !self.inaccessibleExternalFolders.contains(where: { $0.folderID == folder.folderID })
			}
			return false
		}
	}
}

private struct DiskSpaceWarningView: View {
	@State private var diskSpaceFree: Int64? = nil
	@State private var formatter = ByteCountFormatter()

	var body: some View {
		VStack(alignment: .leading, spacing: 5) {
			Label("Insufficient storage space", systemImage: "externaldrive.fill.badge.exclamationmark")
				.bold()
				.foregroundStyle(.red)
			if let b = diskSpaceFree {
				Text("There is only \(formatter.string(fromByteCount: b)) of free storage space left on this device.")
					.foregroundStyle(.red)
			}
			else {
				Text("There is little to no free storage space left on this device.")
					.foregroundStyle(.red)
			}
			Text(
				"To prevent issues, synchronization is temporarily disabled. To resume synchronization, free up space on the device by removing files, and/or by unselecting files for synchronization in selectively synced folders. If there is space available, empty the trash can, restart the app and the device."
			)
			.foregroundStyle(.red)
		}.task {
			self.update()
		}
	}

	private func update() {
		self.diskSpaceFree = Int64(SushitrainGetFreeDiskSpaceMegaBytes()) * 1024 * 1024
	}
}
