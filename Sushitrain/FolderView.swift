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
    
    var possiblePeers: [String: SushitrainPeer] {
        get {
            let peers = appState.peers().filter({d in !d.isSelf()})
            var dict: [String: SushitrainPeer] = [:]
            for peer in peers {
                dict[peer.deviceID()] = peer
            }
            return dict
        }
    }
    
    var body: some View {
        Form {
            let formatter = ByteCountFormatter()
            if let stats = try? self.folder.statistics() {
                Section("Full folder") {
                    // Use .formatted() here because zero is hidden in badges and that looks weird
                    Text("Number of files").badge(stats.global!.files.formatted())
                    Text("Number of directories").badge(stats.global!.directories.formatted())
                    Text("File size").badge(formatter.string(fromByteCount: stats.global!.bytes))
                }
                
                let totalWant = Double(stats.localNeed!.bytes)
                let myCompletion = Int(totalWant > 0 ? (100.0 * Double(stats.local!.bytes) / totalWant) : 100)
                
                Section {
                    Text("Number of files").badge(stats.local!.files.formatted())
                    Text("Number of directories").badge(stats.local!.directories.formatted())
                    Text("File size").badge(formatter.string(fromByteCount: stats.local!.bytes))
                } header: {
                    Text("On this device: \(myCompletion)%")
                }
                
                let devices = self.folder.sharedWithDeviceIDs()?.asArray() ?? []
                let peers = self.possiblePeers
                
                if !devices.isEmpty {
                    Section {
                        ForEach(devices, id: \.self) { deviceID in
                            if let completion = try? self.folder.completion(forDevice: deviceID) {
                                if let device = peers[deviceID] {
                                    Label(device.name(), systemImage: "externaldrive").badge(Text("\(Int(completion.completionPct))%"))
                                }
                            }
                        }
                    }
                header: {
                    Text("Other devices")
                }
                    footer : {
                        Text("The percentage of the full folder's size that each device stores locally.")
                    }
                }
            }
        }
#if os(macOS)
        .formStyle(.grouped)
#endif
        .navigationTitle("Folder statistics")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
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
        Group {
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
                                    if let file = try? folder.getFileInformation(item) {
                                        NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState)) {
                                            Label(item, systemImage: file.systemImage)
                                        }
                                    }
                                    else {
                                        Label(item, systemImage: "pin")
                                    }
                                }
                            }.onDelete { pathIndexes in
                                let paths = pathIndexes.map({idx in selectedPaths[idx]})
                                paths.forEach { path in
                                    if let file = try? folder.getFileInformation(path) {
                                        try? file.setExplicitlySelected(false)
                                    }
                                }
                                selectedPaths.remove(atOffsets: pathIndexes)
                            }.disabled(!folder.isIdleOrSyncing)
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
#if os(macOS)
                .formStyle(.grouped)
#endif
            }
            else {
                ContentUnavailableView("No files selected", systemImage: "pin.slash.fill", description: Text("To keep files on this device, navigate to a file and select 'keep on this device'. Selected files will appear here."))
            }
        }
        .navigationTitle("Selected files")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
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
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .monospaced()
                        .focused($passwordFieldFocus)
                }
            }
#if os(macOS)
            .formStyle(.grouped)
#endif
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
                    if !folder.isSelective() {
                        if let statistics = try? folder.statistics(), statistics.global!.bytes > 0 {
                            let formatter = ByteCountFormatter()
                            let globalBytes = statistics.global!.bytes;
                            let localBytes = statistics.local!.bytes;
                            let remainingText = formatter.string(fromByteCount: (globalBytes - localBytes));
                            ProgressView(value: Double(localBytes) / Double(globalBytes), total: 1.0) {
                                Label("Synchronizing...", systemImage: "bolt.horizontal.circle")
                                    .foregroundStyle(.orange)
                                    .badge(Text(remainingText))
                            }.tint(.orange)
                        }
                        else {
                            Label("Synchronizing...", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
                        }
                    }
                    else {
                        Label("Synchronizing...", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
                    }
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
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }
        }
    }
}

struct FolderSyncTypePicker: View {
    @ObservedObject var appState: AppState
    @State private var changeProhibited = true
    var folder: SushitrainFolder
    
    var body: some View {
        if folder.exists() {
            Picker("Selection", selection: Binding(get: { folder.isSelective() }, set: { s in try? folder.setSelective(s) })) {
                Text("All files").tag(false)
                Text("Selected files").tag(true)
            }
            .pickerStyle(.menu)
            .disabled(changeProhibited)
            .onAppear {
                // Only allow changes to selection mode when folder is idle
                if !folder.isIdleOrSyncing {
                    changeProhibited = true
                    return
                }
                
                // Prohibit change in selection mode when there are extraneous files
                var hasExtra: ObjCBool = false
                let _ = try! folder.hasExtraneousFiles(&hasExtra)
                changeProhibited = hasExtra.boolValue
            }
        }
    }
}


struct FolderDirectionPicker: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    @State private var changeProhibited: Bool = true
    
    var body: some View {
        if folder.exists() {
            Picker("Direction", selection: Binding(get: { folder.folderType() }, set: { s in try? folder.setFolderType(s) })) {
                Text("Send and receive").tag(SushitrainFolderTypeSendReceive)
                Text("Receive only").tag(SushitrainFolderTypeReceiveOnly)
            }
            .pickerStyle(.menu)
            .disabled(changeProhibited)
            .onAppear {
                // Only allow changes to selection mode when folder is idle
                if !folder.isIdleOrSyncing {
                    changeProhibited = true
                    return
                }
                
                // Prohibit change in selection mode when there are extraneous files
                var hasExtra: ObjCBool = false
                let _ = try! folder.hasExtraneousFiles(&hasExtra)
                changeProhibited = hasExtra.boolValue
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
    @State var showUnlinkConfirmation = false
    
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
                    
                    LabeledContent {
                        TextField("", text: Binding(get: { folder.label() }, set: {lbl in try? folder.setLabel(lbl) }), prompt: Text(folder.folderID))
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Display name")
                    }
                    
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
                
#if os(iOS)
                Section("System settings") {
                    Toggle("Include in device back-up", isOn: Binding(get: {
                        if let f = folder.isExcludedFromBackup { return !f }
                        return false
                    }, set: { nv in
                        folder.isExcludedFromBackup = !nv
                    }))
                    
                    Toggle("Hide in Files app", isOn: Binding(get: {
                        if let f = folder.isHidden { return f }
                        return false
                    }, set: { nv in
                        folder.isHidden = nv
                    }))
                }
#endif
                
                if self.folder.isSelective() {
                    NavigationLink(destination: SelectiveFolderView(appState: appState, folder: folder)) {
                        Label("Files kept on this device", systemImage: "pin")
                    }
                }
                
                
                #if os(macOS)
                // On iOS, this is in the folder popup menu instead
                Section {
                    NavigationLink(destination: FolderStatisticsView(appState: appState, folder: folder)) {
                        Label("Folder statistics", systemImage: "scalemass")
                    }
                }
                #endif
                
                Section {
                    Button("Re-scan folder", systemImage: "sparkle.magnifyingglass") {
                        do {
                            try folder.rescan()
                        }
                        catch let error {
                            showError = true
                            errorText = error.localizedDescription
                        }
                    }
                    
                    Button("Unlink folder", systemImage: "folder.badge.minus", role:.destructive) {
                        showUnlinkConfirmation = true
                    }
                    .foregroundColor(.red)
                    .confirmationDialog("Are you sure you want to unlink this folder? The folder will not be synchronized any longer. Files currently on this device will not be deleted.", isPresented: $showUnlinkConfirmation, titleVisibility: .visible) {
                        Button("Unlink the folder", role: .destructive) {
                            do {
                                dismiss()
                                try folder.unlink()
                            }
                            catch let error {
                                showError = true
                                errorText = error.localizedDescription
                            }
                        }
                    }
 
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
#if os(macOS)
        .formStyle(.grouped)
#endif
        .navigationTitle(folder.displayName)
        .sheet(isPresented: $showEditEncryptionPassword) {
            FolderDeviceView(appState: self.appState, folder: self.folder, deviceID: $editEncryptionPasswordDeviceID)
        }
        .alert(isPresented: $showError, content: {
            Alert(title: Text("An error occured"), message: Text(errorText), dismissButton: .default(Text("OK")))
        })
    }
}
