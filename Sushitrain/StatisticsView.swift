// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct TotalStatisticsView: View {
	@Environment(AppState.self) private var appState
	@State private var stats: SushitrainFolderStats? = nil
	@State private var diskSpaceFree: Int64? = nil
	@State private var diskSpaceTotal: Int64? = nil

	var body: some View {
		let formatter = ByteCountFormatter()

		Form {
			if let stats = stats {
				if let global = stats.global {
					Section("All devices") {
						Text("Number of files").badge(global.files)
						Text("Number of directories").badge(global.directories)
						Text("File size").badge(formatter.string(fromByteCount: global.bytes))
					}
				}

				if let local = stats.local {
					Section("This device") {
						Text("Number of files").badge(local.files)
						Text("Number of directories").badge(local.directories)
						Text("File size").badge(formatter.string(fromByteCount: local.bytes))
					}
				}

				if let free = self.diskSpaceFree, let total = self.diskSpaceTotal {
					Section {
						Text("Available disk space").badge(formatter.string(fromByteCount: free))
						Text("Total disk space").badge(formatter.string(fromByteCount: total))
					} footer: {
						Text(
							"The above numbers concern the disk the Synctrain database is stored on. If these values do not match those shown by the Settings app, restarting the device may help."
						)
					}
				}
			}
		}
		.task {
			if self.appState.startupState != .started {
				self.stats = nil
				return
			}
			self.stats = try? self.appState.client.statistics()

			self.diskSpaceFree = Int64(SushitrainGetFreeDiskSpaceMegaBytes()) * 1024 * 1024
			self.diskSpaceTotal = Int64(SushitrainGetTotalDiskSpaceMegaBytes()) * 1024 * 1024
		}
		.navigationTitle("Statistics")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.formStyle(.grouped)
		#endif
	}
}
