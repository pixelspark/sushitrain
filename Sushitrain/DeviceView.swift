// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

private struct DeviceAddressesView: View {
	var device: SushitrainPeer
	@ObservedObject var appState: AppState
	@State private var addresses: [String] = []

	var body: some View {
		AddressesView(
			appState: appState,
			addresses: Binding(
				get: {
					return self.device.addresses()?.asArray() ?? []
				},
				set: { nv in
					try! self.device.setAddresses(SushitrainListOfStrings.from(nv))
				}), editingAddresses: self.device.addresses()?.asArray() ?? [], addressType: .device
		)
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.navigationTitle("Device addresses")
	}
}

struct DeviceView: View {
	var device: SushitrainPeer
	@ObservedObject var appState: AppState
	@Environment(\.dismiss) private var dismiss
	@State var changedDeviceName: String? = nil

	var body: some View {
		Form {
			if self.device.exists() {
				Section {
					if device.isConnected() {
						Label("Connected", systemImage: "checkmark.circle.fill")
							.foregroundStyle(.green)
					}
					else {
						Label("Not connected", systemImage: "xmark.circle")
						if let lastSeen = device.lastSeen(), !lastSeen.isZero() {
							Text("Last seen").badge(Text(lastSeen.date().formatted()))
						}
					}
				}

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

				Section {
					Toggle(
						"Enabled",
						isOn: Binding(
							get: { !device.isPaused() },
							set: { active in try? device.setPaused(!active) }))
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

				Section("Device ID") {
					Label(device.deviceID(), systemImage: "qrcode").contextMenu {
						Button(action: {
							#if os(iOS)
								UIPasteboard.general.string = device.deviceID()
							#endif

							#if os(macOS)
								let pasteboard = NSPasteboard.general
								pasteboard.clearContents()
								pasteboard.prepareForNewContents()
								pasteboard.setString(
									device.deviceID(), forType: .string)
							#endif
						}) {
							Text("Copy to clipboard")
							Image(systemName: "doc.on.doc")
						}
					}.monospaced()
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

				NavigationLink(destination: DeviceAddressesView(device: device, appState: appState)) {
					Label("Addresses", systemImage: "envelope.front")
				}

				let folders = appState.folders()
				Section("Shared folders") {
					ForEach(folders, id: \.self.folderID) { (folder: SushitrainFolder) in
						ShareWithDeviceToggleView(
							appState: self.appState, peer: self.device, folder: folder,
							showFolderName: true)
					}
				}

				let lastAddress = self.appState.client.getLastPeerAddress(self.device.deviceID())
				if !lastAddress.isEmpty {
					Section("Current addresses") {
						Label(lastAddress, systemImage: "network").contextMenu {
							Button(action: {
								#if os(iOS)
									UIPasteboard.general.string = lastAddress
								#endif

								#if os(macOS)
									let pasteboard = NSPasteboard.general
									pasteboard.clearContents()
									pasteboard.prepareForNewContents()
									pasteboard.setString(
										lastAddress, forType: .string)
								#endif
							}) {
								Text("Copy to clipboard")
								Image(systemName: "doc.on.doc")
							}
						}
					}
				}

				Section {
					Button(
						"Unlink device", systemImage: "trash", role: .destructive,
						action: {
							try? device.remove()
							dismiss()
						}
					)
					.foregroundColor(.red)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				}
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.navigationTitle(!device.exists() || device.name().isEmpty ? device.deviceID() : device.name())
	}
}
