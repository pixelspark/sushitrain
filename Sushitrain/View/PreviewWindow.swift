// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

#if os(macOS)
	struct Preview: Hashable, Codable {
		var folderID: String
		var path: String
	}

	private struct VisualEffect: NSViewRepresentable {
		func makeNSView(context: Self.Context) -> NSView { return NSVisualEffectView() }
		func updateNSView(_ nsView: NSView, context: Context) {}
	}

	// A floating preview window (that can be 'detached' from the file preview sheet
	struct PreviewWindow: View {
		let preview: Preview
		@Environment(AppState.self) private var appState

		@State private var entry: SushitrainEntry? = nil
		@State private var siblings: [SushitrainEntry] = []

		@Environment(\.dismissWindow) private var dismissWindow

		var body: some View {
			ZStack {
				if let entry = self.entry {
					FileViewerView(
						file: entry,
						siblings: self.siblings,
						inSheet: false,
						isShown: .constant(true)
					)
				}
				else {
					ProgressView()
				}
			}
			.onAppear {
				self.update()
			}
			.onChange(of: self.preview) {
				self.update()
			}
			.toolbarTitleDisplayMode(.inline)
			.background(VisualEffect().ignoresSafeArea())
		}

		private func update() {
			do {
				if let folder = self.appState.client.folder(withID: preview.folderID) {
					let e = try folder.getFileInformation(preview.path)
					let parentPath = e.parentPath()
					self.siblings = try folder.listEntries(
						prefix: parentPath, directories: false,
						hideDotFiles: appState.userSettings.dotFilesHidden,
						recursive: false)
					self.entry = e
				}
			}
			catch {
				Log.warn("Error loading preview window: \(error.localizedDescription)")
				self.entry = nil
				self.siblings = []
				self.dismissWindow()
			}
		}
	}
#endif
