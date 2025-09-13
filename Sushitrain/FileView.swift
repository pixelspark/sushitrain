// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import QuickLook
import AVKit

struct FileView: View {
	private static let formatter = ByteCountFormatter()

	@State var file: SushitrainEntry
	let showPath: Bool
	let siblings: [SushitrainEntry]?

	@State private var localItemURL: URL? = nil
	@State private var showFullScreenViewer = false
	@State private var showSheetViewer = false
	@State private var showRemoveConfirmation = false
	@State private var showDownloader = false
	@State private var selfIndex: Int? = nil
	@State private var fullyAvailableOnDevices: [SushitrainPeer]? = nil
	@State private var availabilityError: Error? = nil
	@State private var showEncryptionSheet: Bool = false
	@State private var conflictingEntries: [SushitrainEntry]? = nil
	@State private var openWithAppURL: URL? = nil
	@State private var localPath: String? = nil
	@State private var showArchive: Bool = false

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	#if os(macOS)
		@Environment(\.openURL) private var openURL
		@Environment(\.openWindow) private var openWindow
	#endif

	var localIsOnlyCopy: Bool {
		return file.isLocallyPresent()
			&& (self.fullyAvailableOnDevices == nil || (self.fullyAvailableOnDevices ?? []).isEmpty)
	}

	private var folder: SushitrainFolder {
		return self.file.folder!
	}

	var body: some View {
		if file.isDeleted() {
			ContentUnavailableView("File was deleted", systemImage: "trash", description: Text("This file was deleted."))
		}
		else {
			Form {
				// Symbolic link: show link target
				if file.isSymlink() { Section("Link destination") { Text(file.symlinkTarget()) } }

				Section {
					if !file.isDirectory() && !file.isSymlink() {
						Text("File size").badge(Self.formatter.string(fromByteCount: file.size()))
					}

					if let md = file.modifiedAt()?.date(), !file.isSymlink() {
						Text("Last modified").badge(md.formatted(date: .abbreviated, time: .shortened))

						let mby = file.modifiedByShortDeviceID()
						if !mby.isEmpty {
							if let modifyingDevice = appState.client.peer(withShortID: mby) {
								if modifyingDevice.deviceID() == appState.localDeviceID {
									Text("Last modified from").badge(Text("This device"))
								}
								else {
									Text("Last modified from").badge(modifyingDevice.displayName)
								}
							}
						}
					}

					if self.folder.isSelective() && !file.isSymlink() {
						let isExplicitlySelected = file.isExplicitlySelected()

						Toggle(
							"Synchronize with this device", systemImage: "pin",
							isOn: Binding(
								get: { file.isExplicitlySelected() || file.isSelected() },
								set: { s in try? file.setExplicitlySelected(s) }
							)
						).disabled(
							// We're doing something weird
							!folder.isIdleOrSyncing
								// Selected implicitly by parent
								|| (file.isSelected() && !isExplicitlySelected)
								// We have the only copy
								|| (isExplicitlySelected && localIsOnlyCopy)
								// File is selected but is not local, we are probably still downloading it
								|| (file.isSelected() && !file.isLocallyPresent())
						)
					}
				} footer: {
					if !file.isSymlink() && self.folder.isSelective() && (file.isSelected() && !file.isExplicitlySelected()) {
						Text("This item is synchronized with this device because a parent folder is synchronized with this device.")
					}

					if !file.isSymlink() {
						if file.isExplicitlySelected() {
							if localIsOnlyCopy {
								if self.folder.connectedPeerCount() > 0 {
									Text("There are currently no other devices connected that have a full copy of this file.")
								}
								else {
									Text(
										"There are currently no other devices connected, so it can't be established that this file is fully available on at least one other device."
									)
								}
							}
						}
						else if !self.file.isLocallyPresent() {
							if self.folder.connectedPeerCount() == 0 {
								Text(
									"When you select this file, it will not become immediately available on this device, because there are no other devices connected to download the file from."
								)
							}
							else if self.fullyAvailableOnDevices == nil || (self.fullyAvailableOnDevices ?? []).isEmpty {
								Text(
									"When you select this file, it will not become immediately available on this device, because none of the currently connected devices have a full copy of the file that can be downloaded."
								)
							}
						}
					}
				}
				// Conflicts
				if let ce = conflictingEntries, !ce.isEmpty {
					Section("Conflicting versions of this file") {
						ForEach(ce) { (conflictingEntry: SushitrainEntry) in
							if conflictingEntry.path() != self.file.path() {
								FileEntryLink(
									appState: appState, entry: conflictingEntry, inFolder: self.folder, siblings: ce, honorTapToPreview: false
								) {
									// TODO: attempt to interpret conflict file name, show date/time/device info neatly
									Text(conflictingEntry.fileName()).foregroundStyle(.red)
								}
							}
						}
					}
				}

				// Devices that have this file
				if !self.file.isSymlink() {
					if let availability = self.fullyAvailableOnDevices {
						if availability.isEmpty && self.folder.connectedPeerCount() > 0 {
							Label(
								"This file is not fully available on any connected device",
								systemImage: "externaldrive.trianglebadge.exclamationmark"
							).foregroundStyle(.orange)
						}
					}
					else {
						if let err = self.availabilityError {
							Label(
								"Could not determine file availability: \(err.localizedDescription)",
								systemImage: "externaldrive.trianglebadge.exclamationmark"
							).foregroundStyle(.orange)
						}
						else {
							Label("Checking availability on other devices...", systemImage: "externaldrive.badge.questionmark")
								.foregroundStyle(.gray)
						}
					}
				}

				if showPath {
					Section("Location") {
						NavigationLink(destination: BrowserView(folder: folder, prefix: file.parentPath())) {
							Label("\(folder.label()): \(file.parentPath())", systemImage: "folder")
						}
					}
				}

				if !file.isDirectory() && !file.isSymlink() {
					// Image preview
					if file.canThumbnail && !showFullScreenViewer {
						Section {
							ThumbnailView(
								file: file,
								showFileName: false,
								showErrorMessages: true,
								onTap: {
									self.onTapThumbnail()
								}
							)
							.ignoresSafeArea()
							.padding(.all, 0)
							// Fixes issue where image is still tappable outside its rectangle
							.contentShape(Rectangle().inset(by: 0))
							.cornerRadius(8.0)
							.listRowInsets(EdgeInsets())
						}
					}

					self.viewButtons()

					// Zip
					if file.isArchive() {
						Section {
							self.zipButton()
						}
					}

					// Sharing
					Section {
						FileSharingLinksView(entry: file, sync: false)
					}

					// Devices that have this file
					if let availability = self.fullyAvailableOnDevices {
						if !availability.isEmpty {
							Section("This file is fully available on") {
								ForEach(availability, id: \.self) { device in Label(device.displayName, systemImage: "externaldrive") }
							}
						}
					}

					// Remove file
					if file.isSelected() && file.isLocallyPresent() && folder.folderType() == SushitrainFolderTypeSendReceive {
						Section {
							Button("Remove file from all devices", systemImage: "trash", role: .destructive) {
								showRemoveConfirmation = true
							}
							#if os(macOS)
								.buttonStyle(.link)
							#endif
							.foregroundColor(.red)
							.confirmationDialog(
								self.localIsOnlyCopy
									? "Are you sure you want to remove this file from all devices? The local copy of this file is the only one currently available on any device. This will remove the last copy. It will not be possible to recover the file after removing it."
									: "Are you sure you want to remove this file from all devices?", isPresented: $showRemoveConfirmation,
								titleVisibility: .visible
							) {
								Button("Remove the file from all devices", role: .destructive) {
									dismiss()
									try? file.remove()
								}
							}
						}
					}
				}

				if file.isDirectory() {
					// Devices that have this folder and all its contents
					if let availability = self.fullyAvailableOnDevices {
						if !availability.isEmpty {
							Section("This subdirectory and all its contents are fully available on") {
								List(availability, id: \.self) { device in Label(device.displayName, systemImage: "externaldrive") }
							}
						}
					}
				}
			}
			#if os(macOS)
				.formStyle(.grouped)
			#endif
			.navigationTitle(file.fileName()).quickLookPreview(self.$localItemURL)

			// Sheet viewer
			.sheet(isPresented: $showSheetViewer) {
				FileViewerView(file: file, siblings: siblings, inSheet: true, isShown: $showSheetViewer)
					#if os(macOS)
						.presentationSizing(.fitted).frame(minWidth: 640, minHeight: 480)
					#endif
			}

			// Full screen viewer
			#if os(iOS)
				.fullScreenCover(
					isPresented: $showFullScreenViewer,
					content: {
						FileViewerView(file: file, siblings: siblings, inSheet: true, isShown: $showFullScreenViewer)
					})
			#elseif os(macOS)
				.sheet(isPresented: $showFullScreenViewer) {
					FileViewerView(file: file, siblings: siblings, inSheet: true, isShown: $showFullScreenViewer)
					.presentationSizing(.fitted).frame(minWidth: 640, minHeight: 480)
				}
			#endif

			.sheet(isPresented: $showArchive) {
				self.zipSheet()
			}

			.sheet(isPresented: $showDownloader) {
				self.downloaderSheet()
			}

			.toolbar {
				// Next/previous buttons
				if let selfIndex = selfIndex, let siblings = siblings {
					ToolbarItemGroup(placement: .navigation) {
						Button("Previous", systemImage: "chevron.up") { next(-1) }.keyboardShortcut(KeyEquivalent.upArrow)  // Cmd-up
							.disabled(selfIndex < 1)

						Button("Next", systemImage: "chevron.down") { next(1) }.keyboardShortcut(KeyEquivalent.downArrow)  // Cmd-down
							.disabled(selfIndex >= siblings.count - 1)
					}
				}

				#if os(macOS)
					// Menu for advanced actions
					ToolbarItem {
						Menu {
							Button("Encryption details...", systemImage: "lock.document.fill") { showEncryptionSheet = true }
								.disabled(!(file.folder?.hasEncryptedPeers ?? false))

							Button("Explore archive contents...", systemImage: "doc.zipper") { showArchive = true }
						} label: {
							Label("Advanced", systemImage: "ellipsis.circle")
						}
					}

					// Open in Finder button
					ToolbarItem(id: "open-in-finder", placement: .primaryAction) {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								if let localPathActual = localPath { openURLInSystemFilesApp(url: URL(fileURLWithPath: localPathActual)) }
							}
						).labelStyle(.iconOnly).disabled(localPath == nil)
					}
				#endif
			}

			.sheet(isPresented: $showEncryptionSheet) {
				EncryptionView(entry: self.file)
			}

			.onAppear {
				selfIndex = self.siblings?.firstIndex(of: file)
			}

			.onChange(of: file, initial: true) { _, _ in
				self.fullyAvailableOnDevices = nil
				self.update()
			}

			.onChange(of: appState.eventCounter) { _, _ in
				self.update()
			}
		}
	}

	@ViewBuilder private func zipButton() -> some View {
		Button("Explore archive contents", systemImage: "doc.zipper") {
			self.showArchive = true
		}
		#if os(macOS)
			.buttonStyle(.link)
		#endif
	}

	@ViewBuilder private func zipSheet() -> some View {
		NavigationStack {
			if let ar = file.archive() {
				ZipView(archive: ar, prefix: "")
					.navigationTitle(file.fileName())
					.toolbar {
						SheetButton(role: .done) {
							showArchive = false
						}
					}
			}
			else {
				EmptyView()
			}
		}
	}

	@ViewBuilder private func downloaderSheet() -> some View {
		NavigationStack {
			FileQuickLookView(file: file, dismissAfterClose: true)
				#if os(iOS)
					.navigationBarTitleDisplayMode(.inline)
				#endif
				.toolbar {
					SheetButton(role: .cancel) {
						showDownloader = false
					}
				}
		}
	}

	@ViewBuilder private func viewButtons() -> some View {
		#if os(macOS)
			let openInSafariButton = Button(
				"Open in Safari", systemImage: "safari", action: { if let u = URL(string: file.onDemandURL()) { openURL(u) } }
			).buttonStyle(.link).disabled(folder.connectedPeerCount() == 0)
		#endif

		if file.isSelected() {
			// Selective sync uses copy in working dir
			if file.isLocallyPresent() {
				if let localPathActual = localPath {
					Section {
						Button("View file", systemImage: "eye", action: { localItemURL = URL(fileURLWithPath: localPathActual) })
							#if os(macOS)
								.buttonStyle(.link)
							#endif

						#if os(macOS)

							if let appURL = openWithAppURL {
								Button("Open with '\(appURL.lastPathComponent)'", systemImage: "app.badge") {
									NSWorkspace.shared.open(URL(fileURLWithPath: localPathActual))
								}.buttonStyle(.link)
							}
						#endif

						ShareLink("Share file", item: URL(fileURLWithPath: localPathActual))
							#if os(macOS)
								.buttonStyle(.link)
							#endif

						#if os(iOS)
							// On macOS, this button is in the toolbar; on iOS there is not enough horizontal space
							Button(
								openInFilesAppLabel, systemImage: "arrow.up.forward.app",
								action: { openURLInSystemFilesApp(url: URL(fileURLWithPath: localPathActual)) }
							).disabled(localPath == nil)
						#endif
					}
				}
			}
			else {
				// Waiting for sync
				Section { DownloadProgressView(file: file, folder: folder) }
			}
		}
		else {
			let streamButton = Button(
				"Stream", systemImage: file.isVideo ? "tv" : "music.note",
				action: {
					if file.isVideo {
						showFullScreenViewer = true
					}
					else if file.isAudio {
						showSheetViewer = true
					}
				}
			).disabled(folder.connectedPeerCount() == 0)
				#if os(macOS)
					.buttonStyle(.link)
				#endif

			let quickViewButton = Button(
				"View file", systemImage: "arrow.down.circle",
				action: {
					if file.isWebPreviewable {
						showSheetViewer = true
					}
					else {
						showDownloader = true
					}
				}
			).disabled(folder.connectedPeerCount() == 0)
				#if os(macOS)
					.buttonStyle(.link)
				#endif

			if !file.isArchive() {
				Section {
					if file.isMedia {
						// Stream button
						#if os(macOS)
							HStack {
								streamButton
								quickViewButton
								openInSafariButton
							}
						#else
							streamButton
							quickViewButton
						#endif
					}
					else {
						#if os(macOS)
							HStack {
								quickViewButton
								openInSafariButton
							}
						#else
							quickViewButton
						#endif
					}
				}
			}
			else {
				EmptyView()
			}
		}
	}

	private func update() {
		Task {
			await updateConflicts()
		}

		Task {
			let fileEntry = self.file

			// Obtain local paths
			var error: NSError? = nil
			self.localPath = file.isLocallyPresent() ? file.localNativePath(&error) : nil
			#if os(macOS)
				if let localPathActual = self.localPath {
					self.openWithAppURL =
						error == nil ? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: localPathActual)) : nil
				}
			#endif

			do {
				self.availabilityError = nil
				let availability = try await Task.detached { [fileEntry] in return (try fileEntry.peersWithFullCopy()).asArray() }
					.value

				self.fullyAvailableOnDevices = availability.flatMap { devID in
					if let p = self.appState.client.peer(withID: devID) { return [p] }
					return []
				}
			}
			catch {
				self.availabilityError = error
				self.fullyAvailableOnDevices = nil
			}
		}
	}

	private func onTapThumbnail() {
		#if os(macOS)
			// On macOS prefer local QuickLook
			if file.isLocallyPresent() {
				localItemURL = URL(fileURLWithPath: localPath!)
			}
			else if file.isVideo || file.isImage {
				#if os(macOS)
					// Cmd-click to open preview window directory
					if NSEvent.modifierFlags.contains(.command) {
						openWindow(id: "preview", value: Preview(folderID: file.folder!.folderID, path: file.path()))
					}
					else {
						showFullScreenViewer = true
					}
				#else
					showFullScreenViewer = true
				#endif
			}
		#elseif os(iOS)
			// On iOS prefer streaming view over QuickLook
			if file.isVideo || file.isImage {
				showFullScreenViewer = true
			}
			else if file.isLocallyPresent() {
				localItemURL = URL(fileURLWithPath: localPath!)
			}
		#endif
	}

	private func updateConflicts() async {
		self.conflictingEntries = []
		let file = self.file
		let folder = self.folder
		do {
			self.conflictingEntries = try await Task.detached {
				let conflicts = try folder.conflicts(inSubdirectory: file.parentPath())
				if let conflictSiblings = conflicts.conflictSiblings(file.path()) {
					var ce: [SushitrainEntry] = []
					for a in 0..<conflictSiblings.count() {
						let conflictItem = conflictSiblings.item(at: a)
						let conflictEntry = try folder.getFileInformation(conflictItem)
						if conflictEntry.path() != file.path() {
							ce.append(conflictEntry)
						}
					}
					return ce
				}
				else {
					return []
				}
			}.value
		}
		catch {
			Log.warn("Could not fetch conflicts for file \(file.path()): \(error.localizedDescription)")
		}
	}

	private func next(_ offset: Int) {
		if let siblings = siblings {
			if let idx = siblings.firstIndex(of: self.file) {
				let newIndex = idx + offset
				if newIndex >= 0 && newIndex < siblings.count {
					file = siblings[newIndex]
					selfIndex = self.siblings?.firstIndex(of: file)
				}
			}
		}
	}
}

private struct DownloadProgressView: View {
	@Environment(AppState.self) private var appState
	let file: SushitrainEntry
	let folder: SushitrainFolder

	@State private var lastProgress: (Date, SushitrainProgress)? = nil
	@State private var progress: (Date, SushitrainProgress)? = nil

	private var durationFormatter: DateComponentsFormatter {
		let d = DateComponentsFormatter()
		d.allowedUnits = [.day, .hour, .minute]
		d.unitsStyle = .abbreviated
		return d
	}

	var body: some View {
		Group {
			if let (date, progress) = self.progress {
				ProgressView(value: progress.percentage, total: 1.0) {
					VStack {
						HStack {
							Label("Downloading file...", systemImage: "arrow.clockwise").foregroundStyle(.green).symbolEffect(
								.pulse, value: date)
							Spacer()
						}

						if let (lastDate, lastProgress) = self.lastProgress {
							HStack {
								let diffBytes = progress.bytesDone - lastProgress.bytesDone
								let diffTime = date.timeIntervalSince(lastDate)
								let speed = Int64(Double(diffBytes) / Double(diffTime))
								let formatter = ByteCountFormatter()

								Spacer()
								Text("\(formatter.string(fromByteCount: speed))/s").foregroundStyle(.green)

								if speed > 0 {
									let secondsToGo = TimeInterval((progress.bytesTotal - progress.bytesDone) / speed)
									Text(durationFormatter.string(from: secondsToGo) ?? "").foregroundStyle(.green)
								}
							}
						}
					}
				}.tint(.green)
			}
			else {
				Label("Waiting to synchronize...", systemImage: "hourglass")
			}
		}.task { self.updateProgress() }.onChange(of: self.appState.eventCounter) { self.updateProgress() }
	}

	private func updateProgress() {
		self.lastProgress = self.progress
		if let p = self.appState.client.getDownloadProgress(forFile: self.file.path(), folder: self.folder.folderID) {
			self.progress = (Date.now, p)
		}
		else {
			self.progress = nil
		}
	}
}

struct FileSharingLinksView: View {
	let entry: SushitrainEntry
	let sync: Bool  // In some contexts, such as inside a context menu, async tasks don't run
	@State private var sharingLink: URL? = nil

	private func update() async {
		self.sharingLink = nil
		let entry = self.entry
		self.sharingLink = await Task.detached { return await entry.externalSharingURLExpensive() }.value
	}

	private var linkToUse: URL? {
		if self.sync { return self.entry.externalSharingURLExpensive() }
		return self.sharingLink
	}

	var body: some View {
		if entry.hasExternalSharingURL {
			Group {
				if let link = linkToUse {
					ShareLink(item: link) { Label("Share external link", systemImage: "link.circle") }
						#if os(macOS)
							.buttonStyle(.link)
						#endif
				}
				else {
					EmptyView()
				}

				#if os(macOS)
					// On macOS, the share sheet doesn't have an obvious 'copy URL' option
					Button("Copy external link", systemImage: "link.circle") {
						if let se = self.sharingLink {
							writeURLToPasteboard(url: se)
						}
						else if let se = entry.externalSharingURLExpensive() {
							writeURLToPasteboard(url: se)
						}
					}.buttonStyle(.link)
				#endif
			}.task { await self.update() }
				.onChange(of: entry) { Task { await self.update() } }
		}
	}
}
