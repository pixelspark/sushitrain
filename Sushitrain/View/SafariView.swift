// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SafariServices

#if os(iOS)
	struct SafariView: UIViewControllerRepresentable {
		let url: URL

		func makeUIViewController(context: UIViewControllerRepresentableContext<Self>) -> SFSafariViewController {
			return SFSafariViewController(url: url)
		}

		func updateUIViewController(
			_ uiViewController: SFSafariViewController,
			context: UIViewControllerRepresentableContext<SafariView>
		) {
		}
	}

	/// Monitors the `openURL` environment variable and handles them in-app instead of via
	/// the external web browser.
	/// Inspired by https://www.avanderlee.com/swiftui/sfsafariviewcontroller-open-webpages-in-app/
	private struct SafariViewControllerViewModifier: ViewModifier {
		@State private var urlToOpen: URL?

		func body(content: Content) -> some View {
			content
				.environment(
					\.openURL,
					OpenURLAction { url in
						urlToOpen = url
						return .handled
					}
				)
				.sheet(isPresented: Binding.isNotNil($urlToOpen)) {
					SafariView(url: urlToOpen!)
				}
		}
	}

	extension View {
		/// Monitor the `openURL` environment variable and handle them in-app instead of via
		/// the external web browser.
		/// Uses the `SafariViewWrapper` which will present the URL in a `SFSafariViewController`.
		func handleOpenURLInApp() -> some View {
			modifier(SafariViewControllerViewModifier())
		}
	}
#endif
