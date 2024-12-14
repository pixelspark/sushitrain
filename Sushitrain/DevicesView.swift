// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct DevicesView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddDevicePopup = false
    @State private var addingDeviceID: String = ""
    @State private var discoveredNewDevices: [String] = []
    
    fileprivate struct SelectedPeer: Hashable, Equatable {
        var peer: SushitrainPeer
        
        func hash(into hasher: inout Hasher) {
            self.peer.deviceID().hash(into: &hasher)
        }
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            return lhs.peer.deviceID() == rhs.peer.deviceID()
        }
    }
    
    var body: some View {
        let peers = appState.peers().filter({x in !x.isSelf()}).sorted();
        Group {
            List {
                Section("Associated devices") {
                    if peers.isEmpty {
                        HStack {
                            Spacer()
                            ContentUnavailableView("No devices added yet", systemImage: "externaldrive.badge.questionmark", description: Text("To synchronize files, first add a remote device. Either select a device from the list below, or add manually using the device ID."))
                            Spacer()
                        }
                    }
                    else {
                        ForEach(peers) { peer in
                            NavigationLink(destination: DeviceView(device: peer, appState: appState)) {
                                if peer.isPaused() {
                                    Label(peer.displayName, systemImage: "externaldrive.fill").foregroundStyle(.gray)
                                }
                                else {
                                    Label(peer.displayName, systemImage: peer.systemImage)
                                }
                            }
                        }
                        .onDelete(perform: { indexSet in
                            indexSet.map { idx in
                                return peers[idx]
                            }.forEach { peer in try? peer.remove() }
                        })
                    }
                }
                
                if !discoveredNewDevices.isEmpty {
                    Section("Discovered devices") {
                        ForEach(discoveredNewDevices, id: \.self) { devID in
                            Label(devID, systemImage: "plus").onTapGesture {
                                addingDeviceID = devID
                                showingAddDevicePopup = true
                            }
                        }
                    }
                }
                
                // Add peer manually
                Section {
                    Button("Add device...", systemImage: "plus", action: {
                        addingDeviceID = ""
                        showingAddDevicePopup = true
                    })
                    #if os(macOS)
                        .buttonStyle(.borderless)
                    #endif
                }
            }
            .navigationTitle("Devices")
            #if os(iOS)
                .toolbar {
                    if !peers.isEmpty {
                        EditButton()
                    }
                }
            #endif
        }
        .sheet(isPresented: $showingAddDevicePopup) {
            AddDeviceView(appState: appState, suggestedDeviceID: $addingDeviceID)
        }
        .task {
            self.update()
        }
        .onChange(of: appState.discoveredDevices) {
            self.update()
        }
    }
    
    private func update() {
        // Discovered peers
        let peers = self.appState.peerIDs()
        self.discoveredNewDevices = Array(appState.discoveredDevices.keys).filter({ d in
            !peers.contains(d)
        })
    }
}
