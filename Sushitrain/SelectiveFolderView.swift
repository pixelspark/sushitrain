// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

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
                            ForEach(selectedPaths.indices, id: \.self) { itemIndex in
                                let item = selectedPaths[itemIndex]
                                if st.isEmpty || item.lowercased().contains(st) {
                                    #if os(macOS)
                                        let maybeFile = try? folder.getFileInformation(item)
                                        HStack {
                                            Label(item, systemImage: maybeFile?.systemImage ?? "pin")
                                            Spacer()
                                            
                                            Button("Delete", systemImage: "pin.slash") {
                                                self.deselectIndexes(IndexSet([itemIndex]))
                                            }
                                            .labelStyle(.iconOnly)
                                            .foregroundStyle(.red)
                                            .buttonStyle(.borderless)
                                        }
                                        .contextMenu {
                                            if let file = maybeFile {
                                                NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState)) {
                                                    Label("Properties...", systemImage: file.systemImage)
                                                }
                                            }
                                        }
                                    #elseif os(iOS)
                                        if let file = try? folder.getFileInformation(item) {
                                            NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState)) {
                                                Label(item, systemImage: file.systemImage)
                                            }
                                        }
                                        else {
                                            Label(item, systemImage: "pin")
                                        }
                                    #endif
                                }
                            }.onDelete { pathIndexes in
                                deselectIndexes(pathIndexes)
                            }.disabled(!folder.isIdleOrSyncing)
                        }
                    }
                    
                    Section {
                        Button("Free up space", systemImage: "pin.slash", action: {
                            if searchString.isEmpty {
                                Task.detached {
                                    do {
                                        try folder.clearSelection()
                                    }
                                    catch let error {
                                        DispatchQueue.main.async {
                                            showError = true
                                            errorText = error.localizedDescription
                                        }
                                    }
                                }
                                self.selectedPaths.removeAll()
                            }
                            else {
                                self.deselectSearchResults()
                            }
                        })
                        .help("Remove the files shown in the list from this device, but do not remove them from other devices.")
                        #if os(macOS)
                            .buttonStyle(.link)
                        #endif
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
        
        #if os(iOS)
            .navigationTitle("Selected files")
            .navigationBarTitleDisplayMode(.inline)
        #endif
        
        #if os(macOS)
            .navigationTitle("Files kept on this device in '\(self.folder.displayName)'")
        #endif
        
        .searchable(text: $searchString, prompt: "Search files by name...")
        .task {
            self.update()
        }
    }
    
    private func update() {
        do {
            self.isLoading = true
            self.selectedPaths = try self.folder.selectedPaths().asArray().sorted()
        }
        catch {
            self.errorText = error.localizedDescription
            self.showError = true
            self.selectedPaths = []
        }
        self.isLoading = false
    }
    
    private func deselectSearchResults() {
        do {
            let st = searchString.lowercased()
            let verdicts = self.selectedPaths.filter { item in
                return st.isEmpty || item.lowercased().contains(st)
            }.reduce(into: [:]) { dict, p in
                dict[p] = false
            }
            let json = try JSONEncoder().encode(verdicts)
            try folder.setExplicitlySelectedJSON(json)
            Task {
                self.update()
            }
        }
        catch {
            Log.warn("Could not deselect: \(error.localizedDescription)")
        }
    }
    
    private func deselectIndexes(_ pathIndexes: IndexSet) {
        do {
            let verdicts = pathIndexes.map({idx in selectedPaths[idx]}).reduce(into: [:]) { dict, p in
                dict[p] = false
            }
            let json = try JSONEncoder().encode(verdicts)
            try folder.setExplicitlySelectedJSON(json)
            
            selectedPaths.remove(atOffsets: pathIndexes)
        }
        catch {
            Log.warn("Could not deselect: \(error.localizedDescription)")
        }
    }
}
