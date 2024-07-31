// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore


struct FoldersView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddFolderPopup = false
    @State private var pendingFolderIds: [String] = []
    @State private var addFolderID = ""
    @State private var selectedFolder: SelectedFolder?
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    
    fileprivate struct SelectedFolder: Hashable, Equatable {
        var folder: SushitrainFolder
        
        func hash(into hasher: inout Hasher) {
            self.folder.folderID.hash(into: &hasher)
        }
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            return lhs.folder.folderID == rhs.folder.folderID
        }
    }
    
    var body: some View {
        Group {
            let folders = appState.folders().sorted()
            
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                sidebar: {
                    List(selection: $selectedFolder) {
                        Section {
                            ForEach(folders, id: \.self) { folder in
                                NavigationLink(value: SelectedFolder(folder: folder)) {
                                    Label(folder.label().isEmpty ? folder.folderID : folder.label(), systemImage: "folder.fill")
                                }
                            }
                        }
                        
                        if !pendingFolderIds.isEmpty {
                            Section("Discovered folders") {
                                ForEach(pendingFolderIds, id: \.self) { folderID in
                                    Button(folderID, systemImage: "plus", action: {
                                        addFolderID = folderID
                                        showingAddFolderPopup = true
                                    })
                                }
                            }
                        }
                        
                        Section {
                            Button("Add other folder...", systemImage: "plus", action: {
                                addFolderID = ""
                                showingAddFolderPopup = true
                            })
                        }
                    }
                    .navigationTitle("Folders")
                    .toolbar {
                        Button("Open in Files app", systemImage: "arrow.up.forward.app", action: {
                            let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                            let sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                            let furl = URL(string: sharedurl)!
                            UIApplication.shared.open(furl, options: [:], completionHandler: nil)
                        }).labelStyle(.iconOnly)
                    }
                }, detail: {
                    NavigationStack {
                        if let folder = selectedFolder {
                            if folder.folder.exists() {
                                BrowserView(
                                    appState: self.appState,
                                    folder: folder.folder,
                                    prefix: ""
                                ).id(folder.folder.folderID)
                            }
                            else {
                                ContentUnavailableView("Folder was deleted", systemImage: "trash", description: Text("This folder was deleted."))
                            }
                        }
                        else {
                            ContentUnavailableView("Select a folder", systemImage: "folder").onTapGesture {
                                columnVisibility = .doubleColumn
                            }
                        }
                    }
                })
            .navigationSplitViewStyle(.balanced)
        }
        .sheet(isPresented: $showingAddFolderPopup, content: {
            AddFolderView(folderID: $addFolderID, appState: appState)
        })
        .onAppear {
            let addedFolders = Set(appState.folders().map({f in f.folderID}))
            self.pendingFolderIds = ((try? self.appState.client.pendingFolderIDs())?.asArray() ?? []).filter({ folderID in !addedFolders.contains(folderID)
            })
        }
    }
}
