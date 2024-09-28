// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import BackgroundTasks

@MainActor class BackgroundManager: ObservableObject {
    private static let LongBackgroundSyncID = "nl.t-shaped.sushitrain.background-sync"
    private static let ShortBackgroundSyncID = "nl.t-shaped.sushitrain.short-background-sync"
    private static let WatchdogNotificationID = "nl.t-shaped.sushitrain.watchdog-notification"
    
    private var currentBackgroundTask: BGTask? = nil
    fileprivate var appState: AppState
    
    required init(appState: AppState) {
        self.appState = appState
        // Schedule background synchronization task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.LongBackgroundSyncID, using: nil) { task in
            Task { await self.handleBackgroundSync(task: task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.ShortBackgroundSyncID, using: nil) { task in
            Task { await self.handleBackgroundSync(task: task) }
        }
        updateBackgroundRunHistory(appending: nil)
        _ = self.scheduleBackgroundSync()
        Task.detached {
            await self.rescheduleWatchdogNotification()
        }
    }
    
    private func handleBackgroundSync(task: BGTask) async {
        let start = Date.now
        self.currentBackgroundTask = task
        print("Start background sync at", start, task)
        DispatchQueue.main.async {
            _ = self.scheduleBackgroundSync()
        }
        await self.rescheduleWatchdogNotification()
        
        // Start photo synchronization if the user has enabled it
        var photoSyncTask: Task<(),Error>? = nil
        if self.appState.photoSync.enableBackgroundCopy {
            self.appState.photoSync.synchronize(self.appState, fullExport: false)
            photoSyncTask = self.appState.photoSync.syncTask
        }
        
        // Start background sync on long and short sync task
        if appState.longBackgroundSyncEnabled || appState.shortBackgroundSyncEnabled {
            var run = BackgroundSyncRun(started: start, ended: nil)
            appState.lastBackgroundSyncRun = OptionalObject(run)
            
            // Run to expiration
            task.expirationHandler = {
                run.ended = Date.now
                print("Background sync expired at", run.ended!)
                self.currentBackgroundTask = nil
                self.appState.lastBackgroundSyncRun = OptionalObject(run)
                self.updateBackgroundRunHistory(appending: run)
                self.appState.photoSync.cancel()
                self.notifyUserOfBackgroundSyncCompletion(start: start, end: run.ended!)
                task.setTaskCompleted(success: true)
            }
        }
        else {
            if task.identifier == Self.LongBackgroundSyncID {
                // When background task expires, end photo sync
                task.expirationHandler = {
                    self.appState.photoSync.cancel()
                }
                
                // Wait for photo sync to finish
                try? await photoSyncTask?.value
                task.setTaskCompleted(success: true)
                self.currentBackgroundTask = nil
            }
            else {
                // Do not do any photo sync on short background refresh
                task.setTaskCompleted(success: true)
                self.currentBackgroundTask = nil
            }
        }
    }
    
    private func notifyUserOfBackgroundSyncCompletion(start: Date, end: Date) {
        if self.appState.notifyWhenBackgroundSyncCompletes {
            let duration = Int(end.timeIntervalSince(start))
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Background synchronization completed")
            content.body = String(localized: "Background synchronization ran for \(duration) seconds")
            content.interruptionLevel = .passive
            content.sound = .none
            let uuidString = UUID().uuidString
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
            let request = UNNotificationRequest(identifier: uuidString, content: content, trigger: trigger)
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.add(request)
        }
    }
    
    func scheduleBackgroundSync() -> Bool {
        var success = true
        
        if appState.longBackgroundSyncEnabled {
            let longRequest = BGProcessingTaskRequest(identifier: Self.LongBackgroundSyncID)
            longRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // no earlier than within 15 minutes
            longRequest.requiresExternalPower = true
            longRequest.requiresNetworkConnectivity = true
            print("Scheduling next long background sync for (no later than)", longRequest.earliestBeginDate!)
            
            do {
                try BGTaskScheduler.shared.submit(longRequest)
            } catch {
                print("Could not schedule background sync: \(error)")
                success = false
            }
        }
        
        if appState.shortBackgroundSyncEnabled {
            let shortRequest = BGAppRefreshTaskRequest(identifier: Self.ShortBackgroundSyncID)
            shortRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // no earlier than within 15 minutes
            print("Scheduling next short background sync for (no later than)", shortRequest.earliestBeginDate!)
            do {
                try BGTaskScheduler.shared.submit(shortRequest)
            } catch {
                print("Could not schedule short background sync: \(error)")
                success = false
            }
        }
        
        return success
    }
    
    @MainActor
    func rescheduleWatchdogNotification() async {
        print("Re-schedule watchdog notification")
        let notificationCenter = UNUserNotificationCenter.current()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.WatchdogNotificationID])
        
        let appState = self.appState
        var interval: TimeInterval = TimeInterval(appState.watchdogIntervalHours * 60 * 60) // seconds
        if interval < 60.0 {
            interval = 60.0 * 60.0 // one hour minimum
        }
        
        if appState.watchdogNotificationEnabled {
            notificationCenter.getNotificationSettings { @MainActor settings in
                let status = settings.authorizationStatus
                if status == .authorized || status == .provisional {
                    let content = UNMutableNotificationContent()
                    content.title = String(localized: "Synchronisation did not run")
                    content.body = String(localized: "Background synchronization last ran more than \(Int(interval)) seconds ago. Open the app to synchronize.")
                    content.interruptionLevel = .passive
                    content.sound = .none
                    content.badge = 1
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
                    let request = UNNotificationRequest(identifier: Self.WatchdogNotificationID, content: content, trigger: trigger)
                    notificationCenter.add(request) {err in
                        if let err = err {
                            print("Could not add watchdog notification: \(err.localizedDescription)")
                        }
                        else {
                            print("Watchdog notification added")
                        }
                    }
                }
                else {
                    print("Watchdog not enabled or denied, not reinstalling")
                }
            }
        }
    }
    
    private func updateBackgroundRunHistory(appending run: BackgroundSyncRun?) {
        var runs = appState.backgroundSyncRuns
        
        // Remove old runs (older than 24h)
        let now = Date.now
        runs.removeAll(where: {r in
            return now.timeIntervalSince(r.started) > (24 * 60 * 60)
        })
        
        // Append our run
        if let run = run {
            runs.append(run)
        }
        appState.backgroundSyncRuns = runs
    }
}
