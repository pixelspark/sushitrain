// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import QuickLook
import AVKit

struct FileViewerView: View {
	@Environment(AppState.self) private var appState

	@State var file: SushitrainEntry? = nil
	let siblings: [SushitrainEntry]?
	let inSheet: Bool
	@Binding var isShown: Bool

	#if os(iOS)
		@State private var barHidden: Bool = false
	#endif

	#if os(macOS)
		@State private var selfIndex: Int? = nil
		@Environment(\.openWindow) private var openWindow
	#endif

	#if os(iOS)
		private var scrollableFiles: [SushitrainEntry] {
			if let s = siblings {
				return s
			}
			if let f = self.file {
				return [f]
			}
			return []
		}

		// iOS version has infinite scrolling
		var body: some View {
			GeometryReader { reader in
				ScrollView(.horizontal, showsIndicators: false) {
					LazyHStack(spacing: 1.0) {
						ForEach(self.scrollableFiles) { sibling in
							NavigationStack {
								FileViewerContentView(file: sibling, isShown: $isShown)
									.toolbar {
										self.toolbarContent(file: sibling)
									}
									.navigationTitle(sibling.fileName())
									// Allow toolbar to be hidden on iOS
									.navigationBarTitleDisplayMode(.inline)
									.navigationBarHidden(barHidden)
							}
							.frame(width: reader.size.width)
							.tag(sibling)
							.id(sibling)
						}
					}
					.scrollTargetLayout()
				}
				.simultaneousGesture(
					TapGesture().onEnded {
						withAnimation {
							barHidden = !barHidden
						}
					}
				)
				.scrollTargetBehavior(.viewAligned)
				.scrollPosition(id: $file, anchor: .center)
			}
			.onAppear {
				barHidden = false
			}
		}
	#else
		// Mac version has back/forward buttons
		var body: some View {
			NavigationStack {
				if let file = file {
					FileViewerContentView(file: file, isShown: $isShown)
						.navigationTitle(file.fileName())
						.toolbar {
							self.toolbarContent(file: file)
						}
				}
			}
			.onAppear {
				if let file = self.file {
					self.selfIndex = self.siblings?.firstIndex {
						$0.id == file.id
					}
				}
			}
			.presentationSizing(.fitted)
			.frame(minWidth: 640, minHeight: 480)
		}

		private func next(_ offset: Int) {
			if let siblings = siblings, let file = self.file, let idx = self.siblings?.firstIndex(where: { $0.id == file.id }) {
				let newIndex = idx + offset
				if newIndex >= 0 && newIndex < siblings.count {
					let newFile = siblings[newIndex]
					self.file = newFile
					selfIndex = siblings.firstIndex(of: newFile)
				}
			}
		}
	#endif

	@ToolbarContentBuilder private func toolbarContent(file: SushitrainEntry) -> some ToolbarContent {
		if inSheet {
			SheetButton(role: .done) {
				isShown = false
			}

			#if os(macOS)
				ToolbarItemGroup(placement: .automatic) {
					Button(
						"Open in new window",
						systemImage: "macwindow.on.rectangle"
					) {
						if let folder = file.folder {
							openWindow(
								id: "preview",
								value: Preview(
									folderID: folder
										.folderID,
									path: file.path()
								))
							isShown = false
						}
					}
				}
			#endif
		}

		ToolbarItem(placement: .automatic) {
			FileShareLink(file: file)
		}

		#if os(macOS)
			if let siblings = siblings, let selfIndex = selfIndex {
				ToolbarItemGroup(placement: .automatic) {
					Button("Previous", systemImage: "chevron.up") {
						next(-1)
					}
					.disabled(selfIndex < 1)
					.keyboardShortcut(KeyEquivalent.upArrow)

					Button("Next", systemImage: "chevron.down") {
						next(1)
					}
					.disabled(selfIndex >= siblings.count - 1)
					.keyboardShortcut(KeyEquivalent.downArrow)
				}
			}
		#endif
	}
}

private struct FileViewerContentView: View {
	@Environment(AppState.self) private var appState
	var file: SushitrainEntry
	@Binding var isShown: Bool
	@State private var error: (any Error)? = nil
	@State private var loading: Bool = true

	var body: some View {
		Group {
			if let e = error {
				ContentUnavailableView(
					"Cannot preview this file", systemImage: "exclamationmark.triangle.fill",
					description: Text(e.localizedDescription)
				)
				.onTapGesture {
					self.error = nil
				}
			}
			else {
				if file.isVideo || file.isAudio {
					FileMediaPlayer(file: file, visible: $isShown)
				}
				else if file.isWebPreviewable {
					ZStack {
						WebView(url: url, trustFingerprints: [], verticallyCenter: true, isLoading: self.$loading, error: self.$error)
							.id(url)
							#if os(iOS)
								.ignoresSafeArea()
							#endif
						if loading {
							ProgressView()
								.progressViewStyle(.circular).controlSize(.extraLarge)
						}
					}
				}
				else {
					ContentUnavailableView(
						"Cannot preview this file", systemImage: "document",
						description: Text("Cannot show a preview for this type of file."))
				}
			}
		}
		.onChange(of: file) { (_, _) in
			self.error = nil
			self.loading = true
		}
	}

	private var url: URL {
		return file.localNativeFileURL ?? URL(string: self.file.onDemandURL())!
	}
}

private struct FileMediaPlayer: View {
	@Environment(AppState.self) private var appState
	var file: SushitrainEntry
	@Binding var visible: Bool

	@State private var player: AVPlayer?
	#if os(iOS)
		@State private var session = AVAudioSession.sharedInstance()
	#endif

	private func activateSession() {
		#if os(iOS)
			do {
				try session.setCategory(
					.playback,
					mode: .default,
					options: []
				)
			}
			catch _ {}

			do {
				try session.setActive(true, options: .notifyOthersOnDeactivation)
			}
			catch _ {}

			do {
				try session.overrideOutputAudioPort(.speaker)
			}
			catch _ {}
		#endif
	}

	private func deactivateSession() {
		#if os(iOS)
			do {
				try session.setActive(false, options: .notifyOthersOnDeactivation)
			}
			catch let error as NSError {
				Log.warn("Failed to deactivate audio session: \(error.localizedDescription)")
			}
		#endif
	}

	var body: some View {
		ZStack {
			if let player = self.player {
				VideoPlayer(player: player)
			}
			else {
				Rectangle()
					.scaledToFill()
					.foregroundStyle(.black)
					.onTapGesture {
						visible = false
					}
			}
		}
		.background(.black)
		.onAppear {
			Task {
				await startPlayer()
			}
		}
		.onDisappear {
			stopPlayer()
		}
		.onChange(of: file) {
			Task {
				await startPlayer()
			}
		}
	}

	private func stopPlayer() {
		if let player = self.player {
			player.pause()
			self.player = nil
			self.deactivateSession()
		}
	}

	private func startPlayer() async {
		self.stopPlayer()
		do {
			let url = file.localNativeFileURL ?? URL(string: self.file.onDemandURL())!
			let avAsset = AVURLAsset(url: url)
			if try await avAsset.load(.isPlayable) {
				let player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
				// TODO: External playback requires us to use http://devicename.local:xxx/file/.. URLs rather than http://localhost.
				// Resolve using Bonjour perhaps?
				player.allowsExternalPlayback = false
				player.audiovisualBackgroundPlaybackPolicy = .automatic
				player.preventsDisplaySleepDuringVideoPlayback = !file.isAudio
				activateSession()
				player.playImmediately(atRate: 1.0)
				self.player = player
			}
			else {
				self.visible = false
			}
		}
		catch {
			Log.warn("Error starting player: \(error.localizedDescription)")
		}
	}
}
