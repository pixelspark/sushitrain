// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import BackgroundTasks

class SushitrainAppDelegate: NSObject {
    fileprivate var appState: AppState
    
    required init(appState: AppState) {
        self.appState = appState
    }
    
    
}

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

@main
struct SushitrainApp: App {
    fileprivate var appState: AppState
    fileprivate var delegate: SushitrainAppDelegate
    fileprivate var backgroundManager: BackgroundManager
    
    init() {
        let configDirectory = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true);
        let documentsDirectory = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true);
        let documentsPath = documentsDirectory.path(percentEncoded: false)
        let configPath = configDirectory.path(percentEncoded: false)
        
        var error: NSError? = nil
        guard let client = SushitrainNewClient(configPath, documentsPath, &error) else {
            print("Error initializing: \(error?.localizedDescription ?? "unknown error")")
            exit(-1)
        }
        
        self.appState = AppState(client: client)
        self.delegate = SushitrainAppDelegate(appState: self.appState)
        client.delegate = self.delegate;
        client.server?.delegate = self.delegate;
        self.backgroundManager = BackgroundManager(appState: self.appState)
        self.appState.update()
        
        let appState = self.appState
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.start();
                
                DispatchQueue.main.async {
                    appState.applySettings()
                    appState.update()
                    appState.updateBadge()
                }
            }
            catch let error {
                DispatchQueue.main.async {
                    appState.alert(message: error.localizedDescription)
                }
            }
        }
    }
    
    var body: some Scene {
        WindowGroup { [appState] in
            ContentView(appState: appState)
        }
    }
}

extension SushitrainChange: @unchecked @retroactive Sendable {}

extension SushitrainAppDelegate: SushitrainClientDelegateProtocol {
    func onChange(_ change: SushitrainChange?) {
        if let change = change {
            let appState = self.appState
            DispatchQueue.main.async {
                // For example: 25 > 25, 100 > 25
                if appState.lastChanges.count > AppState.maxChanges - 1 {
                    // Remove excess elements at the top
                    // For example: 25 - 25 + 1 = 1, 100 - 25 + 1 = 76
                    appState.lastChanges.removeFirst(appState.lastChanges.count - AppState.maxChanges + 1)
                }
                appState.lastChanges.append(change)
            }
        }
    }
    
    func onEvent(_ event: String?) {
        let appState = self.appState
        DispatchQueue.main.async {
            appState.lastEvent = event ?? "unknown event"
            appState.eventCounter += 1
            appState.update()
        }
        
        if event == "LocalIndexUpdated" || event == "LocalChangeDetected" {
            // Check for extraneous files and update app badge accordingly
            DispatchQueue.main.async {
                appState.updateBadge()
            }
        }
    }
    
    func onListenAddressesChanged(_ addresses: SushitrainListOfStrings?) {
        let appState = self.appState
        let addressSet = Set(addresses?.asArray() ?? [])
        DispatchQueue.main.async {
            appState.listenAddresses = addressSet
        }
    }
    
    func onDeviceDiscovered(_ deviceID: String?, addresses: SushitrainListOfStrings?) {
        let appState = self.appState
        if let deviceID = deviceID, let addresses = addresses?.asArray() {
            DispatchQueue.main.async {
                appState.discoveredDevices[deviceID] = addresses
            }
        }
    }
}

extension SushitrainAppDelegate: SushitrainStreamingServerDelegateProtocol {
    func onStreamChunk(_ folder: String?, path: String?, bytesSent: Int64, bytesTotal: Int64) {
        if let folder = folder, let path = path {
            let appState = self.appState;
            DispatchQueue.main.async {
                appState.streamingProgress = StreamingProgress(
                    folder: folder,
                    path: path,
                    bytesSent: bytesSent,
                    bytesTotal: bytesTotal
                )
            }
        }
    }
}
