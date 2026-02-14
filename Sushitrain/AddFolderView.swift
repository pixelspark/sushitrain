// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct AddFolderView: View {
	enum ShowAlert: Identifiable {
		var id: String {
			switch self {
			case .error(text: let t): return t
			case .addingExternalFolderWarning: return "addExternal"
			}
		}

		case error(text: String)
		case addingExternalFolderWarning
	}

	@Binding var folderID: String
	var shareWithPendingPeersByDefault: Bool = false
	var folderIDReadOnly: Bool = false

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@FocusState private var idFieldFocus: Bool

	@State var sharedWith = Set<String>()
	@State var folderPath: URL? = nil
	@State private var possiblePeers: [SushitrainPeer] = []
	@State private var pendingPeers: [String] = []
	@State private var showPathSelector: Bool = false
	@State private var isSelective = true
	@State private var isPhotoFolder = false
	@State private var isReceiveEncryptedFolder = false
	@State private var photoFolderConfig = PhotoFSConfiguration()
	@State private var showAlert: ShowAlert? = nil

	// Whether any device offers this folder as receive encrypted
	@State private var isOfferedReceiveEncrypted = false

	var folderExists: Bool {
		appState.client.folder(withID: self.folderID) != nil
	}

	@ViewBuilder private func folderIDSection() -> some View {
		Section {
			TextField("", text: $folderID, prompt: Text("XXXX-XXXX"))
				.focused($idFieldFocus)
				.disabled(self.folderIDReadOnly)
				#if os(iOS)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.asciiCapable)
				#endif
		} header: {
			Text("Folder ID")
		} footer: {
			Text(
				"The folder ID must be the same on each device for this folder, and cannot be changed later. You can customize the display name of the folder after creation."
			)
		}
	}

	@ViewBuilder private func folderTypeSection() -> some View {
		Section {
			Button("Regular folder", systemImage: self.folderPath == nil && !isPhotoFolder ? "checkmark.circle.fill" : "circle")
			{
				self.folderPath = nil
				self.isPhotoFolder = false
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif

			// Only allow creation of photo folders for non-discovered folders
			if !folderIDReadOnly {
				Button("Photo folder", systemImage: self.isPhotoFolder ? "checkmark.circle.fill" : "circle") {
					self.isPhotoFolder = true
					self.isReceiveEncryptedFolder = false
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			}

			Button(action: {
				self.showPathSelector = true
			}) {
				if let u = self.folderPath, !isPhotoFolder {
					Label(
						"Existing folder: '\(u.lastPathComponent)'",
						systemImage: "checkmark.circle.fill"
					).contextMenu {
						Text(u.path(percentEncoded: false))
					}
				}
				else {
					Label("Existing folder...", systemImage: "circle")
				}
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif
		} header: {
			Text("Folder type")
		} footer: {
			if self.isPhotoFolder {
				Text(
					"A photo folder contains photos from selected albums from your photo library. Because photos are read directly from the photo album, the photo folder itself does not take up storage space on this device. Photo folders are read-only and send-only, which means that you cannot add files to the folder, nor modify or delete photos in the folder."
				)
			}
		}
	}

	@ViewBuilder private func folderSyncTypeSection() -> some View {
		Section {
			Picker("Synchronize", selection: $isSelective) {
				Text("All files").tag(false)
				Text("Selected files").tag(true)
			}
		} footer: {
			if isSelective {
				Text(
					"Only files that you select will be copied to this device. You can still access all files in the folder on demand when connected to other devices that have a copy of the file."
				)
			}
			else {
				Text("All files in the folder will be copied to this device.")
			}
		}
	}

	@ViewBuilder private func shareWithSection() -> some View {
		Section(header: Text("Share with")) {
			ForEach(self.possiblePeers, id: \.self.id) { (peer: SushitrainPeer) in
				let shared = Binding(
					get: { return sharedWith.contains(peer.deviceID()) },
					set: { share in
						if share {
							sharedWith.insert(peer.deviceID())
						}
						else {
							sharedWith.remove(peer.deviceID())
						}
					})

				let isOffered = pendingPeers.contains(peer.deviceID())
				Toggle(
					peer.displayName, systemImage: peer.systemImage,
					isOn: shared
				)
				.bold(isOffered)
				.foregroundStyle(isOffered ? .blue : .primary)
				.disabled(peer.isUntrusted())
			}

			Button("Select all devices offering this folder") {
				sharedWith = Set(pendingPeers)
			}
			.disabled(pendingPeers.isEmpty)
			#if os(macOS)
				.buttonStyle(.link)
			#endif
		}.id("shareWith")
	}

	var body: some View {
		NavigationStack {
			Form {
				self.folderIDSection()

				self.folderTypeSection()

				if !isPhotoFolder && isOfferedReceiveEncrypted {
					Section {
						Toggle("Receive encrypted", isOn: $isReceiveEncryptedFolder)
					} footer: {
						if isReceiveEncryptedFolder {
							Text(
								"This device will receive encrypted files from other devices. The files are stored on this device, but cannot be accessed from this device."
							)
						}
					}
				}

				if isPhotoFolder {
					PhotoFolderConfigurationView(config: $photoFolderConfig)
				}

				if !isPhotoFolder && !isReceiveEncryptedFolder {
					self.folderSyncTypeSection()
				}

				if !possiblePeers.isEmpty {
					self.shareWithSection()
				}
			}
			#if os(macOS)
				.formStyle(.grouped)
			#endif
			.onAppear {
				idFieldFocus = true
			}
			.task {
				await self.update()
			}
			.onChange(of: folderID, initial: false) { _, _ in
				Task {
					await self.update()
				}
			}
			.onChange(of: shareWithPendingPeersByDefault, initial: false) { _, _ in
				Task {
					await self.update()
				}
			}
			.toolbar {
				SheetButton(role: .add, isDisabled: folderID.isEmpty || folderExists) {
					if self.folderPath != nil {
						self.showAlert = .addingExternalFolderWarning
					}
					else {
						self.add()
					}
				}

				SheetButton(role: .cancel) {
					dismiss()
				}
			}
			.navigationTitle("Add folder")
			.alert(item: self.$showAlert) { sa in
				switch sa {
				case .error(let errorText):
					Alert(
						title: Text("Could not add folder"), message: Text(errorText),
						dismissButton: .default(Text("OK")))

				case .addingExternalFolderWarning:
					Alert(
						title: Text("Adding a folder from another app"),
						message: Text(
							"You are adding a folder that may be controlled by another app. This can cause issues, for instance when synchronization changes the app's files structure in an unsupported way. Are you sure you want to continue?"
						),
						primaryButton: .destructive(Text("Continue")) {
							self.add()
						},
						secondaryButton: .cancel(Text("Cancel"))
					)
				}
			}
			.fileImporter(
				isPresented: $showPathSelector, allowedContentTypes: [.folder],
				onCompletion: { result in
					switch result {
					case .success(let url):
						if appState.isInsideDocumentsFolder(url) {
							// Check if the folder path is or is inside our regular folder path - that is not allowed
							self.showAlert = .error(
								text: String(
									localized:
										"The folder you have selected is inside the app folder. Only folders outside the app folder can be selected."
								))
							self.folderPath = nil
						}
						else {
							self.folderPath = url
							self.isPhotoFolder = false
						}
					case .failure(let e):
						Log.warn("Failed to select folder: \(e.localizedDescription)")
						self.folderPath = nil
					}
				})
		}
	}

	private func update() async {
		self.possiblePeers = await appState.peers().sorted().filter({ d in !d.isSelf() })
		self.pendingPeers = (try? appState.client.devicesPendingFolder(self.folderID))?.asArray() ?? []
		if self.shareWithPendingPeersByDefault && sharedWith.isEmpty {
			sharedWith = Set(pendingPeers.filter { !(appState.client.peer(withID: $0)?.isUntrusted() ?? false) })
		}

		do {
			var isOffered: ObjCBool = false
			try appState.client.isPendingFolderOfferedReceiveEncrypted(self.folderID, isOffered: &isOffered)
			self.isOfferedReceiveEncrypted = isOffered.boolValue
		}
		catch {
			self.isOfferedReceiveEncrypted = false
		}
	}

	private func add() {
		do {
			// Add the folder
			if self.isPhotoFolder {
				let path = String(data: try JSONEncoder().encode(self.photoFolderConfig), encoding: .utf8)!
				try appState.client.addSpecialFolder(self.folderID, fsType: photoFSType, folderPath: path, folderType: "sendonly")
			}
			else {
				if let fp = self.folderPath {
					// Check data protection class of target directory
					if fp.hasUnsupportedProtection() {
						self.showAlert = .error(
							text: String(
								localized: "The selected folder is protected, and therefore cannot be accessed while the device is locked."))
						return
					}

					try BookmarkManager.shared.saveBookmark(folderID: self.folderID, url: fp)

					try appState.client.addFolder(
						self.folderID,
						folderPath: fp.path(percentEncoded: false),
						createAsOnDemand: self.isSelective && !isReceiveEncryptedFolder,
						createAsReceiveEncrypted: isReceiveEncryptedFolder
					)
				}
				else {
					try appState.client.addFolder(
						self.folderID,
						folderPath: "",
						createAsOnDemand: self.isSelective && !isReceiveEncryptedFolder,
						createAsReceiveEncrypted: isReceiveEncryptedFolder
					)
				}
			}

			if let folder = appState.client.folder(withID: self.folderID) {
				if folder.isRegularFolder {
					// By default, exclude from backup
					folder.isExcludedFromBackup = true
				}

				// Add peers
				for devID in self.sharedWith {
					try folder.share(withDevice: devID, toggle: true, encryptionPassword: "")
				}
				dismiss()
			}
			else {
				// Something went wrong creating the folder{
				self.showAlert = .error(text: String(localized: "Folder could not be added"))
			}
		}
		catch let error {
			self.showAlert = .error(text: error.localizedDescription)
		}
	}
}
