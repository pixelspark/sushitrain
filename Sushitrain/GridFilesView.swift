// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

fileprivate struct GridItemView: View {
    @ObservedObject var appState: AppState
    let size: Double
    let file: SushitrainEntry

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailView(file: file, appState: appState)
            .frame(width: size, height: size)
            .contextMenu(menuItems: {
                Text(file.fileName())
            }, preview: {
                NavigationStack { // to force the image to take up all available space
                    VStack {
                        ThumbnailView(file: file, appState: appState)
                            .frame(minWidth: 240, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
                    }
                }
            })
        }
    }
}

struct GridFilesView: View {
    @ObservedObject var appState: AppState
    var prefix: String
    var files: [SushitrainEntry]
    var subdirectories: [SushitrainEntry]
    var folder: SushitrainFolder
    
    var body: some View {
        let gridColumns = Array(repeating: GridItem(.flexible()), count: appState.browserGridColumns)
        
        LazyVGrid(columns: gridColumns) {
            // List subdirectories
            ForEach(subdirectories, id: \.self) { (subDirEntry: SushitrainEntry) in
                GeometryReader { geo in
                    let fileName = subDirEntry.fileName()
                    NavigationLink(destination: BrowserView(
                        appState: appState,
                        folder: folder,
                        prefix: "\(self.prefix)\(fileName)/"
                    )) {
                        GridItemView(appState: appState, size: geo.size.width, file: subDirEntry)
                    }
                    .contextMenu(ContextMenu(menuItems: {
                        if let file = try? folder.getFileInformation(self.prefix + fileName) {
                            NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState)) {
                                Label("Subdirectory properties", systemImage: "folder.badge.gearshape")
                            }
                        }
                    }))
                }
                .aspectRatio(1, contentMode: .fit)
                .cornerRadius(8.0)
            }
            
            ForEach(files, id: \.self) { file in
                GeometryReader { geo in
                    NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState, siblings: [])) {
                        GridItemView(appState: appState, size: geo.size.width, file: file)
                    }
                }
                .cornerRadius(8.0)
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
