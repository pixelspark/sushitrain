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
    @State private var isClearing = false
    @State private var selectedPaths: [String] = []
    @State private var showConfirmClearSelection = false
    
    var body: some View {
        Group {
            if isLoading || isClearing {
                ProgressView()
            }
            else if !selectedPaths.isEmpty {
                List {
                    let st = searchString.lowercased()
                    Section("Files kept on device") {
                        ForEach(selectedPaths.indices, id: \.self) { itemIndex in
                            let item = selectedPaths[itemIndex]
                            if st.isEmpty || item.lowercased().contains(st) {
                                SelectiveFileView(appState: appState, path: item, folder: folder, deselect: {
                                    self.deselectIndexes(IndexSet([itemIndex]))
                                })
                            }
                        }.onDelete { pathIndexes in
                            deselectIndexes(pathIndexes)
                        }.disabled(!folder.isIdleOrSyncing)
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
        
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Free up space", systemImage: "pin.slash", action: {
                    showConfirmClearSelection = true
                }).disabled(isClearing || isLoading)
                .help("Remove the files shown in the list from this device, but do not remove them from other devices.")
            }
        }
        .alert(isPresented: $showConfirmClearSelection) {
            Alert(
                title: Text("Free up space"),
                message: Text("This will remove all locally stored copies of files in this folder. Any files that are not also present on another device will be permanently lost and cannot be recovered. Are you sure yu want to continue?"),
                primaryButton: .destructive(Text("Remove files")) {
                    showConfirmClearSelection = false
                    self.clearSelection()
                },
                secondaryButton: .cancel() {
                    showConfirmClearSelection = false
                }
            )
        }
        .navigationBarBackButtonHidden(isClearing)
        
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
    
    private func clearSelection() {
        if searchString.isEmpty && !isClearing {
            isClearing = true
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
                DispatchQueue.main.async {
                    isClearing = false
                }
            }
            self.selectedPaths.removeAll()
        }
        else {
            self.deselectSearchResults()
        }
    }
    
    private func update() {
        do {
            self.isLoading = true
            self.selectedPaths = try self.folder.selectedPaths(true).asArray().sorted()
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

fileprivate struct SelectiveFileView: View {
    @ObservedObject var appState: AppState
    let path: String
    let folder: SushitrainFolder
    let deselect: () -> Void
    
    @State private var entry: SushitrainEntry? = nil
    @State private var fullyAvailableOnDevices: [SushitrainPeer]? = nil
    
    var body: some View {
        ZStack {
            if let file = self.entry {
                if !file.isDeleted() {
                    #if os(macOS)
                        HStack {
                            if let fa = self.fullyAvailableOnDevices {
                                Label(path, systemImage: file.systemImage).badge(fa.count)
                                
                                Spacer()
                                
                                if !fa.isEmpty {
                                    Button("Remove from this device, keep on \(fa.count) others", systemImage: "pin.slash") {
                                        self.deselect()
                                    }
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.red)
                                    .buttonStyle(.borderless)
                                }
                            }
                            else {
                                Label(path, systemImage: file.systemImage)
                            }
                        }
                        .contextMenu {
                            NavigationLink(destination: FileView(file: file, appState: self.appState)) {
                                Label("Properties...", systemImage: file.systemImage)
                            }
                        }
                    #else
                        NavigationLink(destination: FileView(file: file, appState: self.appState)) {
                            Label(path, systemImage: file.systemImage)
                        }
                    #endif
                }
                else {
                    Label(path, systemImage: file.systemImage).strikethrough()
                }
            }
        }
        .task {
            do {
                self.entry = try? folder.getFileInformation(path)
                if let fileEntry = self.entry {
                    let availability = try await Task.detached { [fileEntry] in
                        return (try fileEntry.peersWithFullCopy()).asArray()
                    }.value
                    
                    self.fullyAvailableOnDevices = availability.flatMap { devID in
                        if let p = self.appState.client.peer(withID: devID) {
                            return [p]
                        }
                        return []
                    }
                }
            }
            catch {
                print("Error fetching file info: \(error.localizedDescription)")
                self.entry = nil
            }
        }
    }
}
