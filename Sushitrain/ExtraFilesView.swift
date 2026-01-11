// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import QuickLook

struct ExtraFilesView: View {
	private static let conflictFileMarker = ".sync-conflict"

	var folder: SushitrainFolder
	@Environment(AppState.self) private var appState
	@Environment(\.showToast) private var showToast

	@State private var extraFiles: [String] = []
	@Environment(\.dismiss) private var dismiss
	@State private var verdicts: [String: Bool] = [:]
	@State private var allVerdict: Bool? = nil
	@State private var errorMessage: String? = nil
	@State private var showApplyConfirmation = false
	@State private var showConflictFiles = false
	@State private var hasConflictFiles = false

	var body: some View {
		Group {
			if extraFiles.isEmpty {
				ContentUnavailableView("No extra files found", systemImage: "checkmark.circle")
			}
			else {
				List {
					Section {
						if folder.folderType() == SushitrainFolderTypeSendReceive {
							Text("Extra files have been found. Please decide for each file whether they should be synchronized or removed.")
								.textFieldStyle(.plain)
						}
						else if folder.folderType() == SushitrainFolderTypeReceiveOnly {
							Text("Extra files have been found. Because this is a receive-only folder, these files will not be synchronized.")
								.textFieldStyle(.plain)
						}
					}

					Section {
						HStack {
							VStack(alignment: .leading) { Text("For all files").multilineTextAlignment(.leading) }.frame(
								maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

							Picker(
								"Action",
								selection: Binding(
									get: { return allVerdict },
									set: { s in
										allVerdict = s
										for f in extraFiles { verdicts[f] = s }
									})
							) {
								Image(systemName: "trash").tint(.red).tag(false).help("Delete file")
								if folder.folderType() == SushitrainFolderTypeReceiveOnly {
									Image(systemName: "trash.slash").tag(true).help("Keep file")
								}
								else {
									Image(systemName: "plus.square.fill").tag(true).help("Keep file")
								}
							}
							.pickerStyle(.segmented)
							.frame(width: 100)
							.labelsHidden()
						}
					}

					Section {
						PathsOutlineGroup(paths: extraFiles, disableIntermediateSelection: false) { path, isIntermediate in
							if !isIntermediate {
								ExtraFileView(
									path: path, folder: folder,
									verdict: Binding(
										get: {
											return verdicts[path]
										},
										set: { s in
											verdicts[path] = s
											allVerdict = nil
										}))
							}
							else {
								ExtraSubdirectoryView(path: path, folder: folder, onChange: self.onChangeSubdirectory)
							}
						}
					}

					if hasConflictFiles && !showConflictFiles {
						Button("Show conflicted files") {
							self.showConflictFiles = true
						}
					}
				}
			}
		}
		.refreshable {
			Task {
				await reload()
			}
		}
		.contextMenu {
			Button("Refresh", systemImage: "arrow.clockwise") {
				Task {
					await reload()
				}
			}
		}
		.task {
			await reload()
		}
		.navigationTitle("Extra files in folder \(folder.label())")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.toolbar {
			ToolbarItem(
				placement: .confirmationAction,
				content: {
					Button("Apply") {
						showApplyConfirmation = true
					}
					.disabled(!folder.isIdleOrSyncing || verdicts.isEmpty || extraFiles.isEmpty)
					.confirmationDialog(
						"Are you sure you want to permanently delete \(deleteCount) files from this device, and add \(keepCount) files for synchronization with other devices?",
						isPresented: $showApplyConfirmation,
						titleVisibility: .visible
					) {
						if deleteCount > 0 {
							Button("Delete \(deleteCount) files, keep \(keepCount) files", role: .destructive) {
								Task { await self.apply() }
							}
						}
						else {
							Button("Keep \(keepCount) files") {
								Task { await self.apply() }
							}
						}
					}
				})
		}
		.alert(isPresented: Binding.isNotNil($errorMessage)) {
			Alert(
				title: Text("An error occurred"), message: Text(errorMessage ?? ""),
				dismissButton: .default(Text("OK")) { errorMessage = nil })
		}
	}

	private func onChangeSubdirectory(_ prefix: String, _ verdict: SubdirectoryVerdict) {
		let prefixWithSlash = prefix.withoutEndingSlash + "/"
		for path in self.extraFiles where path.hasPrefix(prefixWithSlash) {
			switch verdict {
			case .keepAllChildren:
				self.verdicts[path] = true
			case .deleteAllChildren:
				self.verdicts[path] = false
			case .addSubdirectory:
				self.verdicts.removeValue(forKey: path)
			}
		}

		switch verdict {
		case .addSubdirectory:
			do {
				let json = try JSONEncoder().encode([
					prefix.withoutEndingSlash: true
				])
				try folder.setExplicitlySelectedJSON(json)
				Task {
					showToast(Toast(title: "Subdirectory will be kept on this device", image: "folder.fill.badge.plus"))
					await self.reload()
				}
			}
			catch {
				self.errorMessage = error.localizedDescription
			}

		case .keepAllChildren, .deleteAllChildren:
			break
		}
	}

	private var keepCount: Int {
		var count = 0
		for (_, i) in self.verdicts {
			if i {
				count += 1
			}
		}
		return count
	}

	private var deleteCount: Int {
		var count = 0
		for (_, i) in self.verdicts {
			if !i {
				count += 1
			}
		}
		return count
	}

	private func apply() async {
		do {
			var currentVerdicts: [String: Bool] = [:]
			var numKeeping = 0
			var numRemoving = 0

			for path in extraFiles {
				if let verdict = verdicts[path] {
					currentVerdicts[path] = verdict
					if verdict {
						numKeeping += 1
					}
					else {
						numRemoving += 1
					}
				}
			}

			let json = try JSONEncoder().encode(currentVerdicts)
			try folder.setExplicitlySelectedJSON(json)
			verdicts = [:]
			allVerdict = nil
			showToast(
				Toast(title: "Keeping \(numKeeping), removing \(numRemoving) files", image: "plus.square.fill.on.square.fill"))
			dismiss()
		}
		catch {
			errorMessage = error.localizedDescription
			Task { await reload() }
		}
	}

	private func reload() async {
		if folder.isIdleOrSyncing {
			extraFiles = await Task.detached { return (try? folder.extraneousFiles().asArray().sorted()) ?? [] }.value
			hasConflictFiles = extraFiles.contains(where: { $0.contains(Self.conflictFileMarker) })
		}
		else {
			extraFiles = []
			hasConflictFiles = false
		}
	}
}

private struct ExtraFileView: View {
	let path: String
	let folder: SushitrainFolder
	@Binding var verdict: Bool?

	@State private var localItemURL: URL? = nil

	var body: some View {
		let globalEntry = try? folder.getFileInformation(path)

		HStack {
			VStack(alignment: .leading) {
				Text(path.lastPathComponent).multilineTextAlignment(.leading).dynamicTypeSize(.small).foregroundStyle(
					verdict == false ? .red : verdict == true ? .green : .primary
				)
			}.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

			Picker("Action", selection: $verdict) {
				Image(systemName: "trash").tint(.red).tag(false).help("Delete file")
				if folder.folderType() == SushitrainFolderTypeReceiveOnly {
					Image(systemName: "trash.slash").tag(true).help("Keep file")
				}
				else {
					if let ge = globalEntry, !ge.isDeleted() {
						Image(systemName: "rectangle.2.swap").tag(true).help("Replace existing file")
					}
					else {
						Image(systemName: "plus.square.fill").tag(true).help("Keep file")
					}
				}
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.frame(maxWidth: 100)
		}.quickLookPreview(self.$localItemURL)
			.contextMenu {
				let globalEntry = try? folder.getFileInformation(path)

				if let ge = globalEntry, !ge.isDeleted() {
					Button("Replace existing file", systemImage: "rectangle.2.swap") {
						verdict = true
					}
				}
				else {
					Button("Keep files", systemImage: "plus.square.fill") {
						verdict = true
					}
				}

				Button("Delete file", systemImage: "trash", role: .destructive) {
					verdict = false
				}

				Divider()

				Button("Show preview", systemImage: "text.page.badge.magnifyingglass") {
					if let folderNativePath = folder.localNativeURL {
						self.localItemURL = folderNativePath.appending(path: path)
					}
				}

				Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app") {
					if let localItemURL = localItemURL {
						openURLInSystemFilesApp(url: localItemURL)
					}
				}
			}
	}
}

private enum SubdirectoryVerdict {
	case keepAllChildren
	case deleteAllChildren
	case addSubdirectory
}

// Controls the verdicts for all children (recursively)
private struct ExtraSubdirectoryView: View {
	let path: String
	let folder: SushitrainFolder
	let onChange: (_ path: String, _ verdict: SubdirectoryVerdict) -> Void

	var body: some View {
		HStack {
			VStack(alignment: .leading) {
				Text(path.lastPathComponent)
					.multilineTextAlignment(.leading)
					.dynamicTypeSize(.small)
					.foregroundStyle(.primary)
			}.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		}.contextMenu {
			Button(
				"Keep all files in here",
				systemImage: folder.folderType() == SushitrainFolderTypeReceiveOnly ? "trash.slash" : "plus.square.fill"
			) {
				self.onChange(self.path, .keepAllChildren)
			}

			Button("Delete all files in here", systemImage: "trash", role: .destructive) {
				self.onChange(self.path, .deleteAllChildren)
			}

			if folder.isSelective() {
				Divider()

				Button("Always keep this subdirectory", systemImage: "pin.fill") {
					self.onChange(self.path, .addSubdirectory)
				}
			}

			Divider()

			Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app") {
				if let localURL = folder.localNativeURL?.appending(path: self.path, directoryHint: .isDirectory) {
					openURLInSystemFilesApp(url: localURL)
				}
			}
		}
	}
}
