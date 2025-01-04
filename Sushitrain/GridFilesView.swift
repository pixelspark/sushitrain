// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

fileprivate struct GridItemView: View {
    let appState: AppState
    let size: Double
    let file: SushitrainEntry

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .frame(width: size, height: size)
                .backgroundStyle(Color.primary)
                .opacity(0.05)
            
            ThumbnailView(file: file, appState: appState, showFileName: true, showErrorMessages: false)
                .frame(width: size, height: size)
                .id(file.id)
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
            ForEach(subdirectories, id: \.self.id) { (subDirEntry: SushitrainEntry) in
                GeometryReader { geo in
                    let fileName = subDirEntry.fileName()
                    NavigationLink(destination: BrowserView(
                        appState: appState,
                        folder: folder,
                        prefix: "\(self.prefix)\(fileName)/"
                    )) {
                        GridItemView(appState: appState, size: geo.size.width, file: subDirEntry)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu(ContextMenu(menuItems: {
                        if let file = try? folder.getFileInformation(self.prefix + fileName) {
                            NavigationLink(destination: FileView(file: file, appState: self.appState)) {
                                Label("Subdirectory properties", systemImage: "folder.badge.gearshape")
                            }
                            
                            ItemSelectToggleView(file: file)
                        }
                    }))
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerSize: CGSize(width: 8.0, height: 8.0)))
            }
            
            // List files
            ForEach(files, id: \.self) { file in
                GeometryReader { geo in
                    FileEntryLink(appState: appState, entry: file, siblings: files) {
                        GridItemView(appState: appState, size: geo.size.width, file: file)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .clipShape(.rect(cornerSize: CGSize(width: 8.0, height: 8.0)))
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
