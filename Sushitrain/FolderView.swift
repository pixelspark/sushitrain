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
	var folder: SushitrainFolder
	@Binding var deviceID: String
	@State var newPassword: String = ""
	@FocusState private var passwordFieldFocus: Bool
	@State private var error: String? = nil

	var body: some View {
		NavigationStack {
			Form {
				if let device = appState.client.peer(withID: deviceID) {
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
			.toolbar(content: {
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
				ToolbarItem(
					placement: .cancellationAction,
					content: {
						Button("Cancel") {
							dismiss()
						}
					})
			})
		}
		.alert(
			isPresented: Binding(
				get: { self.error != nil }, set: { nv in self.error = nv ? self.error : nil })
		) {
			Alert(title: Text("Could not set encryption key"), message: Text(self.error!))
		}
	}
}

struct FolderStatusDescription {
	var text: String
	var systemImage: String
	var color: Color
	var badge: String

	init(_ folder: SushitrainFolder) {
		self.badge = ""
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

					default:
						if !folder.isDiskSpaceSufficient() {
							(self.text, self.systemImage, self.color) = (
								String(localized: "Insufficient free storage space"), "exclamationmark.triangle.fill", .red
							)
						}
						else {
							(self.text, self.systemImage, self.color) = (
								String(localized: "Unknown state"), "exclamationmark.triangle.fill", .red
							)
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

	var body: some View {
		var error: NSError? = nil
		let status = folder.state(&error)

		if status == "syncing" && !folder.isSelective() {
			if let statistics = try? folder.statistics(), statistics.global!.bytes > 0 {
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

		if let error = error, folder.isDiskSpaceSufficient() {
			Text(error.localizedDescription).foregroundStyle(.red)
		}
	}

	@ViewBuilder private func statusLabel() -> some View {
		let folderStatus = FolderStatusDescription(folder)

		#if os(iOS)
			Label(folderStatus.text, systemImage: folderStatus.systemImage)
				.foregroundStyle(folderStatus.color)
				.badge(folderStatus.badge)
		#else
			Label(folderStatus.fullText, systemImage: folderStatus.systemImage)
				.foregroundStyle(folderStatus.color)
		#endif
	}
}

struct FolderSyncTypePicker: View {
	@Environment(AppState.self) private var appState
	@State private var changeProhibited = true
	var folder: SushitrainFolder

	var body: some View {
		if folder.exists() {
			Picker(
				"Selection",
				selection: Binding(
					get: { folder.isSelective() }, set: { s in try? folder.setSelective(s) })
			) {
				Text("All files").tag(false)
				Text("Selected files").tag(true)
			}
			.pickerStyle(.menu)
			.disabled(changeProhibited)
			.onAppear {
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
	}
}

struct FolderDirectionPicker: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder
	@State private var changeProhibited: Bool = true

	var body: some View {
		if folder.exists() {
			Picker(
				"Direction",
				selection: Binding(
					get: { folder.folderType() }, set: { s in try? folder.setFolderType(s) })
			) {
				Text("Send and receive").tag(SushitrainFolderTypeSendReceive)
				Text("Receive only").tag(SushitrainFolderTypeReceiveOnly)

				// Cannot be selected, but should be here when it is set
				if folder.folderType() == SushitrainFolderTypeSendOnly {
					Text("Send only").tag(SushitrainFolderTypeSendOnly)
				}
			}
			.pickerStyle(.menu)
			.disabled(changeProhibited)
			.onAppear {
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
			.alert(
				isPresented: .constant(self.errorText != nil),
				content: {
					Alert(title: Text("Could not relink folder"), message: Text(errorText ?? ""), dismissButton: .default(Text("OK")))
				}
			)
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
			.alert(
				isPresented: .constant(self.errorText != nil),
				content: {
					Alert(title: Text("Could not relink folder"), message: Text(errorText ?? ""), dismissButton: .default(Text("OK")))
				}
			)
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
	private enum ConfirmableAction {
		case none
		case unlinkFolder
		case removeFolder

		var message: String {
			switch self {
			case .none: return ""
			case .removeFolder:
				return String(
					localized:
						"Are you sure you want to remove this folder? Please consider carefully. All files in this folder will be removed from this device. Files that have not been synchronized to other devices yet cannot be recovered."
				)
			case .unlinkFolder:
				return String(
					localized:
						"Are you sure you want to unlink this folder? The folder will not be synchronized any longer. Files currently on this device will not be deleted."
				)
			}
		}

		var buttonTitle: String {
			switch self {
			case .none: return ""
			case .removeFolder: return String(localized: "Remove the folder and all files")
			case .unlinkFolder: return String(localized: "Unlink the folder")
			}
		}
	}

	var folder: SushitrainFolder
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var isWorking = false
	@State private var showAlert: ShowAlert? = nil
	@State private var showConfirmable: ConfirmableAction = .none
	@State private var advancedExpanded = false

	private enum ShowAlert: Identifiable {
		case error(String)
		case removeSuperfluousCompleted

		var id: String {
			switch self {
			case .error(let e): return e
			case .removeSuperfluousCompleted: return "removeSuperfluousCompleted"
			}
		}
	}

	var possiblePeers: [SushitrainPeer] {
		return appState.peers().sorted().filter({ d in !d.isSelf() })
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

				Section("Folder settings") {
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

					Toggle(
						"Synchronize",
						isOn: Binding(
							get: { !folder.isPaused() },
							set: { active in try? folder.setPaused(!active) }))
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
		.alert(item: $showAlert) { alert in
			switch alert {
			case .error(let err):
				Alert(
					title: Text("An error occurred"), message: Text(err),
					dismissButton: .default(Text("OK")))
			case .removeSuperfluousCompleted:
				Alert(
					title: Text("Unsynchronized empty subdirectories removed"),
					message: Text(
						"Subdirectories that were empty and had no files in them were removed from this device."
					), dismissButton: .default(Text("OK")))

			}
		}
		.toolbar {
			#if os(iOS)
				ToolbarItem(placement: .topBarLeading) {
					self.folderOperationsMenu()
				}
			#else
				ToolbarItem(placement: .automatic) {
					self.folderOperationsMenu()
				}
			#endif
		}
		.confirmationDialog(
			showConfirmable.message,
			isPresented: Binding(
				get: { self.showConfirmable != .none },
				set: { self.showConfirmable = $0 ? self.showConfirmable : .none }
			),
			titleVisibility: .visible
		) {
			Button(showConfirmable.buttonTitle, role: .destructive, action: self.confirmedAction)
		}
	}

	@ViewBuilder private func folderOperationsMenu() -> some View {
		Menu {
			Button("Re-scan folder", systemImage: "sparkle.magnifyingglass", action: rescanFolder)
				#if os(macOS)
					.buttonStyle(.link)
				#endif

			Divider()

			if folder.isSelective() {
				Button(
					"Remove unsynchronized empty subdirectories",
					systemImage: "eraser", role: .destructive
				) {
					self.removeUnsynchronizedEmpty()
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.foregroundColor(.red)
				.disabled(isWorking)
			}

			Divider()

			Button("Unlink folder", systemImage: "folder.badge.minus", role: .destructive) {
				showConfirmable = .unlinkFolder
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif
			.foregroundColor(.red)

			// Only allow removing a full folder when we are sure it is in the area managed by us
			if folder.isRegularFolder && folder.isExternal == false {
				Button("Remove folder", systemImage: "trash", role: .destructive) {
					showConfirmable = .removeFolder
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.foregroundColor(.red)
			}
		} label: {
			Label("Folder actions", systemImage: "ellipsis.circle")
		}
	}

	private func confirmedAction() {
		do {
			switch self.showConfirmable {
			case .none:
				return
			case .unlinkFolder:
				dismiss()
				try folder.unlinkFolderAndRemoveSettings()
			case .removeFolder:
				dismiss()
				try folder.removeFolderAndSettings()
			}
		}
		catch let error {
			self.showAlert = .error(error.localizedDescription)
		}
		self.showConfirmable = .none
	}

	private func rescanFolder() {
		do {
			try folder.rescan()
		}
		catch let error {
			self.showAlert = .error(error.localizedDescription)
		}
	}

	private func removeUnsynchronizedEmpty() {
		Task {
			do {
				self.isWorking = true
				try await Task.detached {
					try folder.removeSuperfluousSubdirectories()
					try folder.removeSuperfluousSelectionEntries()
				}.value
				self.isWorking = false
				self.showAlert = .removeSuperfluousCompleted
			}
			catch {
				self.showAlert = .error(error.localizedDescription)
			}
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

	private var isShared: Bool {
		if let swid = folder.sharedWithDeviceIDs() {
			return swid.asArray().contains(peer.deviceID())
		}
		return false
	}

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
	}

	private var isPending: Bool {
		let pendingPeerIDs = Set(
			(try? appState.client.devicesPendingFolder(self.folder.folderID))?.asArray() ?? [])
		return pendingPeerIDs.contains(self.peer.deviceID())
	}

	private var isSharedEncrypted: Bool {
		let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
		return sharedEncrypted.contains(peer.deviceID())
	}

	var body: some View {
		HStack {
			let isShared = Binding(
				get: {
					return self.isShared
				},
				set: { nv in
					share(nv)
				})

			if showFolderName {
				Toggle(folder.displayName, systemImage: "folder.fill", isOn: isShared)
					.bold(isPending)
			}
			else {
				Toggle(peer.displayName, systemImage: peer.systemImage, isOn: isShared)
					.bold(isPending)
			}

			Button(
				"Encryption password", systemImage: isSharedEncrypted ? "lock" : "lock.open",
				action: {
					editEncryptionPasswordDeviceID = peer.deviceID()
					showEditEncryptionPassword = true
				}
			).labelStyle(.iconOnly)
		}
		.sheet(isPresented: $showEditEncryptionPassword) {
			NavigationStack {
				ShareFolderWithDeviceDetailsView(
					folder: self.folder,
					deviceID: $editEncryptionPasswordDeviceID)
			}
		}
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
					.toolbar(content: {
						ToolbarItem(
							placement: .cancellationAction,
							content: {
								Button("Cancel") {
									showGenerateThumbnails = false
								}
							})
					})
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
		.alert(isPresented: Binding.constant(error != nil)) {
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
		let ic = ImageCache.forFolder(self.folder)
		let tg = FolderSettingsManager.shared.settingsFor(folderID: self.folder.folderID).thumbnailGeneration

		// If thumbnails are written to a custom folder, also write thumbnails for local images
		let forceCachingLocalFiles: Bool
		switch tg {
		case .global:
			forceCachingLocalFiles = !appState.userSettings.cacheThumbnailsToFolderID.isEmpty
		case .disabled:
			forceCachingLocalFiles = false
		case .deviceLocal:
			forceCachingLocalFiles = false
		case .inside(_):
			forceCachingLocalFiles = true
		}

		// Iterate over this folder's entries
		let files = try self.folder.list(prefix, directories: false, recurse: false)

		for idx in 0..<files.count() {
			let filePath = files.item(at: idx)
			if Task.isCancelled {
				Log.info("Thumbnail generate task cancelled")
				return
			}

			let fullPath = (prefix ?? "") + "/" + filePath

			if case .inside(path: let insidePath) = tg, fullPath.withoutStartingSlash.starts(with: insidePath) {
				Log.info("Skipping file \(fullPath), inside thumbnail directory")
				continue
			}

			if let file = try? self.folder.getFileInformation(fullPath) {
				// Recurse into subdirectories (depth-first)
				if file.isDirectory() {
					try await self.generateFor(prefix: file.path())
				}

				// Generate thumbnail for files that are not locally present (otherwise QuickLook will manage it for us)
				// except when we are writing to a custom thumbnail folder (this device can then generate thumbnails for
				// another from local files)
				if file.canThumbnail && (forceCachingLocalFiles || !file.isLocallyPresent()) {
					let thumb = await ic.getThumbnail(file: file, forceCache: forceCachingLocalFiles)

					if (-lastThumbnailTime.timeIntervalSinceNow) > Self.thumbnailInterval {
						lastThumbnailTime = Date.now
						self.lastThumbnail = thumb
					}
				}
				self.processedFiles += 1
			}
			else {
				Log.warn("Could not get file entry for path \(filePath)")
			}
		}
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
