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
							ForEach(self.encryptedPeers, id: \.0.id) { (peer, password) in
								Text(peer.displayName).tag(password)
							}
							Text("None").tag(folderPassword)
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

					Section("File encryption key") {
						let key = entry.fileKeyBase32(self.folderPassword)
						Text(key).monospaced()
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

// Shows a list of decrypted paths
struct DecryptedFilePathsView: View {
	let folder: SushitrainFolder
	let path: String
	@ObservedObject var appState: AppState
	@State private var decryptedPaths: [String] = []

	private var passwords: [String] {
		let peerIDs = self.folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? []
		return peerIDs.compactMap { peerID in
			let pw = self.folder.encryptionPassword(for: peerID)
			if !pw.isEmpty {
				return pw
			}
			return nil
		}
	}

	private func update() async {
		let passwords = self.passwords
		self.decryptedPaths = await Task.detached {
			return passwords.compactMap { pw in
				var error: NSError? = nil
				let decryptedPath = self.folder.decryptedFilePath(
					path, folderPassword: pw, error: &error)
				if error == nil && !decryptedPath.isEmpty {
					return decryptedPath
				}
				return nil
			}
		}.value
	}

	var body: some View {
		Group {
			if !self.decryptedPaths.isEmpty {
				Section("Decrypted path") {
					ForEach(self.decryptedPaths, id: \.self) { path in
						if let entry = try? self.folder.getFileInformation(path) {
							EntryView(
								appState: appState,
								entry: entry,
								folder: self.folder,
								siblings: [],
								showThumbnail: appState.showThumbnailsInSearchResults)
						}
					}
				}
			}
			else {
				EmptyView()
			}
		}
		.task {
			await self.update()
		}
		.onChange(of: self.path) {
			Task {
				await self.update()
			}
		}
	}
}
