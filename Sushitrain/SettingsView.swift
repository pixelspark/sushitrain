import Foundation
import SwiftUI
import SushitrainCore

struct TotalStatisticsView: View {
    @ObservedObject var appState: SushitrainAppState
    
    init(appState: SushitrainAppState) {
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
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var appState: SushitrainAppState
    
    var body: some View {
        Form {
            Section("Connectivity") {
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
        }.navigationTitle("Advanced settings")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct BackgroundSettingsView: View {
    @ObservedObject var appState: SushitrainAppState
    let durationFormatter = DateComponentsFormatter()
    @State private var alertShown = false
    @State private var alertMessage = ""
    @AppStorage("backgroundSyncEnabled") var backgroundSyncEnabled = false
    
    init(appState: SushitrainAppState) {
        self.appState = appState
        durationFormatter.allowedUnits = [.day, .hour, .minute]
        durationFormatter.unitsStyle = .abbreviated
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Background synchronization enabled", isOn: $backgroundSyncEnabled)
            }
            
            Section("Last background synchronization") {
                if let lastSyncStarted = UserDefaults.standard.value(forKey: "lastBackgroundSyncStart") as? Date {
                    Text("Started").badge(lastSyncStarted.formatted(date: .abbreviated, time: .shortened))
                }
                else {
                    Text("Started").badge("Never")
                }
                
                if let lastSyncEnded = UserDefaults.standard.value(forKey: "lastBackgroundSyncEnd") as? Date {
                    Text("Ended").badge(lastSyncEnded.formatted(date: .abbreviated, time: .shortened))
                }
                
                if let lastSyncStarted = UserDefaults.standard.value(forKey: "lastBackgroundSyncStart") as? Date,
                   let lastSyncEnded = UserDefaults.standard.value(forKey: "lastBackgroundSyncEnd") as? Date {
                    Text("Duration").badge(durationFormatter.string(from: lastSyncEnded.timeIntervalSince(lastSyncStarted)))
                }
            }
            
            let backgroundSyncs = (UserDefaults.standard.value(forKey: "backgroundRuns") as? [BackgroundSyncRun]) ?? []
            if !backgroundSyncs.isEmpty {
                Section("During the last 24 hours") {
                    ForEach(backgroundSyncs, id: \.started) { (log: BackgroundSyncRun) in
                        Text(log.asString)
                    }
                }
            }
                
            Button("Request background synchronization") {
                if SushitrainApp.scheduleBackgroundSync() {
                    alertShown = true
                    alertMessage = String(localized: "Background synchronization has been requested. The system will typically allow background synchronization to occur overnight, when the device is not used and charging.")
                }
                else {
                    alertShown = true
                    alertMessage = String(localized: "Background synchronization could not be scheduled. Please verify whether background processing is enabled for this app.")
                }
            }
            
            Section {
                Text("Uptime").badge(durationFormatter.string(from: Date.now.timeIntervalSince(appState.launchedAt)))
            }
        }.navigationTitle("Background synchronization")
            .navigationBarTitleDisplayMode(.inline)
            .alert(isPresented: $alertShown, content: {
                Alert(title: Text("Background synchronization"), message: Text(alertMessage))
            })
    }
}

struct SettingsView: View {
    @ObservedObject var appState: SushitrainAppState
    
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
            
            NavigationLink("Background synchronization") {
                BackgroundSettingsView(appState: appState)
            }
            
            NavigationLink("Advanced settings") {
                AdvancedSettingsView(appState: appState)
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
