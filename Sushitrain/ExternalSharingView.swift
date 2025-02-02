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
}

struct ExternalSharingSettingsView: View {
	var folder: SushitrainFolder
	@State private var settings: ExternalSharingType = .none

	var body: some View {
		let typeBinding = Binding(
			get: {
				switch settings {
				case .none: return ExternalSharingTypeBare.none
				case .unencrypted(_): return ExternalSharingTypeBare.unencrypted
				}
			},
			set: { (newValue: ExternalSharingTypeBare) in
				switch (settings, newValue) {
				case (_, .none): settings = .none
				case (.none, .unencrypted):
					settings = .unencrypted(ExternalSharingUnencrypted(url: "", prefix: ""))
				case (.unencrypted(_), .unencrypted): break
				}
			}
		)

		Form {
			Picker("Link type", selection: typeBinding) {
				Text("None").tag(ExternalSharingTypeBare.none)
				Text("Unencrypted").tag(ExternalSharingTypeBare.unencrypted)
			}
			.pickerStyle(.menu)

			// Unencrypted sharing
			if case .unencrypted(let externalSharingUnencrypted) = settings {
				UnencryptedSharingSettingsView(
					settings: Binding(
						get: {
							return externalSharingUnencrypted
						},
						set: { nv in
							self.settings = .unencrypted(nv)
						}))
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
