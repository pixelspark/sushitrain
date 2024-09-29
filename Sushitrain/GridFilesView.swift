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
        }
    }
}

struct GridFilesView: View {
    private static let initialColumns = 3
    @State private var gridColumns = Array(repeating: GridItem(.flexible()), count: initialColumns)
    @State private var numColumns = initialColumns
    
    @ObservedObject var appState: AppState
    var files: [SushitrainEntry]
    var folder: SushitrainFolder
    
    var body: some View {
        LazyVGrid(columns: gridColumns) {
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
