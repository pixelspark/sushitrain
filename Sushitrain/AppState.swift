// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct StreamingProgress: Hashable, Equatable {
    var folder: String
    var path: String
    var bytesSent: Int64
    var bytesTotal: Int64
}

import Combine

@MainActor class AppState: ObservableObject {
    var client: SushitrainClient
    @Published var alertMessage: String = ""
    @Published var alertShown: Bool = false
    @Published var localDeviceID: String = ""
    @Published var lastEvent: String = ""
    @Published var eventCounter: Int = 0
    @Published var discoveredDevices: [String: [String]] = [:]
    @Published var listenAddresses = Set<String>()
    @Published var launchedAt = Date.now
    @Published var streamingProgress: StreamingProgress? = nil
    @Published var lastChanges: [SushitrainChange] = []
    
    @AppStorage("backgroundSyncRuns") var backgroundSyncRuns: [BackgroundSyncRun] = []
    @AppStorage("lastBackgroundSyncRun") var lastBackgroundSyncRun = OptionalObject<BackgroundSyncRun>()
    @AppStorage("backgroundSyncEnabled") var longBackgroundSyncEnabled: Bool = true
    @AppStorage("shortBackgroundSyncEnabled") var shortBackgroundSyncEnabled: Bool = false
    @AppStorage("notifyWhenBackgroundSyncCompletes") var notifyWhenBackgroundSyncCompletes: Bool = false
    @AppStorage("watchdogNotificationEnabled") var watchdogNotificationEnabled: Bool = false
    @AppStorage("watchdogIntervalHours") var watchdogIntervalHours: Int = 2 * 24 // 2 days
    @AppStorage("streamingLimitMbitsPerSec") var streamingLimitMbitsPerSec: Int = 0
    @AppStorage("maxBytesForPreview") var maxBytesForPreview: Int = 2 * 1024 * 1024 // 2 MiB
    @AppStorage("browserViewStyle") var browserViewStyle: BrowserViewStyle = .list
    @AppStorage("browserGridColumns") var browserGridColumns: Int = 3
    
    var photoSync = PhotoSynchronisation()
    
#if os(iOS)
    var backgroundManager: BackgroundManager!
#endif
    
    static let maxChanges = 25
    
    init(client: SushitrainClient) {
        self.client = client;
#if os(iOS)
        self.backgroundManager = BackgroundManager(appState: self)
#endif
    }
    
    func applySettings() {
        self.client.server?.maxMbitsPerSecondsStreaming = Int64(self.streamingLimitMbitsPerSec)
        print("Apply settings; mbits/s streaming=", self.streamingLimitMbitsPerSec, "\n")
    }
    
    var isFinished: Bool {
        return !self.client.isDownloading() && !self.client.isUploading() && !self.photoSync.isSynchronizing
    }
    
    @MainActor
    func alert(message: String) {
        self.alertShown = true;
        self.alertMessage = message;
    }
    
    @MainActor
    func update() {
        let devID = self.client.deviceID()
        DispatchQueue.main.async {
            self.localDeviceID = devID
        }
    }
    
    func folders() -> [SushitrainFolder] {
        let folderIDs = self.client.folders()!.asArray()
        var folderInfos: [SushitrainFolder] = []
        for fid in folderIDs {
            let folderInfo = self.client.folder(withID: fid)!
            folderInfos.append(folderInfo)
        }
        return folderInfos
    }
    
    @MainActor
    func peerIDs() -> [String] {
        return self.client.peers()!.asArray()
    }
    
    @MainActor
    func peers() -> [SushitrainPeer] {
        let peerIDs = self.client.peers()!.asArray()
        
        var peers: [SushitrainPeer] = []
        for peerID in peerIDs {
            let peerInfo = self.client.peer(withID: peerID)!
            peers.append(peerInfo)
        }
        return peers
    }
    
    func updateBadge() {
#if os(iOS)
        var numExtra = 0
        for folder in self.folders() {
            if folder.isIdle {
                var hasExtra: ObjCBool = false
                let _ = try? folder.hasExtraneousFiles(&hasExtra)
                if hasExtra.boolValue {
                    numExtra += 1
                }
            }
        }
        let numExtraFinal = numExtra
        
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(numExtraFinal)
        }
#endif
        //! TODO: set Dock badge count on macOS
    }
    
    var systemImage: String {
        let isDownloading = self.client.isDownloading()
        let isUploading = self.client.isUploading()
        if isDownloading && isUploading {
            return "arrow.up.arrow.down.circle.fill"
        }
        else if isDownloading {
            return "arrow.down.circle.fill"
        }
        else if isUploading {
            return "arrow.up.circle.fill"
        }
        else if self.client.connectedPeerCount() > 0 {
            return "checkmark.circle.fill"
        }
        return "network.slash"
    }
    
    static func requestNotificationPermissionIfNecessary() {
#if os(iOS)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                let options: UNAuthorizationOptions = [.alert, .badge, .provisional]
                UNUserNotificationCenter.current().requestAuthorization(options: options) {
                    (status, error) in
                    print("Notifications requested: \(status) \(error?.localizedDescription ?? "")")
                }
            }
        }
#endif
    }
}
