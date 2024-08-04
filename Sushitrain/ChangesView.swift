// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI

struct ChangesView: View {
    @ObservedObject var appState: AppState
    var body: some View {
        List {
            ForEach(appState.lastChanges, id: \.id) { change in
                if let folder = appState.client.folder(withID: change.folderID) {
                    VStack(alignment: .leading) {
                        Label(
                            "\(folder.displayName): \(change.path)",
                            systemImage: change.systemImage
                        )
                        if let dateString = change.time?.date().formatted() {
                            Text(dateString).dynamicTypeSize(.small).foregroundColor(.gray)
                        }
                        
                        if let peer = appState.client.peer(withShortID: change.shortID) {
                            if peer.deviceID() == appState.localDeviceID {
                                Text("By this device").dynamicTypeSize(.small).foregroundColor(.gray)
                            }
                            else {
                                Text("By \(peer.label)").dynamicTypeSize(.small).foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recent changes")
    }
}
