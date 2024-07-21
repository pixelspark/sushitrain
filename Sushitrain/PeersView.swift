// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct PeersView: View {
    @ObservedObject var appState: SushitrainAppState
    @State var showingAddDevicePopup = false
    
    var peers: [SushitrainPeer] {
        get {
            return appState.peers().filter({x in !x.isSelf()}).sorted()
        }
    }
    
    var body: some View {
        ZStack {
            NavigationStack {
                List {
                    Section("Associated devices") {
                        ForEach(self.peers) {
                            key in NavigationLink(destination: PeerView(peer: key, appState: appState)) {
                                Label(key.name().isEmpty ? key.deviceID() : key.name(), systemImage: key.isConnected() ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                            }
                        }
                        .onDelete(perform: { indexSet in
                            let peers = self.peers
                            indexSet.map { idx in
                                return peers[idx]
                            }.forEach { peer in try? peer.remove() }
                        })
                    }
                    
                    // Discovered peers
                    let peers = self.appState.peerIDs()
                    let relevantDevices = Array(appState.discoveredDevices.keys).filter({ d in
                        !peers.contains(d)
                    })
                    
                    if !relevantDevices.isEmpty {
                        Section("Discovered devices") {
                            ForEach(relevantDevices, id: \.self) { devID in
                                Label(devID, systemImage: "plus").onTapGesture {
                                    try! appState.client.addPeer(devID)
                                }
                            }
                        }
                    }
                    
                    // Add peer manually
                    Section {
                        Button("Add other device...", systemImage: "plus", action: {
                            showingAddDevicePopup = true
                        })
                    }
                }
                
                .navigationTitle("Devices")
                .toolbar {
                    EditButton()
                }
                
            }
        }
        .sheet(isPresented: $showingAddDevicePopup, content: {
            AddDeviceView(appState: appState)
        })
    }
}
