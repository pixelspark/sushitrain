// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

struct SelectiveFolderView: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder
	let prefix: String

	@State private var showError = false
	@State private var errorText = ""
	@State private var searchString = ""
	@State private var isLoading = false
	@State private var isClearing = false
	@State private var selectedPaths: [String] = []
	@State private var selectedFilteredPaths: [String] = []
	@State private var showConfirmClearSelectionHard = false
	@State private var showConfirmClearSelectionSoft = false
	@State private var listSelection = Set<String>()

	#if os(iOS)
		@Environment(\.editMode) private var editMode
	#endif

	private var inEditMode: Bool {
		#if os(macOS)
			return false
		#else
			return editMode?.wrappedValue.isEditing ?? false
		#endif
	}

	var body: some View {
		ZStack {
			if isLoading || isClearing {
				ProgressView()
			}
			else if selectedPaths.isEmpty {
				ContentUnavailableView(
					"No files selected", systemImage: "pin.slash.fill",
					description: Text(
						"To keep files on this device, navigate to a file and select 'keep on this device'. Selected files will appear here."
					))
			}

			List(selection: $listSelection) {
				Section(self.prefix.isEmpty ? "Files kept on device" : "Files in '\(self.prefix)' kept on this device") {
					PathsOutlineGroup(paths: self.selectedFilteredPaths, disableIntermediateSelection: false) { item, isIntermediate in
						if item.isEmpty {
							EmptyView()
						}
						else {
							SelectiveFileView(
								path: item,
								folder: folder,
								deselect: {
									Task {
										let entry = try folder.getFileInformation(item)
										if entry.isExplicitlySelected() {
											await self.deselectItems([item])
										}
										else {
											await self.deselectPrefix(item)
										}
									}
								}
							)
							.tag(item)
							.swipeActions(allowsFullSwipe: false) {
								// Unselect button
								if !isIntermediate {
									Button(role: .destructive) {
										Task {
											await self.deselectItems([item])
										}
									} label: {
										Label("Do not synchronize with this device", systemImage: "pin.slash")
									}
								}
							}
						}
					}
					.disabled(!folder.isIdleOrSyncing && folder.isDiskSpaceSufficient())
				}
			}
			.refreshable {
				Task { @MainActor in
					await self.update()
				}
			}
			.opacity(selectedPaths.isEmpty ? 0.0 : 1.0)
			.disabled(isLoading || isClearing)
			#if os(macOS)
				.formStyle(.grouped)
			#endif
		}
		.toolbar {
			#if os(iOS)
				ToolbarItem {
					EditButton()
				}
			#endif

			ToolbarItem(placement: .primaryAction) {
				Menu {
					Section(inEditMode ? "Remove selected files from this device" : "Remove files from this device") {
						Button("All files that are available on other devices", systemImage: "pin.slash") {
							showConfirmClearSelectionSoft = true
						}
						.help(
							"Remove the files shown in the list from this device, but do not remove them from other devices. If a file is not available on at least one other device, it will not be removed."
						)

						if !inEditMode && self.prefix.isEmpty {
							Button("All files including those not available elsewhere", systemImage: "pin.slash") {
								showConfirmClearSelectionHard = true
							}
							.help(
								"Remove the files shown in the list from this device, but do not remove them from other devices. If the file is not available on another device it will be permanently removed."
							)

							if self.prefix.isEmpty {
								Divider()

								Button("Remove unsynchronized empty subdirectories", systemImage: "eraser") {
									self.removeUnsynchronizedEmpty()
								}
							}
						}
					}
				} label: {
					Label("Free up space", systemImage: "pin.slash")
				}.disabled(isClearing || isLoading)
			}
		}
		.alert(isPresented: .constant(showConfirmClearSelectionSoft || showConfirmClearSelectionHard)) {
			if showConfirmClearSelectionSoft {
				return Alert(
					title: Text("Free up space"),
					message: Text(
						inEditMode
							? "This will remove the local copy of the selected files in this folder. Any files that are not also present on another device will not be removed. Are you sure yu want to continue?"
							: "This will remove all locally stored copies of files in this folder. Any files that are not also present on another device will not be removed. Are you sure yu want to continue?"
					),
					primaryButton: .destructive(Text("Remove files")) {
						showConfirmClearSelectionSoft = false
						self.clearSelectionSoft()
					},
					secondaryButton: .cancel {
						showConfirmClearSelectionSoft = false
					}
				)
			}
			else {
				return Alert(
					title: Text("Free up space"),
					message: Text(
						"This will remove all locally stored copies of files in this folder. Any files that are not also present on another device will be permanently lost and cannot be recovered. Are you sure yu want to continue?"
					),
					primaryButton: .destructive(Text("Remove files")) {
						showConfirmClearSelectionHard = false
						self.clearSelectionHard()
					},
					secondaryButton: .cancel {
						showConfirmClearSelectionHard = false
					}
				)
			}
		}
		.navigationBarBackButtonHidden(isClearing)

		#if os(iOS)
			.navigationTitle("Selected files")
			.navigationBarTitleDisplayMode(.inline)
		#endif

		#if os(macOS)
			.navigationTitle("Files kept on this device in '\(self.folder.displayName)'")
		#endif
		.searchable(text: $searchString, prompt: "Search files by name...")
		.task {
			Task {
				await self.update()
			}
		}
		.onChange(of: self.searchString) {
			self.updateFilter()
		}
		.onChange(of: appState.eventCounter) {
			// Doesn't really need to do anything, just re-render the view (it relies on folder.isIdleOrSyncing which
			// cannot be observed directly for changes)
		}
	}

	private func updateFilter() {
		if searchString.isEmpty {
			self.selectedFilteredPaths = self.selectedPaths
		}
		else {
			let st = searchString.lowercased()
			self.selectedFilteredPaths = self.selectedPaths.filter { $0.lowercased().contains(st) }
		}
	}

	private func removeUnsynchronizedEmpty() {
		Task {
			do {
				if isClearing {
					return
				}
				self.isClearing = true
				try await Task.detached {
					try folder.removeSuperfluousSubdirectories()
					try folder.removeSuperfluousSelectionEntries()
				}.value
				self.isClearing = false
			}
			catch {
				self.showError = true
				errorText = error.localizedDescription
				self.isClearing = false
			}
		}
	}

	private func clearSelectionSoft() {
		if isClearing {
			return
		}
		isClearing = true
		let inEditMode = self.inEditMode

		Task.detached {
			do {
				if inEditMode {
					try await self.deselectListSelection(includingLastCopy: false)
				}
				else {
					try await self.deselectSearchResults(includingLastCopy: false)
				}
			}
			catch let error {
				DispatchQueue.main.async {
					showError = true
					errorText = error.localizedDescription
				}
			}
			Task { @MainActor in
				await self.update()
				isClearing = false
			}
		}
	}

	private func clearSelectionHard() {
		if isClearing {
			return
		}
		isClearing = true

		if searchString.isEmpty {
			Task.detached {
				do {
					try folder.clearSelection()
				}
				catch let error {
					DispatchQueue.main.async {
						showError = true
						errorText = error.localizedDescription
					}
				}
				DispatchQueue.main.async {
					isClearing = false
				}
			}
			self.selectedPaths.removeAll()
		}
		else {
			Task.detached {
				do {
					try await self.deselectSearchResults(includingLastCopy: true)
				}
				catch {
					DispatchQueue.main.async {
						errorText = error.localizedDescription
						showError = true
					}
				}
				Task { @MainActor in
					await self.update()
					isClearing = false
				}
			}
		}
	}

	private func update() async {
		if self.isLoading {
			return
		}

		do {
			self.isLoading = true
			let folder = self.folder
			self.selectedPaths = try await Task.detached {
				try folder.selectedPaths(true).asArray().filter {
					$0.starts(with: self.prefix)
				}.sorted()
			}.value
		}
		catch {
			self.errorText = error.localizedDescription
			self.showError = true
			self.selectedPaths = []
		}

		self.updateFilter()
		self.isLoading = false
	}

	private nonisolated func deselectSearchResults(includingLastCopy: Bool) async throws {
		let st = await self.searchString.lowercased()

		let paths = Set(
			await self.selectedPaths.filter { item in
				return st.isEmpty || item.lowercased().contains(st)
			})

		try await self.deselect(paths: paths, includingLastCopy: includingLastCopy)
	}

	private nonisolated func deselectListSelection(includingLastCopy: Bool) async throws {
		try await self.deselect(paths: self.listSelection, includingLastCopy: includingLastCopy)
	}

	private nonisolated func deselect(paths: Set<String>, includingLastCopy: Bool) async throws {
		var paths = paths
		
		for path in paths {
			let entry = try folder.getFileInformation(path)
			if !entry.isExplicitlySelected() {
				Log.info("Not deselecting \(path), it is not explicitly selected")
				paths.remove(path)
				continue
			}
			
			// If we should not delete if our copy is the only one available, check availability for each file first
			if !includingLastCopy {
				let peersWithFullCopy = try entry.peersWithFullCopy()
				if peersWithFullCopy.count() == 0 {
					Log.info("Not removing \(path), it is the last copy")
					paths.remove(path)
					continue
				}
			}
		}

		let verdicts = paths.reduce(into: [:]) { dict, p in
			dict[p] = false
		}

		let json = try JSONEncoder().encode(verdicts)
		try folder.setExplicitlySelectedJSON(json)

		Task { @MainActor in
			await self.update()
		}
	}

	// Deselects all items contained here that are explicitly selected, and available on at least one other device
	private func deselectPrefix(_ path: String) async {
		do {
			let prefix = path.withoutEndingSlash + "/"
			let items = Set(self.selectedFilteredPaths.filter { $0.starts(with: prefix) })
			try await self.deselect(paths: items, includingLastCopy: false)
		}
		catch {
			Log.warn("Could not deselect prefix \(path): \(error.localizedDescription)")
		}
	}
	
	private func deselectItems(_ paths: [String]) async {
		do {
			let verdicts = paths.reduce(into: [:]) { dict, p in
				dict[p] = false
			}
			let json = try JSONEncoder().encode(verdicts)

			try await Task.detached {
				try folder.setExplicitlySelectedJSON(json)
			}.value
		}
		catch {
			Log.warn("Could not deselect: \(error.localizedDescription)")
		}

		Task { @MainActor in
			await self.update()
		}
	}
}

private struct SelectiveFileView: View {
	let path: String
	let folder: SushitrainFolder
	let deselect: () -> Void

	@State private var entry: SushitrainEntry? = nil

	var body: some View {
		ZStack {
			if let entry = entry {
				if entry.isDeleted() {
					Label(entry.fileName(), systemImage: entry.systemImage).strikethrough()
				}
				else if !entry.isExplicitlySelected() {
					IntermediateSelectiveFileView(entry: entry, deselect: deselect)
				}
				else {
					SelectedFileView(entry: entry, folder: folder, deselect: deselect)
				}
			}
			else {
				// This needs to be here, because otherwise macOS doesn't show disclosure arrows
				Text(path).opacity(0)
			}
		}
		.task {
			do {
				self.entry = try folder.getFileInformation(path)
			}
			catch {
				print("Error fetching file info: \(error.localizedDescription)")
				self.entry = nil
			}
		}
	}
}

/** Entry in the list that is not explicitly selected itself, but can deselect a whole prefix  */
private struct IntermediateSelectiveFileView: View {
	let entry: SushitrainEntry
	let deselect: () -> Void
	
	var body: some View {
		HStack {
			Label(entry.fileName(), systemImage: entry.systemImage).opacity(0.8)
			Spacer()
			Menu {
				Section("For all files in here") {
					Button("Remove from this device if available on other devices") {
						self.deselect()
					}
				}
			} label: {
				Label("", systemImage: "pin.slash.fill").accessibilityLabel("Actions")
			}.buttonStyle(.borderless)
		}
	}
}

/** Entry in the list that is explicitly selected itself */
private struct SelectedFileView: View {
	@Environment(AppState.self) private var appState
	let entry: SushitrainEntry
	let folder: SushitrainFolder
	let deselect: () -> Void

	@State private var fullyAvailableOnDevices: [SushitrainPeer]? = nil

	var body: some View {
		ZStack {
			#if os(macOS)
				HStack {
					if let fa = self.fullyAvailableOnDevices {
						Label(entry.fileName(), systemImage: entry.systemImage)
							.badge(fa.count)

						Spacer()

						if fa.isEmpty {
							Text("Only copy")
								.foregroundStyle(.orange).bold()
								.padding(.all, 3).overlay(
									RoundedRectangle(
										cornerRadius: 3
									).stroke(
										Color.orange,
										lineWidth: 1)
								)
								.help(
									"This file is only available on this device."
								)
						}

						Button(
							"Remove from this device, keep on \(fa.count) others",
							systemImage: "pin.slash"
						) {
							self.deselect()
						}
						.disabled(fa.isEmpty)
						.labelStyle(.iconOnly)
						.foregroundStyle(fa.isEmpty ? .gray : .red)
						.buttonStyle(.borderless)
					}
					else {
						Label(entry.fileName(), systemImage: entry.systemImage)
					}
				}
				.contextMenu {
					NavigationLink(
						destination: FileView(
							file: entry,
							showPath: false,
							siblings: nil
						)
					) {
						Label("Show info", systemImage: entry.systemImage)
					}
				}
			#else
				NavigationLink(destination: FileView(file: entry, showPath: false, siblings: nil)) {
					Label(entry.fileName(), systemImage: entry.systemImage)
				}
			#endif
		}
		.task {
			do {
				let availability = try await Task.detached { [entry] in
					return (try entry.peersWithFullCopy()).asArray()
				}.value

				self.fullyAvailableOnDevices = availability.flatMap { devID in
					if let p = self.appState.client.peer(withID: devID) {
						return [p]
					}
					return []
				}
			}
			catch {
				print("Error fetching file availability: \(error.localizedDescription)")
			}
		}
	}
}
