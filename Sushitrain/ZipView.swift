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

	struct ZipFileName: Identifiable, Hashable {
		typealias ObjectIdentifier = String
		var name: String

		var id: ObjectIdentifier {
			return self.name
		}
	}

	@State private var loading = false
	@State private var error: String? = nil
	@State private var files: [ZipFileName] = []

	#if os(macOS)
		@State private var inspectedFile: String? = nil
		@State private var selectedFiles = Set<ZipFileName.ID>()
		@SceneStorage("ZipTableViewConfig") private var columnCustomization: TableColumnCustomization<ZipFileName>
	#endif

	var body: some View {
		ZStack {
			if self.loading {
				ProgressView()
			}
			else if let e = self.error {
				ContentUnavailableView(e, systemImage: "exclamationmark.triangle")
			}
			else {
				#if os(macOS)
					self.tableBody()
				#else
					self.listBody()
				#endif
			}
		}
		.navigationTitle(self.archive.name() + " " + self.prefix.withoutEndingSlash)
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		#if os(macOS)
			.frame(minWidth: 600, minHeight: 500)
			.presentationSizing(.fitted)
		#endif
		.task {
			await Task.detached(priority: .userInitiated) {
				await self.update()
			}.value
		}
	}

	#if os(macOS)
		@ViewBuilder private func tableBody() -> some View {
			Table(files, selection: $selectedFiles, columnCustomization: $columnCustomization) {
				TableColumn("File") { file in
					if archive.isDirectory(file.name) {
						let fileName = String(file.name.trimmingPrefix(self.prefix))
						Label(fileName.withoutEndingSlash, systemImage: "folder")
					}
					else {
						let fileName = String(file.name.trimmingPrefix(self.prefix))
						Label(fileName, systemImage: "doc.fill")
					}
				}
			}.contextMenu(
				forSelectionType: ZipFileName.ID.self,
				menu: { items in
					Text("\(items.count) selected")
				}, primaryAction: self.doubleClick
			)
			.navigationDestination(item: $inspectedFile) { filePath in
				if archive.isDirectory(filePath) {
					ZipView(archive: archive, prefix: filePath)
				}
				else {
					ZipFileView(archive: archive, path: filePath)
				}
			}
		}

		private func doubleClick(_ items: Set<ZipFileName.ID>) {
			if let fileName = items.first, items.count == 1 {
				self.inspectedFile = fileName
			}
		}
	#endif

	#if os(iOS)
		@ViewBuilder private func listBody() -> some View {
			List(files, id: \.self) { file in
				let fileName = String(file.name.trimmingPrefix(self.prefix))
				if archive.isDirectory(file.name) {
					NavigationLink(destination: ZipView(archive: self.archive, prefix: file.name)) {
						Label(fileName.withoutEndingSlash, systemImage: "folder.fill")
					}
				}
				else {
					NavigationLink(destination: ZipFileView(archive: self.archive, path: file.name)) {
						Label(fileName, systemImage: "doc.fill")
					}
				}
			}
		}
	#endif

	private nonisolated func update() async {
		let ar = await self.archive
		DispatchQueue.main.async {
			self.loading = true
			self.error = nil
		}

		do {
			let fs = (try ar.files(self.prefix)).asArray()
			DispatchQueue.main.async {
				self.files = fs.sorted(by: { a, b in
					if a.hasSuffix("/") && !b.hasSuffix("/") {
						return true
					}
					if b.hasSuffix("/") && !a.hasSuffix("/") {
						return false
					}
					return a < b
				}).map {
					ZipFileName(name: $0)
				}
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

private struct ZipFileView: View {
	let archive: SushitrainArchiveProtocol
	let path: String

	@State private var error: Error? = nil

	@State private var file: SushitrainDownloadableProtocol? = nil

	var body: some View {
		ZStack {
			if let e = error {
				ContentUnavailableView(
					"Could not view file", systemImage: "exclamationmark.triangle", description: Text(e.localizedDescription))
			}
			else if let file = file {
				EntryDownloaderView(file: file, action: .quickLook(dismissAfterClose: false))
			}
			else {
				EmptyView()
			}
		}
		#if os(macOS)
			.frame(minWidth: 500, minHeight: 400)
			.presentationSizing(.fitted)
		#endif
		.navigationTitle(path)
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.task {
			do {
				self.file = try archive.file(path).asDownloadable()
			}
			catch {
				self.error = error
			}
		}
	}
}
