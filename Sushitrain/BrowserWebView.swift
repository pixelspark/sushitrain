// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

struct BrowserWebView: View {
	@EnvironmentObject var appState: AppState

	let folderID: String
	var path: String

	@State private var error: Error? = nil
	@State private var server: SushitrainFolderServer? = nil
	@State private var ready = false

	var body: some View {
		ZStack {
			if let err = self.error {
				ContentUnavailableView(
					"Cannot show this page", systemImage: "exclamationmark.triangle.fill", description: Text(err.localizedDescription)
				)
				.onTapGesture {
					if self.ready {
						self.error = nil
					}
				}
			}
			else if let s = self.server, ready {
				WebView(url: URL(string: s.url())!, isOpaque: true, isLoading: .constant(false), error: $error)
					.background(.white)
					.id(s.url())
			}
			else {
				ProgressView()
			}
		}
		.onDisappear {
			self.server?.shutdown()
			self.server = nil
			self.ready = false
		}
		.task {
			self.ready = false
			self.server = SushitrainNewFolderServer(appState.client, folderID, path)
			do {
				try self.server?.listen()
				self.ready = true
			}
			catch {
				self.error = error
			}
		}
	}
}
