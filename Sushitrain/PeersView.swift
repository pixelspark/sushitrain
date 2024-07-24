// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct PeersView: View {
    @ObservedObject var appState: AppState
    @State var showingAddDevicePopup = false
    @State var addingDeviceID: String = ""
    
    var body: some View {
        let peers = appState.peers().filter({x in !x.isSelf()}).sorted();
        ZStack {
            NavigationStack {
                List {
                    Section("Associated devices") {
                        if peers.isEmpty {
                            ContentUnavailableView("No devices added yet", systemImage: "externaldrive.badge.questionmark", description: Text("To synchronize files, first add a remote device. Either select a device from the list below, or add manually using the device ID."))
                        }
                        else {
                            ForEach(peers) {
                                key in NavigationLink(destination: PeerView(peer: key, appState: appState)) {
                                    Label(key.name().isEmpty ? key.deviceID() : key.name(), systemImage: key.isConnected() ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                                }
                            }
                            .onDelete(perform: { indexSet in
                                indexSet.map { idx in
                                    return peers[idx]
                                }.forEach { peer in try? peer.remove() }
                            })
                        }
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
                                    addingDeviceID = devID
                                    showingAddDevicePopup = true
                                }
                            }
                        }
                    }
                    
                    // Add peer manually
                    Section {
                        Button("Add other device...", systemImage: "plus", action: {
                            addingDeviceID = ""
                            showingAddDevicePopup = true
                        })
                    }
                }
                
                .navigationTitle("Devices")
                .toolbar {
                    if !peers.isEmpty {
                        EditButton()
                    }
                }
                
            }
        }
        .sheet(isPresented: $showingAddDevicePopup) {
            AddDeviceView(appState: appState, suggestedDeviceID: $addingDeviceID)
        }
    }
}
