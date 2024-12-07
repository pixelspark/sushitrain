// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
#if os(iOS)
import UIKit

enum QuickAction: String, Equatable {
    case search = "search"
    
    init?(type: String) {
        switch type {
        case "search":
            self = .search
        default:
            return nil
        }
    }
}

class QuickActionService: ObservableObject {
    @MainActor static let shared = QuickActionService()
    @Published var action: QuickAction?
    
    @MainActor
    static func provideActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: "search",
                localizedTitle: String(localized: "Search"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon.init(type: .search)
            ),
        ]
    }
}

// Glue code for quick actions
class AppDelegate: NSObject, UIApplicationDelegate {
    private let qaService = QuickActionService.shared
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            qaService.action = QuickAction(type: shortcutItem.type)
        }
        let configuration = UISceneConfiguration(name: connectingSceneSession.configuration.name, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private let qaService = QuickActionService.shared
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            qaService.action = QuickAction(type: shortcutItem.type)
        }
    }
    
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        qaService.action = QuickAction(type: shortcutItem.type)
        completionHandler(true)
    }
}
#endif
