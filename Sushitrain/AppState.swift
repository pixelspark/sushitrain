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
    @Published var resolvedListenAddresses = Set<String>()
    @Published var launchedAt = Date.now
    @Published var streamingProgress: StreamingProgress? = nil
    @Published var lastChanges: [SushitrainChange] = []
    @Published var isLogging: Bool = false
    
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
    @AppStorage("loggingEnabled") var loggingEnabled: Bool = false
    @AppStorage("dotFilesHidden") var dotFilesHidden: Bool = true
    @AppStorage("lingeringEnabled") var lingeringEnabled: Bool = true
    
    // The IDs of the peers that were suspended when the app last entered background, and should be re-enabled when the
    // app enters the foreground state.
    @AppStorage("suspendedPeerIds") private var suspendedPeerIds: [String] = []
    
    var photoSync = PhotoSynchronisation()
    
#if os(iOS)
    var backgroundManager: BackgroundManager!
    private var lingerManager: LingerManager!
#endif
    
    static let maxChanges = 25
    
    init(client: SushitrainClient) {
        self.client = client;
        #if os(iOS)
            self.backgroundManager = BackgroundManager(appState: self)
            self.lingerManager = LingerManager(appState: self)
        #endif
    }
    
    func applySettings() {
        self.client.server?.maxMbitsPerSecondsStreaming = Int64(self.streamingLimitMbitsPerSec)
        Log.info("Apply settings; streaming limit=\(self.streamingLimitMbitsPerSec) mbits/s")
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
    
    private func rebindServer() {
        Log.info("(Re-)activate streaming server")
        do {
            try self.client.server?.listen()
        } catch let error {
            Log.warn("Error activating streaming server: " + error.localizedDescription)
        }
    }
    
    func suspend(_ suspend: Bool) {
        do {
            if suspend {
                if !self.suspendedPeerIds.isEmpty {
                    Log.warn("Suspending, but there are still suspended peers, this should not happen (working around it anyway)")
                }
                let suspendedPeers = try self.client.suspendPeers()
                var suspendedIds = suspendedPeers.asArray()
                suspendedIds.append(contentsOf: self.suspendedPeerIds)
                self.suspendedPeerIds = suspendedIds
            }
            else {
                if self.suspendedPeerIds.isEmpty {
                    Log.info("No peers to unsuspend")
                }
                else {
                    Log.info("Requesting unsuspend of devices:" + self.suspendedPeerIds.debugDescription)
                    try self.client.unsuspend(SushitrainListOfStrings.from(self.suspendedPeerIds))
                    self.suspendedPeerIds = []
                }
            }
        }
        catch {
            Log.warn("Could not suspend \(suspend): \(error.localizedDescription)")
        }
    }
    
    func onScenePhaseChange(to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            #if os(iOS)
                if self.lingeringEnabled {
                    self.lingerManager.lingerThenSuspend()
                }
                else {
                     self.suspend(true)
                }
                try? self.client.setReconnectIntervalS(60)
                self.client.ignoreEvents = true
            #endif
            self.updateBadge()
            break

        case .inactive:
            self.updateBadge()
            #if os(iOS)
                self.client.ignoreEvents = true
            #endif
            break

        case .active:
            #if os(iOS)
                self.lingerManager.cancelLingering()
                try? self.client.setReconnectIntervalS(1)
                self.suspend(false)
                Task {
                    await self.backgroundManager.rescheduleWatchdogNotification()
                }
                self.rebindServer()
                self.client.ignoreEvents = false
            #endif
            break

        @unknown default:
            break
        }
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
                        Log.info("Notifications requested: \(status) \(error?.localizedDescription ?? "")")
                    }
                }
            }
        #endif
    }
}

#if os(iOS)
@MainActor
fileprivate class LingerManager {
    unowned var appState: AppState
    private var wantsSuspendAfterLinger = false
    private var lingerTask: UIBackgroundTaskIdentifier? = nil
    private var lingerTimer: Timer? = nil
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func cancelLingering() {
        Log.info("Cancel lingering")
        if let lt = self.lingerTask {
            UIApplication.shared.endBackgroundTask(lt)
        }
        self.lingerTask = nil
        self.lingerTimer?.invalidate()
        self.lingerTimer = nil
        self.wantsSuspendAfterLinger = false
    }

    func lingerThenSuspend() {
        Log.info("Linger then suspend")
        self.wantsSuspendAfterLinger = true
        if self.lingerTask == nil {
            self.lingerTask = UIApplication.shared.beginBackgroundTask(withName: "Short-term connection persistence", expirationHandler: {
                Log.info("Suspend after expiration of linger time")
                if self.wantsSuspendAfterLinger {
                    self.wantsSuspendAfterLinger = false
                    self.appState.suspend(true)
                }
                self.cancelLingering()
            })
            Log.info("Lingering before suspend: \(UIApplication.shared.backgroundTimeRemaining) remaining")
        }
        
        if self.lingerTimer?.isValid != true {
            // Try to stay awake for 3/4th of the estimated background time remaining, at most 29s
            // (at 30s the system appears to terminate)
            let lingerTime = min(29.0, UIApplication.shared.backgroundTimeRemaining * 3.0 / 4.0)
            if lingerTime < 1.0 {
                // Too short, just end lingering now
                Log.info("Lingering time allotted by the system is too short, suspending immediately")
                self.wantsSuspendAfterLinger = false
                self.appState.suspend(true)
                if let lt = self.lingerTask {
                    UIApplication.shared.endBackgroundTask(lt)
                }
                self.lingerTask = nil
            }
            else {
                Log.info("Start lingering timer for \(lingerTime)")
                self.lingerTimer = Timer.scheduledTimer(withTimeInterval: lingerTime, repeats: false) { _ in
                    DispatchQueue.main.async {
                        Log.info("Suspend after linger")
                        self.wantsSuspendAfterLinger = false
                        self.appState.suspend(true)
                        if let lt = self.lingerTask {
                            UIApplication.shared.endBackgroundTask(lt)
                        }
                        self.lingerTask = nil
                    }
                }
            }
        }
    }
}
#endif
