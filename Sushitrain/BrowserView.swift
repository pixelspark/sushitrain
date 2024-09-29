// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore
import QuickLook

struct EntryView: View {
    @ObservedObject var appState: AppState
    let entry: SushitrainEntry
    let folder: SushitrainFolder
    let siblings: [SushitrainEntry]
    
    var body: some View {
        if entry.isSymlink() {
            // Find the destination
            let targetEntry = try? entry.symlinkTargetEntry()
            if let targetEntry = targetEntry {
                if targetEntry.isDirectory() {
                    NavigationLink(destination: BrowserView(
                        appState: appState,
                        folder: folder,
                        prefix: targetEntry.path() + "/"
                    )) {
                        Label(entry.fileName(), systemImage: entry.systemImage)
                    }
                    .contextMenu {
                        NavigationLink(destination: FileView(file: targetEntry, folder: self.folder, appState: self.appState, siblings: [])) {
                            Label(targetEntry.fileName(), systemImage: targetEntry.systemImage)
                        }
                        NavigationLink(destination: FileView(file: entry, folder: self.folder, appState: self.appState, siblings: siblings)) {
                            Label(entry.fileName(), systemImage: entry.systemImage)
                        }
                    }
                }
                else {
                    NavigationLink(destination: FileView(file: targetEntry, folder: self.folder, appState: self.appState, siblings: [])) {
                        Label(entry.fileName(), systemImage: entry.systemImage)
                    }.contextMenu {
                        NavigationLink(destination: FileView(file: targetEntry, folder: self.folder, appState: self.appState, siblings: [])) {
                            Label(targetEntry.fileName(), systemImage: targetEntry.systemImage)
                        }
                        NavigationLink(destination: FileView(file: entry, folder: self.folder, appState: self.appState, siblings: siblings)) {
                            Label(entry.fileName(), systemImage: entry.systemImage)
                        }
                    }
                    preview: {
#if os(iOS)
                        if targetEntry.size() < appState.maxBytesForPreview || targetEntry.isLocallyPresent() {
                            BareOnDemandFileView(appState: appState, file: targetEntry, isShown: .constant(true), videoOverlay: {
                                // Nothing
                            })
                        }
                        else {
                            ContentUnavailableView("File is too large to preview", systemImage: "scalemass")
                        }
#endif
                    }
                }
            }
            else if let targetURL = URL(string: entry.symlinkTarget()), targetURL.scheme == "https" || targetURL.scheme == "http" {
                Link(destination: targetURL) {
                    Label(entry.fileName(), systemImage: entry.systemImage)
                }
                .contextMenu {
                    Link(destination: targetURL) {
                        Label(targetURL.absoluteString, systemImage: "globe")
                    }
                    NavigationLink(destination: FileView(file: entry, folder: self.folder, appState: self.appState, siblings: siblings)) {
                        Label(entry.fileName(), systemImage: entry.systemImage)
                    }
                }
            }
            else {
                Label(entry.fileName(), systemImage: "questionmark.app.dashed")
            }
        }
        else {
            NavigationLink(destination: FileView(file: entry, folder: self.folder, appState: self.appState, siblings: siblings)) {
                Label(entry.fileName(), systemImage: entry.systemImage)
            }.contextMenu {
                NavigationLink(destination: FileView(file: entry, folder: self.folder, appState: self.appState, siblings: siblings)) {
                    Label(entry.fileName(), systemImage: entry.systemImage)
                }
            } preview: {
#if os(iOS)
                if entry.size() < appState.maxBytesForPreview || entry.isLocallyPresent() {
                    BareOnDemandFileView(appState: appState, file: entry, isShown: .constant(true), videoOverlay: {
                        // Nothing
                    })
                }
                else {
                    ContentUnavailableView("File is too large to preview", systemImage: "scalemass")
                }   
#endif
            }
        }
    }
}

fileprivate struct BrowserListView: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    var prefix: String
    @Binding var searchText: String
    @Binding var showSettings: Bool
    
    @State private var subdirectories: [SushitrainEntry] = []
    @State private var files: [SushitrainEntry] = []
    @State private var hasExtraneousFiles = false
    @State private var isLoading = true
    
    @Environment(\.isSearching) private var isSearching
    
    var body: some View {
        let isEmpty = subdirectories.isEmpty && files.isEmpty;
        
        Group {
            if self.folder.exists() {
                if !isSearching {
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
                            ForEach(subdirectories, id: \.self) { (subDirEntry: SushitrainEntry) in
                                let fileName = subDirEntry.fileName()
                                NavigationLink(destination: BrowserView(
                                    appState: appState,
                                    folder: folder,
                                    prefix: "\(prefix)\(fileName)/"
                                )) {
                                    Label(fileName, systemImage: subDirEntry.systemImage)
                                }
                                .contextMenu(ContextMenu(menuItems: {
                                    if let file = try? folder.getFileInformation(self.prefix + fileName) {
                                        NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState)) {
                                            Label("Subdirectory properties", systemImage: "folder.badge.gearshape")
                                        }
                                    }
                                }))
                            }
                        }
                        
                        // List files
                        Section {
                            ForEach(files, id: \.self) { file in
                                EntryView(appState: appState, entry: file, folder: folder, siblings: files)
                            }
                        }
                    }
                    #if os(macOS)
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                    #endif
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
        .task(id: self.folder.folderStateForUpdating) {
            self.isLoading = true
            
            subdirectories = self.listSubdirectories();
            files = self.listFiles();
            if self.folder.isIdle {
                var hasExtra: ObjCBool = false
                do {
                    try folder.hasExtraneousFiles(&hasExtra)
                    hasExtraneousFiles = hasExtra.boolValue
                }
                catch let error {
                    print("error checking for extraneous files: \(error.localizedDescription)")
                }
            }
            else {
                hasExtraneousFiles = false
            }
            self.isLoading = false
        }
    }
    
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
                    if fileInfo.isDirectory() || fileInfo.isDeleted() {
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
}

struct BrowserView: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder;
    var prefix: String;
    
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var localNativeURL: URL? = nil
    
    var folderName: String {
        if prefix.isEmpty {
            return self.folder.label()
        }
        let parts = prefix.split(separator: "/")
        if parts.count > 0 {
            return String(parts[parts.count - 1])
        }
        return prefix
    }
    
    var body: some View {
        BrowserListView(appState: appState, folder: folder, prefix: prefix, searchText: $searchText, showSettings: $showSettings)
        .navigationTitle(folderName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        
        #if os(macOS)
        // Disabled due to glitchy transitions (on iOS 17.4 at least)
         // .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search files in this folder...")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search files in this folder...")
        #endif
        .toolbar {
            if folder.exists() {
                ToolbarItem {
                    Button("Settings", systemImage: "folder.badge.gearshape", action: {
                        showSettings = true
                    }).labelStyle(.iconOnly)
                }
                ToolbarItem {
                    Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app", action: {
                        if let localNativeURL = self.localNativeURL {
                            openURLInSystemFilesApp(url: localNativeURL)
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
        .task {
            self.localNativeURL = nil
            var error: NSError? = nil
            let localNativePath = self.folder.localNativePath(&error)
            
            if error == nil {
                let localNativeURL = URL(fileURLWithPath: localNativePath).appendingPathComponent(self.prefix)
                
                if FileManager.default.fileExists(atPath: localNativeURL.path) {
                    self.localNativeURL = localNativeURL
                }
            }
        }
    }
    
    
}


extension SushitrainFolder {
    fileprivate var folderStateForUpdating: Int {
        var error: NSError? = nil
        let state = self.state(&error)
        var hasher = Hasher()
        hasher.combine(state)
        hasher.combine(self.isPaused())
        return hasher.finalize()
    }
}
