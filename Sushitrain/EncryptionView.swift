// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct EncryptionView: View {
	let entry: SushitrainEntry
	@ObservedObject var appState: AppState

	@Environment(\.dismiss) private var dismiss

	@State private var folderPassword: String = ""

	private var encryptedPeers: [(SushitrainPeer, String)] {
		if let folder = entry.folder {
			let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
			return sharedEncrypted.compactMap {
				if let peer = appState.client.peer(withID: $0) {
					return (peer, folder.encryptionPassword(for: $0))
				}
				return nil
			}
		}
		return []
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Get encrypted file details") {
					LabeledContent {
						TextField("", text: $folderPassword).monospaced()
					} label: {
						Text("Folder encryption password")
					}

					LabeledContent {
						Picker("", selection: $folderPassword) {
							Text("None").tag("")
							ForEach(self.encryptedPeers, id: \.0.id) { (peer, password) in
								Text(peer.displayName).tag(password)
							}
						}
						.pickerStyle(.menu)
					} label: {
						Text("Use password for device")
					}
				}

				if !self.folderPassword.isEmpty {
					Section("Encrypted file path") {
						let path = entry.encryptedFilePath(self.folderPassword)
						Text(path).monospaced()

						Button("Copy", systemImage: "document.on.document") {
							writeTextToPasteboard(
								entry.encryptedFilePath(self.folderPassword))
						}
						#if os(macOS)
							.buttonStyle(.link)
						#endif
					}
				}
			}
			.formStyle(.grouped)
			.navigationTitle(entry.name())
			.toolbar(content: {
				ToolbarItem(
					placement: .confirmationAction,
					content: {
						Button("Done") {
							self.dismiss()
						}
					})
			})
		}
	}
}
