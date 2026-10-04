// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

/// Shared by incoming documents and imports into the file browser.
enum FileImport {
	struct Failure: LocalizedError {
		let copiedURLs: [URL]
		let message: String
		var errorDescription: String? { message }
	}

	nonisolated static func copy(_ urls: [URL], folder: SushitrainFolder, prefix: String) throws -> Int {
		guard folder.exists(), !folder.isPaused(), !folder.isPhotoFolder, !folder.isReceiveEncryptedFolder else {
			throw CocoaError(.fileWriteNoPermission)
		}

		let isSelective = try folder.checkedIsSelective()

		// Find out the native location of our folder
		var error: NSError? = nil
		let localNativePath = folder.localNativePath(&error)
		if let error = error {
			throw error
		}

		// If we are in a subdirectory, and the folder is selective, ensure the folder is materialized
		if !prefix.isEmpty && isSelective {
			let entry = try folder.getFileInformation(prefix.withoutEndingSlash)
			if entry.isDirectory() && !entry.isDeleted() {
				try entry.materializeSubdirectory()
			}
			else {
				throw CocoaError(.fileWriteInvalidFileName)
			}
		}

		let localNativeURL = URL(fileURLWithPath: localNativePath).appendingPathComponent(
			prefix)
		var pathsToSelect: [String] = []

		if FileManager.default.fileExists(atPath: localNativeURL.path) {
			var copyErrors: [String] = []
			var copiedURLs: [URL] = []
			for url in urls {
				do {
					let targetURL = localNativeURL.appendingPathComponent(url.lastPathComponent)
					try FileImportCopy.copy(url, to: targetURL)
					copiedURLs.append(url)

					// Select the dropped file
					if isSelective {
						let localURL = (prefix.withoutEndingSlash + "/" + url.lastPathComponent).withoutStartingSlash
						pathsToSelect.append(localURL)
					}
				}
				catch {
					Log.warn("failed to copy a dropped file: \(error)")
					copyErrors.append(url.lastPathComponent + ": " + error.localizedDescription)
				}
			}

			do {
				if isSelective && !pathsToSelect.isEmpty {
					try folder.setLocalPathsExplicitlySelected(SushitrainListOfStrings.from(pathsToSelect))
				}
				try folder.rescanSubdirectory(prefix)
			}
			catch {
				throw Failure(copiedURLs: copiedURLs, message: error.localizedDescription)
			}

			if !copyErrors.isEmpty {
				throw Failure(copiedURLs: copiedURLs, message: copyErrors.joined(separator: "\n"))
			}
			return copiedURLs.count
		}

		throw CocoaError(.fileNoSuchFile)
	}

}

/// Owns sandbox access while the destination sheet is open, including during startup.
@Observable @MainActor final class IncomingFiles {
	private(set) var urls: [URL] = []
	@ObservationIgnored private var scopedURLs: Set<URL> = []
	var isSaving = false
	var error: String?

	deinit {
		for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
	}

	func receive(_ url: URL) {
		guard url.isFileURL, !urls.contains(url) else { return }
		if url.startAccessingSecurityScopedResource() { scopedURLs.insert(url) }
		urls.append(url)
	}

	func remove(_ completed: [URL]) {
		for url in completed {
			if scopedURLs.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
		}
		urls.removeAll { completed.contains($0) }
	}
}

struct IncomingFilesModifier: ViewModifier {
	@Environment(AppState.self) private var appState
	@State private var incoming = IncomingFiles()

	func body(content: Content) -> some View {
		content
			.onOpenURL { incoming.receive($0) }
			.sheet(
				isPresented: Binding(
					get: { appState.startupState == .started && (!incoming.urls.isEmpty || incoming.error != nil) },
					set: {
						if !$0 && !incoming.isSaving {
							incoming.remove(incoming.urls)
							incoming.error = nil
						}
					}
				)
			) {
				IncomingFilesView(incoming: incoming)
			}
	}
}

#if os(macOS)
	/// One import window receives all files, even with no browser window open.
	struct IncomingFilesWindow: View {
		@Environment(AppState.self) private var appState
		@Environment(\.dismissWindow) private var dismissWindow
		let incoming: IncomingFiles

		var body: some View {
			Group {
				if appState.startupState == .started {
					IncomingFilesView(incoming: incoming)
				}
				else {
					ProgressView().frame(width: 440, height: 400)
				}
			}
			.windowDismissBehavior(incoming.isSaving ? .disabled : .enabled)
			.onChange(of: incoming.urls.isEmpty) { _, empty in
				if empty && incoming.error == nil { dismissWindow(id: "import") }
			}
			.onChange(of: incoming.error) { _, error in
				if error == nil && incoming.urls.isEmpty { dismissWindow(id: "import") }
			}
			.onDisappear {
				if !incoming.isSaving {
					incoming.remove(incoming.urls)
					incoming.error = nil
				}
			}
		}
	}
#endif

private struct IncomingFilesView: View {
	@Environment(AppState.self) private var appState
	let incoming: IncomingFiles
	@State private var folders: [SushitrainFolder] = []
	@State private var folderID = ""
	@State private var prefix = ""
	@State private var directories: [String] = []
	@State private var loading = true

	private var folder: SushitrainFolder? { folders.first { $0.folderID == folderID } }

	var body: some View {
		NavigationStack {
			Form {
				Section {
					ForEach(incoming.urls, id: \.self) { url in
						Label(url.lastPathComponent, systemImage: "doc")
					}
				} header: {
					Text("Files to import")
				}
				Section {
					Picker("Folder", selection: $folderID) {
						Text("Select a folder").tag("")
						ForEach(folders, id: \.folderID) { folder in
							Text(folder.displayName).tag(folder.folderID)
						}
					}
					if folder != nil {
						LabeledContent("Subdirectory", value: prefix.isEmpty ? "/" : prefix)
						if !prefix.isEmpty {
							Button("Enclosing directory", systemImage: "arrow.up") {
								loading = true
								prefix = prefix.split(separator: "/").dropLast().joined(separator: "/")
								if !prefix.isEmpty { prefix += "/" }
							}
						}
						ForEach(loading ? [] : directories, id: \.self) { name in
							Button {
								loading = true
								prefix += name.withoutEndingSlash + "/"
							} label: {
								Label(name.withoutEndingSlash, systemImage: "folder")
							}
							#if os(macOS)
								.buttonStyle(.link)
							#endif
						}
					}
					if loading {
						ProgressView()
					}
					else if folders.isEmpty {
						Text("No folders are available for importing files.")
					}
				} header: {
					Text("Save to")
				}
				if incoming.isSaving { ProgressView("Saving files…") }
			}
			.formStyle(.grouped)
			.disabled(incoming.isSaving)
			.navigationTitle("Import files")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") {
						incoming.remove(incoming.urls)
						incoming.error = nil
					}.disabled(incoming.isSaving)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") { save() }
						.disabled(folder == nil || loading || incoming.isSaving || incoming.urls.isEmpty)
				}
			}
			.alert(
				"Cannot import files",
				isPresented: Binding(
					get: { incoming.error != nil }, set: { if !$0 { incoming.error = nil } }
				)
			) {
				Button("OK") { incoming.error = nil }
			} message: {
				Text(incoming.error ?? "")
			}
		}
		.interactiveDismissDisabled(incoming.isSaving)
		#if os(macOS)
			.frame(minWidth: 440, idealWidth: 500, minHeight: 400, idealHeight: 550)
		#endif
		.task {
			folders = await appState.folders().filter {
				$0.exists() && !$0.isPaused() && !$0.isPhotoFolder && !$0.isReceiveEncryptedFolder && $0.localNativeURL != nil
			}.sorted()
			loading = false
		}
		.onChange(of: folderID) {
			prefix = ""
			directories = []
			loading = !folderID.isEmpty
		}
		.task(id: folderID + ":" + prefix) { await loadDirectories() }
	}

	private func loadDirectories() async {
		directories = []
		guard let folder else { return }
		loading = true
		defer { if !Task.isCancelled { loading = false } }
		let requestedPrefix = prefix
		do {
			let names = try await Task.detached(priority: .utility) {
				try folder.list(requestedPrefix, directories: true, recurse: false).asArray().sorted()
			}.value
			guard !Task.isCancelled else { return }
			directories = names
		}
		catch { if !Task.isCancelled { incoming.error = error.localizedDescription } }
	}

	private func save() {
		guard let folder else { return }
		let urls = incoming.urls
		let destination = prefix
		incoming.isSaving = true
		Task {
			defer { incoming.isSaving = false }
			do {
				_ = try await Task.detached(priority: .utility) {
					try FileImport.copy(urls, folder: folder, prefix: destination)
				}.value
				incoming.remove(urls)
			}
			catch let failure as FileImport.Failure {
				incoming.error = failure.localizedDescription
				incoming.remove(failure.copiedURLs)
			}
			catch { incoming.error = error.localizedDescription }
		}
	}
}
