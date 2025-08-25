// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
@preconcurrency import SushitrainCore

struct ChangesView: View {
	private struct ChangeInfo: Identifiable, Hashable {
		var id: ObjectIdentifier {
			return change.id
		}

		var change: SushitrainChange
		var entry: SushitrainEntry?
		var folder: SushitrainFolder?
		var peer: SushitrainPeer?
	}

	@State private var changes: [ChangeInfo] = []
	@Environment(AppState.self) private var appState

	#if os(macOS)
		@State private var inspectedChange: ChangeInfo? = nil
		@State private var selectedChanges = Set<ChangeInfo.ID>()
		@SceneStorage("ChangesTableViewConfig") private var columnCustomization: TableColumnCustomization<ChangeInfo>
	#endif

	var body: some View {
		#if os(macOS)
			Table(changes, selection: $selectedChanges, columnCustomization: $columnCustomization) {
				TableColumn("") { change in
					Image(systemName: change.change.systemImage)
				}.width(min: 32, max: 32).customizationID("icon")

				TableColumn("Folder") { change in
					Text(change.folder?.displayName ?? "")
				}.width(ideal: 100).customizationID("folder")

				TableColumn("File") { change in
					Text(change.change.path)
				}.customizationID("file")

				TableColumn("Changed at") { change in
					if let dateString = change.change.time?.date()?.formatted() {
						Text(dateString)
					}
				}.width(ideal: 100).customizationID("date")

				TableColumn("Changed by") { change in
					if let peer = change.peer {
						if peer.deviceID() == appState.localDeviceID {
							Text("This device")
						}
						else {
							Text(peer.displayName)
						}
					}
				}.width(ideal: 100).customizationID("changingDevice")
			}
			.contextMenu(
				forSelectionType: ChangeInfo.ID.self,
				menu: { items in
					Text("\(items.count) selected")
				}, primaryAction: self.doubleClick
			)
			.task {
				await self.update()
			}
			.onChange(of: appState.lastChanges) { _, _ in
				Task {
					await self.update()
				}
			}
			.navigationTitle("Recent changes")
			.navigationDestination(item: $inspectedChange) { change in
				if let entry = change.entry {
					FileView(file: entry, showPath: true, siblings: nil)
				}
			}
		#else
			List {
				ForEach(changes, id: \.id) { change in
					if let folder = change.folder {
						if let entry = change.entry {
							NavigationLink(destination: FileView(file: entry, showPath: true, siblings: nil)) {
								self.changeDetails(change: change.change, folder: folder)
							}
						}
						else {
							self.changeDetails(change: change.change, folder: folder)
						}
					}
				}
			}
			.task {
				await self.update()
			}
			.onChange(of: appState.lastChanges) { _, _ in
				Task {
					await self.update()
				}
			}
			.navigationTitle("Recent changes")
		#endif
	}

	#if os(macOS)
		private func doubleClick(_ items: Set<ChangeInfo.ID>) {
			if let itemID = items.first, items.count == 1 {
				if let change = self.changes.first(where: { $0.id == itemID }) {
					self.inspectedChange = change
				}
			}
		}
	#endif

	private func update() async {
		self.changes = appState.lastChanges.map { change in
			let folder = appState.client.folder(withID: change.folderID)
			let entry = try? folder?.getFileInformation(change.path)
			let peer = appState.client.peer(withShortID: change.shortID)
			return ChangeInfo(
				change: change,
				entry: entry,
				folder: folder,
				peer: peer
			)
		}
	}

	@ViewBuilder private func changeDetails(change: SushitrainChange, folder: SushitrainFolder) -> some View {
		HStack {
			VStack(alignment: .leading) {
				Text("\(folder.displayName): \(change.path)")
					.multilineTextAlignment(.leading)
					.bold()

				if let dateString = change.time?.date()?.formatted() {
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
