// Copyright (C) 2024-2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct DeviceView: View {
	var device: SushitrainPeer

	private enum DeviceViewTab: String, CaseIterable, Identifiable {
		case general = "general"
		case sharing = "sharing"
		case connection = "connection"
		var id: Self { self }
	}

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	@State private var selectedTab: DeviceViewTab = .general
	@State private var changedDeviceName: String? = nil
	@State private var sharedFolders: [SushitrainFolder] = []
	@State private var otherFolders: [SushitrainFolder] = []
	@State private var lastAddress: String = ""
	@State private var showAddresses: Bool = false
	@State private var showConfirmUnlink = false
	@State private var editSharingWith: SushitrainFolder? = nil

	var body: some View {
		VStack {
			if self.device.exists() {
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
						self.sharingTab()
					case .connection:
						self.connectionTab()
					}
				}
				#if os(macOS)
					.formStyle(.grouped)
				#endif
			}
			else {
				ContentUnavailableView("Unknown device", systemImage: "externaldrive.badge.questionmark")
			}
		}
		.sheet(item: $editSharingWith) { withFolder in
			NavigationStack {
				ShareFolderWithDeviceDetailsView(
					folder: withFolder,
					deviceID: self.device.deviceID()
				)
			}
		}
		.navigationTitle(!device.exists() || device.name().isEmpty ? device.deviceID() : device.name())
		.task(id: appState.eventCounter) {
			await self.update()
		}
	}

	@concurrent private func update() async {
		let client = await self.appState.client
		let folders = await appState.folders().sorted()
		let deviceID = self.device.deviceID()

		let sharedFolders = folders.filter { folder in
			folder.isShared(withDeviceID: deviceID)
		}
		let otherFolders = folders.filter { folder in
			!folder.isShared(withDeviceID: deviceID)
		}
		let lastAddress = client.getLastPeerAddress(self.device.deviceID())

		Task { @MainActor in
			withAnimation {
				self.sharedFolders = sharedFolders
				self.otherFolders = otherFolders
			}
			self.lastAddress = lastAddress
		}
	}

	@ViewBuilder private func generalTab() -> some View {
		LabeledContent {
			TextField(
				"",
				text: Binding(
					get: {
						if let cn = changedDeviceName {
							return cn
						}
						return device.name()
					},
					set: { lbl in
						self.changedDeviceName = lbl
						Task {
							try? device.setName(lbl)
						}
					}), prompt: Text(device.displayName)
			)
			.multilineTextAlignment(.trailing)
		} label: {
			Text("Display name")
		}

		Section("Device ID") {
			DeviceIDView(device: device)
		}

		Section {
			Toggle(
				"Enabled",
				isOn: Binding(
					get: { !appState.isDevicePausedByUser(device) },
					set: { active in appState.setDevice(device, pausedByUser: !active) }
				))
		} header: {
			Text("Device settings")
		} footer: {
			Text("If a device is not enabled, synchronization with this device is paused.")
		}

		Section {
			Toggle(
				"Trusted",
				isOn: Binding(
					get: { !device.isUntrusted() },
					set: { trusted in try? device.setUntrusted(!trusted) }))
		} footer: {
			Text(
				"If a device is not trusted, an encryption password is required for each folder synchronized with the device."
			)
		}

		Section {
			Toggle(
				"Introducer",
				isOn: Binding(
					get: { device.isIntroducer() },
					set: { trusted in try? device.setIntroducer(trusted) }))

			if let introducedBy = device.introducedBy() {
				LabeledContent("Introduced by") {
					Text(introducedBy.displayName)
				}
			}
		} footer: {
			Text(
				"This device will automatically add all devices that an introducer device is connected to."
			)
		}

		Section {
			Button("Unlink device", systemImage: "trash", role: .destructive) {
				self.showConfirmUnlink = true
			}
			.confirmationDialog(
				"Are you sure you want to unlink this device? Folders will not be synchronized with this device any more. You can re-add the device later if necessary.",
				isPresented: $showConfirmUnlink,
				titleVisibility: .visible
			) {
				Button("Unlink device", role: .destructive) {
					try? device.remove()
					self.dismiss()
				}
			}
			.foregroundColor(.red)
			#if os(macOS)
				.buttonStyle(.link)
			#endif
		}
	}

	@ViewBuilder private func sharingTab() -> some View {
		if !sharedFolders.isEmpty {
			Section("Shared folders") {
				ForEach(sharedFolders, id: \.self.folderID) { (folder: SushitrainFolder) in
					ShareWithDeviceToggleView(
						peer: self.device,
						folder: folder,
						showFolderName: true,
						details: { editSharingWith = folder }
					)
				}
			}
			.animation(.default, value: sharedFolders)
		}

		Section {
			ForEach(otherFolders, id: \.self.folderID) { (folder: SushitrainFolder) in
				ShareWithDeviceToggleView(
					peer: self.device,
					folder: folder,
					showFolderName: true,
					details: { editSharingWith = folder }
				)
			}
		}
		.animation(.default, value: otherFolders)
	}

	@ViewBuilder private func connectionTab() -> some View {
		Section {
			if device.isConnected() {
				Label("Connected", systemImage: "checkmark.circle.fill")
					.foregroundStyle(.green)
			}
			else {
				Label("Not connected", systemImage: "xmark.circle")
			}
		}

		// Connection details
		if device.isConnected() {
			let latency = appState.client.measurements?.latency(for: device.deviceID())
			if latency != nil || !lastAddress.isEmpty {
				Section("Connection details") {
					if let latency, !latency.isNaN {
						LabeledContent("Latency") {
							HStack {
								Spacer()
								Text("\(Int(latency * 1000)) ms")
								LatencyView(latency: latency)
							}
						}
					}

					if !lastAddress.isEmpty {
						LabeledContent("Last address") {
							Text(lastAddress).monospaced()
						}.contextMenu {
							Button("Copy to clipboard", systemImage: "doc.on.doc") {
								writeTextToPasteboard(lastAddress)
							}
						}
					}
				}
			}
		}

		// Last seen and watchdog
		Section {
			if let lastSeen = device.lastSeen()?.date(), !device.isConnected() {
				Text("Last seen").badge(Text(lastSeen.formatted()))
			}

			Toggle(
				"Warn when device has not connected for a while",
				isOn: Binding(
					get: {
						return !appState.userSettings.ignoreLongTimeNoSeeDevices.contains(self.device.deviceID())
					},
					set: { nv in
						if nv {
							appState.userSettings.ignoreLongTimeNoSeeDevices.remove(self.device.deviceID())
						}
						else {
							appState.userSettings.ignoreLongTimeNoSeeDevices.insert(self.device.deviceID())
						}
					}))
		}

		// Device addresses configuration
		Button("Addresses...", systemImage: "envelope.front") {
			showAddresses = true
		}
		.sheet(isPresented: $showAddresses) {
			NavigationStack {
				DeviceAddressesView(device: device)
					.toolbar {
						SheetButton(role: .done) {
							showAddresses = false
						}
					}
			}
		}
		#if os(macOS)
			.buttonStyle(.link)
		#endif
	}

	@ViewBuilder private func tabSwitcher() -> some View {
		Picker("Page", selection: $selectedTab) {
			Text("General").tag(DeviceViewTab.general)
			Text("Sharing").tag(DeviceViewTab.sharing)
			Text("Connection").tag(DeviceViewTab.connection)
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
}

private struct DeviceAddressesView: View {
	var device: SushitrainPeer
	@Environment(AppState.self) private var appState
	@State private var addresses: [String] = []
	@State private var error: String? = nil
	@State private var loading: Bool? = nil

	var body: some View {
		AddressesView(
			addresses: self.addresses,
			onChange: {
				self.addresses = $0
				if loading == false {
					self.write()
				}
			}, addressType: .device
		)
		.disabled(loading != false)
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.navigationTitle("Device addresses")
		.task {
			await self.update()
		}
		.alert(isPresented: Binding.isNotNil($error)) {
			Alert(
				title: Text("Could not change addresses"), message: Text(self.error ?? ""),
				dismissButton: .default(Text("OK")))
		}
	}

	private func update() async {
		if self.loading != true {
			self.loading = true
			let device = self.device
			self.addresses = await Task.detached {
				return device.addresses()?.asArray() ?? []
			}.value
			self.addresses.sort()
			self.loading = false
		}
	}

	private func write() {
		let addresses = self.addresses
		Task.detached {
			try! device.setAddresses(SushitrainListOfStrings.from(addresses))
		}
	}
}
