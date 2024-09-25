// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct DeviceView: View {
    var device: SushitrainPeer
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            if self.device.exists() {
                Section {
                    if device.isConnected() {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    else {
                        Label("Not connected", systemImage: "xmark.circle")
                        if let lastSeen = device.lastSeen(), !lastSeen.isZero() {
                            Text("Last seen").badge(Text(lastSeen.date().formatted()))
                        }
                    }
                }
                
                LabeledContent {
                    TextField(device.displayName, text: Binding(get: { device.name() }, set: {lbl in try? device.setName(lbl) }))
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("Display name")
                }
                
                Section {
                    Toggle("Enabled", isOn: Binding(get: { !device.isPaused() }, set: {active in try? device.setPaused(!active) }))
                } footer: {
                    Text("If a device is not enabled, synchronization with this device is paused.")
                }
                
                Section {
                    Toggle("Trusted", isOn: Binding(get: { !device.isUntrusted() }, set: {trusted in try? device.setUntrusted(!trusted) }))
                } footer: {
                    Text("If a device is not trusted, an encryption password is required for each folder synchronized with the device.")
                }
                
                Section("Device ID") {
                    Label(device.deviceID(), systemImage: "qrcode").contextMenu {
                        Button(action: {
                            UIPasteboard.general.string = device.deviceID()
                        }) {
                            Text("Copy to clipboard")
                            Image(systemName: "doc.on.doc")
                        }
                    }.monospaced()
                }
                
                let sharedFolderIDs = device.sharedFolderIDs()?.asArray().sorted() ?? []
                if !sharedFolderIDs.isEmpty {
                    Section("Shared folders") {
                        ForEach(sharedFolderIDs, id: \.self) { fid in
                            if let folder = self.appState.client.folder(withID: fid), let completion = try? folder.completion(forDevice: device.deviceID()) {
                                Label(folder.displayName, systemImage: "folder").badge(Text("\(Int(completion.completionPct))%"))
                            }
                            else {
                                Label(fid, systemImage: "folder")
                            }
                        }
                    }
                }
                
                let lastAddress = self.appState.client.getLastPeerAddress(self.device.deviceID())
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
                        try? device.remove()
                        dismiss()
                    }).foregroundColor(.red)
                }
            }
        }.navigationTitle(!device.exists() || device.name().isEmpty ? device.deviceID() : device.name())
    }
}