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

@main
struct SushitrainApp: App {
    fileprivate var appState: AppState
    fileprivate var delegate: SushitrainAppDelegate
    fileprivate var backgroundManager: BackgroundManager
    
    init() {
        var configDirectory = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true);
        let documentsDirectory = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true);
        let documentsPath = documentsDirectory.path(percentEncoded: false)
        let configPath = configDirectory.path(percentEncoded: false)
        
        // Exclude config and database directory from device back-up
        var excludeFromBackup = URLResourceValues()
        excludeFromBackup.isExcludedFromBackup = true
        do {
            try configDirectory.setResourceValues(excludeFromBackup)
        }
        catch {
            print("Error excluding \(configDirectory.path) from backup: \(error.localizedDescription)")
        }
        
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
