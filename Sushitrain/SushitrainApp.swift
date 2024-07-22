// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore
import BackgroundTasks

@main
class SushitrainApp: NSObject, App, SushitrainClientDelegateProtocol, SushitrainStreamingServerDelegateProtocol {
    fileprivate var appState: SushitrainAppState
    private static let BackgroundSyncID = "nl.t-shaped.sushitrain.background-sync"
    private var currentBackgroundTask: BGTask? = nil
    
    required override init() {
        let configDirectory = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true);
        let documentsDirectory = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true);
        let documentsPath = documentsDirectory.path(percentEncoded: false)
        let configPath = configDirectory.path(percentEncoded: false)
        
        var error: NSError? = nil
        guard let client = SushitrainNewClient(configPath, documentsPath, &error) else {
            print("Error initializing: \(error?.localizedDescription ?? "unknown error")")
            exit(-1)
        }
        
        self.appState = SushitrainAppState(client: client)
        super.init()
        client.delegate = self;
        client.server?.delegate = self;
        
        updateBackgroundRunHistory(appending: BackgroundSyncRun(started: Date.now, ended: Date.now.addingTimeInterval(69)))
        
        // Schedule background synchronization task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SushitrainApp.BackgroundSyncID, using: nil) { task in
            self.handleBackgroundSync(task: task)
        }
        _ = Self.scheduleBackgroundSync()
        self.appState.update()
        
        let appState = self.appState
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try appState.client.start();
                
                DispatchQueue.main.async {
                    appState.applySettings()
                    appState.update()
                }
            }
            catch let error {
                DispatchQueue.main.async {
                    appState.alert(message: error.localizedDescription)
                }
            }
        }
    }
    
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
    
    @MainActor
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
    
    @MainActor
    private func handleBackgroundSync(task: BGTask) {
        _ = Self.scheduleBackgroundSync()
        
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
                task.setTaskCompleted(success: true)
            }
        }
        else {
            task.setTaskCompleted(success: true)
        }
    }
    
    static func scheduleBackgroundSync() -> Bool {
        let request = BGProcessingTaskRequest(identifier: SushitrainApp.BackgroundSyncID)
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
    
    var body: some Scene {
        WindowGroup { [appState] in
            ContentView(appState: appState)
        }
    }
    
    func onListenAddressesChanged(_ addresses: SushitrainListOfStrings?) {
        let appState = self.appState
        let addressSet = Set(addresses?.asArray() ?? [])
        DispatchQueue.main.async {
            appState.listenAddresses = addressSet
        }
    }
    
    func onFolderOffered(_ deviceID: String?, folder: String?) {
        let appState = self.appState
        if let deviceID = deviceID, let folderID = folder {
            DispatchQueue.main.async {
                appState.folderOffers.append(Offer(
                    deviceID: deviceID,
                    folderID: folderID
                ));
            }
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
    
    func alert(_ s: String?) {
        appState.alertMessage = s!;
        appState.alertShown = true;
    }
    
    func onEvent(_ event: String?) {
        let appState = self.appState
        DispatchQueue.main.async {
            appState.lastEvent = event ?? "unknown event"
            appState.update()
        }
    }
}
