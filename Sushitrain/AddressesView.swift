// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

enum AddressType {
	case listening
	case device
	case stun
	case discovery

	var defaultOption: String {
		switch self {
		case .listening, .discovery, .stun: return "default"
		case .device: return "dynamic"
		}
	}

	var templateAddress: String {
		switch self {
		// Must not be equal to defaultListeningAddresses
		case .listening: return "tcp://0.0.0.0:22123"
		case .device: return "tcp://192.168.0.1:22000"
		case .stun: return "stun.example:4378"
		case .discovery: return "https://discovery.example"
		}
	}

	// The 'default' relay address for listening (https://docs.syncthing.net/users/config.html#listen-addresses)
	static let defaultRelayAddress: String = "dynamic+https://relays.syncthing.net/endpoint"

	// The 'default' set of listening addresses (not including relay)
	// See https://docs.syncthing.net/users/config.html#listen-addresses
	static let defaultListeningAddresses: [String] = [
		"tcp://0.0.0.0:22000",
		"quic://0.0.0.0:22000",
	]
}

private struct AddressView: View {
	@State var address: String = ""
	var addressType: AddressType
	let onChange: (_ address: String) -> Void

	private var url: URL? {
		get {
			switch self.addressType {
			case .stun: return URL(string: "stun://" + self.address)
			case .device, .discovery, .listening: return URL(string: self.address)
			}
		}
		nonmutating set {
			switch self.addressType {
			case .stun:
				if let h = newValue?.host() {
					if let p = newValue?.port {
						self.address = "\(h):\(p)"
					}
					else {
						self.address = h
					}
				}
				else {
					self.address = ""
				}

			case .device, .discovery, .listening: self.address = newValue?.absoluteString ?? ""
			}
		}
	}

	var body: some View {
		Form {
			Section {
				// Type picker
				if self.addressType != .stun {
					Picker(
						"Address type",
						selection: Binding(
							get: {
								let url = self.url
								return url?.scheme ?? ""
							},
							set: { (nv: String) in
								var url =
									URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false)
									?? URLComponents()
								url.scheme = nv
								if nv == "dynamic+https" {
									url.path = "/relays"
								}
								else {
									url.path = ""
								}

								if nv != "relay" { url.queryItems = nil }

								if self.addressType == .discovery {
									url.queryItems = nv == "http" ? [URLQueryItem(name: "insecure", value: nil)] : []
								}

								self.address = url.string ?? ""
							}),
						content: {
							switch self.addressType {
							case .stun:
								// Unreachable
								Text("STUN").tag("stun")
							case .discovery:
								Text("HTTPS").tag("https")
								Text("HTTP").tag("http")
							case .listening:
								Text("TCP").tag("tcp")
								Text("QUIC").tag("quic")
								Text("Relay").tag("relay")
								Text("Relay pool").tag("dynamic+https")
							case .device:
								Text("TCP").tag("tcp")
								Text("QUIC").tag("quic")
							}

						}
					).pickerStyle(.segmented)
				}
			}

			Section {
				// Host
				LabeledContent {
					TextField(
						"",
						text: Binding(
							get: {
								let url = self.url
								return url?.host() ?? ""
							},
							set: { nv in
								var url =
									URLComponents(url: self.url ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
								url.host = nv
								self.url = url.url
							}), prompt: Text("0.0.0.0")
					).multilineTextAlignment(.trailing)
						#if os(iOS)
							.keyboardType(.asciiCapable).autocorrectionDisabled().autocapitalization(.none)
						#endif
				} label: {
					Text("IP address or host name")
				}

				LabeledContent {
					TextField(
						"",
						text: Binding(
							get: {
								let url = self.url
								if let p = url?.port { return String(p) }
								return ""
							},
							set: { nv in
								var url =
									URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false)
									?? URLComponents()
								url.port = Int(nv)
								self.address = url.string ?? ""
							}), prompt: Text("22000")
					).multilineTextAlignment(.trailing)
						#if os(iOS)
							.keyboardType(.numberPad).autocorrectionDisabled().autocapitalization(.none)
						#endif
				} label: {
					Text("Port")
				}

				let urlComponents =
					URLComponents(url: self.url ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()

				if urlComponents.scheme == "relay" {
					LabeledContent {
						TextField(
							"",
							text: Binding(
								get: {
									let url =
										URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false)
										?? URLComponents()
									return url.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
								},
								set: { nv in
									var url =
										URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false)
										?? URLComponents()
									var qi = url.queryItems ?? []
									qi.removeAll(where: { $0.name == "id" })
									qi.append(URLQueryItem(name: "id", value: nv))
									url.queryItems = qi
									self.address = url.string ?? ""
								}), prompt: Text("")
						).multilineTextAlignment(.trailing).monospaced()
							#if os(iOS)
								.keyboardType(.asciiCapable).autocorrectionDisabled().autocapitalization(.none)
							#endif
					} label: {
						Text("Relay ID")
					}

					LabeledContent {
						TextField(
							"",
							text: Binding(
								get: {
									let url =
										URLComponents(url: self.url ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
									return url.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
								},
								set: { nv in
									var url =
										URLComponents(url: self.url ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
									var qi = url.queryItems ?? []
									qi.removeAll(where: { $0.name == "token" })
									qi.append(URLQueryItem(name: "token", value: nv))
									url.queryItems = qi
									self.address = url.string ?? ""
								}), prompt: Text("")
						).multilineTextAlignment(.trailing).monospaced()
							#if os(iOS)
								.keyboardType(.asciiCapable).autocorrectionDisabled().autocapitalization(.none)
							#endif
					} label: {
						Text("Access token")
					}
				}
			}

			if self.addressType != .stun {
				Section("URL") {
					TextField("", text: $address).frame(maxWidth: .infinity).monospaced().multilineTextAlignment(.leading)
						#if os(iOS)
							.autocorrectionDisabled().autocapitalization(.none)
						#endif
				}
			}
		}
		.onChange(of: self.address) { _, nv in
			self.onChange(nv)
		}
		.navigationTitle(self.address)
		#if os(macOS)
			.formStyle(.grouped)
		#endif
	}
}

struct AddressesView: View {
	@Environment(AppState.self) private var appState
	@Binding var addresses: [String]
	var addressType: AddressType

	// The 'default' option (includes listening addresses and relays for listening address type)
	private func setUseDefaultOption(_ newValue: Bool) {
		if newValue && !self.addresses.contains(self.addressType.defaultOption) {
			self.addresses.append(self.addressType.defaultOption)
		}
		else {
			self.addresses.removeAll { $0 == self.addressType.defaultOption }
		}
		self.mergeListeningAddressesIntoDefaultOption()
	}

	private var useDefaultOption: Bool {
		return self.addresses.contains(self.addressType.defaultOption)
	}

	// Default listening addresses
	private var useDefaultListeningAddresses: Bool {
		// Either the address list contains "default" or it contains all default listening addresses separately
		return self.addresses.contains(self.addressType.defaultOption)
			|| AddressType.defaultListeningAddresses.allSatisfy({ self.addresses.contains($0) })
	}

	private func setUseDefaultListeningAddresses(_ newValue: Bool) {
		if self.addressType != .listening {
			return
		}

		if newValue {
			self.addresses.append(contentsOf: AddressType.defaultListeningAddresses)
		}
		else {
			self.addresses.removeAll(where: { AddressType.defaultListeningAddresses.contains($0) })
			// If we have the 'default' option, split it
			if self.addresses.contains(AddressType.listening.defaultOption) {
				self.addresses.removeAll(where: { $0 == AddressType.listening.defaultOption })
				self.addresses.append(AddressType.defaultRelayAddress)
			}
		}

		self.mergeListeningAddressesIntoDefaultOption()
	}

	// Default relays
	private var useDefaultRelays: Bool {
		// Either the address list contains "default" or it contains the default relay address
		return self.addresses.contains(self.addressType.defaultOption)
			|| self.addresses.contains(AddressType.defaultRelayAddress)
	}

	private func setUseDefaultRelays(_ newValue: Bool) {
		if self.addressType != .listening {
			return
		}

		if newValue {
			// Just append, will deduplicate later on
			self.addresses.append(AddressType.defaultRelayAddress)
		}
		else {
			self.addresses.removeAll(where: { $0 == AddressType.defaultRelayAddress })
			// If we have the 'default' option, split it
			if self.addresses.contains(AddressType.listening.defaultOption) {
				self.addresses.removeAll(where: { $0 == AddressType.listening.defaultOption })
				self.addresses.append(contentsOf: AddressType.defaultListeningAddresses)
			}
		}

		self.mergeListeningAddressesIntoDefaultOption()
	}

	private func mergeListeningAddressesIntoDefaultOption() {
		if self.addressType != .listening {
			return
		}

		// Remove duplicates
		self.addresses = Array(Set(self.addresses))

		let containsDefaultRelay = self.addresses.contains(AddressType.defaultRelayAddress)
		let containsDefaultAddresses = AddressType.defaultListeningAddresses.allSatisfy({ self.addresses.contains($0) })
		let containsDefault = self.addresses.contains(AddressType.listening.defaultOption)

		if containsDefault {
			self.addresses.removeAll(where: {
				$0 == AddressType.defaultRelayAddress || AddressType.defaultListeningAddresses.contains($0)
			})
		}
		// Merge default relays and listening addresses to 'default' option
		else if containsDefaultRelay && containsDefaultAddresses {
			self.addresses.removeAll {
				$0 == AddressType.defaultRelayAddress || AddressType.defaultListeningAddresses.contains($0)
					|| $0 == AddressType.listening.defaultOption
			}
			self.addresses.append(AddressType.listening.defaultOption)
		}
	}

	private func isAddressHidden(_ address: String) -> Bool {
		if address == self.addressType.defaultOption {
			return true
		}
		else if self.addressType == .listening {
			if address == AddressType.defaultRelayAddress {
				return true
			}
			if AddressType.defaultListeningAddresses.contains(address) {
				return true
			}
		}

		return false
	}

	var body: some View {
		Form {
			if self.addressType != .listening {
				Section {
					Toggle(
						"Use default addresses",
						isOn: Binding(get: { return self.useDefaultOption }, set: { self.setUseDefaultOption($0) }))
				} footer: {
					switch self.addressType {
					case .stun: Text("When enabled, the app will use the default STUN servers.")
					case .discovery: Text("When enabled, the app will use the default discovery service to announce itself.")
					case .listening:
						Text("When enabled, the app will listen on default addresses, and will use the default relay pool.")
					case .device:
						Text(
							"When enabled, the app will look up addresses for this device automatically using various discovery mechanisms.")
					}
				}
			}

			if self.addressType == .listening {
				Section {
					Toggle(
						"Use default listening addresses",
						isOn: Binding(
							get: { return self.useDefaultListeningAddresses }, set: { self.setUseDefaultListeningAddresses($0) }))
				}

				Section {
					Toggle(
						"Use default relays", isOn: Binding(get: { return self.useDefaultRelays }, set: { self.setUseDefaultRelays($0) }))
				} footer: {
					Text(
						"When enabled, the app will register your device with the Syncthing relay pool. Your other devices will then be able to connect to it through a relay when necessary."
					)
				}
			}

			Section("Additional addresses") {
				ForEach(Array(addresses.enumerated()), id: \.offset) { idx in
					if !self.isAddressHidden(idx.element) {
						NavigationLink(
							destination: AddressView(
								address: addresses[idx.offset],
								addressType: addressType,
								onChange: {
									addresses[idx.offset] = $0
								})
						) {
							HStack {
								#if os(macOS)
									Button("Delete", systemImage: "trash") { addresses.remove(at: idx.offset) }.labelStyle(.iconOnly)
										.buttonStyle(.borderless)
								#endif
								Text(idx.element)

							}
						}
					}
				}.onDelete(perform: { indexSet in addresses.remove(atOffsets: indexSet) })

				Button("Add address") {
					self.addresses.append(self.addressType.templateAddress)
				}
				.deleteDisabled(true)
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			}
		}
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.toolbar {
			#if os(iOS)
				ToolbarItem(placement: .topBarLeading) {
					if !addresses.isEmpty {
						EditButton()
					}
				}
			#endif
		}
	}
}
