// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct TotalStatisticsView: View {
    @ObservedObject var appState: AppState
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    var body: some View {
        let formatter = ByteCountFormatter()
        let stats: SushitrainFolderStats? = try? self.appState.client.statistics()
        
        Form {
            if let stats = stats {
                Section("All devices") {
                    Text("Number of files").badge(stats.global!.files)
                    Text("Number of directories").badge(stats.global!.directories)
                    Text("File size").badge(formatter.string(fromByteCount: stats.global!.bytes))
                }
                
                Section("This device") {
                    Text("Number of files").badge(stats.local!.files)
                    Text("Number of directories").badge(stats.local!.directories)
                    Text("File size").badge(formatter.string(fromByteCount: stats.local!.bytes))
                }
            }
        }.navigationTitle("Statistics")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Form {
            Section {
                Toggle("Listen for incoming connections", isOn: Binding(get: {
                    return appState.client.isListening()
                }, set: { listening in
                    try? appState.client.setListening(listening)
                }))
            } header: {
                Text("Connectivity")
            } footer: {
                if appState.client.isListening() {
                    Text("Added devices can connect to this device on their initiative, while the app is running. This may cause additional battery drain. It is advisable to enable this only if you experience difficulty connecting to other devices.")
                }
                else {
                    Text("Connections to other devices can only be initiated by this device, not by the other added devices.")
                }
            }
            
            Section {
                Toggle("One connection is enough", isOn: Binding(get: {
                    return appState.client.getEnoughConnections() == 1
                }, set: { enough in
                    try! appState.client.setEnoughConnections(enough ? 1 : 0)
                }))
            } footer: {
                Text("When this setting is enabled, the app will not attempt to connect to more devices after one connection has been established.")
            }
            
            Section {
                Toggle("Enable NAT-PMP / UPnP", isOn: Binding(get: {
                    return appState.client.isNATEnabled()
                }, set: {nv in
                    try? appState.client.setNATEnabled(nv)
                }))
                
                Toggle("Enable relaying", isOn: Binding(get: {
                    return appState.client.isRelaysEnabled()
                }, set: {nv in
                    try? appState.client.setRelaysEnabled(nv)
                }))
                
                Toggle("Announce on local networks", isOn: Binding(get: {
                    return appState.client.isLocalAnnounceEnabled()
                }, set: {nv in
                    try? appState.client.setLocalAnnounceEnabled(nv)
                }))
                
                Toggle("Announce globally", isOn: Binding(get: {
                    return appState.client.isGlobalAnnounceEnabled()
                }, set: {nv in
                    try? appState.client.setGlobalAnnounceEnabled(nv)
                }))
                
                Toggle("Announce LAN addresses", isOn: Binding(get: {
                    return appState.client.isAnnounceLANAddressesEnabled()
                }, set: {nv in
                    try? appState.client.setAnnounceLANAddresses(nv)
                }))
            }
            
            Section("Previews") {
                Toggle("Show image previews", isOn: Binding(get: {
                    return appState.maxBytesForPreview > 0
                }, set: { nv in
                    if nv {
                        appState.maxBytesForPreview = 3 * 1024 * 1024 // 3 MiB
                    }
                    else {
                        appState.maxBytesForPreview = 0
                    }
                }))
                
                if appState.maxBytesForPreview > 0 {
                    Stepper("\(appState.maxBytesForPreview / 1024 / 1024) MB", value: Binding(get: {
                        appState.maxBytesForPreview / 1024 / 1024
                    }, set: { nv in
                        appState.maxBytesForPreview = nv * 1024 * 1024
                    }), in: 1...100)
                }
            }
        }
        .navigationTitle("Advanced settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

#if os(iOS)
struct BackgroundSettingsView: View {
    @ObservedObject var appState: AppState
    let durationFormatter = DateComponentsFormatter()
    @State private var alertShown = false
    @State private var alertMessage = ""
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    
    init(appState: AppState) {
        self.appState = appState
        durationFormatter.allowedUnits = [.day, .hour, .minute]
        durationFormatter.unitsStyle = .abbreviated
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable while charging (long)", isOn: appState.$longBackgroundSyncEnabled)
                Toggle("Enable on battery (short)", isOn: appState.$shortBackgroundSyncEnabled)
            }
            header: {
                Text("Background synchronization")
            }
            footer: {
                Text("The operating system will periodically grant the app a few minutes of time in the background, depending on network connectivity and battery status.")
            }
            
            Section {
                if self.authorizationStatus == .notDetermined {
                    Button("Enable notifications") {
                        AppState.requestNotificationPermissionIfNecessary()
                        self.updateNotificationStatus()
                    }
                }
                else {
                    Toggle("When background synchronization completes", isOn: appState.$notifyWhenBackgroundSyncCompletes)
                        .disabled((!appState.longBackgroundSyncEnabled && !appState.shortBackgroundSyncEnabled) || (authorizationStatus != .authorized && authorizationStatus != .provisional))
                }
            }
            header: {
                Text("Notifications")
            }
            
            Section {
                if self.authorizationStatus != .notDetermined {
                    Toggle("When last synchronization happened long ago", isOn: appState.$watchdogNotificationEnabled)
                        .disabled(authorizationStatus != .authorized && authorizationStatus != .provisional)
                        .onChange(of: appState.watchdogNotificationEnabled) {
                            self.updateNotificationStatus()
                        }
                    
                    if appState.watchdogNotificationEnabled {
                        Stepper("After \(appState.watchdogIntervalHours) hours", value: appState.$watchdogIntervalHours, in: 1...(24*7))
                    }
                }
            }
            footer: {
                if self.authorizationStatus == .denied {
                    Text("Go to the Settings app to alllow notifications.")
                }
            }
            
            Section("Last background synchronization") {
                if let lastSyncRun = appState.lastBackgroundSyncRun.wrappedValue {
                    Text("Started").badge(lastSyncRun.started.formatted(date: .abbreviated, time: .shortened))
                    
                    if let lastSyncEnded = lastSyncRun.ended {
                        Text("Ended").badge(lastSyncEnded.formatted(date: .abbreviated, time: .shortened))
                        Text("Duration").badge(durationFormatter.string(from: lastSyncEnded.timeIntervalSince(lastSyncRun.started)))
                    }
                }
                else {
                    Text("Started").badge("Never")
                }
            }
            
            let backgroundSyncs = appState.backgroundSyncRuns
            if !backgroundSyncs.isEmpty {
                Section("During the last 24 hours") {
                    ForEach(backgroundSyncs, id: \.started) { (log: BackgroundSyncRun) in
                        Text(log.asString)
                    }
                }
            }
            
            Section {
                Text("Uptime").badge(durationFormatter.string(from: Date.now.timeIntervalSince(appState.launchedAt)))
            }
        }
        .task {
            updateNotificationStatus()
        }
        .onDisappear {
                Task.detached {
                    _ = await self.appState.backgroundManager.scheduleBackgroundSync()
                    await self.appState.backgroundManager.rescheduleWatchdogNotification()
                }
        }
        .navigationTitle("Background synchronization")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $alertShown, content: {
            Alert(title: Text("Background synchronization"), message: Text(alertMessage))
        })
    }
    
    private func updateNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            self.authorizationStatus = settings.authorizationStatus
        }
    }
}
#endif

fileprivate struct BandwidthSettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Limit file transfer bandwidth") {
                // Global down
                Toggle("Limit receiving bandwidth", isOn: Binding(get: {
                    return appState.client.getBandwidthLimitDownMbitsPerSec() > 0
                }, set: { nv in
                    if nv {
                        try! appState.client.setBandwidthLimitsMbitsPerSec(10, up: appState.client.getBandwidthLimitUpMbitsPerSec())
                    }
                    else {
                        try! appState.client.setBandwidthLimitsMbitsPerSec(0, up: appState.client.getBandwidthLimitUpMbitsPerSec())
                    }
                }))
                
                if appState.client.getBandwidthLimitDownMbitsPerSec() > 0 {
                    Stepper("\(appState.client.getBandwidthLimitDownMbitsPerSec()) Mbit/s", value: Binding(get: {
                        return appState.client.getBandwidthLimitDownMbitsPerSec()
                    }, set: { nv in
                        try! appState.client.setBandwidthLimitsMbitsPerSec(nv, up: appState.client.getBandwidthLimitUpMbitsPerSec())
                    }), in: 1...100)
                }
                
                // Global up
                Toggle("Limit sending bandwidth", isOn: Binding(get: {
                    return appState.client.getBandwidthLimitUpMbitsPerSec() > 0
                }, set: { nv in
                    if nv {
                        try! appState.client.setBandwidthLimitsMbitsPerSec(appState.client.getBandwidthLimitDownMbitsPerSec(), up: 10)
                    }
                    else {
                        try! appState.client.setBandwidthLimitsMbitsPerSec(appState.client.getBandwidthLimitDownMbitsPerSec(), up: 0)
                    }
                }))
                
                if appState.client.getBandwidthLimitUpMbitsPerSec() > 0 {
                    Stepper("\(appState.client.getBandwidthLimitUpMbitsPerSec()) Mbit/s", value: Binding(get: {
                        return appState.client.getBandwidthLimitUpMbitsPerSec()
                    }, set: { nv in
                        try! appState.client.setBandwidthLimitsMbitsPerSec(appState.client.getBandwidthLimitDownMbitsPerSec(), up: nv)
                    }), in: 1...100)
                }
                
                // LAN bandwidth limit
                if appState.client.getBandwidthLimitUpMbitsPerSec() > 0 || appState.client.getBandwidthLimitDownMbitsPerSec() > 0 {
                    Toggle("Also limit in local networks", isOn: Binding(get: {
                        return appState.client.isBandwidthLimitedInLAN()
                    }, set: {nv in
                        try? appState.client.setBandwidthLimitedInLAN(nv)
                    }))
                }
            }
            
            Section("Limit streaming") {
                Toggle("Limit streaming bandwidth", isOn: Binding(get: {
                    appState.streamingLimitMbitsPerSec > 0
                }, set: { nv in
                    if nv {
                        appState.streamingLimitMbitsPerSec = 15
                    }
                    else {
                        appState.streamingLimitMbitsPerSec = 0
                    }
                }))
                
                if appState.streamingLimitMbitsPerSec > 0 {
                    Stepper("\(appState.streamingLimitMbitsPerSec) Mbit/s", value: appState.$streamingLimitMbitsPerSec, in: 1...100)
                }
            }
        }.navigationTitle("Bandwidth limitations")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
                
    var limitsEnabled: Bool {
        return self.appState.streamingLimitMbitsPerSec > 0
            || self.appState.client.getBandwidthLimitUpMbitsPerSec() > 0
            || self.appState.client.getBandwidthLimitDownMbitsPerSec() > 0
    }
    
    var body: some View {
        Form {
            Section("Device name") {
                TextField("hostname", text: Binding(get: {
                    var err: NSError? = nil
                    return appState.client.getName(&err)
                }, set: { nn in
                    try? appState.client.setName(nn)
                }))
            }
            
            Section {
                NavigationLink(destination: BandwidthSettingsView(appState: appState)) {
                    Text("Bandwidth limitations").badge(limitsEnabled  ? "On": "Off")
                }
           
#if os(iOS)
                NavigationLink(destination: BackgroundSettingsView(appState: appState)) {
                    Text("Background synchronization").badge(appState.longBackgroundSyncEnabled || appState.shortBackgroundSyncEnabled ? "On": "Off")
                }
#endif
          
                NavigationLink(destination: PhotoSettingsView(appState: appState, photoSync: appState.photoSync)) {
                    Text("Photo synchronization").badge(appState.photoSync.isReady && appState.photoSync.enableBackgroundCopy ? "On" : "")
                }
           
                NavigationLink("Advanced settings") {
                    AdvancedSettingsView(appState: appState)
                }
            }
             
            Section {
                NavigationLink("Statistics") {
                    TotalStatisticsView(appState: appState)
                }
            }
             
            Section {
                NavigationLink("About this app") {
                    AboutView()
                }
            }
        }.navigationTitle("Settings")
    }
}
