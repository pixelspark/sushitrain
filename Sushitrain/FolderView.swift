// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct FolderStatisticsView: View {
	@ObservedObject var appState: AppState
	var folder: SushitrainFolder

	init(appState: AppState, folder: SushitrainFolder) {
		self.appState = appState
		self.folder = folder
	}

	var possiblePeers: [String: SushitrainPeer] {
		let peers = appState.peers().filter({ d in !d.isSelf() })
		var dict: [String: SushitrainPeer] = [:]
		for peer in peers {
			dict[peer.deviceID()] = peer
		}
		return dict
	}

	var body: some View {
		Form {
			let formatter = ByteCountFormatter()
			if let stats = try? self.folder.statistics() {
				if let g = stats.global {
					Section("Full folder") {
						// Use .formatted() here because zero is hidden in badges and that looks weird
						Text("Number of files").badge(g.files.formatted())
						Text("Number of directories").badge(g.directories.formatted())
						Text("File size").badge(formatter.string(fromByteCount: g.bytes))
					}
				}

				let totalLocal = Double(stats.global!.bytes)
				let myPercentage = Int(
					totalLocal > 0 ? (100.0 * Double(stats.local!.bytes) / totalLocal) : 100)

				if let local = stats.local {
					Section {
						Text("Number of files").badge(local.files.formatted())
						Text("Number of directories").badge(local.directories.formatted())
						Text("File size").badge(formatter.string(fromByteCount: local.bytes))
					} header: {
						Text("On this device: \(myPercentage)% of the full folder")
					}
				}

				let devices = self.folder.sharedWithDeviceIDs()?.asArray() ?? []
				let peers = self.possiblePeers

				if !devices.isEmpty {
					Section {
						ForEach(devices, id: \.self) { deviceID in
							if let completion = try? self.folder.completion(
								forDevice: deviceID)
							{
								if let device = peers[deviceID] {
									Label(
										device.name(),
										systemImage: "externaldrive"
									).badge(
										Text(
											"\(Int(completion.completionPct))%"
										))
								}
							}
						}
					} header: {
						Text("Other devices progress")
					} footer: {
						Text(
							"The percentage of the files a device has synchronized, relative to the part of the folder it wants to synchronize. Because devices may ignore certain files or not synchronize any files at all, the percentage does not indicate the percentage of the full folder actually present on the device."
						)
					}
				}
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
			.navigationTitle("Folder statistics: '\(self.folder.displayName)'")
		#endif

		#if os(iOS)
			.navigationTitle("Folder statistics")
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}

struct ShareFolderWithDeviceDetailsView: View {
	@ObservedObject var appState: AppState
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
						DeviceIDView(appState: appState, device: device)
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

struct FolderStatusView: View {
	@ObservedObject var appState: AppState
	var folder: SushitrainFolder

	var isAvailable: Bool {
		return self.folder.connectedPeerCount() > 0
	}

	var peerStatusText: String {
		if self.folder.exists() {
			let peerCount = (folder.sharedWithDeviceIDs()?.count() ?? 1) - 1
			return "\(folder.connectedPeerCount())/\(peerCount)"
		}
		return ""
	}

	var body: some View {
		var error: NSError? = nil
		let status = folder.state(&error)

		if !self.folder.exists() {
			Section {
				Label("Folder does not exist", systemImage: "trash").foregroundColor(.gray)
			}
		}
		else if !self.folder.isPaused() {
			let isSelective = self.folder.isSelective()
			Section {
				if !isAvailable {
					Label("Not connected", systemImage: "network.slash").badge(Text(peerStatusText))
						.foregroundColor(.gray)
				}

				// Sync status (in case non-selective or selective with selected files
				else if status == "idle" {
					if !isSelective {
						Label("Synchronized", systemImage: "checkmark.circle.fill")
							.foregroundStyle(.green).badge(Text(peerStatusText))
					}
					else {
						if self.isAvailable {
							Label("Connected", systemImage: "checkmark.circle.fill")
								.foregroundStyle(.green).badge(Text(peerStatusText))
						}
						else {
							Label("Unavailable", systemImage: "xmark.circle").badge(
								Text(peerStatusText))
						}
					}
				}
				else if status == "syncing" {
					if !isSelective {
						if let statistics = try? folder.statistics(),
							statistics.global!.bytes > 0
						{
							let formatter = ByteCountFormatter()
							if let globalBytes = statistics.global?.bytes,
								let localBytes = statistics.local?.bytes
							{
								let remainingText = formatter.string(
									fromByteCount: (globalBytes - localBytes))
								ProgressView(
									value: Double(localBytes) / Double(globalBytes),
									total: 1.0
								) {
									Label(
										"Synchronizing...",
										systemImage: "bolt.horizontal.circle"
									)
									.foregroundStyle(.orange)
									.badge(Text(remainingText))
								}.tint(.orange)
							}
						}
						else {
							Label("Synchronizing...", systemImage: "bolt.horizontal.circle")
								.foregroundStyle(.orange)
						}
					}
					else {
						Label("Synchronizing...", systemImage: "bolt.horizontal.circle")
							.foregroundStyle(.orange)
					}
				}
				else if status == "scanning" {
					Label("Scanning...", systemImage: "bolt.horizontal.circle").foregroundStyle(
						.orange)
				}
				else if status == "sync-preparing" {
					Label("Preparing to synchronize...", systemImage: "bolt.horizontal.circle")
						.foregroundStyle(.orange)
				}
				else if status == "cleaning" {
					Label("Cleaning up...", systemImage: "bolt.horizontal.circle").foregroundStyle(
						.orange)
				}
				else if status == "sync-waiting" {
					Label("Waiting to synchronize...", systemImage: "ellipsis.circle")
						.foregroundStyle(.gray)
				}
				else if status == "scan-waiting" {
					Label("Waiting to scan...", systemImage: "ellipsis.circle").foregroundStyle(
						.gray)
				}
				else if status == "clean-waiting" {
					Label("Waiting to clean...", systemImage: "ellipsis.circle").foregroundStyle(
						.gray)
				}
				else if status == "error" {
					Label("Error", systemImage: "exclamationmark.triangle.fill").foregroundStyle(
						.red)
				}
				else {
					Label("Unknown state", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
				}

				if let error = error {
					Text(error.localizedDescription).foregroundStyle(.red)
				}
			}
		}
	}
}

struct FolderSyncTypePicker: View {
	@ObservedObject var appState: AppState
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
	@ObservedObject var appState: AppState
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

private struct ExternalFolderSectionView: View {
	var folderID: String

	var body: some View {
		let isAccessible = BookmarkManager.shared.hasBookmarkFor(folderID: folderID)
		Section {
			if isAccessible {
				Label("External folder", systemImage: "app.badge.checkmark").foregroundStyle(.pink)
			}
			else {
				Label("Inaccessible external folder", systemImage: "xmark.app").foregroundStyle(.red)
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
}

struct FolderView: View {
	var folder: SushitrainFolder
	@ObservedObject var appState: AppState
	@Environment(\.dismiss) private var dismiss
	@State private var isWorking = false
	@State private var showAlert: ShowAlert? = nil
	@State private var showRemoveConfirmation = false
	@State private var showUnlinkConfirmation = false
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

		Form {
			if folder.exists() {
				#if os(iOS)
					FolderStatusView(appState: appState, folder: folder)
				#endif

				if isExternal == true {
					ExternalFolderSectionView(folderID: folder.folderID)
				}

				Section("Folder settings") {
					Text("Folder ID").badge(Text(folder.folderID))

					LabeledContent {
						TextField(
							"",
							text: Binding(
								get: { folder.label() },
								set: { lbl in try? folder.setLabel(lbl) }),
							prompt: Text(folder.folderID)
						)
						.multilineTextAlignment(.trailing)
					} label: {
						Text("Display name")
					}

					FolderDirectionPicker(appState: appState, folder: folder)
					FolderSyncTypePicker(appState: appState, folder: folder)

					Toggle(
						"Synchronize",
						isOn: Binding(
							get: { !folder.isPaused() },
							set: { active in try? folder.setPaused(!active) }))
				}

				if !possiblePeers.isEmpty {
					Section(header: Text("Shared with")) {
						ForEach(self.possiblePeers, id: \.self.id) { (addr: SushitrainPeer) in
							ShareWithDeviceToggleView(
								appState: appState, peer: addr, folder: folder,
								showFolderName: false)
						}
					}
				}

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

				#if os(iOS)
					NavigationLink(
						destination: AdvancedFolderSettingsView(
							appState: appState, folder: folder)
					) {
						Text("Advanced folder settings")
					}
				#endif

				Section {
					Button("Re-scan folder", systemImage: "sparkle.magnifyingglass") {
						do {
							try folder.rescan()
						}
						catch let error {
							self.showAlert = .error(error.localizedDescription)
						}
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif

					Button("Unlink folder", systemImage: "folder.badge.minus", role: .destructive) {
						showUnlinkConfirmation = true
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
					.foregroundColor(.red)
					.confirmationDialog(
						"Are you sure you want to unlink this folder? The folder will not be synchronized any longer. Files currently on this device will not be deleted.",
						isPresented: $showUnlinkConfirmation, titleVisibility: .visible
					) {
						Button("Unlink the folder", role: .destructive) {
							do {
								dismiss()
								try folder.unlinkFolderAndRemoveSettings()
							}
							catch let error {
								self.showAlert = .error(error.localizedDescription)
							}
						}
					}

					// Only allow removing a full folder when we are sure it is in the area managed by us
					if isExternal == false {
						Button("Remove folder", systemImage: "trash", role: .destructive) {
							showRemoveConfirmation = true
						}
						#if os(macOS)
							.buttonStyle(.link)
						#endif
						.foregroundColor(.red)
						.confirmationDialog(
							"Are you sure you want to remove this folder? Please consider carefully. All files in this folder will be removed from this device. Files that have not been synchronized to other devices yet cannot be recoered.",
							isPresented: $showRemoveConfirmation, titleVisibility: .visible
						) {
							Button("Remove the folder and all files", role: .destructive) {
								do {
									dismiss()
									try folder.removeFolderAndSettings()
								}
								catch let error {
									self.showAlert = .error(
										error.localizedDescription)
								}
							}
						}
					}

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
				}

				#if os(macOS)
					Section {
						NavigationLink(
							destination: AdvancedFolderSettingsView(
								appState: appState, folder: self.folder)
						) {
							Label("Advanced folder settings", systemImage: "gear")
						}
					}
				#endif
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
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
	@ObservedObject var appState: AppState
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
					appState: self.appState, folder: self.folder,
					deviceID: $editEncryptionPasswordDeviceID)
			}
		}
	}
}

private struct FolderThumbnailSettingsView: View {
	@ObservedObject var appState: AppState
	let folder: SushitrainFolder
	@State private var showGenerateThumbnails = false
	@State private var showGenerateThumbnailsConfirm = false
	@State private var showClearThumbnailsConfirm = false
	@State private var diskCacheSizeBytes: UInt? = nil
	
	private var settings: ThumbnailGeneration {
		get {
			return FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
		}
		set {
			FolderSettingsManager.shared.mutateSettingsFor(folderID: folder.folderID) { fs in
				fs.thumbnailGeneration = newValue
			}
		}
	}
	
	private var insidePathBinding: Binding<String> {
		return Binding(get: {
			let tg = FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
			if case ThumbnailGeneration.inside(path: let path) = tg {
				return path
			}
			return ThumbnailGeneration.DefaultInsideFolderThumbnailPath
		}, set: { newPath in
			FolderSettingsManager.shared.mutateSettingsFor(folderID: folder.folderID) { fs in
				fs.thumbnailGeneration = .inside(path: newPath)
			}
		})
	}
	
	private var insideChoice: ThumbnailGeneration {
		switch settings {
			case .inside(path: let path): return .inside(path: path)
			default: return .inside(path: ThumbnailGeneration.DefaultInsideFolderThumbnailPath)
		}
	}
	
	private var localDirectoryEntry: SushitrainEntry? {
		switch settings {
		case .inside(path: let path):
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
		case .inside(_):
			let ic = ImageCache.forFolder(self.folder)
			if ic !== ImageCache.shared {
				self.diskCacheSizeBytes = try? await ic.diskCacheSizeBytes()
			}
		case .deviceLocal, .disabled, .global: return
		}
	}
	
	var body: some View {
		let settings = self.settings
		
		let settingsBinding = Binding(get: {
			return FolderSettingsManager.shared.settingsFor(folderID: folder.folderID).thumbnailGeneration
		}, set: { newSettings in
			FolderSettingsManager.shared.mutateSettingsFor(folderID: folder.folderID) { fs in
				fs.thumbnailGeneration = newSettings
			}
		})
		
		Form {
			Section {
				Picker("Thumbnails", selection: settingsBinding) {
					Text("Do not cache").tag(ThumbnailGeneration.disabled)
					Text("Use app-wide cache").tag(ThumbnailGeneration.global)
					Text("Cache inside folder").tag(insideChoice)
					Text("Cache on this device").tag(ThumbnailGeneration.deviceLocal)
				}
				.pickerStyle(.menu)
				
				if case ThumbnailGeneration.inside(_) = settings {
					LabeledContent {
						TextField("", text: insidePathBinding, prompt: Text(ThumbnailGeneration.DefaultInsideFolderThumbnailPath))
							.multilineTextAlignment(.trailing)
					} label: {
						Text("Subdirectory")
					}
					
					if let localDirectoryEntry = self.localDirectoryEntry, self.folder.isSelective() {
						Toggle("Synchronize", isOn: Binding(get: { localDirectoryEntry.isExplicitlySelected() }, set: {
							try? localDirectoryEntry.setExplicitlySelected($0)
						}))
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
			
			Section {
				Button("Generate thumbnails", systemImage: "photo.stack") {
					self.showGenerateThumbnailsConfirm = true
				}
				.disabled(settings == .disabled || settings == .global && !appState.cacheThumbnailsToDisk)
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
			
			if case .inside(let insidePath) = settings, !insidePath.isEmpty {
				Section {
					Button("Clear thumbnail cache", systemImage: "eraser.line.dashed.fill") {
						self.showClearThumbnailsConfirm = true
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
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
		}
		.task {
			await self.updateSize()
		}
		.sheet(isPresented: $showGenerateThumbnails) {
			NavigationStack {
				FolderGenerateThumbnailsView(
					appState: self.appState, isShown: $showGenerateThumbnails, folder: self.folder
				)
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
}

private struct FolderGenerateThumbnailsView: View {
	@ObservedObject var appState: AppState
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
					default:
						Rectangle().frame(width: 200, height: 200)
							.foregroundStyle(.gray)
							.opacity(0.2)
							.clipShape(.rect(cornerRadius: 10))
					}
				}
				else {
					Rectangle().frame(width: 200, height: 200).foregroundStyle(.gray).opacity(0.2)
						.clipShape(.rect(cornerRadius: 10))
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
			forceCachingLocalFiles = !appState.cacheThumbnailsToFolderID.isEmpty
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
	@ObservedObject var appState: AppState
	let folder: SushitrainFolder

	var body: some View {
		Form {
			#if os(iOS)
				if !folder.isSelective() {
					Section {
						NavigationLink(
							destination: IgnoresView(
								appState: self.appState, folder: self.folder
							)
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
				NavigationLink(destination:
					FolderThumbnailSettingsView(appState: appState, folder: folder)
						.navigationTitle("Thumbnails")
						#if os(iOS)
							.navigationBarTitleDisplayMode(.inline)
						#endif
				) {
					Label("Thumbnails", systemImage: "photo.stack")
				}
			}
			
			Section {
				NavigationLink(
					destination: ExternalSharingSettingsView(
						folder: self.folder, appState: appState)
				) {
					Label("External sharing", systemImage: "link.circle.fill")
				}
			}
			
			Section {
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

				Toggle(
					"Watch for changes",
					isOn: Binding(get: { folder.isWatcherEnabled() }, set: { try? folder.setWatcherEnabled($0) }))

				if folder.isWatcherEnabled() {
					LabeledContent {
						TextField(
							"",
							text: Binding(
								get: {
									let interval: Int = folder .watcherDelaySeconds()
									return "\(interval)"
								},
								set: { (lbl: String) in
									if !lbl.isEmpty {
										let interval = Int(lbl) ?? 0
										try? folder .setWatcherDelaySeconds(interval)
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
		.navigationTitle(Text("Advanced folder settings"))
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
	}
}
