// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct DevicesView: View {
	@EnvironmentObject var appState: AppState

	var body: some View {
		#if os(macOS)
			DevicesGridView().navigationTitle("Devices")
		#else
			DevicesListView().navigationTitle("Devices")
		#endif

	}
}

#if os(iOS)
	private struct DevicesListView: View {
		@EnvironmentObject var appState: AppState
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
									"No devices added yet", systemImage: "externaldrive.badge.questionmark",
									description: Text(
										"To synchronize files, first add a remote device. Either select a device from the list below, or add manually using the device ID."
									))
							}
							Spacer()
						}
					}
					else {
						ForEach(peers) { peer in
							NavigationLink(destination: DeviceView(device: peer)) {
								if peer.isPaused() {
									Label(peer.displayName, systemImage: "externaldrive.fill").foregroundStyle(.gray)
								}
								else {
									Label(peer.displayName, systemImage: peer.systemImage)
								}
							}
						}.onDelete(perform: { indexSet in
							let p = peers
							for idx in indexSet { try? p[idx].remove() }
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
				.toolbar { if !peers.isEmpty { EditButton() } }
			#endif
			.sheet(isPresented: $showingAddDevicePopup) {
				AddDeviceView(suggestedDeviceID: $addingDeviceID)
			}.task { self.update() }.onChange(of: appState.eventCounter) { self.update() }
		}

		private func update() {
			self.loading = true
			self.peers = appState.peers().filter({ x in !x.isSelf() }).sorted()

			// Discovered peers
			let peerIDs = peers.map { $0.deviceID() }
			self.discoveredNewDevices = Array(appState.discoveredDevices.keys).filter({ d in !peerIDs.contains(d) })
			self.loading = false
		}
	}
#endif

#if os(macOS)
	private enum GridViewStyle: String {
		case simple = "simple"
		case sharing = "sharing"
		case percentageOfGlobal = "percentageOfGlobal"
		case needBytes = "needBytes"
	}

	private struct DevicesGridView: View {
		private enum DevicesGridRow: Identifiable {
			var id: String {
				switch self {
				case .connectedDevice(let p): return p.id
				case .discoveredDevice(let s): return s
				}
			}

			case connectedDevice(SushitrainPeer)
			case discoveredDevice(String)
		}

		@EnvironmentObject var appState: AppState

		@State private var loading = true
		@State private var peers: [SushitrainPeer] = []
		@State private var folders: [SushitrainFolder] = []
		@State private var transpose = false
		@State private var selectedPeers = Set<DevicesGridRow.ID>()
		@State private var selectedFolders = Set<SushitrainFolder.ID>()
		@State private var viewStyle: GridViewStyle = .simple
		@State private var openedDevice: SushitrainPeer? = nil
		@State private var showingAddDevicePopup = false
		@State private var addingDeviceID: String = ""
		@State private var discoveredNewDevices: [String] = []
		@State private var confirmDeleteSelection = false

		@SceneStorage("DeviceTableViewConfig") private var columnCustomization: TableColumnCustomization<DevicesGridRow>

		var body: some View {
			ZStack {
				if self.loading {
					ProgressView()
				}
				else {
					if self.transpose && self.viewStyle != .simple {
						Table(self.folders, selection: $selectedFolders) {
							TableColumn("Folder") { folder in Label(folder.displayName, systemImage: "folder") }.width(ideal: 100)

							TableColumnForEach(self.peers) { peer in
								TableColumn(peer.displayName) { folder in
									DevicesGridCellView(device: peer, folder: folder, viewStyle: viewStyle)
										// Needed because for some reason SwiftUI doesn't propagate environment inside TableColumn
										.environmentObject(self.appState)
								}.width(ideal: 50).alignment(.center)
							}
						}
					}
					else {
						Table(
							of: DevicesGridRow.self, selection: $selectedPeers, columnCustomization: $columnCustomization,
							columns: {
								// Device name and label
								TableColumn("Device") { (row: DevicesGridRow) in
									switch row {
									case .connectedDevice(let peer):
										HStack {
											Image(systemName: peer.systemImage).foregroundStyle(peer.displayColor)
											Text(peer.displayName).foregroundStyle(Color.primary)
											Spacer()
										}.frame(maxWidth: .infinity)

									case .discoveredDevice(let devID):
										HStack {
											Image(systemName: "plus").foregroundStyle(Color.accentColor)

											Text(SushitrainShortDeviceID(devID)).monospaced().foregroundStyle(Color.primary)
											Spacer()
										}.frame(maxWidth: .infinity)
									}
								}.width(min: 100, ideal: self.viewStyle == .simple ? 200 : 100, max: 500).defaultVisibility(.visible)
									.customizationID("deviceName")

								if viewStyle == .simple {
									// Identicon
									TableColumn("Fingerprint") { (row: DevicesGridRow) in
										switch row {
										case .connectedDevice(let peer):
											IdenticonView(deviceID: peer.deviceID())
												.padding(5)
												// Needed because for some reason SwiftUI doesn't propagate environment inside TableColumn
												.environmentObject(self.appState)
										case .discoveredDevice(let s):
											IdenticonView(deviceID: s)
												.padding(5)
												// Needed because for some reason SwiftUI doesn't propagate environment inside TableColumn
												.environmentObject(self.appState)
										}
									}.width(min: 25, ideal: 25, max: 125).defaultVisibility(.hidden).customizationID("fingerprint")

									// Short device ID
									TableColumn("Short device ID") { (row: DevicesGridRow) in
										switch row {
										case .connectedDevice(let peer): Text(peer.shortDeviceID()).monospaced()
										case .discoveredDevice(let s): Text(SushitrainShortDeviceID(s)).monospaced()
										}
									}.width(min: 80, ideal: 100).defaultVisibility(.automatic).customizationID("shortID")

									// Long device ID
									TableColumn("Device ID") { (row: DevicesGridRow) in
										switch row {
										case .connectedDevice(let peer): Text(peer.deviceID()).monospaced()
										case .discoveredDevice(let s): Text(s).monospaced()
										}
									}.width(min: 100, ideal: 520).defaultVisibility(.hidden).customizationID("longID")

									// Last seen device address
									TableColumn("Last address") { (row: DevicesGridRow) in
										switch row {
										case .connectedDevice(let peer): Text(self.appState.client.getLastPeerAddress(peer.deviceID())).monospaced()
										case .discoveredDevice(let s): Text(self.appState.client.getLastPeerAddress(s)).monospaced()
										}
									}.width(min: 100, ideal: 200).defaultVisibility(.hidden).customizationID("lastAddress")

									Group {
										// Introduced by
										TableColumn("Introduced by") { (row: DevicesGridRow) in
											switch row {
											case .connectedDevice(let peer):
												if let introducedBy = peer.introducedBy() {
													Text(introducedBy.displayName)
												}
												else {
													EmptyView()
												}
											case .discoveredDevice(_): EmptyView()
											}
										}.width(min: 100, ideal: 200).defaultVisibility(.hidden).customizationID("introducedBy")

										// Trusted
										TableColumn("Trusted") { (row: DevicesGridRow) in
											switch row {
											case .connectedDevice(let device):
												Toggle(
													isOn: Binding(get: { !device.isUntrusted() }, set: { trusted in try? device.setUntrusted(!trusted) })
												) { EmptyView() }
											case .discoveredDevice(_): EmptyView()
											}
										}.width(min: 50, ideal: 50, max: 50).alignment(.center).defaultVisibility(.hidden).customizationID("trusted")

										// Enabled
										TableColumn("Enabled") { (row: DevicesGridRow) in
											switch row {
											case .connectedDevice(let device):
												Toggle(isOn: Binding(get: { !device.isPaused() }, set: { active in try? device.setPaused(!active) })) {
													EmptyView()
												}
											case .discoveredDevice(_): EmptyView()
											}
										}.width(min: 50, ideal: 50, max: 50).alignment(.center).defaultVisibility(.hidden).customizationID("enabled")

										// Introducer
										TableColumn("Introducer") { (row: DevicesGridRow) in
											switch row {
											case .connectedDevice(let device):
												Toggle(
													isOn: Binding(get: { device.isIntroducer() }, set: { trusted in try? device.setIntroducer(trusted) })
												) { EmptyView() }
											case .discoveredDevice(_): EmptyView()
											}
										}.width(min: 50, ideal: 50, max: 50).alignment(.center).defaultVisibility(.hidden).customizationID(
											"introducer")

										// Last seen
										TableColumn("Last seen") { (row: DevicesGridRow) in
											switch row {
											case .connectedDevice(let device):
												if let lastSeen = device.lastSeen(), !lastSeen.isZero() { Text(lastSeen.date().formatted()) }
											case .discoveredDevice(_): EmptyView()
											}
										}.width(min: 100, ideal: 150).defaultVisibility(.hidden).customizationID("lastSeen")
									}
								}

								if viewStyle != .simple {
									TableColumnForEach(self.folders) { folder in
										TableColumn(folder.displayName) { (row: DevicesGridRow) in
											if case .connectedDevice(let peer) = row {
												DevicesGridCellView(device: peer, folder: folder, viewStyle: viewStyle)
											}
											else {
												EmptyView()
											}
										}.width(ideal: 50).alignment(.center)
									}
								}
							},
							rows: {
								Section { ForEach(self.peers) { peer in TableRow(DevicesGridRow.connectedDevice(peer)) } }

								if !discoveredNewDevices.isEmpty {
									Section("Discovered devices") {
										ForEach(discoveredNewDevices, id: \.self) { devID in TableRow(DevicesGridRow.discoveredDevice(devID)) }
									}
								}
							}
						).onDeleteCommand { confirmDeleteSelection = true }.confirmationDialog(
							"Are you sure you want to unlink the selected devices?", isPresented: $confirmDeleteSelection,
							titleVisibility: .visible
						) {
							Button("Unlink devices", role: .destructive) {
								confirmDeleteSelection = false
								self.unlinkSelectedDevices()
							}
						}.contextMenu(
							forSelectionType: SushitrainPeer.ID.self, menu: { items in Text("\(items.count) selected") },
							primaryAction: self.doubleClick
						).navigationDestination(
							isPresented: Binding(
								get: { self.openedDevice != nil }, set: { self.openedDevice = $0 ? self.openedDevice : nil }),
							destination: { self.nextView() })
					}
				}
			}.task { self.update() }.toolbar {
				ToolbarItemGroup(placement: .primaryAction) {
					Menu {
						Picker("Show details", selection: $viewStyle) {
							Text("Device information").tag(GridViewStyle.simple)
							Text("Shared folders").tag(GridViewStyle.sharing)
							Text("Completion").tag(GridViewStyle.percentageOfGlobal)
							Text("Remaining").tag(GridViewStyle.needBytes)
						}.pickerStyle(.inline)

						Divider()

						Toggle(isOn: $transpose) { Label("Switch rows/columns", systemImage: "rotate.right") }.disabled(
							viewStyle == .simple)

					} label: {
						Label("Show details", systemImage: "slider.vertical.3")
					}

					Button("Add device", systemImage: "plus") {
						addingDeviceID = ""
						showingAddDevicePopup = true
					}
				}
			}.sheet(isPresented: $showingAddDevicePopup) {
				AddDeviceView(suggestedDeviceID: $addingDeviceID)
			}
		}

		@ViewBuilder private func nextView() -> some View {
			if let device = self.openedDevice {
				DeviceView(device: device)
			}
			else {
				EmptyView()
			}
		}

		private func unlinkSelectedDevices() {
			for peer in self.peers { if self.selectedPeers.contains(peer.id) { try? peer.remove() } }

			self.update()
		}

		private func doubleClick(_ items: Set<DevicesGridRow.ID>) {
			if let itemID = items.first, items.count == 1 {
				if let device = self.peers.first(where: { $0.id == itemID }) {
					self.openedDevice = device
				}
				else {
					self.addingDeviceID = itemID
					self.showingAddDevicePopup = true
				}
			}
		}

		private func update() {
			self.loading = true
			self.peers = appState.peers().filter({ x in !x.isSelf() }).sorted()
			self.folders = appState.folders().sorted()

			let peerIDs = peers.map { $0.deviceID() }
			self.discoveredNewDevices = Array(appState.discoveredDevices.keys).filter({ d in !peerIDs.contains(d) })

			self.loading = false
		}
	}

	private struct DevicesGridCellView: View {
		@EnvironmentObject var appState: AppState
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
				case .simple: EmptyView()  // Not reached
				case .sharing:
					Toggle(isOn: Binding(get: { return isShared }, set: { nv in self.share(nv) })) { EmptyView() }.disabled(
						self.isLoading)

					Image(systemName: "lock").help("An encrypted version of the folder is shared with this device.").opacity(
						isSharedEncrypted ? 1 : 0)
				case .percentageOfGlobal:
					if isShared {
						if let c = self.completion {
							Text("\(Int(c.completionPct))%").foregroundStyle(c.completionPct < 100 ? .red : .primary).bold(
								c.completionPct < 100
							).help(
								c.completionPct < 100
									? "This device still needs \(c.needItems) items out of \(c.globalItems)"
									: "This device has a copy of all items")
						}
					}
				case .needBytes:
					if isShared {
						if let c = self.completion {
							Text(c.needBytes.formatted(.byteCount(style: .file))).foregroundStyle(c.completionPct < 100 ? .red : .primary)
								.bold(c.completionPct < 100).help(
									c.completionPct < 100
										? "This device still needs \(c.needBytes.formatted(.byteCount(style: .file))) of \(c.globalBytes.formatted(.byteCount(style: .file)))"
										: "This device has a copy of all items")
						}
					}
				}
			}.contextMenu { Button(action: { self.showEditEncryptionPassword = true }) { Text("Show info...") } }
				.task {
					self.update()
				}.onChange(of: viewStyle, initial: false) { _, _ in self.update() }.sheet(isPresented: $showEditEncryptionPassword)
			{
				NavigationStack {
					ShareFolderWithDeviceDetailsView(folder: self.folder, deviceID: .constant(device.deviceID()))
				}
			}
			.onChange(of: appState.eventCounter) {
				self.update()
			}
		}

		private func update() {
			self.isLoading = true
			let devID = self.device.deviceID()
			Task {
				let sharedWithDeviceIDs = folder.sharedWithDeviceIDs()?.asArray() ?? []
				let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
				let completion = self.viewStyle == .sharing ? nil : try? self.folder.completion(forDevice: devID)

				Task { @MainActor in 
					withAnimation {
						self.isShared = sharedWithDeviceIDs.contains(self.device.deviceID())
						self.isSharedEncrypted = sharedEncrypted.contains(device.deviceID())
						self.completion = completion
						self.isLoading = false
					}
				}
			}
		}

		private func share(_ shared: Bool) {
			do {
				if shared {
					showEditEncryptionPassword = true
				}
				else {
					try folder.share(withDevice: device.deviceID(), toggle: shared, encryptionPassword: "")
					self.update()
				}
			}
			catch let error { Log.warn("Error sharing folder: " + error.localizedDescription) }
		}
	}
#endif
