// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
#if os(iOS)
	import UIKit
#endif

import SwiftUI

class QuickActionService: ObservableObject {
	@MainActor static let shared = QuickActionService()
	@Published var action: Route?

	#if os(iOS)
		@MainActor
		static func provideActions(bookmarks: [Route]) {
			let bookmarkedActions = bookmarks.map { route in
				UIApplicationShortcutItem(
					type: route.url.absoluteString,
					localizedTitle: route.localizedTitle,
					localizedSubtitle: route.localizedSubtitle,
					icon: UIApplicationShortcutIcon.init(type: .bookmark)
				)
			}

			UIApplication.shared.shortcutItems =
				[
					UIApplicationShortcutItem(
						type: Route.search(for: "").url.absoluteString,
						localizedTitle: String(localized: "Search"),
						localizedSubtitle: nil,
						icon: UIApplicationShortcutIcon.init(type: .search)
					)
				] + bookmarkedActions
		}
	#endif
}

#if os(iOS)
	// Glue code for quick actions
	class AppDelegate: NSObject, UIApplicationDelegate {
		private let qaService = QuickActionService.shared

		func application(
			_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
			options: UIScene.ConnectionOptions
		) -> UISceneConfiguration {
			if let shortcutItem = options.shortcutItem, let url = URL(string: shortcutItem.type) {
				qaService.action = Route(url: url)
			}

			let configuration = UISceneConfiguration(
				name: connectingSceneSession.configuration.name,
				sessionRole: connectingSceneSession.role)
			configuration.delegateClass = SceneDelegate.self
			return configuration
		}
	}

	class SceneDelegate: NSObject, UIWindowSceneDelegate {
		private let qaService = QuickActionService.shared

		func scene(
			_ scene: UIScene, willConnectTo session: UISceneSession,
			options connectionOptions: UIScene.ConnectionOptions
		) {
			if let shortcutItem = connectionOptions.shortcutItem, let url = URL(string: shortcutItem.type) {
				qaService.action = Route(url: url)
			}
		}

		func windowScene(
			_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
			completionHandler: @escaping (Bool) -> Void
		) {
			if let url = URL(string: shortcutItem.type) {
				qaService.action = Route(url: url)
			}
			completionHandler(true)
		}
	}
#endif
