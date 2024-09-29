// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct ThumbnailView: View {
    var file: SushitrainEntry
    @ObservedObject var appState: AppState
    @State var showPreview = false
    
    var body: some View {
        if file.canThumbnail {
            if file.isLocallyPresent() {
                var error: NSError? = nil
                let localPath = file.isLocallyPresent() ? file.localNativePath(&error) : nil
                
                if let localPath = localPath {
                    #if os(iOS)
                    if let uiImage = UIImage(contentsOfFile: localPath) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 200)
                    }
                    #endif
                    
                    #if os(macOS)
                    if let uiImage = NSImage(contentsOfFile: localPath) {
                        Image(nsImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 200)
                    }
                    #endif
                }
            }
            else if showPreview || file.size() <= appState.maxBytesForPreview {
                CachedAsyncImage(cacheKey: file.blocksHash(), url: URL(string: file.onDemandURL())!, content: { phase in
                    switch phase {
                        case .empty:
                            HStack(alignment: .center, content: {
                                ProgressView()
                            })
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure(_):
                            Text("The file is currently not available for preview.")
                        @unknown default:
                            EmptyView()
                    }
                })
                .frame(maxWidth: .infinity, maxHeight: 200)
            }
            else {
                Button("Show preview for large files") {
                    showPreview = true
                }
            }
        }
        else {
            VStack(alignment: .center, spacing: 6.0, content: {
                Image(systemName: file.systemImage).dynamicTypeSize(.large)
                Text(file.fileName()).lineLimit(1).padding(.horizontal, 4)
            })
        }
    }
}
