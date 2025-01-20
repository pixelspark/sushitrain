// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct DevicesView: View {
	@ObservedObject var appState: AppState
	@State private var viewStyle: DevicesViewStyle = .list

	enum DevicesViewStyle: String {
		case list = "list"
		#if os(macOS)
			case grid = "grid"
		#endif
	}

	var body: some View {
		ZStack {
			switch self.viewStyle {
			#if os(macOS)
				case .grid:
					DevicesGridView(appState: appState)
			#endif
			case .list:
				DevicesListView(appState: appState)
			}
		}
		.navigationTitle("Devices")
		#if os(macOS)
			.toolbar {
				ToolbarItemGroup(placement: .primaryAction) {
					Picker("View as", selection: $viewStyle) {
						Image(systemName: "list.bullet").tag(DevicesViewStyle.list)
						.accessibilityLabel(Text("List"))
						Image(systemName: "tablecells").tag(DevicesViewStyle.grid)
						.accessibilityLabel(Text("Grid"))
					}
					.pickerStyle(.segmented)
				}
			}
		#endif
	}
}

private struct DevicesListView: View {
	@ObservedObject var appState: AppState
	@State private var showingAddDevicePopup = false
	@State private var addingDeviceID: String = ""
	@State private var discoveredNewDevices: [String] = []
	@State private var peers: [SushitrainPeer] = []
	@State private var loading = true

	var body: some View {
		List {
			Section("Associated devices") {
				if peers.isEmpty {
					HStack {
						Spacer()
						if loading {
							ProgressView()
						}
						else {
							ContentUnavailableView(
								"No devices added yet",
								systemImage: "externaldrive.badge.questionmark",
								description: Text(
									"To synchronize files, first add a remote device. Either select a device from the list below, or add manually using the device ID."
								))
						}
						Spacer()
					}
				}
				else {
					ForEach(peers) { peer in
						NavigationLink(
							destination: DeviceView(device: peer, appState: appState)
						) {
							if peer.isPaused() {
								Label(
									peer.displayName,
									systemImage: "externaldrive.fill"
								).foregroundStyle(.gray)
							}
							else {
								Label(peer.displayName, systemImage: peer.systemImage)
							}
						}
					}
					.onDelete(perform: { indexSet in
						indexSet.map { idx in
							return peers[idx]
						}.forEach { peer in try? peer.remove() }
					})
				}
			}

			if !discoveredNewDevices.isEmpty {
				Section("Discovered devices") {
					ForEach(discoveredNewDevices, id: \.self) { devID in
						Label(devID, systemImage: "plus").onTapGesture {
							addingDeviceID = devID
							showingAddDevicePopup = true
						}
					}
				}
			}

			// Add peer manually
			Section {
				Button(
					"Add device...", systemImage: "plus",
					action: {
						addingDeviceID = ""
						showingAddDevicePopup = true
					}
				)
				#if os(macOS)
					.buttonStyle(.borderless)
				#endif
			}
		}
		#if os(iOS)
			.toolbar {
				if !peers.isEmpty {
					EditButton()
				}
			}
		#endif
		.sheet(isPresented: $showingAddDevicePopup) {
			AddDeviceView(appState: appState, suggestedDeviceID: $addingDeviceID)
		}
		.task {
			self.update()
		}
		.onChange(of: appState.eventCounter) {
			self.update()
		}
	}

	private func update() {
		self.loading = true
		self.peers = appState.peers().filter({ x in !x.isSelf() }).sorted()

		// Discovered peers
		let peerIDs = peers.map { $0.deviceID() }
		self.discoveredNewDevices = Array(appState.discoveredDevices.keys).filter({ d in
			!peerIDs.contains(d)
		})
		self.loading = false
	}
}

#if os(macOS)
	private enum GridViewStyle: String {
		case sharing = "sharing"
		case percentageOfGlobal = "percentageOfGlobal"
		case needBytes = "needBytes"
	}

	private struct DevicesGridView: View {
		@ObservedObject var appState: AppState
		@State private var loading = true
		@State private var peers: [SushitrainPeer] = []
		@State private var folders: [SushitrainFolder] = []
		@State private var transpose = false
		@State private var selectedPeers = Set<SushitrainPeer.ID>()
		@State private var selectedFolders = Set<SushitrainFolder.ID>()
		@State private var viewStyle: GridViewStyle = .sharing

		var body: some View {
			ZStack {
				if self.loading {
					ProgressView()
				}
				else {
					if self.transpose {
						Table(self.folders, selection: $selectedFolders) {
							TableColumn("Folder") { folder in
								Label(folder.displayName, systemImage: "folder")
							}
							.width(ideal: 100)

							TableColumnForEach(self.peers) { peer in
								TableColumn(peer.displayName) { folder in
									DevicesGridCellView(
										appState: appState, device: peer,
										folder: folder, viewStyle: viewStyle)
								}
								.width(ideal: 50)
								.alignment(.center)
							}
						}
					}
					else {
						Table(self.peers, selection: $selectedPeers) {
							TableColumn("Device") { peer in
								Label(peer.displayName, systemImage: peer.systemImage)
									.contextMenu {
										NavigationLink(
											destination: DeviceView(
												device: peer,
												appState: appState)
										) {
											Text("Properties...")
										}
									}
							}
							.width(ideal: 100)

							TableColumnForEach(self.folders) { folder in
								TableColumn(folder.displayName) { device in
									DevicesGridCellView(
										appState: appState, device: device,
										folder: folder, viewStyle: viewStyle)
								}
								.width(ideal: 50)
								.alignment(.center)
							}
						}
					}
				}
			}
			.task {
				self.update()
			}
			.toolbar {
				ToolbarItemGroup(placement: .status) {
					Picker("View as", selection: $viewStyle) {
						Text("Sharing").tag(GridViewStyle.sharing)
						Text("Completion").tag(GridViewStyle.percentageOfGlobal)
						Text("Remaining").tag(GridViewStyle.needBytes)
					}
					.pickerStyle(.segmented)
				}

				ToolbarItem(placement: .status) {
					Toggle(isOn: $transpose) {
						Label("Switch rows/columns", systemImage: "rotate.right")
					}
				}
			}
		}

		private func update() {
			self.loading = true
			self.peers = appState.peers().filter({ x in !x.isSelf() }).sorted()
			self.folders = appState.folders().sorted()
			self.loading = false
		}
	}

	private struct DevicesGridCellView: View {
		var appState: AppState
		var device: SushitrainPeer
		var folder: SushitrainFolder
		var viewStyle: GridViewStyle
		@State private var isShared: Bool = false
		@State private var isSharedEncrypted: Bool = false
		@State private var isLoading: Bool = true
		@State private var showEditEncryptionPassword = false
		@State private var completion: SushitrainCompletion? = nil

		var body: some View {
			HStack {
				switch viewStyle {
				case .sharing:
					Toggle(
						isOn: Binding(
							get: {
								return isShared
							}, set: { nv in self.share(nv) })
					) {
						EmptyView()
					}
					.disabled(self.isLoading)

					Image(systemName: "lock").help(
						"An encrypted version of the folder is shared with this device."
					).opacity(isSharedEncrypted ? 1 : 0)
				case .percentageOfGlobal:
					if isShared {
						if let c = self.completion {
							Text("\(Int(c.completionPct))%")
								.foregroundStyle(
									c.completionPct < 100 ? .red : .primary
								)
								.bold(c.completionPct < 100)
								.help(
									c.completionPct < 100
										? "This device still needs \(c.needItems) items out of \(c.globalItems)"
										: "This device has a copy of all items")
						}
					}
				case .needBytes:
					if isShared {
						if let c = self.completion {
							Text(c.needBytes.formatted(.byteCount(style: .file)))
								.foregroundStyle(
									c.completionPct < 100 ? .red : .primary
								)
								.bold(c.completionPct < 100)
								.help(
									c.completionPct < 100
										? "This device still needs \(c.needBytes.formatted(.byteCount(style: .file))) of \(c.globalBytes.formatted(.byteCount(style: .file)))"
										: "This device has a copy of all items")
						}
					}
				}
			}
			.contextMenu {
				Button(action: { self.showEditEncryptionPassword = true }) {
					Text("Properties...")
				}
			}
			.task {
				self.update()
			}
			.onChange(of: viewStyle, initial: false) { _, _ in
				self.update()
			}
			.sheet(isPresented: $showEditEncryptionPassword) {
				NavigationStack {
					ShareFolderWithDeviceDetailsView(
						appState: self.appState, folder: self.folder,
						deviceID: .constant(device.deviceID()))
				}
			}
		}

		private func update() {
			self.isLoading = true
			let devID = self.device.deviceID()
			Task.detached {
				let sharedWithDeviceIDs = folder.sharedWithDeviceIDs()?.asArray() ?? []
				let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
				let completion =
					self.viewStyle == .sharing ? nil : try? self.folder.completion(forDevice: devID)

				DispatchQueue.main.async {
					self.isShared = sharedWithDeviceIDs.contains(self.device.deviceID())
					self.isSharedEncrypted = sharedEncrypted.contains(device.deviceID())
					self.completion = completion
					self.isLoading = false
				}
			}
		}

		private func share(_ shared: Bool) {
			do {
				if shared && device.isUntrusted() {
					showEditEncryptionPassword = true
				}
				else {
					try folder.share(
						withDevice: device.deviceID(), toggle: shared, encryptionPassword: "")
					self.update()
				}
			}
			catch let error {
				Log.warn("Error sharing folder: " + error.localizedDescription)
			}
		}
	}
#endif
