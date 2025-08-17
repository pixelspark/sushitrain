// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

struct BrowserWebView: View {
	@Environment(AppState.self) private var appState

	let folderID: String
	var path: String

	@State private var error: Error? = nil
	@State private var server: SushitrainFolderServer? = nil
	@State private var ready = false
	@State private var serverFingerprintSha256: [Data] = []
	@State private var cookies: [HTTPCookie] = []

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
				WebView(
					url: URL(string: s.url())!,
					trustFingerprints: self.serverFingerprintSha256,
					cookies: cookies,
					isOpaque: true,
					isLoading: .constant(false),
					error: $error
				)
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
			if let s = self.server {
				s.shutdown()
			}
			self.server = SushitrainNewFolderServer(appState.client, folderID, path)

			do {
				if let server = self.server {
					try server.listen()
					self.serverFingerprintSha256 = [server.certificateFingerprintSHA256()!]
					self.cookies = [
						// FIXME: the cookie can be read from the webpage itself using document.cookie. While not particularly
						// problematic, it is probably best to prevent this.
						HTTPCookie(properties: [
							.domain: "localhost",
							.path: "/",
							.name: server.cookieName(),
							.sameSitePolicy: "Strict",
							.value: server.cookieValue(),
							.secure: "TRUE",
							.expires: NSDate(timeIntervalSinceNow: 86400 * 365),
						])!
					]
					Log.info("Folder server URL: \(server.url()) cookie=\(self.cookies)")
					self.ready = true
				}
			}
			catch {
				self.error = error
			}
		}
	}
}
