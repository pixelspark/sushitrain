// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct Offer: Hashable {
    var deviceID: String
    var folderID: String
}

struct StreamingProgress: Hashable, Equatable {
    var folder: String
    var path: String
    var bytesSent: Int64
    var bytesTotal: Int64
}

class SushitrainAppState: ObservableObject, @unchecked Sendable {
    var client: SushitrainClient
    @Published var alertMessage: String = ""
    @Published var alertShown: Bool = false
    @Published var localDeviceID: String = ""
    @Published var lastEvent: String = ""
    @Published var discoveredDevices: [String: [String]] = [:]
    @Published var folderOffers: [Offer] = []
    @Published var listenAddresses = Set<String>()
    @Published var launchedAt = Date.now
    @Published var streamingProgress: StreamingProgress? = nil
    @AppStorage("streamingLimitMbitsPerSec") var streamingLimitMbitsPerSec = 0
    
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
    
    @MainActor
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
}
