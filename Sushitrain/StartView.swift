// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

#if os(iOS)
	private struct WaitView: View {
		@EnvironmentObject var appState: AppState
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

							if appState.photoSync.isSynchronizing {
								PhotoSyncProgressView(photoSync: appState.photoSync)
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
	@EnvironmentObject var appState: AppState
	@State private var lastProgress: (Date, SushitrainProgress)? = nil
	@State private var progress: (Date, SushitrainProgress)? = nil
	@State private var showSpeeds: Bool = false

	var body: some View {
		Group {
			if let (date, progress) = progress {
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

						// Download speed
						if let (lastDate, lastProgress) = self.lastProgress, showSpeeds {
							HStack {
								let diffBytes =
									progress.bytesDone - lastProgress.bytesDone
								let diffTime = date.timeIntervalSince(lastDate)
								let speed = Int64(Double(diffBytes) / Double(diffTime))
								let formatter = ByteCountFormatter()

								Spacer()
								Text("\(formatter.string(fromByteCount: speed))/s")
									.foregroundStyle(.green)

								if speed > 0 {
									let secondsToGo =
										(progress.bytesTotal
											- progress.bytesDone) / speed
									Text("\(secondsToGo) seconds").foregroundStyle(
										.green)
								}
							}
						}
					}

				}.tint(.green)
					.onTapGesture {
						showSpeeds = !showSpeeds
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
			self.updateProgress()
		}
		.onChange(of: self.appState.eventCounter) {
			self.updateProgress()
		}
	}

	private var peerStatusText: String {
		return "\(self.appState.client.connectedPeerCount())/\(self.appState.peers().count - 1)"
	}

	private func updateProgress() {
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
	@EnvironmentObject var appState: AppState

	private var peerStatusText: String {
		return "\(self.appState.client.connectedPeerCount())/\(self.appState.peers().count - 1)"
	}

	private var isConnected: Bool {
		return self.appState.client.connectedPeerCount() > 0
	}

	var body: some View {
		if self.isConnected {
			let isDownloading = self.appState.client.isDownloading()
			let isUploading = self.appState.client.isUploading()
			if isDownloading || isUploading {
				if isDownloading {
					OverallDownloadProgressView()
				}

				// Uploads
				if isUploading {
					let progress = self.appState.client.getTotalUploadProgress()

					NavigationLink(destination: UploadView()) {
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
								.badge(self.peerStatusText)
								.frame(maxWidth: .infinity)
						}
					}
				}
			}
			else {
				Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).badge(
					Text(self.peerStatusText))
			}
		}
		else {
			Label("Not connected", systemImage: "network.slash").badge(Text(self.peerStatusText))
				.foregroundColor(.gray)
		}
	}
}

struct StartView: View {
	@EnvironmentObject var appState: AppState
	@Binding var route: Route?
	@State private var qrCodeShown = false
	@State private var showWaitScreen: Bool = false
	@State private var showAddresses = false
	@State private var showAddFolderSheet = false
	@State private var addFolderID = ""
	@State private var showNoPeersEnabledWarning = false
	@State private var peers: [SushitrainPeer]? = nil

	var body: some View {
		Form {
			Section {
				OverallStatusView()
					#if os(iOS)
						.contextMenu {
							if !self.appState.isFinished {
								Button(action: {
									self.showWaitScreen = true
								}) {
									Text("Wait for completion")
									Image(systemName: "hourglass.circle")
								}
							}
						}
					#endif
			}

			Section(header: Text("This device's identifier")) {
				DeviceIDView(device: self.appState.client.peer(withID: self.appState.localDeviceID)!)
			}

			// Getting started
			if let p = peers, p.isEmpty {
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
			else if showNoPeersEnabledWarning {
				Section("Devices that need your attention") {
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
						for peer in peers ?? [] {
							try? peer.setPaused(false)
						}
						showNoPeersEnabledWarning = false
					}
				}
			}

			if self.appState.folders().count == 0 {
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

			if !appState.foldersWithExtraFiles.isEmpty {
				Section("Folders that need your attention") {
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

			Section("Manage files and folders") {
				NavigationLink(destination: ChangesView()) {
					Label("Recent changes", systemImage: "clock.arrow.2.circlepath").badge(
						appState.lastChanges.count)
				}.disabled(appState.lastChanges.isEmpty)
			}

			if appState.photoSync.isReady {
				Section {
					PhotoSyncButton(photoSync: appState.photoSync)
				}
			}

		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.navigationTitle("Start")
		#if os(iOS)
			.toolbar {
				ToolbarItem {
					NavigationLink(destination: SettingsView()) {
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
		.task {
			showNoPeersEnabledWarning = false
			let p = self.appState.peers()
			self.peers = p
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
	}
}
