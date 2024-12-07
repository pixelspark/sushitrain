// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import AppIntents

struct SynchronizePhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy new photos"
    
    @Dependency private var appState: AppState
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await appState.photoSync.synchronize(appState, fullExport: false, isInBackground: true)
        return .result(dialog: "Copied new photos")
    }
}

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SynchronizePhotosIntent(), phrases: ["Copy new photos"], shortTitle: "Copy new photos", systemImageName: "photo.badge.arrow.down.fill")
    }
}
