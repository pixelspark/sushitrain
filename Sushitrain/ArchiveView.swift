// Copyright (C) 2025-2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct ArchiveView: View {
	let archive: SushitrainArchiveProtocol
	let prefix: String

	struct ArchiveFileName: Identifiable, Hashable {
		typealias ObjectIdentifier = String
		var name: String

		var id: ObjectIdentifier {
			return self.name
		}
	}

	@State private var loading: Bool? = nil
	@State private var error: String? = nil
	@State private var files: [ArchiveFileName] = []
	@State private var showDownloaderFor: ArchiveFileName? = nil

	#if os(macOS)
		@State private var inspectedFile: String? = nil
		@State private var selectedFiles = Set<ArchiveFileName.ID>()
		@SceneStorage("ZipTableViewConfig") private var columnCustomization: TableColumnCustomization<ArchiveFileName>
	#endif

	var body: some View {
		ZStack {
			if self.loading == nil || self.loading == true {
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
		#if os(macOS)
			.presentationSizing(.form.sticky())
			.frame(minWidth: 640, minHeight: 480)
		#endif
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.task {
			await Task(priority: .userInitiated) {
				await self.update()
			}.value
		}
	}

	#if os(macOS)
		@ViewBuilder private func tableBody() -> some View {
			Table(files, selection: $selectedFiles, columnCustomization: $columnCustomization) {
				TableColumn("File") { file in
					if archive.isDirectory(file.name) {
						let fileName = String(file.name.trimmingPrefix(self.prefix).trimmingPrefix("/"))
						Label(fileName.withoutEndingSlash, systemImage: "folder")
					}
					else {
						let fileName = String(file.name.trimmingPrefix(self.prefix).trimmingPrefix("/"))
						Label(fileName, systemImage: "doc.fill")
					}
				}
			}
			.contextMenu(
				forSelectionType: ArchiveFileName.ID.self,
				menu: { items in
					if items.count == 1 {
						Button("Download...", systemImage: "square.and.arrow.down") {
							showDownloaderFor = ArchiveFileName(name: items.first!)
						}
					}
					else {
						Text("\(items.count) selected")
					}
				}, primaryAction: self.doubleClick
			)
			.navigationDestination(item: $inspectedFile) { filePath in
				if archive.isDirectory(filePath) {
					ArchiveView(archive: archive, prefix: filePath)
				}
				else {
					ZipFileView(archive: archive, path: filePath)
				}
			}
			.sheet(item: $showDownloaderFor) { downloadFile in
				self.downloaderSheet(zipFileName: downloadFile)
			}
		}

		private func doubleClick(_ items: Set<ArchiveFileName.ID>) {
			if let fileName = items.first, items.count == 1 {
				self.inspectedFile = fileName
			}
		}

		@ViewBuilder private func downloaderSheet(zipFileName: ArchiveFileName) -> some View {
			if let downloadable = try? archive.file(zipFileName.name).asDownloadable() {
				NavigationStack {
					EntryDownloaderView(file: downloadable, action: .share)
						#if os(iOS)
							.navigationBarTitleDisplayMode(.inline)
						#endif
						.toolbar {
							SheetButton(role: .cancel) {
								showDownloaderFor = nil
							}
						}
				}
			}
		}
	#endif

	#if os(iOS)
		@ViewBuilder private func listBody() -> some View {
			List(files, id: \.self) { file in
				let fileName = String(file.name.trimmingPrefix(self.prefix))
				if archive.isDirectory(file.name) {
					NavigationLink(destination: ArchiveView(archive: self.archive, prefix: file.name)) {
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

	@concurrent private func update() async {
		dispatchPrecondition(condition: .notOnQueue(.main))
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
					ArchiveFileName(name: $0)
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
