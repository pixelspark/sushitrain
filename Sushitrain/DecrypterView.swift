// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

#if os(macOS)
	struct DecrypterView: View {
		private enum PickerFor {
			case source
			case dest
		}

		// The 'showPicker' variable controls fileImporter visibility, and showPickerFor decides what it is picking for.
		// We can't just use Binding.isNotNull(showPickerFor) for fileImporter visibility, because it is set to nil before
		// the callback is able to determine its value.
		@State private var showPickerFor: PickerFor? = nil
		@State private var showPicker: Bool = false

		@State private var error: Error? = nil
		@State private var loading: Bool = false
		@State private var sourceURL: URL? = nil
		@State private var sourceURLAccessor: BookmarkManager.Accessor? = nil
		@State private var allEntries: [EncryptedFileEntry] = []
		@State private var foundEntries: [EncryptedFileEntry] = []
		@State private var folderID: String = ""
		@State private var folderPassword: String = ""
		@State private var searchText: String = ""
		@State private var destURL: URL? = nil
		@State private var selectedDecryptedPaths: Set<String> = []
		@State private var showSuccessMessage = false
		@State private var keepFolderStructure = true

		var body: some View {
			HStack {
				HSplitView {
					// Left pane: Encryption settings
					Form {
						Section("Encrypted folder") {
							LabeledContent("Folder") {
								HStack {
									Text(sourceURL?.lastPathComponent ?? "")
									Button("Select...") {
										showPickerFor = .source
										showPicker = true
									}
								}
							}

							LabeledContent("Folder ID") {
								TextField("", text: $folderID).textFieldStyle(.roundedBorder)
							}

							LabeledContent("Encryption password") {
								TextField("", text: $folderPassword).textFieldStyle(.roundedBorder).textContentType(.password)
							}

							Button("Decrypt file list") {
								self.refresh()
							}
							.disabled(folderPassword.isEmpty || folderID.isEmpty || sourceURL == nil)
						}

						Section("\(selectedDecryptedPaths.count) files selected") {
							LabeledContent("Folder") {
								HStack {
									Text(destURL?.lastPathComponent ?? "")
									Button("Select...") {
										showPickerFor = .dest
										showPicker = true
									}
								}
							}

							Toggle(isOn: $keepFolderStructure) {
								Text("Recreate folder structure")
							}

							Button("Decrypt \(selectedDecryptedPaths.count) files") {
								Task {
									await self.decryptSelection()
								}
							}.disabled(destURL == nil)
						}.disabled(folderPassword.isEmpty || folderID.isEmpty || sourceURL == nil || selectedDecryptedPaths.isEmpty)
					}
					.formStyle(.grouped)
					.disabled(loading)
					.frame(minWidth: 250, idealWidth: 250, maxWidth: 320, maxHeight: .infinity)

					// Right pane
					Group {
						if loading {
							ProgressView()
						}
						else if let e = error {
							ContentUnavailableView {
								Label("Could not decrypt folder", systemImage: "exclamationmark.triangle.fill")
							} description: {
								Text(e.localizedDescription)
							}
						}
						else if sourceURL != nil && !folderID.isEmpty && !folderPassword.isEmpty {
							// List of files
							DecrypterItemsView(
								folderID: folderID, folderPassword: folderPassword,
								entries: searchText.isEmpty ? allEntries : foundEntries,
								selectedDecryptedPaths: $selectedDecryptedPaths
							)
							.id(searchText)
						}
						else {
							ContentUnavailableView {
								Label("No encrypted folder selected", systemImage: "questionmark.folder")
							}
						}
					}.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.fileImporter(isPresented: $showPicker, allowedContentTypes: [.directory]) { (result) in
					switch (result, showPickerFor) {
					case (.success(let url), .source):
						self.sourceURL = url
						self.error = nil
						if self.folderID.isEmpty {
							self.folderID = url.lastPathComponent
						}
					case (.success(let url), .dest):
						self.destURL = url
						self.error = nil
					case (.failure(let err), .source):
						self.sourceURL = nil
						self.error = err
					case (.failure(_), .dest):
						self.destURL = nil
					default:
						break
					}
					self.showPicker = false
					self.showPickerFor = nil
				}
				.navigationTitle(self.sourceURL?.lastPathComponent ?? String(localized: "Decrypt folder"))
				.searchable(text: $searchText, prompt: "Zoek bestand...")
				.onChange(of: sourceURL) { (_, _) in
					self.refresh()
				}
				.onChange(of: searchText) { (_, _) in
					self.updateSearch()
				}
				.alert("Decryption completed", isPresented: $showSuccessMessage) {
					Button("OK") {}
				}
			}
		}

		private func enumerate(
			fileManager: FileManager, url: URL, folderKey: SushitrainFolderKey, entries: inout [EncryptedFileEntry]
		) async throws {
			let children = try fileManager.contentsOfDirectory(
				at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
			for c in children {
				if let isDir = (try c.resourceValues(forKeys: [.isDirectoryKey])).isDirectory, isDir {
					// Recurse into directories
					try await enumerate(fileManager: fileManager, url: c, folderKey: folderKey, entries: &entries)
				}
				else {
					// Append leafs to our list, ignoring files like .DS_Store
					if c.lastPathComponent.hasPrefix(".") {
						continue
					}
					let rootPath = self.sourceURL!.path(percentEncoded: false)
					let filePath = c.path(percentEncoded: false)
					var error: NSError? = nil
					let trimmedPath = String(filePath.trimmingPrefix(rootPath))
					if trimmedPath.starts(with: ".stfolder") {
						continue
					}
					let decryptedPath = folderKey.decryptedFilePath(trimmedPath, error: &error)
					if let e = error {
						throw e
					}
					entries.append(EncryptedFileEntry(decryptedPath: decryptedPath, url: c))
				}
			}
		}

		private func decryptSelection() async {
			if self.loading {
				return
			}
			self.loading = true
			let folderID = self.folderID
			let folderPassword = self.folderPassword
			let destURL = self.destURL
			let selectedDecryptedPaths = self.selectedDecryptedPaths
			let sourceURL = self.sourceURL
			let keepFolderStructure = self.keepFolderStructure
			let entries = self.allEntries

			await Task.detached(priority: .userInitiated) {
				do {
					// Keep a bookmark accessor alive whle we write files to the destination URL
					try withExtendedLifetime(try BookmarkManager.Accessor(url: destURL!)) {
						let folderKey = SushitrainNewFolderKey(folderID, folderPassword)
						for entry in entries {
							if !selectedDecryptedPaths.contains(entry.decryptedPath) {
								continue
							}

							let rootPath = sourceURL!.path(percentEncoded: false)
							let filePath = entry.url.path(percentEncoded: false)
							let trimmedPath = String(filePath.trimmingPrefix(rootPath))
							Log.info("Decrypt \(trimmedPath) \(sourceURL!) \(destURL!)")
							try folderKey?.decryptFile(
								sourceURL?.path(percentEncoded: false), encryptedPath: trimmedPath,
								destRoot: destURL?.path(percentEncoded: false),
								keepFolderStructure: keepFolderStructure
							)
						}
					}
					Task { @MainActor in
						self.showSuccessMessage = true
					}
				}
				catch {
					Task { @MainActor in
						self.error = error
					}
				}
			}.value

			self.loading = false
		}

		private func refresh() {
			if self.loading {
				return
			}

			Task {
				self.loading = true
				do {
					self.error = nil
					try await Task.detached {
						try await self.update()
					}.value
				}
				catch {
					self.error = error
				}
				self.loading = false
			}
		}

		private func updateSearch() {
			self.foundEntries = self.allEntries.filter {
				$0.decryptedPath.lowercased().contains(self.searchText.lowercased())
			}
		}

		private func update() async throws {
			if let u = sourceURL {
				self.sourceURLAccessor = try BookmarkManager.Accessor(url: u)

				let fm = FileManager.default
				self.allEntries = []
				self.foundEntries = []
				var re: [EncryptedFileEntry] = []

				let folderKey = SushitrainNewFolderKey(self.folderID, self.folderPassword)!
				try await self.enumerate(fileManager: fm, url: u, folderKey: folderKey, entries: &re)

				re.sort {
					return $0.decryptedPath < $1.decryptedPath
				}
				self.allEntries = re
				self.updateSearch()
			}
			else {
				self.sourceURLAccessor = nil
				self.allEntries = []
			}
		}
	}

	private struct EncryptedFileEntry: Identifiable, Sendable {
		var id: String {
			return self.url.absoluteString
		}

		var decryptedPath: String
		var url: URL
	}

	private struct DecrypterItemsView: View {
		let folderID: String
		let folderPassword: String
		let entries: [EncryptedFileEntry]
		@State private var decryptedPaths: [String] = []

		@Binding var selectedDecryptedPaths: Set<String>

		var body: some View {
			List(selection: $selectedDecryptedPaths) {
				PathsOutlineGroup(paths: decryptedPaths, disableIntermediateSelection: true) { decryptedPath, isIntermediate in
					Text(decryptedPath.lastPathComponent)
				}
			}
			.task {
				await self.update()
			}
		}

		private func update() async {
			self.decryptedPaths = self.entries.map { $0.decryptedPath }
		}
	}

#endif
