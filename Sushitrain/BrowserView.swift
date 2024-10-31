// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import QuickLook

enum BrowserViewStyle: String {
    case grid = "grid"
    case list = "list"
}

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
                        NavigationLink(destination: FileView(file: targetEntry, appState: self.appState, siblings: [])) {
                            Label(targetEntry.fileName(), systemImage: targetEntry.systemImage)
                        }
                        NavigationLink(destination: FileView(file: entry, appState: self.appState, siblings: siblings)) {
                            Label(entry.fileName(), systemImage: entry.systemImage)
                        }
                    }
                }
                else {
                    NavigationLink(destination: FileView(file: targetEntry, appState: self.appState, siblings: [])) {
                        Label(entry.fileName(), systemImage: entry.systemImage)
                    }.contextMenu {
                        NavigationLink(destination: FileView(file: targetEntry, appState: self.appState, siblings: [])) {
                            Label(targetEntry.fileName(), systemImage: targetEntry.systemImage)
                        }
                        NavigationLink(destination: FileView(file: entry, appState: self.appState, siblings: siblings)) {
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
                    NavigationLink(destination: FileView(file: entry, appState: self.appState, siblings: siblings)) {
                        Label(entry.fileName(), systemImage: entry.systemImage)
                    }
                }
            }
            else {
                Label(entry.fileName(), systemImage: "questionmark.app.dashed")
            }
        }
        else {
            NavigationLink(destination: FileView(file: entry, appState: self.appState, siblings: siblings)) {
                Label(entry.fileName(), systemImage: entry.systemImage)
            }.contextMenu {
                NavigationLink(destination: FileView(file: entry, appState: self.appState, siblings: siblings)) {
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
    @Binding var viewStyle: BrowserViewStyle
    
    @State private var subdirectories: [SushitrainEntry] = []
    @State private var files: [SushitrainEntry] = []
    @State private var hasExtraneousFiles = false
    @State private var isLoading = true
    @State private var showSpinner = false
    
    @Environment(\.isSearching) private var isSearching
    
    var body: some View {
        let isEmpty = subdirectories.isEmpty && files.isEmpty;
        
        Group {
            if self.folder.exists() {
                if !isSearching {
                    switch self.viewStyle {
                    case .grid:
                        VStack {
                            ScrollView {
                                HStack {
                                    FolderStatusView(appState: appState, folder: folder).padding(.all, 10)
                                    
                                    Spacer()
                                    
                                    Slider(value: Binding(get: {
                                        return Double(appState.browserGridColumns)
                                    }, set: { nv in
                                        appState.browserGridColumns = Int(nv)
                                    }), in: 1.0...10.0, step: 1.0)
                                    .frame(minWidth: 50, maxWidth: 100)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                }
                                
                                GridFilesView(appState: appState, prefix: self.prefix, files: files, subdirectories: subdirectories, folder: folder)
                                    .padding(.horizontal, 15)
                            }
                        }
                    case .list:
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
                                            NavigationLink(destination: FileView(file: file, appState: self.appState)) {
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
                if showSpinner {
                    ProgressView()
                }
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
            await self.reload()
        }
    }
    
    private func reload() async {
        self.isLoading = true
        self.showSpinner = false
        let loadingSpinnerTask = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled && self.isLoading {
                self.showSpinner = true
            }
        }
        
        let folder = self.folder
        let prefix = self.prefix
        let dotFilesHidden = self.appState.dotFilesHidden
        
        subdirectories = await Task.detached {
            if !folder.exists() {
                return []
            }
            do {
                var dirNames = try folder.list(prefix, directories: true, recurse: false).asArray().sorted()
                if dotFilesHidden {
                    dirNames = dirNames.filter({ !$0.starts(with: ".") })
                }
                return try dirNames.map({ dirName in
                    return try folder.getFileInformation(prefix + dirName)
                })
            }
            catch let error {
                Log.warn("Error listing: \(error.localizedDescription)")
            }
            return []
        }.value
        
        files = await Task.detached {
            if !folder.exists() {
                return []
            }
            do {
                let list = try folder.list(self.prefix, directories: false, recurse: false)
                var entries: [SushitrainEntry] = [];
                for i in 0..<list.count() {
                    let path = list.item(at: i)
                    if dotFilesHidden && path.starts(with: ".") {
                        continue
                    }
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
                Log.warn("Error listing: \(error.localizedDescription)")
            }
            return []
        }.value
        
        if self.folder.isIdle {
            hasExtraneousFiles = await Task.detached {
                var hasExtra: ObjCBool = false
                do {
                    try folder.hasExtraneousFiles(&hasExtra)
                    return hasExtra.boolValue
                }
                catch let error {
                    Log.warn("error checking for extraneous files: \(error.localizedDescription)")
                }
                return false
            }.value
        }
        else {
            hasExtraneousFiles = false
        }
        
        self.isLoading = false
        loadingSpinnerTask.cancel()
    }
}

struct BrowserView: View {
    @ObservedObject var appState: AppState
    var folder: SushitrainFolder
    var prefix: String
    
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var localNativeURL: URL? = nil
    @State private var folderExists = false
    @State private var folderIsSelective = false
    @State private var showSearch = false
    
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
        BrowserListView(appState: appState, folder: folder, prefix: prefix, searchText: $searchText, showSettings: $showSettings, viewStyle: appState.$browserViewStyle)
        .navigationTitle(folderName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
            .searchable(text: $searchText, placement: SearchFieldPlacement.toolbar, prompt: "Search files in this folder...")
        #elseif os(iOS)
            .sheet(isPresented: $showSearch) {
                NavigationStack {
                    SearchView(appState: self.appState, prefix: self.prefix)
                        .navigationTitle("Search in this folder")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(content: {
                            ToolbarItem(placement: .cancellationAction, content: {
                                Button("Cancel") {
                                    showSearch = false
                                }
                            })
                        })
                }
            }
        #endif
        .toolbar {
            #if os(macOS)
                ToolbarItemGroup(placement: .status) {
                    Picker("View as", selection: appState.$browserViewStyle) {
                        Image(systemName: "list.bullet").tag(BrowserViewStyle.list).accessibilityLabel(Text("List"))
                        Image(systemName: "square.grid.2x2").tag(BrowserViewStyle.grid).accessibilityLabel(Text("Grid"))
                    }
                    .pickerStyle(.segmented)
                }
            #endif
            
            #if os(macOS)
                ToolbarItem {
                    // Open in Finder/Files (and possibly materialize empty folder)
                    if let localNativeURL = self.localNativeURL {
                        Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app", action: {
                            if let localNativeURL = self.localNativeURL {
                                openURLInSystemFilesApp(url: localNativeURL)
                            }
                        }).disabled(!folderExists)
                    }
                    else if folderExists {
                        if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
                            if entry.isDirectory() && !entry.isLocallyPresent() {
                                Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app", action: {
                                    try? entry.materializeSubdirectory()
                                    self.updateLocalURL()
                                    
                                    if let localNativeURL = self.localNativeURL {
                                        openURLInSystemFilesApp(url: localNativeURL)
                                    }
                                })
                            }
                        }
                    }
                }
            
            ToolbarItem {
                Menu {
                    if folderExists {
                        NavigationLink(destination: FolderStatisticsView(appState: appState, folder: folder)) {
                            Label("Folder statistics...", systemImage: "scalemass")
                        }
                    }
                    
                    if folderExists && folderIsSelective {
                        NavigationLink(destination: SelectiveFolderView(appState: appState, folder: folder)) {
                            Label("Files kept on this device...", systemImage: "pin")
                        }
                    }
                    
                    Divider()
                    
                    Button {
                        showSettings = true
                    } label: {
                        Label("Folder settings...", systemImage: "folder.badge.gearshape")
                    }
                    
                } label: {
                    Label("Folder settings", systemImage:  "folder.badge.gearshape")
                }.disabled(!folderExists)
            }
            #elseif os(iOS)
                ToolbarItem {
                    Menu(content: {
                        Picker("View as", selection: appState.$browserViewStyle) {
                            HStack {
                                Image(systemName: "list.bullet")
                                Text("List")
                            }.tag(BrowserViewStyle.list)
                            HStack {
                                Image(systemName: "square.grid.2x2")
                                Text("Grid")
                            }.tag(BrowserViewStyle.grid)
                        }
                        .pickerStyle(.inline)
                        
                        Toggle("Search here...", systemImage: "magnifyingglass", isOn: $showSearch).disabled(!folderExists)
                        
                        if folderExists {
                            // Open in Finder/Files (and possibly materialize empty folder)
                            if let localNativeURL = self.localNativeURL {
                                Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app", action: {
                                    if let localNativeURL = self.localNativeURL {
                                        openURLInSystemFilesApp(url: localNativeURL)
                                    }
                                })
                            }
                            else {
                                if let entry = try? self.folder.getFileInformation(self.prefix.withoutEndingSlash) {
                                    if entry.isDirectory() && !entry.isLocallyPresent() {
                                        Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app", action: {
                                            try? entry.materializeSubdirectory()
                                            self.updateLocalURL()
                                            
                                            if let localNativeURL = self.localNativeURL {
                                                openURLInSystemFilesApp(url: localNativeURL)
                                            }
                                        })
                                    }
                                }
                            }
                            
                            NavigationLink(destination: FolderStatisticsView(appState: appState, folder: folder)) {
                                Label("Folder statistics...", systemImage: "scalemass")
                            }
                            
                            NavigationLink(destination: SelectiveFolderView(appState: appState, folder: folder)) {
                                Label("Files kept on this device...", systemImage: "pin")
                            }.disabled(!folderIsSelective)
                        }
                        
                        Divider()
                        
                        Button("Folder settings...", systemImage: "folder.badge.gearshape", action: {
                            showSettings = true
                        }).disabled(!folderExists)
                        
                    }, label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Menu")) })
                }
            #endif
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
            self.folderExists = folder.exists()
            self.updateLocalURL()
            self.folderIsSelective = folder.isSelective()
        }
    }
    
    private func updateLocalURL() {
        // Get local native URL
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
