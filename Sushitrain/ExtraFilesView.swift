// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import QuickLook

struct ExtraFilesView: View {
    var folder: SushitrainFolder
    @ObservedObject var appState: AppState
    @State private var adressedPaths = Set<String>()
    @State private var extraFiles: [String] = []
    @State private var showCleanAll = false
    @State private var localItemURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        let unadressedExtraFiles = extraFiles.filter({ p in !self.adressedPaths.contains(p) })
        
        ZStack {
            if unadressedExtraFiles.isEmpty {
                ContentUnavailableView("No extra files found", systemImage: "checkmark.circle")
            }
            else {
                List {
                    if folder.folderType() == SushitrainFolderTypeSendReceive {
                        Text("Extra files have been found. Please decide for each file whether they should be synchronized or removed.").textFieldStyle(.plain)
                    }
                    else if folder.folderType() == SushitrainFolderTypeReceiveOnly {
                        Text("Extra files have been found. Because this is a receive-only folder, these files will not be synchronized.").textFieldStyle(.plain)
                    }
                    
                    Button("Remove all extra files", systemImage: "trash", role: .destructive) {
                        showCleanAll = true
                    }.confirmationDialog("Are you sure you want to delete \(unadressedExtraFiles.count) files? Files that are not synchronized to other device will be lost. This cannot be undone!", isPresented: $showCleanAll, titleVisibility: .visible, actions: {
                        Button("Remove \(unadressedExtraFiles.count) files from my device", role: .destructive) {
                            dismiss()
                            try? folder.cleanSelection()
                        }
                    }).foregroundColor(.red)
                    
                    ForEach(unadressedExtraFiles, id: \.self) { path in
                        let globalInfo = try? folder.getFileInformation(path)
                        let isAlsoGlobalFile = globalInfo != nil && !(globalInfo!.isDeleted())
                        Section {
                            Button(path) {
                                if let info = try? folder.getFileInformation(path) {
                                    var error: NSError? = nil
                                    let path = info.localNativePath(&error)
                                    if error == nil {
                                        self.localItemURL = URL(fileURLWithPath: path)
                                    }
                                }
                            }
                            
                            if isAlsoGlobalFile {
                                Button("Delete my copy of this file", systemImage: "trash", role: .destructive, action: {
                                    try! folder.deleteLocalFile(path)
                                    self.adressedPaths.insert(path)
                                }).foregroundColor(.red)
                            }
                            else {
                                Button("Permanently delete this file", systemImage: "trash", role: .destructive, action: {
                                    try! folder.deleteLocalFile(path)
                                    self.adressedPaths.insert(path)
                                }).foregroundColor(.red)
                            }
                            
                            if folder.folderType() == SushitrainFolderTypeSendReceive {
                                if isAlsoGlobalFile {
                                    Button("Synchronize file (overwrite existing)", systemImage: "rectangle.2.swap", action: {
                                        try! folder.setLocalFileExplicitlySelected(path, toggle: true)
                                        self.adressedPaths.insert(path)
                                    })
                                }
                                else {
                                    Button("Synchronize file", systemImage: "plus", action: {
                                        try! folder.setLocalFileExplicitlySelected(path, toggle: true)
                                        self.adressedPaths.insert(path)
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }.onAppear {
            extraFiles = try! folder.extraneousFiles().asArray().sorted()
        }
        .navigationTitle("Extra files in folder \(folder.label())")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview(self.$localItemURL)
    }
    
    
}
