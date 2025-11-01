// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct ShareFolderWithDeviceDetailsView: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	let folder: SushitrainFolder
	@Binding var deviceID: String

	@State private var newPassword: String = ""
	@FocusState private var passwordFieldFocus: Bool
	@State private var error: String? = nil
	@State private var device: SushitrainPeer? = nil

	private func update() async {
		self.device = appState.client.peer(withID: deviceID)
	}

	var body: some View {
		NavigationStack {
			Form {
				if let device = device {
					Section("Share with device") {
						DeviceIDView(device: device)
					}

					Section {
						TextField("Password", text: $newPassword)
							.textContentType(.password)
							#if os(iOS)
								.textInputAutocapitalization(.never)
							#endif
							.monospaced()
							.focused($passwordFieldFocus)
					} header: {
						Text("Encryption password")
					} footer: {
						Text(
							"If you leave the password empty, files will not be encrypted on the other device, and therefore can be read by anyone who has access to the other device. If you set an encryption password, ensure that all devices that synchronize the same folder with the other device are using the same password."
						).multilineTextAlignment(.leading)
							.lineLimit(nil)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			.task {
				await self.update()
			}
			#if os(macOS)
				.formStyle(.grouped)
			#endif
			.onAppear {
				self.newPassword = folder.encryptionPassword(for: deviceID)
				passwordFieldFocus = true
			}
			.navigationTitle("Share folder '\(folder.displayName)'")
			#if os(iOS)
				.navigationBarTitleDisplayMode(.inline)
			#endif
			.toolbar {
				ToolbarItem(
					placement: .confirmationAction,
					content: {
						Button("Save") {
							do {
								try folder.share(
									withDevice: self.deviceID, toggle: true,
									encryptionPassword: newPassword)
								dismiss()
							}
							catch let error {
								self.error = error.localizedDescription
							}
						}
					})

				SheetButton(role: .cancel) {
					dismiss()
				}
			}
		}
		.alert(isPresented: Binding.isNotNil($error)) {
			Alert(title: Text("Could not set encryption key"), message: Text(self.error!))
		}
	}
}

struct FolderStatusDescription {
	var text: String
	var systemImage: String
	var color: Color
	var badge: String
	var additionalText: String?

	init(_ folder: SushitrainFolder) {
		self.badge = ""
		self.additionalText = nil
		if !folder.exists() {
			(self.text, self.systemImage, self.color) = (String(localized: "Folder does not exist"), "trash", .red)
		}
		else {
			let isAvailable = folder.connectedPeerCount() > 0

			if !folder.isPaused() {
				let isSelective = folder.isSelective()

				let peerStatusText: String
				if folder.exists() {
					let peerCount = (folder.sharedWithDeviceIDs()?.count() ?? 1) - 1
					peerStatusText = "\(folder.connectedPeerCount())/\(peerCount)"
				}
				else {
					peerStatusText = ""
				}

				if !isAvailable {
					(self.text, self.systemImage, self.color) = (String(localized: "Not connected"), "network.slash", .gray)
					self.badge = peerStatusText
				}
				else {
					var error: NSError? = nil
					let status = folder.state(&error)

					switch status {
					case "idle", "sync-waiting", "scan-waiting", "clean-waiting":
						if !isSelective {
							(self.text, self.systemImage, self.color) = (String(localized: "Synchronized"), "checkmark.circle.fill", .green)
							self.badge = peerStatusText
						}
						else {
							(self.text, self.systemImage, self.color) = (String(localized: "Connected"), "checkmark.circle.fill", .green)
							self.badge = peerStatusText
						}

					case "syncing":
						(self.text, self.systemImage, self.color) = (
							String(localized: "Synchronizing..."), "bolt.horizontal.circle", .orange
						)

					case "scanning":
						(self.text, self.systemImage, self.color) = (String(localized: "Scanning..."), "bolt.horizontal.circle", .orange)

					case "sync-preparing":
						(self.text, self.systemImage, self.color) = (
							String(localized: "Preparing to synchronize..."), "bolt.horizontal.circle", .orange
						)

					case "cleaning":
						(self.text, self.systemImage, self.color) = (
							String(localized: "Cleaning up..."), "bolt.horizontal.circle", .orange
						)

					case "error":
						(self.text, self.systemImage, self.color) = (String(localized: "Error"), "exclamationmark.triangle.fill", .red)
						self.additionalText = error?.localizedDescription

					default:
						if !folder.isDiskSpaceSufficient() {
							(self.text, self.systemImage, self.color) = (
								String(localized: "Insufficient free storage space"), "exclamationmark.triangle.fill", .red
							)
						}
						// Error message is "fcntl /private/...: too many open files"
						else if let err = error, folder.isWatcherEnabled() && err.localizedDescription.contains("too many open files") {
							(self.text, self.systemImage, self.color) = (
								String(localized: "Folder too large for watching"), "exclamationmark.triangle.fill", .red
							)
							self.additionalText = String(localized: "Disabling 'watch for changes' for this folder may resolve the issue.")
						}
						else {
							(self.text, self.systemImage, self.color) = (
								String(localized: "Unknown state"), "exclamationmark.triangle.fill", .red
							)
							self.additionalText = error?.localizedDescription
						}
					}
				}
			}
			else {
				(self.text, self.systemImage, self.color) = (String(localized: "Synchronization paused"), "pause.circle", .gray)
			}
		}
	}

	var fullText: String {
		var text = self.text
		if !self.badge.isEmpty {
			text += " (\(self.badge))"
		}
		return text
	}
}

struct FolderStatusView: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder

	@State private var statistics: SushitrainFolderStats? = nil
	@State private var status: String? = nil
	@State private var folderStatusDescription: FolderStatusDescription? = nil

	var body: some View {
		VStack {
			if let status = status {
				if status == "syncing" && !folder.isSelective() {
					if let statistics = self.statistics, statistics.global!.bytes > 0 {
						let formatter = ByteCountFormatter()
						if let globalBytes = statistics.global?.bytes, let localBytes = statistics.local?.bytes {
							let remainingText = formatter.string(fromByteCount: (globalBytes - localBytes))

							ProgressView(
								value: Double(localBytes) / Double(globalBytes),
								total: 1.0
							) {
								Label(
									"Synchronizing...", systemImage: "bolt.horizontal.circle"
								)
								.foregroundStyle(.orange)
								.badge(Text(remainingText))
							}.tint(.orange)
						}
						else {
							self.statusLabel()
						}
					}
					else {
						self.statusLabel()
					}
				}
				else {
					self.statusLabel()
				}

				if let folderStatus = self.folderStatusDescription, let txt = folderStatus.additionalText {
					Text(txt).foregroundStyle(.red)
				}
			}
		}.task {
			await Task.detached {
				await self.update()
			}.value
		}
		.onChange(of: appState.eventCounter) { _, _ in
			Task.detached {
				await self.update()
			}
		}
	}

	private func update() async {
		var error: NSError? = nil
		self.status = folder.state(&error)
		self.statistics = try? folder.statistics()
		self.folderStatusDescription = FolderStatusDescription(folder)
	}

	@ViewBuilder private func statusLabel() -> some View {
		let folderStatus = FolderStatusDescription(folder)

		#if os(iOS)
			Label(folderStatus.text, systemImage: folderStatus.systemImage)
				.foregroundStyle(folderStatus.color)
				.badge(Text(folderStatus.badge).foregroundStyle(folderStatus.color))
		#else
			Label(folderStatus.fullText, systemImage: folderStatus.systemImage)
				.foregroundStyle(folderStatus.color)
		#endif
	}
}

struct FolderSyncTypePicker: View {
	private enum FolderSyncType: String {
		case allFiles = "allFiles"
		case selectedFiles = "selectedFiles"
	}

	@Environment(AppState.self) private var appState
	@State private var changeProhibited = true
	@State private var folderSyncType: FolderSyncType? = nil
	var folder: SushitrainFolder

	var body: some View {
		if folder.exists() {
			Picker("Selection", selection: $folderSyncType) {
				Text("All files").tag(FolderSyncType.allFiles)
				Text("Selected files").tag(FolderSyncType.selectedFiles)
			}
			.onChange(of: folderSyncType) { _, nv in
				try? self.folder.setSelective(nv == .selectedFiles)
			}
			.pickerStyle(.menu)
			.disabled(changeProhibited)
			.onAppear {
				self.update()
			}
		}
	}

	private func update() {
		self.folderSyncType = self.folder.isSelective() ? .selectedFiles : .allFiles

		// Only allow changes to selection mode when folder is idle
		if !folder.isIdleOrSyncing {
			changeProhibited = true
			return
		}

		// Prohibit change in selection mode when there are extraneous files
		Task.detached {
			var hasExtra: ObjCBool = false
			do {
				let _ = try folder.hasExtraneousFiles(&hasExtra)
				let hasExtraFinal = hasExtra
				DispatchQueue.main.async {
					changeProhibited = hasExtraFinal.boolValue
				}
			}
			catch {
				Log.warn(
					"Error calling hasExtraneousFiles: \(error.localizedDescription)"
				)
				DispatchQueue.main.async {
					changeProhibited = true
				}
			}
		}
	}
}

struct FolderDirectionPicker: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder
	@State private var changeProhibited: Bool = true
	@State private var folderType: String? = nil

	var body: some View {
		if folder.exists() {
			Picker("Direction", selection: $folderType) {
				Text("Send and receive").tag(SushitrainFolderTypeSendReceive as String?)
				Text("Receive only").tag(SushitrainFolderTypeReceiveOnly as String?)

				// Cannot be selected, but should be here when it is set
				if folder.folderType() == SushitrainFolderTypeSendOnly {
					Text("Send only").tag(SushitrainFolderTypeSendOnly as String?)
				}
			}
			.pickerStyle(.menu)
			.disabled(changeProhibited)
			.onAppear {
				self.update()
			}
			.onChange(of: folderType) { _, nv in
				try? self.folder.setFolderType(nv)
			}
		}
	}

	private func update() {
		self.folderType = self.folder.folderType()
		// Only allow changes to selection mode when folder is idle
		if !folder.isIdleOrSyncing {
			changeProhibited = true
			return
		}

		// Prohibit change in selection mode when there are extraneous files
		Task.detached {
			do {
				var hasExtra: ObjCBool = false
				let _ = try folder.hasExtraneousFiles(&hasExtra)
				let hasExtraFinal = hasExtra
				DispatchQueue.main.async {
					changeProhibited = hasExtraFinal.boolValue
				}
			}
			catch {
				Log.warn(
					"Error calling hasExtraneousFiles: \(error.localizedDescription)"
				)
				DispatchQueue.main.async {
					changeProhibited = true
				}
			}
		}
	}
}

private struct PhotoFolderSectionView: View {
	var body: some View {
		Label("Photo folder", systemImage: "camera.fill").foregroundStyle(.cyan)
	}
}

private struct ExternalFolderSectionView: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder
	@State private var showPathSelector: Bool = false
	@State private var errorText: String? = nil

	var body: some View {
		let isAccessible = BookmarkManager.shared.hasBookmarkFor(folderID: folder.folderID)
		Section {
			ZStack {
				if isAccessible {
					Label("External folder", systemImage: "app.badge.checkmark").foregroundStyle(.pink)
						.onLongPressGesture {
							self.showPathSelector = true
						}
				}
				else {
					Label("Inaccessible external folder", systemImage: "xmark.app").foregroundStyle(.red).onTapGesture {
						self.tryFixBookmark()
					}
				}
			}
			// Folder selector for fixing external folders
			.fileImporter(
				isPresented: $showPathSelector, allowedContentTypes: [.folder],
				onCompletion: { result in
					switch result {
					case .success(let url):
						if appState.isInsideDocumentsFolder(url) {
							// Check if the folder path is or is inside our regular folder path - that is not allowed
							self.errorText = String(
								localized:
									"The folder you have selected is inside the app folder. Only folders outside the app folder can be selected."
							)
							return
						}

						// Attempt to create a new bookmark
						do {
							try? self.folder.setPaused(true)
							try BookmarkManager.shared.saveBookmark(folderID: self.folder.folderID, url: url)
							try folder.setPath(url.path(percentEncoded: false))
							try? self.folder.setPaused(false)
						}
						catch {
							self.errorText = String(localized: "Could not re-link folder: \(error.localizedDescription)")
							return
						}

					case .failure(let e):
						Log.warn("Failed to select folder: \(e.localizedDescription)")
					}
				}
			)
			.alert(isPresented: Binding.isNotNil($errorText)) {
				Alert(title: Text("Could not relink folder"), message: Text(errorText ?? ""), dismissButton: .default(Text("OK")))
			}
		} footer: {
			if isAccessible {
				Text("This folder is not in the default location, and may belong to another app.")
			}
			else {
				Text(
					"This folder is external to this app, and cannot be accessed anymore. To resolve this issue, unlink the folder and re-add it."
				)
			}
		}
	}

	private func tryFixBookmark() {
		// Pause the folder
		try? self.folder.setPaused(true)

		if BookmarkManager.shared.hasBookmarkFor(folderID: self.folder.folderID) {
			Log.info("We already have a bookmark for folder \(self.folder.folderID)")
		}

		if let u = self.folder.localNativeURL {
			do {
				try BookmarkManager.shared.saveBookmark(folderID: self.folder.folderID, url: u)
			}
			catch {
				Log.warn("while attempting bookmark recreation: \(error.localizedDescription)")
			}
		}

		// Do we have a bookmark now?
		if BookmarkManager.shared.hasBookmarkFor(folderID: self.folder.folderID) {
			Log.info("We now have a bookmark for folder \(self.folder.folderID)")
			return
		}

		self.showPathSelector = true
	}
}

struct ExternalFolderInaccessibleView: View {
	@Environment(AppState.self) private var appState

	var folder: SushitrainFolder
	@State private var showPathSelector: Bool = false
	@State private var errorText: String? = nil

	var body: some View {
		let isAccessible = BookmarkManager.shared.hasBookmarkFor(folderID: folder.folderID)

		if isAccessible {
			ContentUnavailableView(
				"External folder",
				systemImage: "app.badge.checkmark",
				description: Text("The folder is accessible.")
			)
		}
		else {
			ContentUnavailableView(
				label: {
					Label("Inaccessible folder", systemImage: "xmark.app")
				},
				description: {
					Text(
						"Synctrain cannot access this folder anymore. Please click the button below to re-select the folder on your system. This should re-grant Synctrain access to the folder."
					)
				},
				actions: {
					Button("Re-link folder...", systemImage: "link") {
						self.tryFixBookmark()
					}
				}
			)
			// Folder selector for fixing external folders
			.fileImporter(
				isPresented: $showPathSelector, allowedContentTypes: [.folder],
				onCompletion: { result in
					switch result {
					case .success(let url):
						if appState.isInsideDocumentsFolder(url) {
							// Check if the folder path is or is inside our regular folder path - that is not allowed
							self.errorText = String(
								localized:
									"The folder you have selected is inside the app folder. Only folders outside the app folder can be selected."
							)
							return
						}

						// Attempt to create a new bookmark
						do {
							try? self.folder.setPaused(true)
							try BookmarkManager.shared.saveBookmark(folderID: self.folder.folderID, url: url)
							try folder.setPath(url.path(percentEncoded: false))
							try? self.folder.setPaused(false)
						}
						catch {
							self.errorText = String(localized: "Could not re-link folder: \(error.localizedDescription)")
							return
						}

					case .failure(let e):
						Log.warn("Failed to select folder: \(e.localizedDescription)")
					}
				}
			)
			.alert(isPresented: Binding.isNotNil($errorText)) {
				Alert(title: Text("Could not relink folder"), message: Text(errorText ?? ""), dismissButton: .default(Text("OK")))
			}
		}
	}

	private func tryFixBookmark() {
		// Pause the folder
		try? self.folder.setPaused(true)

		if BookmarkManager.shared.hasBookmarkFor(folderID: self.folder.folderID) {
			Log.info("We already have a bookmark for folder \(self.folder.folderID)")
		}

		if let u = self.folder.localNativeURL {
			do {
				try BookmarkManager.shared.saveBookmark(folderID: self.folder.folderID, url: u)
			}
			catch {
				Log.warn("while attempting bookmark recreation: \(error.localizedDescription)")
			}
		}

		// Do we have a bookmark now?
		if BookmarkManager.shared.hasBookmarkFor(folderID: self.folder.folderID) {
			Log.info("We now have a bookmark for folder \(self.folder.folderID)")
			return
		}

		self.showPathSelector = true
	}
}

struct FolderView: View {
	var folder: SushitrainFolder
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	@State private var advancedExpanded = false
	@State private var possiblePeers: [SushitrainPeer] = []
	@State private var unsupportedDataProtection = false

	func update() async {
		self.possiblePeers = await appState.peers().sorted().filter({ d in !d.isSelf() })
		self.unsupportedDataProtection =
			self.folder.isRegularFolder && URL(fileURLWithPath: self.folder.path()).hasUnsupportedProtection()
	}

	var body: some View {
		let isExternal = folder.isExternal
		let isPhotoFolder = folder.isPhotoFolder

		Form {
			if folder.exists() {
				if isPhotoFolder {
					PhotoFolderSectionView()
				}
				else if isExternal == true {
					ExternalFolderSectionView(folder: folder)
				}

				if self.unsupportedDataProtection {
					Section {
						Label("Limited access", systemImage: "xmark.circle")
							.foregroundStyle(.red)
					} footer: {
						Text("The selected folder is protected, and therefore cannot be accessed while the device is locked.")
					}
				}

				Section {
					Text("Folder ID").badge(Text(folder.folderID))

					LabeledContent {
						TextField(
							"",
							text: Binding(get: { folder.label() }, set: { lbl in try? folder.setLabel(lbl) }),
							prompt: Text(folder.folderID)
						)
						.multilineTextAlignment(.trailing)
					} label: {
						Text("Display name")
					}

					FolderDirectionPicker(folder: folder).disabled(isPhotoFolder)

					FolderSyncTypePicker(folder: folder).disabled(isPhotoFolder)
				} header: {
					Text("Folder settings")
				} footer: {
					if isPhotoFolder {
						Text("Photo folders can only be send-only and cannot be selectively synchronized.")
					}
				}

				Section {
					Toggle(
						"Synchronize",
						isOn: Binding(
							get: { !folder.isPaused() },
							set: { active in try? folder.setPaused(!active) })
					)
				}

				if folder.isPhotoFolder {
					PhotoFolderSettingsView(folder: self.folder)
				}

				if !possiblePeers.isEmpty {
					Section(header: Text("Shared with")) {
						ForEach(self.possiblePeers, id: \.self.id) { (addr: SushitrainPeer) in
							ShareWithDeviceToggleView(
								peer: addr, folder: folder,
								showFolderName: false)
						}
					}
				}

				if folder.isRegularFolder || folder.isPhotoFolder {
					NavigationLink(destination: AdvancedFolderSettingsView(folder: self.folder)) {
						Label("Advanced folder settings", systemImage: "gear")
					}
				}
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.navigationTitle(folder.displayName)
		.task {
			await self.update()
		}
	}
}

struct ShareWithDeviceToggleView: View {
	@Environment(AppState.self) private var appState
	let peer: SushitrainPeer
	let folder: SushitrainFolder
	let showFolderName: Bool

	@State private var editEncryptionPasswordDeviceID = ""
	@State private var showEditEncryptionPassword = false
	@State private var isShared: Bool? = nil
	@State private var isPending: Bool = false
	@State private var isSharedEncrypted: Bool = false

	private func share(_ shared: Bool) {
		do {
			if shared && peer.isUntrusted() {
				editEncryptionPasswordDeviceID = peer.deviceID()
				showEditEncryptionPassword = true
			}
			else {
				try folder.share(withDevice: peer.deviceID(), toggle: shared, encryptionPassword: "")
			}
		}
		catch let error {
			Log.warn("Error sharing folder: " + error.localizedDescription)
		}
		Task {
			self.update()
		}
	}

	var body: some View {
		HStack {
			let isSharedBinding = Binding(
				get: {
					return self.isShared ?? false
				},
				set: { nv in
					share(nv)
				})

			if showFolderName {
				Toggle(folder.displayName, systemImage: "folder.fill", isOn: isSharedBinding)
					.bold(isPending)
					.disabled(self.isShared == nil)
			}
			else {
				Toggle(peer.displayName, systemImage: peer.systemImage, isOn: isSharedBinding)
					.bold(isPending)
					.disabled(self.isShared == nil)
			}

			Button(
				"Encryption password", systemImage: isSharedEncrypted ? "lock" : "lock.open",
				action: {
					editEncryptionPasswordDeviceID = peer.deviceID()
					showEditEncryptionPassword = true
				}
			).labelStyle(.iconOnly).disabled(self.isShared == nil)
		}
		.sheet(isPresented: $showEditEncryptionPassword) {
			NavigationStack {
				ShareFolderWithDeviceDetailsView(
					folder: self.folder,
					deviceID: $editEncryptionPasswordDeviceID)
			}
		}
		.onChange(of: showEditEncryptionPassword) { _, nv in
			if !nv {
				self.update()
			}
		}
		.task {
			self.update()
		}
	}

	private func update() {
		if let swid = folder.sharedWithDeviceIDs() {
			self.isShared = swid.asArray().contains(peer.deviceID())
		}
		else {
			self.isShared = nil
		}

		let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
		self.isSharedEncrypted = sharedEncrypted.contains(peer.deviceID())

		let pendingPeerIDs = Set(
			(try? appState.client.devicesPendingFolder(self.folder.folderID))?.asArray() ?? [])
		self.isPending = pendingPeerIDs.contains(self.peer.deviceID())
	}
}

private struct FolderThumbnailSettingsView: View {
	@Environment(AppState.self) private var appState
	let folder: SushitrainFolder

	@State private var showGenerateThumbnails = false
	@State private var showGenerateThumbnailsConfirm = false
	@State private var showClearThumbnailsConfirm = false
	@State private var diskCacheSizeBytes: UInt? = nil
	@State private var deletingFromSharedCache = false
	@State private var settings = ThumbnailGeneration.disabled

	private var insidePathBinding: Binding<String> {
		return Binding(
			get: {
				let tg = FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
				if case ThumbnailGeneration.inside(path: let path) = tg {
					return path
				}
				return ThumbnailGeneration.defaultInsideFolderThumbnailPath
			},
			set: { newPath in
				FolderSettingsManager.shared.mutateSettingsFor(folderID: folder.folderID) { fs in
					fs.thumbnailGeneration = .inside(path: newPath)
				}
			})
	}

	private var insideChoice: ThumbnailGeneration {
		switch settings {
		case .inside(let path): return .inside(path: path)
		default: return .inside(path: ThumbnailGeneration.defaultInsideFolderThumbnailPath)
		}
	}

	private var localDirectoryEntry: SushitrainEntry? {
		switch settings {
		case .inside(let path):
			let e = try? self.folder.getFileInformation(path)
			if let e = e, e.isDirectory() && !e.isDeleted() {
				return e
			}
			return nil
		default:
			return nil
		}
	}

	private func updateSize() async {
		self.diskCacheSizeBytes = nil
		switch self.settings {
		case .inside(_), .deviceLocal:
			let ic = ImageCache.forFolder(self.folder)
			if ic !== ImageCache.shared {
				self.diskCacheSizeBytes = try? await ic.diskCacheSizeBytes()
			}
		case .disabled, .global: return
		}
	}

	var canClear: Bool {
		switch self.settings {
		case .inside(path: let p): return !p.isEmpty
		case .deviceLocal: return true
		case .disabled, .global: return false
		}
	}

	var body: some View {
		Form {
			Section {
				Picker("Thumbnails", selection: $settings) {
					Text("Do not cache").tag(ThumbnailGeneration.disabled)
					Text("Use app-wide cache").tag(ThumbnailGeneration.global)
					Text("Cache inside folder").tag(insideChoice)
					Text("Cache on this device").tag(ThumbnailGeneration.deviceLocal)
				}
				.pickerStyle(.menu)

				if case ThumbnailGeneration.inside(_) = settings {
					LabeledContent {
						TextField("", text: insidePathBinding, prompt: Text(ThumbnailGeneration.defaultInsideFolderThumbnailPath))
							.multilineTextAlignment(.trailing)
					} label: {
						Text("Subdirectory")
					}

					if let localDirectoryEntry = self.localDirectoryEntry, self.folder.isSelective() {
						Toggle(
							"Synchronize",
							isOn: Binding(
								get: { localDirectoryEntry.isExplicitlySelected() },
								set: {
									try? localDirectoryEntry.setExplicitlySelected($0)
								})
						)
						.disabled(localDirectoryEntry.isSelected() != localDirectoryEntry.isExplicitlySelected())
					}
				}
			} footer: {
				if let bytes = self.diskCacheSizeBytes {
					let formatter = ByteCountFormatter()
					Text(
						"Currently the thumbnail cache is using \(formatter.string(fromByteCount: Int64(bytes))) of disk space."
					)
				}
			}

			if settings != .disabled {
				Section {
					Button("Generate thumbnails", systemImage: "photo.stack") {
						self.showGenerateThumbnailsConfirm = true
					}
					.disabled(settings == .disabled || settings == .global && !appState.userSettings.cacheThumbnailsToDisk)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
					.confirmationDialog(
						"Generating thumbnails may take a while and could use a lot of data. It is advisable to connect to a Wi-Fi network before proceeding. Are you sure you want to continue?",
						isPresented: $showGenerateThumbnailsConfirm, titleVisibility: .visible
					) {
						Button("Generate thumbnails") {
							self.showGenerateThumbnails = true
							self.diskCacheSizeBytes = nil
						}
					}
				}
			}

			if self.canClear {
				Section {
					if case .inside(_) = settings {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								let ic = ImageCache.forFolder(self.folder)
								if let url = ic.customCacheDirectory {
									openURLInSystemFilesApp(url: url)
								}
							}
						)
					}

					Button("Clear thumbnail cache", systemImage: "eraser.line.dashed.fill") {
						self.showClearThumbnailsConfirm = true
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
					.foregroundStyle(.red)
					.confirmationDialog(
						"This will delete all files from inside the configured subdirectory. Are you sure you want to continue?",
						isPresented: $showClearThumbnailsConfirm, titleVisibility: .visible
					) {
						Button("Delete thumbnails") {
							let ic = ImageCache.forFolder(self.folder)
							if ic !== ImageCache.shared {
								ic.clear()
								self.diskCacheSizeBytes = nil
							}
						}
					}
				}
			}

			if appState.userSettings.cacheThumbnailsToDisk {
				Section {
					Button("Remove thumbnails from app-wide cache", systemImage: "eraser.line.dashed.fill") {
						deletingFromSharedCache = true
						Task.detached {
							do {
								try await self.deleteFromSharedCache(prefix: nil)
							}
							catch {
								Log.warn("Failed deleting from shared cache: \(error.localizedDescription)")
							}

							DispatchQueue.main.async {
								Task {
									self.diskCacheSizeBytes = nil
									await self.updateSize()
									deletingFromSharedCache = false
								}
							}
						}
					}
					.disabled(deletingFromSharedCache)
					.foregroundStyle(.red)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				} footer: {
					Text("Remove thumbnails that were generated for files in this folder from the app-wide thumbnail cache.")
				}
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.navigationTitle("Thumbnails")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.onChange(of: settings, initial: false) { _, nv in
			FolderSettingsManager.shared.mutateSettingsFor(folderID: folder.folderID) { fs in
				fs.thumbnailGeneration = nv
			}
		}
		.onAppear {
			self.settings = FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
		}
		.task {
			await Task.detached {
				await self.updateSize()
			}.value
		}
		.sheet(isPresented: $showGenerateThumbnails) {
			NavigationStack {
				FolderGenerateThumbnailsView(isShown: $showGenerateThumbnails, folder: self.folder)
					.navigationTitle("Generate thumbnails")
					#if os(iOS)
						.navigationBarTitleDisplayMode(.inline)
					#endif
					.toolbar {
						SheetButton(role: .cancel) {
							showGenerateThumbnails = false
						}
					}
			}
		}
	}

	private func deleteFromSharedCache(prefix: String?) async throws {
		// Iterate over this folder's entries
		let files = try self.folder.list(prefix, directories: false, recurse: false)

		for idx in 0..<files.count() {
			let filePath = files.item(at: idx)
			if Task.isCancelled {
				Log.info("Thumbnail generate task cancelled")
				return
			}

			let fullPath = (prefix ?? "") + "/" + filePath

			if let file = try? self.folder.getFileInformation(fullPath) {
				// Recurse into subdirectories (depth-first)
				if file.isDirectory() {
					try await self.deleteFromSharedCache(prefix: file.path())
				}

				try? ImageCache.shared.remove(cacheKey: file.cacheKey)
			}
			else {
				Log.warn("Could not get file entry for path \(filePath)")
			}
		}
	}
}

private struct FolderGenerateThumbnailsView: View {
	@Environment(AppState.self) private var appState
	@Binding var isShown: Bool
	let folder: SushitrainFolder
	@State private var error: String? = nil
	@State private var totalFiles: Int = 0
	@State private var processedFiles: Int = 0
	@State private var lastThumbnail: AsyncImagePhase? = nil
	@State private var lastThumbnailTime: Date = Date.distantPast
	@State private var generatingTask: Task<Void, Never>? = nil

	private func startGenerating() {
		if self.generatingTask != nil {
			return
		}

		self.generatingTask = Task {
			Log.info("Start generating thumbnails")
			let ic = ImageCache.forFolder(self.folder)
			if !ic.diskCacheEnabled || !ic.diskHasSpace {
				self.error = String(
					localized:
						"There is very little disk space available. Free up some space and try again."
				)
				return
			}

			#if os(iOS)
				UIApplication.shared.isIdleTimerDisabled = true
			#endif

			do {
				let stats = try self.folder.statistics()
				self.totalFiles = stats.global?.files ?? 0
				self.processedFiles = 0
				try await self.generateFor(prefix: nil)
				self.isShown = false
			}
			catch {
				self.error = error.localizedDescription
			}
			#if os(iOS)
				UIApplication.shared.isIdleTimerDisabled = false
			#endif
		}
	}

	var body: some View {
		VStack {
			if let e = error {
				Text(e).foregroundStyle(.red)
			}
			else {
				if let img = self.lastThumbnail {
					switch img {
					case .success(let img):
						img.frame(maxWidth: 200, maxHeight: 200)
							.scaledToFit()
							.clipShape(.rect(cornerRadius: 10))
							.contentShape(.rect)
					default:
						Rectangle().frame(width: 200, height: 200)
							.foregroundStyle(.gray)
							.opacity(0.2)
							.clipShape(.rect(cornerRadius: 10))
							.contentShape(.rect)
					}
				}
				else {
					Rectangle().frame(width: 200, height: 200).foregroundStyle(.gray).opacity(0.2)
						.clipShape(.rect(cornerRadius: 10))
						.contentShape(.rect)
				}

				Text("Generating thumbnails... (\(self.processedFiles) / \(self.totalFiles))")
				if self.totalFiles > 0 {
					ProgressView(value: Float(self.processedFiles), total: Float(max(self.totalFiles, self.processedFiles)))
				}
			}
		}
		.padding(30)
		.alert(isPresented: Binding.isNotNil($error)) {
			Alert(
				title: Text("An error occurred"), message: Text(error!),
				dismissButton: .default(Text("OK")) {
					isShown = false
				})
		}
		.onAppear {
			self.startGenerating()
		}
		.onDisappear {
			self.generatingTask?.cancel()
		}
	}

	private static let thumbnailInterval: TimeInterval = 1.0

	private func generateFor(prefix: String?) async throws {
		let tg = FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
		try await generateThumbnailsFor(
			folder: self.folder, prefix: prefix, userSettings: appState.userSettings, generation: tg,
			callback: { thumb in
				if (-lastThumbnailTime.timeIntervalSinceNow) > Self.thumbnailInterval {
					lastThumbnailTime = Date.now
					self.lastThumbnail = thumb
				}
				self.processedFiles += 1
			})
	}
}

private struct AdvancedFolderSettingsView: View {
	@Environment(AppState.self) private var appState
	let folder: SushitrainFolder

	var body: some View {
		let isExternal = folder.isExternal

		Form {
			#if os(iOS)
				if !folder.isSelective() && !folder.isPhotoFolder {
					Section {
						NavigationLink(
							destination: IgnoresView(folder: self.folder)
								.navigationTitle("Files to ignore")
								#if os(iOS)
									.navigationBarTitleDisplayMode(.inline)
								#endif
						) {
							Label(
								"Files to ignore",
								systemImage: "rectangle.dashed")
						}
					}
				}
			#endif

			Section {
				NavigationLink(
					destination:
						FolderThumbnailSettingsView(folder: folder)
				) {
					Label("Thumbnails", systemImage: "photo.stack")
				}
			}

			Section {
				NavigationLink(
					destination: ExternalSharingSettingsView(folder: self.folder)
				) {
					Label("External sharing", systemImage: "link.circle.fill")
				}
			}

			if !folder.isPhotoFolder {
				Section("System settings") {
					#if os(iOS)
						Toggle(
							"Include in device back-up",
							isOn: Binding(
								get: {
									if let f = folder.isExcludedFromBackup {
										return !f
									}
									return false
								},
								set: { nv in
									folder.isExcludedFromBackup = !nv
								})
						).disabled(isExternal != false)
					#endif

					Toggle(
						"Hide in Files app",
						isOn: Binding(
							get: {
								if let f = folder.isHidden { return f }
								return false
							},
							set: { nv in
								folder.isHidden = nv
							})
					).disabled(isExternal != false)
				}
			}

			Section("File handling") {
				LabeledContent {
					TextField(
						"",
						text: Binding(
							get: {
								let interval: Int = folder.rescanIntervalSeconds() / 60
								return "\(interval)"
							},
							set: { (lbl: String) in
								if !lbl.isEmpty {
									let interval = Int(lbl) ?? 0
									try? folder.setRescanInterval(interval * 60)
								}
							}), prompt: Text("")
					)
					.multilineTextAlignment(.trailing)
				} label: {
					Text("Rescan interval (minutes)")
				}

				if !folder.isPhotoFolder {
					Toggle(
						"Keep conflicting versions",
						isOn: Binding(
							get: {
								return folder.maxConflicts() != 0
							},
							set: { nv in
								try? folder.setMaxConflicts(nv ? -1 : 0)
							}))
				}
			}

			if !folder.isPhotoFolder {
				Section {
					Toggle(
						"Watch for changes",
						isOn: Binding(get: { folder.isWatcherEnabled() }, set: { try? folder.setWatcherEnabled($0) }))

					if folder.isWatcherEnabled() {
						LabeledContent {
							TextField(
								"",
								text: Binding(
									get: {
										let interval: Int = folder.watcherDelaySeconds()
										return "\(interval)"
									},
									set: { (lbl: String) in
										if !lbl.isEmpty {
											let interval = Int(lbl) ?? 0
											try? folder.setWatcherDelaySeconds(interval)
										}
									}), prompt: Text("")
							)
							.multilineTextAlignment(.trailing)
						} label: {
							Text("Delay for processing changes (seconds)")
						}
					}
				} footer: {
					#if os(iOS)
						Text(
							"Because of limitations in iOS, watching for changes will only work for about 250 subdirectories in total across all folders. If you are experiencing issues, disable this setting for all folders."
						)
					#endif
				}
			}
		}
		.navigationTitle(Text("Advanced folder settings"))
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
	}
}
