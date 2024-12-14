// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct UploadView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        List {
            if let uploadingToPeers = appState.client.uploadingToPeers() {
                if uploadingToPeers.count() == 0 {
                    ContentUnavailableView("Not uploading",
                       systemImage: "pause.circle",
                       description: Text("Currently no files are being sent to other devices.")
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                else {
                    // Grouped by peers we are uploading to
                    ForEach(uploadingToPeers.asArray(), id: \.self) { peerID in
                        if let peer = appState.client.peer(withID: peerID) {
                            Section(peer.displayName) {
                                if let uploadingFolders = appState.client.uploadingFolders(forPeer: peerID) {
                                    
                                    // For each folder we are uploading files from to this peer
                                    ForEach(uploadingFolders.asArray(), id: \.self) { folderID in
                                        if let folder = appState.client.folder(withID: folderID) {
                                            if let uploadingFiles = appState.client.uploadingFiles(forPeerAndFolder: peerID, folderID: folderID) {
                                                
                                                // For each file that is being uploaded...
                                                ForEach(uploadingFiles.asArray(), id: \.self) { filePath in
                                                    if let progress = appState.client.uploadProgress(forPeerFolderPath: peerID, folderID: folderID, path: filePath) {
                                                        ProgressView(value: progress.percentage, total: 1.0) {
                                                            Label("\(folder.displayName): \(filePath)", systemImage: "arrow.up")
                                                                .foregroundStyle(.green)
                                                                .symbolEffect(.pulse, value: true)
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                .multilineTextAlignment(.leading)
                                                        }.tint(.green)
                                                    }
                                                    else {
                                                        Text("\(folder.displayName): \(filePath)")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Sending files")
    }
}
