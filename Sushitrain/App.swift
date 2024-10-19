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
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
        @AppStorage("hideInDock") var hideInDock: Bool = false
    #endif
    
    private static var configDirectory: URL {
        return try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    
    static var documentsDirectory: URL {
        return try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    
    init() {
        var configDirectory = Self.configDirectory
        let documentsDirectory = Self.documentsDirectory
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
        
        let enableLogging = UserDefaults.standard.bool(forKey: "loggingEnabled")
        print("Logging enabled: \(enableLogging)")
        var error: NSError? = nil
        guard let client = SushitrainNewClient(configPath, documentsPath, enableLogging, &error) else {
            print("Error initializing: \(error?.localizedDescription ?? "unknown error")")
            exit(-1)
        }
        
        self.appState = AppState(client: client)
        self.appState.isLogging = enableLogging
        self.delegate = SushitrainAppDelegate(appState: self.appState)
        client.delegate = self.delegate;
        client.server?.delegate = self.delegate;
        self.appState.update()
        
        let appState = self.appState
        
        // Resolve bookmarks
        let folderIDs = client.folders()?.asArray() ?? []
        for folderID in folderIDs {
            do {
                if let bm = try BookmarkManager.shared.resolveBookmark(folderID: folderID) {
                    print("We have a bookmark for folder \(folderID): \(bm)")
                    if let folder = client.folder(withID: folderID) {
                        try folder.setPath(bm.path(percentEncoded: false))
                    }
                    else {
                        print("Cannot obtain folder configuration for \(folderID) for setting bookmark; skipping")
                    }
                }
            }
            catch {
                print("Error restoring bookmark for \(folderID): \(error.localizedDescription)")
            }
        }
        BookmarkManager.shared.removeBookmarksForFoldersNotIn(Set(folderIDs))
        
        // Start Syncthing node in the background
        #if os(macOS)
            let hideInDock = self.hideInDock
        #endif
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.start();
                
                DispatchQueue.main.async {
                    appState.applySettings()
                    appState.update()
                    appState.updateBadge()
                    Self.protectFiles()
                }
            }
            catch let error {
                DispatchQueue.main.async {
                    appState.alert(message: error.localizedDescription)
                }
            }
            
            #if os(macOS)
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(hideInDock ? .accessory : .regular)
                }
            #endif
        }
    }
    
    var body: some Scene {
        WindowGroup(id: "main") { [appState] in
            ContentView(appState: appState)
            #if os(iOS)
                .handleOpenURLInApp()
            #endif
        }
        #if os(macOS)
            .onChange(of: hideInDock, initial: true) { _ov, nv in
                NSApp.setActivationPolicy(nv ? .accessory : .regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        
            .commands {
                CommandGroup(replacing: CommandGroupPlacement.appInfo) {
                    Button(action: {
                        // Open the "about" window
                        openWindow(id: "about")
                    }, label: {
                        Text("About Synctrain")
                    })
                    
                    Button(action: {
                        openWindow(id: "stats")
                    }, label: {
                        Text("Statistics...")
                    })
                }
            }
            .defaultLaunchBehavior(hideInDock ? .suppressed : .presented)
            .restorationBehavior(hideInDock ? .disabled : .automatic)
            
        #endif
        
        #if os(macOS)
            MenuBarExtraView(hideInDock: $hideInDock, appState: appState)
        
            Settings {
                NavigationStack {
                    TabbedSettingsView(appState: appState, hideInDock: $hideInDock)
                }
            }
            .windowResizability(.contentSize)
            
            // About window
            WindowGroup("About Synctrain", id: "about") {
                AboutView()
            }
            .windowResizability(.contentSize)
        
            WindowGroup("Statistics", id: "stats") {
                TotalStatisticsView(appState: appState)
                    .frame(maxWidth: 320)
            }
            .windowResizability(.contentSize)
        #endif
    }
    
    @MainActor private static func protectFiles() {
        // Set data protection for config file and keys
        let configDirectoryURL = Self.configDirectory
        let files = [SushitrainConfigFileName, SushitrainKeyFileName, SushitrainCertFileName]
        for file in files {
            do {
                let fileURL = configDirectoryURL.appendingPathComponent(SushitrainConfigFileName, isDirectory: false)
                try (fileURL as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
                print("Data protection class set for \(fileURL)")
            }
            catch {
                print("Error setting data protection class for \(file): \(error.localizedDescription)")
            }
        }
    }
}

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
            appState.resolvedListenAddresses = addressSet
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

#if os(macOS)
struct MenuBarExtraView: Scene {
    @Binding var hideInDock: Bool
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        Window("Settings", id: "appSettings") {
            NavigationStack {
                TabbedSettingsView(appState: appState, hideInDock: $hideInDock)
            }
        }
        
        MenuBarExtra("Synctrain", systemImage: self.menuIcon, isInserted: $hideInDock) {
            OverallStatusView(appState: appState)
            
            Button("Open file browser...") {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
            
            Divider()
            
            Button(action: {
                // Open the "about" window
                openWindow(id: "appSettings")
                NSApplication.shared.activate()
            }, label: {
                Text("Settings...")
            })
            
            Button(action: {
                openWindow(id: "stats")
                NSApplication.shared.activate()
            }, label: {
                Text("Statistics...")
            })
            
            Button(action: {
                // Open the "about" window
                openWindow(id: "about")
                NSApplication.shared.activate()
            }, label: {
                Text("About...")
            })
            
            Divider()
            
            Toggle(isOn: $hideInDock) {
                Label("Hide in dock", systemImage: "eye.slash")
            }

            Button("Quit Synctrain") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    private var menuIcon: String {
        if self.appState.client.connectedPeerCount() > 0 {
            if self.appState.client.isDownloading() || self.appState.client.isUploading() {
                return "folder.fill.badge.gearshape"
            }
            return "folder.fill"
        }
        else {
            return "folder"
        }
    }
}
#endif
