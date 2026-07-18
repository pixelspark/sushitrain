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

	var defaultScheme: String {
		switch self {
		case .listening: return "tcp"
		case .device: return "tcp"
		case .stun: return "stun"
		case .discovery: return "https"
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
	let onSave: (_ address: String) -> Void

	// When filled, takes precedence over URL(address).host
	// When setting address, either this is filled, or when URL(address).host == new host, it can be set to nil
	@State private var editingHost: String? = nil

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
								if let host = self.editingHost {
									return host
								}
								if let url = self.url, let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
									let host = urlComponents.host
								{
									return host
								}
								return ""
							},
							set: { nv in
								// Try to create a new URL and edit the host
								var url =
									URLComponents(
										url: self.url ?? URL(string: "\(self.addressType.defaultScheme)://")!, resolvingAgainstBaseURL: false)
									?? URLComponents()
								url.host = nv

								// If the host remains stable, set the URL and clear self.editingHost
								if let createdURL = url.url,
									let createdComponents = URLComponents(url: createdURL, resolvingAgainstBaseURL: false),
									createdComponents.host == nv
								{
									self.url = url.url
									self.editingHost = nil
								}
								else {
									// We're editing some hostname that is not yet valid
									// Still set self.url but also keep self.editingHost filled
									self.editingHost = nv
									if let createdURL = url.url {
										self.url = createdURL
									}
								}
							}), prompt: Text("0.0.0.0")
					).multilineTextAlignment(.trailing)
						#if os(iOS)
							.keyboardType(.asciiCapable).autocorrectionDisabled().autocapitalization(.none)
						#endif
				} label: {
					Text("IP address or host name")
				}

				// Port
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
									URLComponents(
										url: self.url ?? URL(string: "\(self.addressType.defaultScheme)://")!, resolvingAgainstBaseURL: false)
									?? URLComponents()
								url.port = Int(nv)
								self.url = url.url
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
					// Relay ID
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

					// Access token
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
			} footer: {
				Text("To use IPv6 addresses, enter it in the host name between brackets, e.g. as `[c0ff:ff33::1]`.")
			}

			if self.addressType != .stun {
				Section("URL") {
					TextField(
						"",
						text: Binding(
							get: {
								return self.address
							},
							set: {
								// If the user is editing the URL, throw away any pending host name edit
								self.editingHost = nil
								self.address = $0
							})
					).frame(maxWidth: .infinity).monospaced().multilineTextAlignment(.leading)
						#if os(iOS)
							.autocorrectionDisabled().autocapitalization(.none)
						#endif
				}
			}
		}
		.onDisappear {
			self.onSave(self.address)
		}
		.navigationTitle(self.address)
		#if os(macOS)
			.formStyle(.grouped)
		#endif
	}
}

struct AddressesView: View {
	@Environment(AppState.self) private var appState
	let addresses: [String]
	let onChange: ([String]) -> ()?
	var addressType: AddressType

	// The 'default' option (includes listening addresses and relays for listening address type)
	private func setUseDefaultOption(_ newValue: Bool) {
		if newValue && !self.addresses.contains(self.addressType.defaultOption) {
			self.save(self.addresses + [self.addressType.defaultOption])
		}
		else {
			self.save(self.addresses.filter { $0 != self.addressType.defaultOption })
		}
	}

	private var useDefaultOption: Bool {
		return self.addresses.contains(self.addressType.defaultOption)
	}

	private func save(_ addresses: [String]) {
		// Remove duplicates while preserving the user's current row order.
		var seenAddresses = Set<String>()
		var newAddresses = addresses.filter { seenAddresses.insert($0).inserted }

		// Merge default addresses into 'default'
		if self.addressType == .listening {
			let containsDefaultRelay = newAddresses.contains(AddressType.defaultRelayAddress)
			let containsDefaultAddresses = AddressType.defaultListeningAddresses.allSatisfy({ newAddresses.contains($0) })
			let containsDefault = newAddresses.contains(AddressType.listening.defaultOption)

			if containsDefault {
				newAddresses.removeAll(where: {
					$0 == AddressType.defaultRelayAddress || AddressType.defaultListeningAddresses.contains($0)
				})
			}
			// Merge default relays and listening addresses to 'default' option
			else if containsDefaultRelay && containsDefaultAddresses {
				newAddresses.removeAll {
					$0 == AddressType.defaultRelayAddress || AddressType.defaultListeningAddresses.contains($0)
						|| $0 == AddressType.listening.defaultOption
				}
				newAddresses.append(AddressType.listening.defaultOption)
			}
		}

		self.onChange(newAddresses)
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
			self.save(self.addresses + AddressType.defaultListeningAddresses)
		}
		else {
			var newAddresses = self.addresses
			newAddresses.removeAll(where: { AddressType.defaultListeningAddresses.contains($0) })
			// If we have the 'default' option, split it
			if newAddresses.contains(AddressType.listening.defaultOption) {
				newAddresses.removeAll(where: { $0 == AddressType.listening.defaultOption })
				newAddresses.append(AddressType.defaultRelayAddress)
			}
			self.save(newAddresses)
		}
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

		var newAddresses = self.addresses
		if newValue {
			// Just append, will deduplicate later on
			newAddresses.append(AddressType.defaultRelayAddress)
		}
		else {
			newAddresses.removeAll(where: { $0 == AddressType.defaultRelayAddress })
			// If we have the 'default' option, split it
			if newAddresses.contains(AddressType.listening.defaultOption) {
				newAddresses.removeAll(where: { $0 == AddressType.listening.defaultOption })
				newAddresses.append(contentsOf: AddressType.defaultListeningAddresses)
			}
		}
		self.save(newAddresses)
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
								onSave: {
									var newAddresses = addresses
									newAddresses[idx.offset] = $0
									self.save(newAddresses)
								})
						) {
							HStack {
								#if os(macOS)
									Button("Delete", systemImage: "trash") {
										var newAddresses = addresses
										newAddresses.remove(at: idx.offset)
										self.save(newAddresses)
									}
									.labelStyle(.iconOnly)
									.buttonStyle(.borderless)
								#endif
								Text(idx.element)

							}
						}
					}
				}.onDelete(perform: { indexSet in
					var newAddresses = addresses
					newAddresses.remove(atOffsets: indexSet)
					self.save(newAddresses)
				})

				Button("Add address") {
					// Uses self.onChange instead of self.save because .save deduplicates
					var newAddresses = self.addresses + [self.addressType.templateAddress]
					self.onChange(newAddresses)
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
