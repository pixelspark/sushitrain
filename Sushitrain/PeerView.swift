// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct PeerView: View {
    var peer: SushitrainPeer
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            if self.peer.exists() {
                Section {
                    if peer.isConnected() {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    else {
                        Label("Not connected", systemImage: "xmark.circle")
                        if let lastSeen = peer.lastSeen(), !lastSeen.isZero() {
                            Text("Last seen").badge(Text(lastSeen.date().formatted()))
                        }
                    }
                }
                
                LabeledContent {
                    TextField(peer.displayName, text: Binding(get: { peer.name() }, set: {lbl in try? peer.setName(lbl) }))
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("Display name")
                }
                
                Section {
                    Toggle("Enabled", isOn: Binding(get: { !peer.isPaused() }, set: {active in try? peer.setPaused(!active) }))
                } footer: {
                    Text("If a device is not enabled, synchronization with this device is paused.")
                }
                
                Section {
                    Toggle("Trusted", isOn: Binding(get: { !peer.isUntrusted() }, set: {trusted in try? peer.setUntrusted(!trusted) }))
                } footer: {
                    Text("If a device is not trusted, an encryption password is required for each folder synchronized with the device.")
                }
                
                Section("Device ID") {
                    Label(peer.deviceID(), systemImage: "qrcode").contextMenu {
                        Button(action: {
                            UIPasteboard.general.string = peer.deviceID()
                        }) {
                            Text("Copy to clipboard")
                            Image(systemName: "doc.on.doc")
                        }
                    }.monospaced()
                }
                
                let sharedFolderIDs = peer.sharedFolderIDs()?.asArray().sorted() ?? []
                if !sharedFolderIDs.isEmpty {
                    Section("Shared folders") {
                        ForEach(sharedFolderIDs, id: \.self) { fid in
                            if let folder = self.appState.client.folder(withID: fid), let completion = try? folder.completion(forDevice: peer.deviceID()) {
                                Label(folder.displayName, systemImage: "folder").badge(Text("\(Int(completion.completionPct))%"))
                            }
                            else {
                                Label(fid, systemImage: "folder")
                            }
                        }
                    }
                }
                
                let lastAddress = self.appState.client.getLastPeerAddress(self.peer.deviceID())
                if !lastAddress.isEmpty {
                    Section("Addresses") {
                        Label(lastAddress, systemImage: "network").contextMenu {
                            Button(action: {
                                UIPasteboard.general.string = lastAddress
                            }) {
                                Text("Copy to clipboard")
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                }
                
                Section {
                    Button("Unlink device", systemImage: "trash", role:.destructive, action: {
                        try? peer.remove()
                        dismiss()
                    }).foregroundColor(.red)
                }
            }
        }.navigationTitle(!peer.exists() || peer.name().isEmpty ? peer.deviceID() : peer.name())
    }
}
