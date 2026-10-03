// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

@Observable class AddFolder {
	var folderID: String
	var sharedWithDevices: [String]

	init(folderID: String = "", sharedWithDevices: [String] = []) {
		self.folderID = folderID
		self.sharedWithDevices = sharedWithDevices
	}
}

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

	private enum AddFolderViewTab: String {
		case general = "general"
		case sharing = "sharing"
	}

	@Bindable var adding: AddFolder
	@Binding var shown: Bool
	var folderIDReadOnly: Bool = false

	@Environment(AppState.self) var appState

	@State private var selectedTab = AddFolderViewTab.general
	@State private var folderPath: URL? = nil
	@State private var showPathSelector: Bool = false
	@State private var isSelective = true
	@State private var isPhotoFolder = false
	@State private var isReceiveEncryptedFolder = false
	@State private var photoFolderConfig = PhotoFSConfiguration()
	@State private var showAlert: ShowAlert? = nil

	// Whether any device offers this folder as receive encrypted
	@State private var isOfferedReceiveEncrypted = false

	@FocusState private var idFieldFocus: Bool

	var folderExists: Bool {
		appState.client.folder(withID: self.adding.folderID) != nil
	}

	var body: some View {
		VStack {
			#if os(macOS)
				self.tabSwitcher()
			#endif

			Form {
				#if os(iOS)
					Section {
						self.tabSwitcher()
					}
				#endif

				switch self.selectedTab {
				case .general:
					self.generalTab()
				case .sharing:
					self.shareWithSection()
				}
			}
			#if os(macOS)
				.formStyle(.grouped)
			#endif
			.task {
				await self.update()
			}
			.toolbar {
				SheetButton(role: .add, isDisabled: self.adding.folderID.isEmpty || folderExists) {
					if self.folderPath != nil {
						self.showAlert = .addingExternalFolderWarning
					}
					else {
						self.add()
					}
				}

				SheetButton(role: .cancel) {
					self.shown = false
				}
			}
			.navigationTitle("Add folder")
			#if os(iOS)
				.navigationBarTitleDisplayMode(.inline)
			#endif
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
		.onAppear {
			idFieldFocus = true
		}
		#if os(macOS)
			.presentationSizing(.fitted.sticky())
		#endif
	}

	@ViewBuilder private func generalTab() -> some View {
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
	}

	@ViewBuilder private func tabSwitcher() -> some View {
		Picker("Page", selection: $selectedTab) {
			Text("Settings").tag(AddFolderViewTab.general)
			Text("Share with").tag(AddFolderViewTab.sharing)
		}
		.pickerStyle(.segmented)
		.controlSize(.large)
		.dynamicTypeSize(.large)
		.listRowBackground(Color.clear)
		.background(Color.clear)
		.labelsHidden()
		.scrollContentBackground(.hidden)
		.listRowInsets(
			EdgeInsets(
				top: 0,
				leading: 0,
				bottom: 8,
				trailing: 0
			)
		)
		#if os(macOS)
			.padding(.top, 24)
		#endif
	}

	@ViewBuilder private func folderIDSection() -> some View {
		Section {
			TextField("", text: $adding.folderID, prompt: Text("XXXX-XXXX"))
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
		ShareWithDevicesView(folderID: self.adding.folderID, sharedWith: $adding.sharedWithDevices)
	}

	private func update() async {
		let appState = self.appState
		let folderID = self.adding.folderID

		var isOffered: ObjCBool = false
		do {
			try appState.client.isPendingFolderOfferedReceiveEncrypted(folderID, isOffered: &isOffered)
		}
		catch {
			isOffered = false
		}

		Task { @MainActor in
			self.isOfferedReceiveEncrypted = isOffered.boolValue
		}
	}

	private func add() {
		do {
			// Add the folder
			if self.isPhotoFolder {
				let path = String(data: try JSONEncoder().encode(self.photoFolderConfig), encoding: .utf8)!
				try appState.client.addSpecialFolder(
					self.adding.folderID, fsType: photoFSType, folderPath: path, folderType: "sendonly")
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

					try BookmarkManager.shared.saveBookmark(folderID: self.adding.folderID, url: fp)

					try appState.client.addFolder(
						self.adding.folderID,
						folderPath: fp.path(percentEncoded: false),
						createAsOnDemand: self.isSelective && !isReceiveEncryptedFolder,
						createAsReceiveEncrypted: isReceiveEncryptedFolder
					)
				}
				else {
					try appState.client.addFolder(
						self.adding.folderID,
						folderPath: "",
						createAsOnDemand: self.isSelective && !isReceiveEncryptedFolder,
						createAsReceiveEncrypted: isReceiveEncryptedFolder
					)
				}
			}

			if let folder = appState.client.folder(withID: self.adding.folderID) {
				if folder.isRegularFolder {
					// By default, exclude from backup
					folder.isExcludedFromBackup = true
				}

				// Add peers
				for devID in self.adding.sharedWithDevices {
					try folder.share(withDevice: devID, toggle: true, encryptionPassword: "")
				}
				self.shown = false
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

private struct ShareWithDevicesView: View {
	@Environment(AppState.self) private var appState
	let folderID: String
	@Binding var sharedWith: [String]

	@State private var possiblePeers: [SushitrainPeer] = []
	@State private var pendingPeers: [String] = []

	var body: some View {
		Section {
			ForEach(self.possiblePeers, id: \.self.id) { (peer: SushitrainPeer) in
				let shared = Binding<Bool>(
					get: {
						return sharedWith.contains(peer.deviceID())
					},
					set: { share in
						if share {
							sharedWith.append(peer.deviceID())
						}
						else {
							sharedWith = sharedWith.filter { $0 != peer.deviceID() }
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
				sharedWith = pendingPeers
			}
			.disabled(pendingPeers.isEmpty)
			#if os(macOS)
				.buttonStyle(.link)
			#endif
		}
		.task {
			await self.update()
		}
	}

	@concurrent private func update() async {
		let appState = await self.appState
		let folderID = self.folderID

		let possiblePeers = await appState.peers().sorted().filter({ d in !d.isSelf() })
		let pendingPeers = (try? appState.client.devicesPendingFolder(folderID))?.asArray() ?? []

		Task { @MainActor in
			self.possiblePeers = possiblePeers
			self.pendingPeers = pendingPeers
		}
	}
}
