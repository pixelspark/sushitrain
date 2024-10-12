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

struct FoldersSections: View {
    @ObservedObject var appState: AppState
    
    @State private var showingAddFolderPopup = false
    @State private var pendingFolderIds: [String] = []
    @State private var addFolderID = ""
    @State private var folders: [SushitrainFolder] = []
    @State private var showFolderProperties: SushitrainFolder? = nil
    
    var body: some View {
        Section("Folders") {
            ForEach(folders, id: \.self) { (folder: SushitrainFolder) in
                NavigationLink(value: Route.folder(folderID: folder.folderID)) {
                    if folder.isPaused() {
                        Label(folder.displayName, systemImage: "folder.fill").foregroundStyle(.gray)
                    }
                    else {
                        Label(folder.displayName, systemImage: "folder.fill")
                    }
                }
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
    }
}
