// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI

struct FoldersView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddFolderPopup = false
    @State private var pendingFolderIds: [String] = []
    @State private var addFolderID = ""
    
    var body: some View {
        ZStack {
            let folders = appState.folders().sorted()
            NavigationStack {
                List {
                    Section {
                        ForEach(folders, id: \.self) { folder in
                            NavigationLink(destination: BrowserView(folder: folder, prefix: "", appState: self.appState)) {
                                Label(folder.label().isEmpty ? folder.folderID : folder.label(), systemImage: "folder.fill")
                            }.contextMenu(ContextMenu(menuItems: {
                                NavigationLink("Folder settings", destination: FolderView(folder: folder, appState: self.appState))
                            }))
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
            }
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
