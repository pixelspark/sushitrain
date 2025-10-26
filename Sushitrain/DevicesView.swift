// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct DevicesView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		#if os(macOS)
			DevicesGridView().navigationTitle("Devices")
		#else
			DevicesListView(userSettings: appState.userSettings).navigationTitle("Devices")
		#endif
	}
}

private struct DeviceMetricView: View {
	@Environment(AppState.self) private var appState

	let device: SushitrainPeer
	let metric: DeviceMetric

	@State private var measurement: Double? = nil
	@State private var address: String? = nil

	static let formatter = ByteCountFormatter()

	var body: some View {
		self.metricView().foregroundStyle(.secondary)
	}

	@ViewBuilder private func metricView() -> some View {
		ZStack {
			switch self.metric {
			case .none:
				EmptyView()

			case .shortID:
				Text(self.device.shortDeviceID()).monospaced()

			case .lastSeenAgo:
				if let secondsAgo = self.measurement, !secondsAgo.isNaN {
					Text(Duration.seconds(secondsAgo).formatted())
				}
				else {
					EmptyView()
				}

			case .lastAddress:
				if let la = self.address {
					Text(la)
				}
				else {
					EmptyView()
				}

			case .latency:
				if let latency = self.measurement, !latency.isNaN {
					LatencyView(latency: latency)
				}
				else {
					EmptyView()
				}
			case .needBytes:
				if let bytes = self.measurement, !bytes.isNaN {
					Text(DeviceMetricView.formatter.string(fromByteCount: Int64(bytes)))
				}
				else {
					EmptyView()
				}
			case .needItems:
				if let items = self.measurement, !items.isNaN {
					Text(items.formatted())
				}
				else {
					EmptyView()
				}

			case .completionPercentage:
				if let pct = self.measurement, !pct.isNaN {
					Text("\(Int(pct))%")
				}
				else {
					EmptyView()
				}
			}
		}.task {
			await self.update()
		}
		.onChange(of: self.metric) { _, _ in
			self.measurement = nil
			Task {
				await self.update()
			}
		}
	}

	private func update() async {
		(self.measurement, self.address) = await Task { @concurrent in
			return await self.calculateMeasurement()
		}.value
	}

	private nonisolated func calculateMeasurement() async -> (Double?, String?) {
		let client = await appState.client

		do {
			switch self.metric {
			case .latency:
				return (client.measurements?.latency(for: self.device.deviceID()), nil)

			case .lastAddress:
				return (nil, client.getLastPeerAddress(self.device.deviceID()))

			case .lastSeenAgo:
				if let ls = device.lastSeen()?.date() {
					return (Date.now.timeIntervalSince(ls), nil)
				}
				else {
					return (nil, nil)
				}

			case .needBytes, .needItems, .completionPercentage:
				if let folders = device.sharedFolderIDs()?.asArray() {
					var total: Int64 = 0
					var totalPercentage: Double = 100.0
					for folderID in folders {
						if let folder = client.folder(withID: folderID) {
							let stats = try folder.completion(forDevice: self.device.deviceID())
							if self.metric == .needBytes {
								total += stats.needBytes
							}
							else if self.metric == .needItems {
								total += Int64(stats.needItems)
							}
							else if self.metric == .completionPercentage {
								totalPercentage *= stats.completionPct / 100.0
							}
						}
					}

					if self.metric == .needBytes || self.metric == .needItems {
						return (Double(total), nil)
					}
					else if self.metric == .completionPercentage {
						return (totalPercentage, nil)
					}
					else {
						return (nil, nil)
					}
				}
				else {
					return (nil, nil)
				}

			case .none, .shortID:
				return (nil, nil)
			}
		}
		catch {
			Log.warn("error getting device metrics: \(error.localizedDescription)")
			return (nil, nil)
		}
	}
}

struct LatencyView: View {
	let latency: Double

	var body: some View {
		if !latency.isNaN {
			Image(systemName: "cellularbars", variableValue: self.quality).foregroundStyle(.green)
		}
		else {
			EmptyView()
		}
	}

	private var quality: Double {
		if latency < 0 {
			return 0.0
		}

		// log(10)/log(5) = 1
		// log(625)/log(5) = 4
		// l = 0..=1
		let ms = max(min(self.latency * 1000.0, 1000.0), 5.0)
		let l = ((log(ms) / log(5.0)) - 1.0) / 3.0
		return min(1.0, max(1.0 - l, 0.0))
	}
}

#if os(iOS)
	struct DeviceMetricPickerView: View {
		@ObservedObject var userSettings: AppUserSettings

		var body: some View {
			Picker("Show metric", selection: self.userSettings.$devicesViewMetric) {
				HStack {
					Text("None")
				}.tag(DeviceMetric.none)

				HStack {
					Image(systemName: "cellularbars")
					Text("Latency")
				}.tag(DeviceMetric.latency)

				HStack {
					Image(systemName: "number.circle.fill")
					Text("Needs (size)")
				}.tag(DeviceMetric.needBytes)

				HStack {
					Image(systemName: "number.circle.fill")
					Text("Needs (items)")
				}.tag(DeviceMetric.needItems)

				HStack {
					Image(systemName: "percent")
					Text("Completion percentage")
				}.tag(DeviceMetric.completionPercentage)

				HStack {
					Image(systemName: "qrcode")
					Text("Device ID")
				}.tag(DeviceMetric.shortID)

				HStack {
					Image(systemName: "timer")
					Text("Last seen (ago)")
				}.tag(DeviceMetric.lastSeenAgo)

				HStack {
					Image(systemName: "envelope.front")
					Text("Address")
				}.tag(DeviceMetric.lastAddress)
			}
			.pickerStyle(.inline)
		}
	}

	private struct DevicesListView: View {
		@Environment(AppState.self) private var appState
		@State private var showingAddDevicePopup = false
		@State private var addingDeviceID: String = ""
		@State private var discoveredNewDevices: [String] = []
		@State private var peers: [SushitrainPeer] = []
		@State private var loading = true

		@ObservedObject var userSettings: AppUserSettings

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
								HStack {
									if peer.isPaused() {
										Label(peer.displayName, systemImage: "externaldrive.fill").foregroundStyle(.gray)
									}
									else {
										Label(peer.displayName, systemImage: peer.systemImage)
									}

									Spacer()

									DeviceMetricView(device: peer, metric: userSettings.devicesViewMetric)
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
						}.onDelete { idxs in
							let toDelete = idxs.map { discoveredNewDevices[$0] }
							for deviceID in toDelete {
								appState.userSettings.ignoreDiscoveredDevices.insert(deviceID)
							}
							Task {
								await self.update()
							}
						}
					}
				}

				// Add peer manually
				Section {
					Button("Add device...", systemImage: "plus") {
						addingDeviceID = ""
						showingAddDevicePopup = true
					}
					#if os(macOS)
						.buttonStyle(.borderless)
					#endif
				}
			}
			#if os(iOS)
				.toolbar {
					ToolbarItem {
						EditButton().disabled(peers.isEmpty)
					}

					ToolbarItem {
						Menu(
							content: {
								DeviceMetricPickerView(userSettings: appState.userSettings)

								Divider()

								Button("Disable all devices") {
									for peer in self.peers {
										self.appState.setDevice(peer, pausedByUser: true)
									}
								}.disabled(self.peers.allSatisfy { self.appState.isDevicePausedByUser($0) })

								Button("Enable all devices") {
									for peer in self.peers {
										self.appState.setDevice(peer, pausedByUser: false)
									}
								}.disabled(self.peers.allSatisfy { !self.appState.isDevicePausedByUser($0) })
							},
							label: {
								Image(systemName: "ellipsis.circle")
									.accessibilityLabel(Text("Menu"))
							}
						)
					}
				}
			#endif
			.sheet(isPresented: $showingAddDevicePopup) {
				AddDeviceView(suggestedDeviceID: $addingDeviceID)
			}.task {
				await self.update()
			}.onChange(of: appState.eventCounter) {
				Task {
					await self.update()
				}
			}
			.onAppear {
				// Measure latencies
				let measurements = appState.client.measurements
				Task.detached {
					measurements?.measure()
				}
			}
		}

		private func update() async {
			self.loading = true
			self.peers = await appState.peers().filter({ x in !x.isSelf() }).sorted()

			// Discovered peers
			let peerIDs = peers.map { $0.deviceID() }
			self.discoveredNewDevices = Array(appState.discoveredDevices.keys).filter({ d in
				!peerIDs.contains(d) && !appState.userSettings.ignoreDiscoveredDevices.contains(d)
			})
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

		@Environment(AppState.self) private var appState

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
		@State private var measurements: [String: Double] = [:]

		@SceneStorage("DeviceTableViewConfig") private var columnCustomization: TableColumnCustomization<DevicesGridRow>

		var body: some View {
			ZStack {
				if self.loading {
					ProgressView()
				}
				if self.transpose && self.viewStyle != .simple {
					Table(self.folders, selection: $selectedFolders) {
						TableColumn("Folder") { folder in Label(folder.displayName, systemImage: "folder") }.width(ideal: 100)

						TableColumnForEach(self.peers) { peer in
							TableColumn(peer.displayName) { folder in
								DevicesGridCellView(appState: appState, device: peer, folder: folder, viewStyle: viewStyle)
									// Needed because for some reason SwiftUI doesn't propagate environment inside TableColumn
									.environment(self.appState)
							}.width(ideal: 50).alignment(.center)
						}
					}
					.disabled(self.loading)
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
											.environment(self.appState)
									case .discoveredDevice(let s):
										IdenticonView(deviceID: s)
											.padding(5)
											// Needed because for some reason SwiftUI doesn't propagate environment inside TableColumn
											.environment(self.appState)
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

									// Latency
									TableColumn("Latency") { (row: DevicesGridRow) in
										switch row {
										case .connectedDevice(let device):
											if let latency = self.measurements[device.deviceID()], !latency.isNaN {
												HStack {
													LatencyView(latency: latency)
													Spacer()
													Text("\(Int(latency * 1000.0)) ms")
												}
											}
										case .discoveredDevice(_): EmptyView()
										}
									}.width(min: 70, ideal: 70, max: 70).alignment(.numeric).defaultVisibility(.hidden).customizationID("latency")

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
											if let lastSeen = device.lastSeen()?.date() {
												Text(lastSeen.formatted())
											}
										case .discoveredDevice(_): EmptyView()
										}
									}.width(min: 100, ideal: 150).defaultVisibility(.hidden).customizationID("lastSeen")
								}
							}

							if viewStyle != .simple {
								TableColumnForEach(self.folders) { folder in
									TableColumn(folder.displayName) { (row: DevicesGridRow) in
										if case .connectedDevice(let peer) = row {
											DevicesGridCellView(appState: self.appState, device: peer, folder: folder, viewStyle: viewStyle)
												// Needed because for some reason SwiftUI doesn't propagate environment inside TableColumn
												.environment(self.appState)
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
					)
					.onDeleteCommand { confirmDeleteSelection = true }
					.disabled(self.loading)
					.confirmationDialog(
						"Are you sure you want to unlink the selected devices?", isPresented: $confirmDeleteSelection,
						titleVisibility: .visible
					) {
						Button("Unlink devices", role: .destructive) {
							confirmDeleteSelection = false
							self.unlinkSelectedDevices()
						}
					}
					.contextMenu(
						forSelectionType: SushitrainPeer.ID.self, menu: { items in Text("\(items.count) selected") },
						primaryAction: self.doubleClick
					)
				}
			}
			.task {
				await self.update()
			}
			.navigationDestination(isPresented: Binding.isNotNil($openedDevice)) {
				self.nextView()
			}
			.toolbar {
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
			.onAppear {
				Task {
					await self.update()
				}
			}
			.onChange(of: appState.eventCounter) { _, _ in
				Task {
					await self.update()
				}
			}
			// Update device list when add device popup is hidden again
			.onChange(of: showingAddDevicePopup) { _, nv in
				if !nv {
					Task {
						await self.update()
					}
				}
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
			for peer in self.peers {
				if self.selectedPeers.contains(peer.id) {
					try? peer.remove()
				}
			}

			Task {
				await self.update()
			}
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

		private func updateMeasurements() {
			// Measurements
			self.measurements = [:]
			if let m = appState.client.measurements {
				for device in self.peers {
					self.measurements[device.deviceID()] = m.latency(for: device.deviceID())
				}
			}
		}

		private func update() async {
			self.loading = true
			self.peers = await appState.peers().filter({ x in !x.isSelf() }).sorted()
			self.folders = await appState.folders().sorted()

			let peerIDs = peers.map { $0.deviceID() }
			self.discoveredNewDevices = Array(appState.discoveredDevices.keys).filter({ d in !peerIDs.contains(d) })

			self.loading = false
			self.updateMeasurements()
		}
	}

	private struct DevicesGridCellView: View {
		var appState: AppState
		var device: SushitrainPeer
		var folder: SushitrainFolder
		var viewStyle: GridViewStyle
		@State private var isShared: Bool = false
		@State private var isSharedEncrypted: Bool = false
		@State private var loadingTask: Task<(), Error>? = nil
		@State private var showEditEncryptionPassword = false
		@State private var completion: SushitrainCompletion? = nil

		var body: some View {
			HStack {
				switch viewStyle {
				case .simple: EmptyView()  // Not reached
				case .sharing:
					Toggle(isOn: Binding(get: { return isShared }, set: { nv in self.share(nv) })) { EmptyView() }.disabled(
						self.loadingTask != nil)

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
			}
			.contextMenu {
				Button("Show info...") {
					self.showEditEncryptionPassword = true
				}
			}
			.task {
				await self.update()
			}
			.onChange(of: viewStyle, initial: false) { _, _ in
				Task {
					await self.update()
				}
			}
			.sheet(isPresented: $showEditEncryptionPassword) {
				NavigationStack {
					ShareFolderWithDeviceDetailsView(folder: self.folder, deviceID: .constant(device.deviceID()))
				}
			}
			.onChange(of: appState.eventCounter) {
				// Update on app events, but only the cheap updates, or while we're not already loading
				if self.loadingTask == nil || self.viewStyle == .simple || self.viewStyle == .sharing {
					Task {
						await self.update()
					}
				}
			}
			.onDisappear {
				self.loadingTask?.cancel()
				self.loadingTask = nil
			}
		}

		private func update() async {
			let devID = self.device.deviceID()
			let folder = self.folder
			let viewStyle = self.viewStyle

			if let t = self.loadingTask {
				t.cancel()
				self.loadingTask = nil
			}

			self.loadingTask = Task(priority: .userInitiated) { @concurrent in
				dispatchPrecondition(condition: .notOnQueue(.main))
				let sharedWithDeviceIDs = folder.sharedWithDeviceIDs()?.asArray() ?? []
				let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
				if Task.isCancelled {
					return
				}
				let completion = viewStyle == .sharing ? nil : try? folder.completion(forDevice: devID)

				Task { @MainActor in
					withAnimation {
						self.isShared = sharedWithDeviceIDs.contains(self.device.deviceID())
						self.isSharedEncrypted = sharedEncrypted.contains(device.deviceID())
						self.completion = completion
						self.loadingTask = nil
					}
				}
			}
			try? await self.loadingTask!.value
			self.loadingTask = nil
		}

		private func share(_ shared: Bool) {
			do {
				if shared {
					showEditEncryptionPassword = true
				}
				else {
					try folder.share(withDevice: device.deviceID(), toggle: shared, encryptionPassword: "")
					Task {
						await self.update()
					}
				}
			}
			catch let error { Log.warn("Error sharing folder: " + error.localizedDescription) }
		}
	}
#endif
