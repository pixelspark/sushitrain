// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct AboutView: View {
	@State private var showOnboarding = false
	@State private var showNotices = false

	var body: some View {
		Form {
			Section {
				Text("Synctrain is © 2024-2025, Tommy van der Vorst")
				Link(
					"End User License Agreement",
					destination: URL(
						string:
							"https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
					)!)
			}

			Section("Open source") {
				Text(
					"The source code of this application is available under the Mozilla Public License 2.0."
				)
				Link(
					"Obtain the source code",
					destination: URL(string: "https://github.com/pixelspark/sushitrain")!)
			}

			Section("Open source components") {
				Text(
					"This application incorporates Syncthing, which is open source software under the Mozilla Public License 2.0. Syncthing is a trademark of the Syncthing Foundation. This application is not associated with nor endorsed by the Syncthing foundation nor Syncthing contributors."
				)
				Link("Read more at syncthing.net", destination: URL(string: "https://syncthing.net")!)
				Button("Legal notices") {
					showNotices = true
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				Link(
					"Obtain the source code",
					destination: URL(string: "https://github.com/syncthing/syncthing")!)
				Link(
					"Obtain the source code modifications",
					destination: URL(string: "https://github.com/pixelspark/syncthing/tree/sushi")!)
			}

			Section("Version information") {
				if let appVersion = Bundle.main.releaseVersionNumber,
					let appBuild = Bundle.main.buildVersionNumber
				{
					Text("App").badge("\(appVersion) (\(appBuild))")
				}
				Text("Syncthing").badge(SushitrainVersion())
			}

			Button("Show introduction screen") {
				showOnboarding = true
			}
		}
		.navigationTitle("About this app")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.sheet(isPresented: $showOnboarding) {
			if #available(iOS 18, *) {
				OnboardingView()
					.interactiveDismissDisabled()
					.presentationSizing(.form.fitted(horizontal: false, vertical: true))
			}
			else {
				OnboardingView()
					.interactiveDismissDisabled()
			}
		}
		.sheet(isPresented: $showNotices) {
			let url = Bundle.main.url(forResource: "notices", withExtension: "html")!
			NavigationStack {
				WebView(url: url, trustFingerprints: [], isLoading: Binding.constant(false), error: Binding.constant(nil))
					.frame(minHeight: 480)
					.toolbar {
						ToolbarItem(
							placement: .cancellationAction,
							content: {
								Button("Close") {
									showNotices = false
								}
							})
					}
					.navigationTitle("Legal notices")
					#if os(iOS)
						.navigationBarTitleDisplayMode(.inline)
					#endif
			}
		}
	}
}
