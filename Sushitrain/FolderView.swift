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
                
                let totalLocal = Double(stats.global!.bytes)
                let myPercentage = Int(totalLocal > 0 ? (100.0 * Double(stats.local!.bytes) / totalLocal) : 100)
                
                Section {
                    Text("Number of files").badge(stats.local!.files.formatted())
                    Text("Number of directories").badge(stats.local!.directories.formatted())
                    Text("File size").badge(formatter.string(fromByteCount: stats.local!.bytes))
                } header: {
                    Text("On this device: \(myPercentage)% of the full folder")
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
                        Text("Other devices progress")
                    }
                    footer : {
                        Text("The percentage of the files a device has synchronized, relative to the part of the folder it wants to synchronize. Because devices may ignore certain files or not synchronize any files at all, the percentage does not indicate the percentage of the full folder actually present on the device.")
                    }
                }
            }
        }
        #if os(macOS)
            .formStyle(.grouped)
            .navigationTitle("Folder statistics: '\(self.folder.displayName)'")
        #endif
        
        #if os(iOS)
            .navigationTitle("Folder statistics")
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

fileprivate struct ShareFolderWithDeviceDetailsView: View {
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
            .navigationTitle("Share folder '\(folder.displayName)'")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
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
            let isSelective = self.folder.isSelective()
            Section {
                if !isAvailable {
                    Label("Not connected", systemImage: "network.slash").badge(Text(peerStatusText)).foregroundColor(.gray)
                }
                
                // Sync status (in case non-selective or selective with selected files
                else if status == "idle" {
                    if !isSelective {
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
                    if !isSelective {
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
                Task.detached {
                    var hasExtra: ObjCBool = false
                    do {
                        let _ = try folder.hasExtraneousFiles(&hasExtra)
                        let hasExtraFinal = hasExtra
                        DispatchQueue.main.async {
                            changeProhibited = hasExtraFinal.boolValue
                        }
                    }
                    catch {
                        Log.warn("Error calling hasExtraneousFiles: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            changeProhibited = true
                        }
                    }
                }
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
                Task.detached {
                    do {
                        var hasExtra: ObjCBool = false
                        let _ = try folder.hasExtraneousFiles(&hasExtra)
                        let hasExtraFinal = hasExtra
                        DispatchQueue.main.async {
                            changeProhibited = hasExtraFinal.boolValue
                        }
                    }
                    catch {
                        Log.warn("Error calling hasExtraneousFiles: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            changeProhibited = true
                        }
                    }
                }
            }
        }
    }
}

fileprivate struct ExternalFolderSectionView: View {
    var folderID: String
    
    var body: some View {
        let isAccessible = BookmarkManager.shared.hasBookmarkFor(folderID: folderID)
        Section {
            if isAccessible {
                Label("External folder", systemImage: "app.badge.checkmark").foregroundStyle(.pink)
            }
            else {
                Label("Inaccessible external folder", systemImage: "xmark.app").foregroundStyle(.red)
            }
        } footer: {
            if isAccessible {
                Text("This folder is not in the default location, and may belong to another app.")
            }
            else {
                Text("This folder is external to this app, and cannot be accessed anymore. To resolve this issue, unlink the folder and re-add it.")
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
    @State var showRemoveConfirmation = false
    @State var showUnlinkConfirmation = false
    @State var showGenerateThumbnails = false
    
    var possiblePeers: [SushitrainPeer] {
        get {
            return appState.peers().sorted().filter({d in !d.isSelf()})
        }
    }
    
    var body: some View {
        let isExternal = folder.isExternal
        
        Form {
            if folder.exists() {
                #if os(iOS)
                    FolderStatusView(appState: appState, folder: folder)
                #endif
                
                if isExternal == true {
                    ExternalFolderSectionView(folderID: folder.folderID)
                }
                
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
                    Section(header: Text("Shared with")) {
                        ForEach(self.possiblePeers, id: \.self.id) { (addr: SushitrainPeer) in
                            ShareWithDeviceToggleView(appState: appState, peer: addr, folder: folder, showFolderName: false)
                        }
                    }
                }
                
                Section("System settings") {
                    #if os(iOS)
                        Toggle("Include in device back-up", isOn: Binding(get: {
                            if let f = folder.isExcludedFromBackup { return !f }
                            return false
                        }, set: { nv in
                            folder.isExcludedFromBackup = !nv
                        })).disabled(isExternal != false)
                    #endif
                        
                    Toggle("Hide in Files app", isOn: Binding(get: {
                        if let f = folder.isHidden { return f }
                        return false
                    }, set: { nv in
                        folder.isHidden = nv
                    })).disabled(isExternal != false)
                }
                
                Section {
                    #if os(iOS)
                        if !folder.isSelective() {
                            NavigationLink(destination: IgnoresView(appState: self.appState, folder: self.folder)
                                .navigationTitle("Files to ignore")
                               #if os(iOS)
                                    .navigationBarTitleDisplayMode(.inline)
                               #endif
                            ) {
                                Label("Files to ignore", systemImage: "rectangle.dashed")
                            }
                        }
                    #endif
                    
                    Button("Re-scan folder", systemImage: "sparkle.magnifyingglass") {
                        do {
                            try folder.rescan()
                        }
                        catch let error {
                            showError = true
                            errorText = error.localizedDescription
                        }
                    }
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                    
                    Button("Generate thumbnails", systemImage: "photo.stack") {
                        self.showGenerateThumbnails = true
                    }
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                    
                    Button("Unlink folder", systemImage: "folder.badge.minus", role:.destructive) {
                        showUnlinkConfirmation = true
                    }
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                    .foregroundColor(.red)
                    .confirmationDialog("Are you sure you want to unlink this folder? The folder will not be synchronized any longer. Files currently on this device will not be deleted.", isPresented: $showUnlinkConfirmation, titleVisibility: .visible) {
                        Button("Unlink the folder", role: .destructive) {
                            do {
                                dismiss()
                                try folder.unlinkAndRemoveBookmark()
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
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                    .disabled(isExternal != false)
                    .foregroundColor(.red)
                    .confirmationDialog("Are you sure you want to remove this folder? Please consider carefully. All files in this folder will be removed from this device. Files that have not been synchronized to other devices yet cannot be recoered.", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                        Button("Remove the folder and all files", role: .destructive) {
                            do {
                                dismiss()
                                try folder.removeAndRemoveBookmark()
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
        .alert(isPresented: $showError, content: {
            Alert(title: Text("An error occured"), message: Text(errorText), dismissButton: .default(Text("OK")))
        })
        .sheet(isPresented: $showGenerateThumbnails) {
            NavigationStack {
                FolderGenerateThumbnailsView(appState: self.appState, isShown: $showGenerateThumbnails, folder: self.folder)
                    .navigationTitle("Generate thumbnails")
                    #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar(content: {
                        ToolbarItem(placement: .cancellationAction, content: {
                            Button("Cancel") {
                                showGenerateThumbnails = false
                            }
                        })
                    })
            }
        }
    }
}

struct ShareWithDeviceToggleView: View {
    @ObservedObject var appState: AppState
    let peer: SushitrainPeer
    let folder: SushitrainFolder
    let showFolderName: Bool
    
    @State private var editEncryptionPasswordDeviceID = ""
    @State private var showEditEncryptionPassword = false
    
    private var isShared: Bool {
        if let swid = folder.sharedWithDeviceIDs() {
            return swid.asArray().contains(peer.deviceID())
        }
        return false
    }
    
    private func share(_ shared: Bool) {
        do {
            if shared && peer.isUntrusted() {
                editEncryptionPasswordDeviceID = peer.deviceID()
                showEditEncryptionPassword = true
            }
            else {
                try folder.share(withDevice: peer.deviceID(), toggle: shared, encryptionPassword: "")
            }
        }
        catch let error {
            Log.warn("Error sharing folder: " + error.localizedDescription)
        }
    }
    
    private var isPending: Bool {
        let pendingPeerIDs = Set((try? appState.client.devicesPendingFolder(self.folder.folderID))?.asArray() ?? [])
        return pendingPeerIDs.contains(self.peer.deviceID())
    }
    
    private var isSharedEncrypted: Bool {
        let sharedEncrypted = folder.sharedEncryptedWithDeviceIDs()?.asArray() ?? [];
        return sharedEncrypted.contains(peer.deviceID())
    }
    
    var body: some View {
        HStack {
            let isShared = Binding(get: {
                return self.isShared
            }, set: { nv in
                share(nv)
            })
            
            if showFolderName {
                Toggle(folder.displayName, systemImage: "folder.fill", isOn: isShared)
                    .bold(isPending)
            }
            else {
                Toggle(peer.displayName, systemImage: peer.systemImage, isOn: isShared)
                    .bold(isPending)
            }
            
            Button("Encryption password", systemImage: isSharedEncrypted ? "lock" : "lock.open", action: {
                editEncryptionPasswordDeviceID = peer.deviceID()
                showEditEncryptionPassword = true
            }).labelStyle(.iconOnly)
        }
        .sheet(isPresented: $showEditEncryptionPassword) {
            NavigationStack {
                ShareFolderWithDeviceDetailsView(appState: self.appState, folder: self.folder, deviceID: $editEncryptionPasswordDeviceID)
            }
        }
    }
}

struct FolderGenerateThumbnailsView: View {
    @ObservedObject var appState: AppState
    @Binding var isShown: Bool
    let folder: SushitrainFolder
    @State private var error: Error? = nil
    @State private var totalFiles: Int = 0
    @State private var processedFiles: Int = 0
    @State private var lastThumbnail: AsyncImagePhase? = nil
    
    var body: some View {
        VStack {
            if let e = error {
                Text(e.localizedDescription)
            }
            else {
                if let img = self.lastThumbnail {
                    switch img {
                    case .success(let img):
                        img.frame(maxWidth: 200, maxHeight: 200).clipShape(.rect(cornerRadius: 10))
                    default:
                        Rectangle().frame(width: 200, height: 200).foregroundStyle(.gray).opacity(0.2).clipShape(.rect(cornerRadius: 10))
                    }
                }
                else {
                    Rectangle().frame(width: 200, height: 200).foregroundStyle(.gray).opacity(0.2).clipShape(.rect(cornerRadius: 10))
                }
                
                Text("Generating thumbnails...")
                if self.totalFiles > 0 {
                    ProgressView(value: Float(self.processedFiles), total: Float(self.totalFiles))
                }
                
            }
        }
        .padding(30)
        .alert(isPresented: Binding.constant(error != nil)) {
            Alert(title: Text("An error occurred"), message: Text(error!.localizedDescription), dismissButton: .default(Text("OK")) {
                isShown = false
            })
        }
        .task {
            #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = true
            #endif
            do {
                let stats = try self.folder.statistics()
                self.totalFiles = stats.global?.files ?? 0
                self.processedFiles = 0
                try await self.generateFor(prefix: nil)
                self.isShown = false
            }
            catch {
                self.error = error
            }
            #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
    }
    
    private func generateFor(prefix: String?) async throws {
        let files = try self.folder.list(prefix, directories: false, recurse: false)
        self.totalFiles += files.count()
        
        for idx in 0..<files.count() {
            let filePath = files.item(at: idx)
            if Task.isCancelled {
                Log.info("Thumbnail generate task cancelled")
                return
            }
            
            if let file = try? self.folder.getFileInformation((prefix ?? "") + "/" + filePath) {
                if file.isDirectory() {
                    try await self.generateFor(prefix: file.path())
                }
                if file.canThumbnail {
                    let url = file.isLocallyPresent() ? file.localNativeFileURL! : URL(string: file.onDemandURL())!
                    let cacheKey = file.cacheKey
                    if cacheKey.count > 5 {
                        let thumb = await getThumbnail(cacheKey: cacheKey, url: url, strategy: file.thumbnailStrategy)
                        self.lastThumbnail = thumb
                    }
                }
                self.processedFiles += 1
            }
            else {
                Log.warn("Could not get file entry for path \(filePath)")
            }
        }
    }
}
