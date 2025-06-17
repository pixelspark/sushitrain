// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
@preconcurrency import SushitrainCore

struct ChangesView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		List {
			ForEach(appState.lastChanges, id: \.id) { change in
				if let folder = appState.client.folder(withID: change.folderID) {
					if let entry = try? folder.getFileInformation(change.path), !entry.isDeleted() {
						NavigationLink(destination: FileView(file: entry, showPath: true, siblings: nil)) {
							self.changeDetails(change: change, folder: folder)
						}
					}
					else {
						self.changeDetails(change: change, folder: folder)
					}
				}
			}
		}
		.navigationTitle("Recent changes")
	}

	@ViewBuilder private func changeDetails(change: SushitrainChange, folder: SushitrainFolder) -> some View {
		HStack {
			VStack(alignment: .leading) {
				Text("\(folder.displayName): \(change.path)")
					.multilineTextAlignment(.leading)
					.bold()

				if let dateString = change.time?.date().formatted() {
					Text(dateString).dynamicTypeSize(.small)
						.foregroundColor(.gray)
				}

				if let peer = appState.client.peer(withShortID: change.shortID) {
					if peer.deviceID() == appState.localDeviceID {
						Text("By this device").dynamicTypeSize(.small)
							.foregroundColor(.gray)
					}
					else {
						Text("By \(peer.displayName)").dynamicTypeSize(
							.small
						).foregroundColor(.gray)
					}
				}
			}.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
			Image(systemName: change.systemImage)
		}
	}
}
