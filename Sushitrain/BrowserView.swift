// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore
import QuickLook

struct BrowserView: View {
    var folder: SushitrainFolder;
    var prefix: String;
    @ObservedObject var appState: AppState
    @State private var showSettings = false
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var subdirectories: [SushitrainEntry] = []
    @State private var files: [SushitrainEntry] = []
    @State private var hasExtraneousFiles = false
    @State private var localNativeURL: URL? = nil
    
    private func listSubdirectories() -> [SushitrainEntry] {
        if !folder.exists() {
            return []
        }
        do {
            let dirNames = try folder.list(self.prefix, directories: true).asArray().sorted()
            return try dirNames.map({ dirName in
                return try folder.getFileInformation(self.prefix + dirName)
            })
        }
        catch let error {
            print("Error listing: \(error.localizedDescription)")
        }
        return []
    }
    
    private func listFiles() -> [SushitrainEntry] {
        if !folder.exists() {
            return []
        }
        do {
            let list = try folder.list(self.prefix, directories: false)
            var entries: [SushitrainEntry] = [];
            for i in 0..<list.count() {
                let path = list.item(at: i)
                if let fileInfo = try? folder.getFileInformation(self.prefix + path) {
                    if fileInfo.isDirectory() || fileInfo.isSymlink() || fileInfo.isDeleted() {
                        continue
                    }
                    entries.append(fileInfo)
                }
            }
            return entries.sorted()
        }
        catch let error {
            print("Error listing: \(error.localizedDescription)")
        }
        return []
    }
    
    var body: some View {
        let isEmpty = subdirectories.isEmpty && files.isEmpty;
        let searchTextLower = searchText.lowercased()
        
        NavigationStack {
            Group {
                if self.folder.exists() {
                    if searchText.isEmpty {
                        List {
                            Section {
                                FolderStatusView(appState: appState, folder: folder)
                                
                                if hasExtraneousFiles {
                                    NavigationLink(destination: {
                                        ExtraFilesView(folder: self.folder, appState: self.appState)
                                    }) {
                                        Label("This folder has new files", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                    }
                                }
                            }
                            
                            // List subdirectories
                            Section {
                                ForEach(subdirectories, id: \.self) {
                                    subDirEntry in
                                    let fileName = subDirEntry.fileName()
                                    if searchTextLower.isEmpty || fileName.lowercased().contains(searchTextLower) {
                                        NavigationLink(destination: BrowserView(folder: folder, prefix: "\(prefix)\(fileName)/", appState: appState)) {
                                            Label(fileName, systemImage: subDirEntry.systemImage)
                                        }
                                        .contextMenu(ContextMenu(menuItems: {
                                            if let file = try? folder.getFileInformation(self.prefix + fileName) {
                                                NavigationLink("Folder properties", destination: FileView(file: file, folder: self.folder, appState: self.appState))
                                            }
                                        }))
                                    }
                                }
                            }
                            
                            // List files
                            Section {
                                ForEach(files, id: \.self) {
                                    file in
                                    if searchTextLower.isEmpty || file.fileName().lowercased().contains(searchTextLower) {
                                        NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState, siblings: files)) {
                                            Label(file.fileName(), systemImage: file.systemImage)
                                        }.contextMenu {
                                            NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState, siblings: files)) {
                                                Label(file.fileName(), systemImage: file.systemImage)
                                            }
                                        } preview: {
                                            if file.size() < appState.maxBytesForPreview || file.isLocallyPresent() {
                                                BareOnDemandFileView(appState: appState, file: file, isShown: .constant(true))
                                            }
                                            else {
                                                ContentUnavailableView("File is too large to preview", systemImage: "scalemass")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    else {
                        // Search
                        SearchResultsView(
                            appState: self.appState,
                            searchText: $searchText,
                            folder: Binding(get: { self.folder.folderID }, set: {_ in ()}),
                            prefix: Binding(get: { prefix }, set: {_ in () })
                        )
                    }
                }
            }
            .navigationTitle(prefix.isEmpty ? self.folder.label() : prefix)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search files in this folder...")
            .overlay {
                if !folder.exists() {
                    ContentUnavailableView("Folder removed", systemImage: "trash", description: Text("This folder was removed."))
                }
                else if isLoading {
                    ProgressView()
                }
                else if isEmpty && self.prefix == "" {
                    if self.folder.isPaused() {
                        ContentUnavailableView("Synchronization disabled", systemImage: "pause.fill", description: Text("Synchronization has been disabled for this folder. Enable it in folder settings to access files.")).onTapGesture {
                            showSettings = true
                        }
                    }
                    else if self.folder.connectedPeerCount() == 0 {
                        ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Share this folder with other devices to start synchronizing files.")).onTapGesture {
                            showSettings = true
                        }
                    }
                    else {
                        ContentUnavailableView("There are currently no files in this folder.", systemImage: "questionmark.folder", description: Text("If this is unexpected, ensure that the other devices have accepted syncing this folder with your device.")).onTapGesture {
                            showSettings = true
                        }
                    }
                }
            }
            .toolbar {
                if folder.exists() {
                    ToolbarItem {
                        Button("Settings", systemImage: "folder.badge.gearshape", action: {
                            showSettings = true
                        }).labelStyle(.iconOnly)
                    }
                    ToolbarItem {
                        Button("Open in Files app", systemImage: "arrow.up.forward.app", action: {
                            if let localNativeURL = self.localNativeURL {
                                let sharedURL = localNativeURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                let furl: URL = URL(string: sharedURL)!
                                UIApplication.shared.open(furl, options: [:], completionHandler: nil)
                            }
                        })
                        .labelStyle(.iconOnly)
                        .disabled(localNativeURL == nil)
                    }
                }
            }
            .sheet(isPresented: $showSettings, content: {
                NavigationStack {
                    FolderView(folder: self.folder, appState: self.appState).toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                showSettings = false
                            }
                        })
                    })
                }
            })
            .task(id: self.folderStateForUpdating()) {
                self.isLoading = true
                
                self.localNativeURL = nil
                var error: NSError? = nil
                let localNativePath = self.folder.localNativePath(&error)
                
                if error == nil {
                    let localNativeURL = URL(fileURLWithPath: localNativePath).appendingPathComponent(self.prefix)
                        
                    if FileManager.default.fileExists(atPath: localNativeURL.path) {
                        self.localNativeURL = localNativeURL
                    }
                }
                
                subdirectories = self.listSubdirectories();
                files = self.listFiles();
                var hasExtra: ObjCBool = false
                do {
                    try folder.hasExtraneousFiles(&hasExtra)
                    hasExtraneousFiles = hasExtra.boolValue
                }
                catch let error {
                    print("error checking for extraneous files: \(error.localizedDescription)")
                }
                self.isLoading = false
            }
        }
    }
    
    private func folderStateForUpdating() -> Int {
        var error: NSError? = nil
        let state = folder.state(&error)
        var hasher = Hasher()
        hasher.combine(state)
        hasher.combine(folder.isPaused())
        return hasher.finalize()
    }
}
