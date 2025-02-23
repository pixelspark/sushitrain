// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
@preconcurrency import SushitrainCore

private enum ExternalSharingTypeBare: Equatable, Hashable {
	case none
	case unencrypted
	case encrypted
}

struct ExternalSharingSettingsView: View {
	var folder: SushitrainFolder
	@ObservedObject var appState: AppState

	@State private var settings: ExternalSharingType = .none

	var body: some View {
		let typeBinding = Binding(
			get: {
				switch settings {
				case .none: return ExternalSharingTypeBare.none
				case .unencrypted(_): return ExternalSharingTypeBare.unencrypted
				case .encrypted(_): return ExternalSharingTypeBare.encrypted
				}
			},
			set: { (newValue: ExternalSharingTypeBare) in
				// Try to transfer as much settings as possible between variants
				// Where not possible, set sensible defaults
				switch (settings, newValue) {
				case (_, .none): settings = .none
				case (.none, .unencrypted):
					settings = .unencrypted(ExternalSharingUnencrypted(url: "", prefix: ""))
				case (.unencrypted(_), .unencrypted): break
				case (.unencrypted(let u), .encrypted):
					settings = .encrypted(ExternalSharingEncrypted(url: u.url, password: ""))
				case (.encrypted(let e), .unencrypted):
					settings = .unencrypted(ExternalSharingUnencrypted(url: e.url, prefix: ""))
				case (_, .encrypted):
					settings = .encrypted(ExternalSharingEncrypted(url: "", password: ""))
				}
			}
		)

		Form {
			Picker("Link type", selection: typeBinding) {
				Text("None").tag(ExternalSharingTypeBare.none)
				Text("Unencrypted").tag(ExternalSharingTypeBare.unencrypted)
				Text("Encrypted").tag(ExternalSharingTypeBare.encrypted)
			}
			.pickerStyle(.menu)

			// Unencrypted sharing
			switch settings {
			case .unencrypted(let externalSharingUnencrypted):
				UnencryptedSharingSettingsView(
					settings: Binding(
						get: {
							return externalSharingUnencrypted
						},
						set: { nv in
							self.settings = .unencrypted(nv)
						}))

			case .encrypted(let encryptedSharingEncrypted):
				EncryptedSharingSettingsView(
					folder: self.folder,
					appState: self.appState,
					settings: Binding(
						get: {
							return encryptedSharingEncrypted
						},
						set: { nv in
							self.settings = .encrypted(nv)
						}))

			case .none:
				EmptyView()
			}
		}
		.navigationTitle("External sharing")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.onAppear {
			self.settings = ExternalSharingManager.shared.externalSharingFor(folderID: folder.folderID)
		}
		.onChange(of: settings) { (_, nv) in
			ExternalSharingManager.shared.setExternalSharingFor(
				folderID: self.folder.folderID, externalSharing: nv)
		}
	}
}

private struct UnencryptedSharingSettingsView: View {
	@Binding var settings: ExternalSharingUnencrypted

	var body: some View {
		Section {
			LabeledContent {
				TextField(
					"",
					text: Binding(
						get: { settings.url },
						set: { url in
							settings.url = url
						})
				)
				.multilineTextAlignment(.trailing)
				.autocorrectionDisabled()
				#if os(iOS)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
				#endif
			} label: {
				Text("Public URL")
			}

			LabeledContent {
				TextField(
					"",
					text: Binding(
						get: { settings.prefix },
						set: { prefix in
							settings.prefix = prefix
						}),
					prompt: Text("(None)")
				)
				.multilineTextAlignment(.trailing)
				.autocorrectionDisabled()
				#if os(iOS)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
				#endif
			} label: {
				Text("Subpath")
			}
		} header: {
			Text("Unencrypted sharing links")
		} footer: {
			let examplePath = "\(settings.prefix)/example file.jpg"
			if let url = settings.urlForFile(path: examplePath, isDirectory: false) {
				Text(
					"For a file inside this folder at location '\(examplePath)', the generated sharing link will be \(url)'. For the link to actually work, you need to set up a web server serving the the folder at the indicated URL."
				)
			}
		}
	}
}

private struct EncryptedSharingSettingsView: View {
	let folder: SushitrainFolder

	@ObservedObject var appState: AppState
	@Binding var settings: ExternalSharingEncrypted

	private var encryptedPeers: [(SushitrainPeer, String)] {
		let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
		return sharedEncrypted.compactMap {
			if let peer = appState.client.peer(withID: $0) {
				return (peer, folder.encryptionPassword(for: $0))
			}
			return nil
		}
	}

	var body: some View {
		Section {
			LabeledContent {
				TextField(
					"",
					text: Binding(
						get: { settings.url },
						set: { url in
							settings.url = url
						})
				)
				.multilineTextAlignment(.trailing)
				.autocorrectionDisabled()
				#if os(iOS)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
				#endif
			} label: {
				Text("Public URL")
			}

			LabeledContent {
				HStack {
					TextField(
						"",
						text: Binding(
							get: { settings.password },
							set: { password in
								settings.password = password
							}),
						prompt: Text("(None)")
					)
					.multilineTextAlignment(.trailing)
					.autocorrectionDisabled()
					#if os(iOS)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
					#endif

					// Menu to select passwords used for encrypted peers of this folder
					if !self.encryptedPeers.isEmpty {
						Menu {
							ForEach(self.encryptedPeers, id: \.0.id) { (peer, password) in
								Button {
									settings.password = password
								} label: {
									Label(
										peer.displayName,
										systemImage: "externaldrive.fill")
								}
							}
						} label: {
							Label("Use password for device", systemImage: "ellipsis.circle")
								.labelStyle(.iconOnly)
						}
						.frame(maxWidth: 52)
					}
				}
			} label: {
				Text("Folder encryption password")
			}
		} header: {
			Text("Encrypted sharing links")
		} footer: {
			if let exURL = settings.exampleURL {
				Text(
					"Generated URLs will look like '\(exURL.absoluteString)'. You will need to configure a web server and/or application to handle these URLs."
				)
			}
		}
	}
}
