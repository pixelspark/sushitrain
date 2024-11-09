// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

enum Route: Hashable, Equatable {
    case start
    case folder(folderID: String?)
    case devices
}

fileprivate struct FolderMetricView: View {
    let metric: FolderMetric
    let folder: SushitrainFolder
    @State private var stats: SushitrainFolderStats? = nil
    
    var body: some View {
        if self.metric != .none {
            self.metricView()
                .foregroundStyle(.secondary)
                .task {
                    await self.updateMetric()
                }
        }
    }
    
    private func metricView() -> some View {
        if let stats = self.stats {
            switch self.metric {
            case .localFileCount:
                if let cnt = stats.local?.files {
                    return Text(cnt.formatted())
                }
                return Text("")
                
            case .globalFileCount:
                if let cnt = stats.global?.files {
                    return Text(cnt.formatted())
                }
                return Text("")
                
            case .localSize:
                let formatter = ByteCountFormatter()
                if let cnt = stats.local?.bytes {
                    return Text(formatter.string(fromByteCount: cnt))
                }
                return Text("")
                
            case .globalSize:
                let formatter = ByteCountFormatter()
                if let cnt = stats.global?.bytes {
                    return Text(formatter.string(fromByteCount: cnt))
                }
                return Text("")
                
            case .localPercentage:
                if let local = stats.local, let global = stats.global {
                    let p = global.bytes > 0 ? Int(Double(local.bytes) / Double(global.bytes) * 100) : 100
                    return Text("\(p)%")
                }
                return Text("")
                
            case .localCompletion:
                if let localNeed = stats.localNeed, let local = stats.local {
                    let p = localNeed.bytes > 0 ? Int(Double(local.bytes) / Double(localNeed.bytes) * 100) : 100
                    return Text("\(p)%")
                }
                return Text("")
                
            case .none:
                fatalError()
            }
        }
        else {
            return Text("")
        }
    }
    
    private func updateMetric() async {
        let folder = self.folder
        self.stats = await Task.detached {
            do {
                return try folder.statistics()
            }
            catch {
                Log.warn("failed to obtain folder metrics: \(error.localizedDescription)")
            }
            return nil
        }.value
    }
}

struct FoldersSections: View {
    @ObservedObject var appState: AppState
    
    @State private var showingAddFolderPopup = false
    @State private var pendingFolderIds: [String] = []
    @State private var addFolderID = ""
    @State private var folders: [SushitrainFolder] = []
    @State private var showFolderProperties: SushitrainFolder? = nil
    
    var body: some View {
        Section("Folders") {
            ForEach(folders, id: \.self.folderID) { (folder: SushitrainFolder) in
                NavigationLink(value: Route.folder(folderID: folder.folderID)) {
                    if folder.isPaused() {
                        Label(folder.displayName, systemImage: "folder.fill")
                            .foregroundStyle(.gray)
                    }
                    else {
                        HStack {
                            Label(folder.displayName, systemImage: "folder.fill")
                            Spacer()
                            FolderMetricView(metric: self.appState.viewMetric, folder: folder).id(folder.folderID)
                        }
                    }
                }
                .id(folder.folderID)
            }.onChange(of: appState.eventCounter) {
                self.updateFolders()
            }
        }
        
        if !pendingFolderIds.isEmpty {
            Section("Discovered folders") {
                ForEach(pendingFolderIds, id: \.self) { folderID in
                    Button(folderID, systemImage: "plus", action: {
                        addFolderID = folderID
                        showingAddFolderPopup = true
                    })
                    .id(folderID)
                    #if os(macOS)
                        .buttonStyle(.link)
                    #endif
                }
            }
        }
        
        Section {
            Button("Add folder...", systemImage: "plus", action: {
                addFolderID = ""
                showingAddFolderPopup = true
            })
            #if os(macOS)
                .buttonStyle(.borderless)
            #endif
        }
        .sheet(isPresented: $showingAddFolderPopup, content: {
            AddFolderView(folderID: $addFolderID, appState: appState)
        })
        .onAppear {
            self.updateFolders()
            
            let addedFolders = Set(appState.folders().map({f in f.folderID}))
            self.pendingFolderIds = ((try? self.appState.client.pendingFolderIDs())?.asArray() ?? []).filter({ folderID in
                !addedFolders.contains(folderID)
            })
        }
    }
    
    private func updateFolders() {
        folders = appState.folders().sorted()
    }
}

struct FoldersView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        List {
            FoldersSections(appState: self.appState)
        }
        .navigationTitle("Folders")
        .navigationDestination(for: Route.self, destination: {r in
            switch r {
            case .folder(folderID: let folderID):
                if let folderID = folderID, let folder = self.appState.client.folder(withID: folderID) {
                    if folder.exists() {
                        BrowserView(
                            appState: self.appState,
                            folder: folder,
                            prefix: ""
                        ).id(folder.folderID)
                    }
                    else {
                        ContentUnavailableView("Folder was deleted", systemImage: "trash", description: Text("This folder was deleted."))
                    }
                }
                else {
                    ContentUnavailableView("Select a folder", systemImage: "folder")
                }
                
            default:
                Text("")
            }
        })
        .toolbar {
            ToolbarItem {
                Menu(content: {
                    Picker("Show metric", selection: self.appState.$viewMetric) {
                        HStack {
                            Text("None")
                        }.tag(FolderMetric.none)
                        
                        HStack {
                            Image(systemName: "number.circle.fill")
                            Text("Files on this device")
                        }.tag(FolderMetric.localFileCount)
                        
                        HStack {
                            Image(systemName: "number.circle")
                            Text("Total number of files")
                        }.tag(FolderMetric.globalFileCount)
                        
                        HStack {
                            Image(systemName: "scalemass.fill")
                            Text("Size on this device")
                        }.tag(FolderMetric.localSize)
                        
                        HStack {
                            Image(systemName: "scalemass")
                            Text("Total folder size")
                        }.tag(FolderMetric.globalSize)
                        
                        HStack {
                            Image(systemName: "percent")
                            Text("Percentage on device")
                        }.tag(FolderMetric.localPercentage)
                        
                        HStack {
                            Image(systemName: "percent")
                            Text("Percentage completed")
                        }.tag(FolderMetric.localCompletion)
                    }
                    .pickerStyle(.inline)
                }, label: { Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Menu")) })
            }
        }
    }
}
