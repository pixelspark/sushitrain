// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct FolderStatisticsView: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    
    init(appState: AppState, folder: SushitrainFolder) {
        self.appState = appState
        self.folder = folder
    }
    
    var body: some View {
        let formatter = ByteCountFormatter()
        let stats: SushitrainFolderStats? = try? self.folder.statistics()
        
        Form {
            if let stats = stats {
                Section("All devices") {
                    Text("Number of files").badge(stats.global!.files)
                    Text("Number of directories").badge(stats.global!.directories)
                    Text("File size").badge(formatter.string(fromByteCount: stats.global!.bytes))
                }
                
                Section("This device") {
                    Text("Number of files").badge(stats.local!.files)
                    Text("Number of directories").badge(stats.local!.directories)
                    Text("File size").badge(formatter.string(fromByteCount: stats.local!.bytes))
                }
            }
        }.navigationTitle("Folder statistics")
    }
}

struct SelectiveFolderView: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    @State private var showError = false
    @State private var errorText = ""
    @State private var searchString = ""
    @State private var isLoading = true
    @State private var selectedPaths: [String] = []
    
    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
            }
            else if !selectedPaths.isEmpty {
                Form {
                    let st = searchString.lowercased()
                    Section("Files kept on device") {
                        List {
                            ForEach(selectedPaths, id: \.self) { item in
                                if st.isEmpty || item.lowercased().contains(st) {
                                    Label(item, systemImage: "pin")
                                }
                            }.onDelete { pathIndexes in
                                let paths = pathIndexes.map({idx in selectedPaths[idx]})
                                paths.forEach { path in
                                    if let file = try? folder.getFileInformation(path) {
                                        try? file.setExplicitlySelected(false)
                                    }
                                }
                                selectedPaths.remove(atOffsets: pathIndexes)
                            }.disabled(!folder.isIdle)
                        }
                    }
                    
                    if st.isEmpty {
                        Section {
                            Button("Free up space", systemImage: "pin.slash", action: {
                                do {
                                    try folder.clearSelection()
                                    self.selectedPaths.removeAll()
                                }
                                catch let error {
                                    showError = true
                                    errorText = error.localizedDescription
                                }
                            })
                        }
                    }
                }
            }
            else {
                ContentUnavailableView("No files selected", systemImage: "pin.slash.fill", description: Text("To keep files on this device, navigate to a file and select 'keep on this device'. Selected files will appear here."))
            }
        }
        .navigationTitle("Selected files")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchString, prompt: "Search files by name...")
            .task {
                self.isLoading = true
                self.selectedPaths = try! self.folder.selectedPaths().asArray().sorted()
                self.isLoading = false
            }
    }
}

struct FolderDeviceView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var folder: SushitrainFolder
    @Binding var deviceID: String
    @State var newPassword: String = ""
    @FocusState private var passwordFieldFocus: Bool
    @State private var error: String? = nil
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Share with device") {
                    Text(deviceID).monospaced()
                }
                
                Section("Encryption password") {
                    TextField("Password", text: $newPassword)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .monospaced()
                        .focused($passwordFieldFocus)
                }
            }
            .onAppear {
                self.newPassword = folder.encryptionPassword(for: deviceID)
                passwordFieldFocus = true
            }
            .navigationTitle("Share folder")
            .toolbar(content: {
                ToolbarItem(placement: .confirmationAction, content: {
                    Button("Save") {
                        do {
                            try folder.share(withDevice: self.deviceID, toggle: true, encryptionPassword: newPassword)
                            dismiss()
                        }
                        catch let error {
                            self.error = error.localizedDescription
                        }
                    }
                })
                ToolbarItem(placement: .cancellationAction, content: {
                    Button("Cancel") {
                        dismiss()
                    }
                })
            })
        }
        .alert(isPresented: Binding(get: { self.error != nil }, set: {nv in self.error = nv ? self.error : nil })) {
            Alert(title: Text("Could not set encryption key"), message: Text(self.error!))
        }
    }
}

struct FolderStatusView: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    
    var isAvailable: Bool {
        get {
            return self.folder.connectedPeerCount() > 0
        }
    }
    
    var peerStatusText: String {
        get {
            if self.folder.exists() {
                return "\(folder.connectedPeerCount())/\(folder.sharedWithDeviceIDs()!.count()-1)"
            }
            return ""
        }
    }
    
    var body: some View {
        var error: NSError? = nil
        let status = folder.state(&error)
        
        if !self.folder.exists() {
            Section {
                Label("Folder does not exist", systemImage: "trash").foregroundColor(.gray)
            }
        }
        else if !self.folder.isPaused() {
            Section {
                if !isAvailable {
                    Label("Not connected", systemImage: "network.slash").badge(Text(peerStatusText)).foregroundColor(.gray)
                }
                
                // Sync status (in case non-selective or selective with selected files
                else if status == "idle" {
                    if !folder.isSelective() {
                        Label("Synchronized", systemImage: "checkmark.circle.fill").foregroundStyle(.green).badge(Text(peerStatusText))
                    }
                    else {
                        if self.isAvailable {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).badge(Text(peerStatusText))
                        }
                        else {
                            Label("Unavailable", systemImage: "xmark.circle").badge(Text(peerStatusText))
                        }
                    }
                }
                else if status == "syncing" {
                    Label("Synchronizing...", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
                }
                else if status == "scanning" {
                    Label("Scanning...", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
                }
                else if status == "sync-preparing" {
                    Label("Preparing to synchronize...", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
                }
                else if status == "cleaning" {
                    Label("Cleaning up...", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
                }
                else if status == "sync-waiting" {
                    Label("Waiting to synchronize...", systemImage: "ellipsis.circle").foregroundStyle(.gray)
                }
                else if status == "scan-waiting" {
                    Label("Waiting to scan...", systemImage: "ellipsis.circle").foregroundStyle(.gray)
                }
                else if status == "clean-waiting" {
                    Label("Waiting to clean...", systemImage: "ellipsis.circle").foregroundStyle(.gray)
                }
                else if status == "error" {
                    Label("Error", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                else {
                    Label("Unknown state", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                
                if let error = error {
                    Text(error.localizedDescription)
                }
            }
        }
    }
}

struct FolderSyncTypePicker: View {
    @ObservedObject var appState: AppState
    @State private var hasExtraneousFiles = true
    var folder: SushitrainFolder
    
    var body: some View {
        if folder.exists() {
            Picker("Selection", selection: Binding(get: { folder.isSelective() }, set: { s in try? folder.setSelective(s) })) {
                Text("All files").tag(false)
                Text("Selected files").tag(true)
            }
            .pickerStyle(.menu)
            .disabled(hasExtraneousFiles)
            .onAppear {
                var hasExtra: ObjCBool = false
                let _ = try! folder.hasExtraneousFiles(&hasExtra)
                hasExtraneousFiles = hasExtra.boolValue
            }
        }
    }
}


struct FolderDirectionPicker: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    @State private var hasExtraneousFiles: Bool = true
    
    var body: some View {
        if folder.exists() {
            Picker("Direction", selection: Binding(get: { folder.folderType() }, set: { s in try? folder.setFolderType(s) })) {
                Text("Send and receive").tag(SushitrainFolderTypeSendReceive)
                Text("Receive only").tag(SushitrainFolderTypeReceiveOnly)
            }
                .pickerStyle(.menu)
                .disabled(hasExtraneousFiles)
                .onAppear {
                    var hasExtra: ObjCBool = false
                    let _ = try! folder.hasExtraneousFiles(&hasExtra)
                    hasExtraneousFiles = hasExtra.boolValue
                }
        }
    }
}


struct FolderView: View {
    var folder: SushitrainFolder
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State var showError = false
    @State var errorText = ""
    @State var editEncryptionPasswordDeviceID = ""
    @State var showEditEncryptionPassword = false
    @State var showRemoveConfirmation = false
    
    var possiblePeers: [SushitrainPeer] {
        get {
            return appState.peers().sorted().filter({d in !d.isSelf()})
        }
    }
    
    var body: some View {
        let sharedWith = folder.sharedWithDeviceIDs()?.asArray() ?? [];
        let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? [];
        
        Form {
            if folder.exists() {
                FolderStatusView(appState: appState, folder: folder)
                
                Section("Folder settings") {
                    Text("Folder ID").badge(Text(folder.folderID))
                    //                HStack {
                    //                    Text("Name")
                    //                    TextField("", text:Binding(get: { folder.label() }, set: {lbl in try? folder.setLabel(lbl) }))
                    //                }
                    
                    FolderDirectionPicker(appState: appState, folder: folder)
                    FolderSyncTypePicker(appState: appState, folder: folder)
                    
                    Toggle("Synchronize", isOn: Binding(get: { !folder.isPaused() }, set: {active in try? folder.setPaused(!active) }))
                }
                
                if !possiblePeers.isEmpty {
                    let pendingPeerIDs = Set((try? appState.client.devicesPendingFolder(self.folder.folderID))?.asArray() ?? [])
                    Section(header: Text("Shared with")) {
                        ForEach(self.possiblePeers, id: \.self) { (addr: SushitrainPeer) in
                            let isShared = sharedWith.contains(addr.deviceID());
                            let shared = Binding(get: { return isShared }, set: {share in
                                do {
                                    if share && addr.isUntrusted() {
                                        editEncryptionPasswordDeviceID = addr.deviceID()
                                        showEditEncryptionPassword = true
                                    }
                                    else {
                                        try folder.share(withDevice: addr.deviceID(), toggle: share, encryptionPassword: "")
                                    }
                                }
                                catch let error {
                                    print(error.localizedDescription)
                                }
                            });
                            HStack {
                                Toggle(addr.name(), systemImage: addr.isConnected() ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill", isOn: shared).bold(pendingPeerIDs.contains(addr.deviceID()))
                                Button("Encryption password", systemImage: sharedEncrypted.contains(addr.deviceID()) ? "lock" : "lock.open", action: {
                                    editEncryptionPasswordDeviceID = addr.deviceID()
                                    showEditEncryptionPassword = true
                                }).labelStyle(.iconOnly)
                            }
                        }
                    }
                }
                
                if self.folder.isSelective() {
                    NavigationLink("Files kept on this device") {
                        SelectiveFolderView(appState: appState, folder: folder)
                    }
                }
                
                NavigationLink("Folder statistics") {
                    FolderStatisticsView(appState: appState, folder: folder)
                }
                
                Section {
                    Button("Remove folder", systemImage: "trash", role:.destructive) {
                        showRemoveConfirmation = true
                    }
                    .foregroundColor(.red)
                    .confirmationDialog("Are you sure you want to remove this folder? Please consider carefully. All files in this folder will be removed from this device. Files that have not been synchronized to other devices yet cannot be recoered.", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                        Button("Remove the folder and all files", role: .destructive) {
                            do {
                                dismiss()
                                try folder.remove()
                            }
                            catch let error {
                                showError = true
                                errorText = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(folder.label().isEmpty ? folder.folderID : folder.label())
        .sheet(isPresented: $showEditEncryptionPassword) {
            FolderDeviceView(appState: self.appState, folder: self.folder, deviceID: $editEncryptionPasswordDeviceID)
        }
        .alert(isPresented: $showError, content: {
            Alert(title: Text("An error occured"), message: Text(errorText), dismissButton: .default(Text("OK")))
        })
    }
}
