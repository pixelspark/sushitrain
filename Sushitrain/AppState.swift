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

@MainActor class AppState: ObservableObject, @unchecked Sendable {
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
    var photoSync = PhotoSynchronisation()
    
    static let maxChanges = 25
    
    @AppStorage("streamingLimitMbitsPerSec") var streamingLimitMbitsPerSec = 0
    @AppStorage("maxBytesForPreview") var maxBytesForPreview = 2 * 1024 * 1024 // 2 MiB
    
    init(client: SushitrainClient) {
        self.client = client;
    }
    
    func applySettings() {
        self.client.server?.maxMbitsPerSecondsStreaming = Int64(self.streamingLimitMbitsPerSec)
        print("Apply settings; mbits/s streaming=", self.streamingLimitMbitsPerSec, "\n")
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
    }
}
