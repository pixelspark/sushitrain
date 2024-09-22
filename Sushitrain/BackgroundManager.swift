// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import BackgroundTasks

@MainActor class BackgroundManager {
    private static let BackgroundSyncID = "nl.t-shaped.sushitrain.background-sync"
    private var currentBackgroundTask: BGTask? = nil
    fileprivate var appState: AppState
    
    required init(appState: AppState) {
        self.appState = appState
        // Schedule background synchronization task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.BackgroundSyncID, using: nil) { task in
            Task { await self.handleBackgroundSync(task: task) }
        }
        updateBackgroundRunHistory(appending: nil)
        _ = Self.scheduleBackgroundSync()
    }
    
    private func handleBackgroundSync(task: BGTask) async {
        _ = Self.scheduleBackgroundSync()
        
        // Start photo synchronization if the user has enabled it
        var photoSyncTask: Task<(),Error>? = nil
        if self.appState.photoSync.enableBackgroundCopy {
            self.appState.photoSync.synchronize(self.appState, fullExport: false)
            photoSyncTask = self.appState.photoSync.syncTask
        }
        
        // Start background sync
        if Settings.backgroundSyncEnabled {
            let start = Date.now
            self.currentBackgroundTask = task
            print("Start background sync at", start, task)
            
            var run = BackgroundSyncRun(started: start, ended: nil)
            Settings.lastBackgroundSyncRun = run
            
            task.expirationHandler = {
                run.ended = Date.now
                print("Background sync expired at", run.ended!)
                self.currentBackgroundTask = nil
                Settings.lastBackgroundSyncRun = run
                self.updateBackgroundRunHistory(appending: run)
                self.appState.photoSync.cancel()
                task.setTaskCompleted(success: true)
            }
        }
        else {
            // Wait for photo sync to finish
            try? await photoSyncTask?.value
            task.setTaskCompleted(success: true)
        }
    }
    
    static func scheduleBackgroundSync() -> Bool {
        let request = BGProcessingTaskRequest(identifier: Self.BackgroundSyncID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // no earlier than within 15 minutes
        print("Scheduled next background sync for (no later than)", request.earliestBeginDate!)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            print("Could not schedule background sync: \(error)")
            return false
        }
    }
    
    private func updateBackgroundRunHistory(appending run: BackgroundSyncRun?) {
        var runs = Settings.backgroundSyncRuns
        
        // Remove old runs (older than 24h)
        let now = Date.now
        runs.removeAll(where: {r in
            return now.timeIntervalSince(r.started) > (24 * 60 * 60)
        })
        
        // Append our run
        if let run = run {
            runs.append(run)
        }
        Settings.backgroundSyncRuns = runs
    }
}
