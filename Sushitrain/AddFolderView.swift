// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct AddFolderView: View {
    @Binding var folderID: String
    var shareWithPendingPeersByDefault: Bool = false
    
    @ObservedObject var appState: AppState
    
    @Environment(\.dismiss) private var dismiss
    @FocusState private var idFieldFocus: Bool
    
    @State var sharedWith = Set<String>()
    @State var showError = false
    @State var errorText = ""
    @State var folderPath: URL? = nil
    @State private var possiblePeers: [SushitrainPeer] = []
    @State private var pendingPeers: [String] = []
    
    @State private var showPathSelector: Bool = false
    @State private var showAddingExternalWarning: Bool = false
    @State private var isSelective = true
    
    var folderExists: Bool {
        get {
            appState.client.folder(withID: self.folderID) != nil
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Folder ID")) {
                    TextField("", text: $folderID, prompt: Text("XXXX-XXXX"))
                        .focused($idFieldFocus)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                        #endif
                }
                
                Section("Folder location") {
                    Button(action: {
                        self.folderPath = nil
                    }) {
                        Label("Create a new folder", systemImage: self.folderPath == nil ? "checkmark" : "")
                    }
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                    
                    Button(action: {
                        self.showPathSelector = true
                    }) {
                        if let u = self.folderPath {
                            Label("Existing folder: '\(u.lastPathComponent)'", systemImage: "checkmark").contextMenu {
                                Text(u.path(percentEncoded: false))
                            }
                        }
                        else {
                            Label("Select existing folder...", systemImage: "")
                        }
                    }
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                }
                
                if self.folderPath == nil {
                    Section {
                        Picker("Synchronize", selection: $isSelective) {
                            Text("All files").tag(false)
                            Text("Selected files").tag(true)
                        }
                    } footer: {
                        if isSelective {
                            Text("Only files that you select will be copied to this device. You can still access all files in the folder on demand when connected to other devices that have a copy of the file.")
                        }
                        else {
                            Text("All files in the folder will be copied to this device.")
                        }
                    }
                }
                
                if !possiblePeers.isEmpty {
                    Section(header: Text("Share with")) {
                        ForEach(self.possiblePeers, id: \.self.id) { (peer: SushitrainPeer) in
                            let isShared = sharedWith.contains(peer.deviceID());
                            let shared = Binding(get: { return isShared }, set: {share in
                                if share {
                                    sharedWith.insert(peer.deviceID())
                                }
                                else {
                                    sharedWith.remove(peer.deviceID())
                                }
                            });
                            
                            let isOffered = pendingPeers.contains(peer.deviceID())
                            Toggle(peer.displayName, systemImage: peer.systemImage, isOn: shared)
                                .bold(isOffered)
                                .foregroundStyle(isOffered ? .blue : .primary)
                                .disabled(peer.isUntrusted())
                        }
                        
                        Button("Select all devices offering this folder") {
                            sharedWith = Set(pendingPeers)
                        }
                        .disabled(pendingPeers.isEmpty)
                        #if os(macOS)
                            .buttonStyle(.link)
                        #endif
                    }
                }
            }
            #if os(macOS)
                .formStyle(.grouped)
            #endif
            .onAppear {
                idFieldFocus = true
            }
            .task {
                self.update()
            }
            .onChange(of: folderID, initial: false) { _, _ in
                self.update()
            }
            .toolbar(content: {
                ToolbarItem(placement: .confirmationAction, content: {
                    Button("Add folder") {
                        if self.folderPath != nil {
                            self.showAddingExternalWarning = true
                        }
                        else {
                            self.add()
                        }
                    }
                    .disabled(folderID.isEmpty || folderExists)
                    .alert(isPresented: $showAddingExternalWarning, content: {
                        Alert(
                            title: Text("Adding a folder from another app"),
                            message: Text("You are adding a folder that may be controlled by another app. This can cause issues, for instance when synchronization changes the app's files structure in an unsupported way. Are you sure you want to continue?"),
                            primaryButton: .destructive(Text("Continue")) {
                                self.add()
                            },
                            secondaryButton: .cancel(Text("Cancel"))
                        )
                    })
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
            .fileImporter(isPresented: $showPathSelector, allowedContentTypes: [.folder], onCompletion: { result in
                switch result {
                case .success(let url):
                    if appState.isInsideDocumentsFolder(url) {
                        // Check if the folder path is or is inside our regular folder path - that is not allowed
                        self.errorText = String(localized: "The folder you have selected is inside the app folder. Only folders outside the app folder can be selected.")
                        self.showError = true
                        self.folderPath = nil
                    }
                    else {
                        self.folderPath = url
                    }
                case .failure(let e):
                    Log.warn("Failed to select folder: \(e.localizedDescription)")
                    self.folderPath = nil
                }
            })
        }
    }
    
    private func update() {
        self.possiblePeers = appState.peers().sorted().filter({d in !d.isSelf()})
        self.pendingPeers = (try? appState.client.devicesPendingFolder(self.folderID))?.asArray() ?? []
        if self.shareWithPendingPeersByDefault && sharedWith.isEmpty {
            sharedWith = Set(pendingPeers)
        }
    }
    
    private func add() {
        do {
            // Add the folder
            if let fp = self.folderPath {
                try BookmarkManager.shared.saveBookmark(folderID: self.folderID, url: fp)
                try appState.client.addFolder(self.folderID, folderPath: fp.path(percentEncoded: false), createAsOnDemand: false)
            }
            else {
                try appState.client.addFolder(self.folderID, folderPath: "", createAsOnDemand: self.isSelective)
            }
            
            if let folder = appState.client.folder(withID: self.folderID) {
                // By default, exclude from backup
                folder.isExcludedFromBackup = true
                
                // Add peers
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
    }
}
