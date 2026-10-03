// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

// Wrapper for folder server, to ensure that it is always deinited
private class FolderServer {
	let server: SushitrainFolderServer

	init(client: SushitrainClient, folderID: String, path: String) throws {
		self.server = SushitrainNewFolderServer(client, folderID, path)!
		try self.server.listen()
	}

	deinit {
		self.server.shutdown()
	}

	var url: URL {
		return URL(string: self.server.url())!
	}
}

struct BrowserWebView: View {
	@Environment(AppState.self) private var appState

	let folderID: String
	var path: String

	@State private var error: Error? = nil
	@State private var server: FolderServer? = nil
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
					url: s.url,
					trustFingerprints: self.serverFingerprintSha256,
					cookies: cookies,
					isOpaque: true,
					isLoading: .constant(false),
					error: $error
				)
				.background(.white)
				.id(s.url)
			}
			else {
				ProgressView()
			}
		}
		.onDisappear {
			self.server = nil
			self.ready = false
		}
		.task {
			self.ready = false
			self.server = nil

			do {
				self.server = try FolderServer(client: appState.client, folderID: folderID, path: path)
				if let server = self.server {
					self.serverFingerprintSha256 = [server.server.certificateFingerprintSHA256()!]
					self.cookies = [
						// FIXME: the cookie can be read from the webpage itself using document.cookie. While not particularly
						// problematic, it is probably best to prevent this.
						HTTPCookie(properties: [
							.domain: "localhost",
							.path: "/",
							.name: server.server.cookieName(),
							.sameSitePolicy: "Strict",
							.value: server.server.cookieValue(),
							.secure: "TRUE",
							.expires: NSDate(timeIntervalSinceNow: 86400 * 365),
						])!
					]
					Log.info("Folder server URL: \(server.url) cookie=\(self.cookies)")
					self.ready = true
				}
			}
			catch {
				self.error = error
			}
		}
	}
}
