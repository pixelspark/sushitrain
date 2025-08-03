// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct ZipView: View {
	let archive: SushitrainArchiveProtocol
	let prefix: String

	@State private var loading = false
	@State private var error: String? = nil
	@State private var files: [String] = []

	var body: some View {
		ZStack {
			if self.loading {
				ProgressView()
			}
			else if let e = self.error {
				ContentUnavailableView(e, systemImage: "exclamationmark.triangle")
			}
			else {
				// TODO: make this a Table on macOS
				List(files, id: \.self) { file in
					let fileName = file.dropFirst(self.prefix.count)
					if archive.isDirectory(file) {
						NavigationLink(destination: ZipView(archive: self.archive, prefix: file)) {
							Label(fileName, systemImage: "folder.fill")
						}
					}
					else {
						Label(fileName, systemImage: "doc.fill")
					}
				}
				#if os(macOS)
					.listStyle(.inset(alternatesRowBackgrounds: true))
				#endif
			}
		}
		.navigationTitle(self.archive.name() + " " + self.prefix)
		#if os(macOS)
			.frame(minWidth: 600, minHeight: 500)
		#endif
		.task {
			await Task.detached(priority: .userInitiated) {
				await self.update()
			}.value
		}
	}

	private nonisolated func update() async {
		let ar = await self.archive
		DispatchQueue.main.async {
			self.loading = true
			self.error = nil
		}

		do {
			let fs = (try ar.files(self.prefix)).asArray()
			DispatchQueue.main.async {
				self.files = fs.sorted()
			}
		}
		catch {
			DispatchQueue.main.async {
				self.loading = false
				self.error = error.localizedDescription
			}
		}
		DispatchQueue.main.async {
			self.loading = false
		}
	}
}
