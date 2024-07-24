// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct AddFolderView: View {
    @State var folderID = ""
    @State var sharedWith = Set<String>()
    
    @Environment(\.dismiss) private var dismiss
    @FocusState private var idFieldFocus: Bool
    @ObservedObject var appState: AppState
    @State var showError = false
    @State var errorText = ""
    
    var possiblePeers: [SushitrainPeer] {
        get {
            return appState.peers().sorted().filter({d in !d.isSelf()})
        }
    }
    
    var folderExists: Bool {
        get {
            appState.client.folder(withID: self.folderID) != nil
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Folder ID")) {
                    TextField("XXXX-XXXX", text: $folderID).focused($idFieldFocus).textInputAutocapitalization(.never)
                }
                
                if !possiblePeers.isEmpty {
                    Section(header: Text("Shared with")) {
                        ForEach(self.possiblePeers, id: \.self) { (addr: SushitrainPeer) in
                            let isShared = sharedWith.contains(addr.deviceID());
                            let shared = Binding(get: { return isShared }, set: {share in
                                if share {
                                    sharedWith.insert(addr.deviceID())
                                }
                                else {
                                    sharedWith.remove(addr.deviceID())
                                }
                            });
                            Toggle(addr.label, systemImage: addr.isConnected() ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill", isOn: shared)
                        }
                    }
                }
            }
            .onAppear {
                idFieldFocus = true
            }
            .toolbar(content: {
                ToolbarItem(placement: .confirmationAction, content: {
                    Button("Add folder") {
                        do {
                            // Add the folder
                            try appState.client.addFolder(self.folderID);
                            
                            // Add peers
                            if let folder = appState.client.folder(withID: self.folderID) {
                                for devID in self.sharedWith {
                                    try folder.share(withDevice: devID, toggle: true, encryptionPassword: "")
                                }
                                dismiss()
                            }
                            else {
                                // Something went wrong creating the folder
                                showError = true
                                errorText = "Folder could not be added"
                            }
                        }
                        catch let error {
                            showError = true
                            errorText = error.localizedDescription
                        }
                    }.disabled(folderID.isEmpty || folderExists)
                })
                ToolbarItem(placement: .cancellationAction, content: {
                    Button("Cancel") {
                        dismiss()
                    }
                })
                
            })
            .navigationTitle("Add folder")
            .alert(isPresented: $showError, content: {
                Alert(title: Text("Could not add folder"), message: Text(errorText), dismissButton: .default(Text("OK")))
            })
        }
    }
}
