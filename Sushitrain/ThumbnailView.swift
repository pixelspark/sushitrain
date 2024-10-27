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
            let isLocallyPresent = file.isLocallyPresent()
            if isLocallyPresent || showPreview || file.size() <= appState.maxBytesForPreview {
                let url = isLocallyPresent ? file.localNativeFileURL! : URL(string: file.onDemandURL())!
                    
                ThumbnailImage(cacheKey: file.blocksHash(), url: url, content: { phase in
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
                #if os(macOS)
                    .buttonStyle(.link)
                #endif
            }
        }
        else {
            VStack(alignment: .center, spacing: 6.0, content: {
                Image(systemName: file.systemImage)
                    .dynamicTypeSize(.large)
                    .foregroundStyle(Color.accentColor)
                Text(file.fileName())
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
            })
        }
    }
}
