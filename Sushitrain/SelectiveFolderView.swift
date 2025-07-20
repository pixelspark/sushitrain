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

	@State private var showError = false
	@State private var errorText = ""
	@State private var searchString = ""
	@State private var isLoading = false
	@State private var isClearing = false
	@State private var selectedPaths: [String] = []
	@State private var showConfirmClearSelectionHard = false
	@State private var showConfirmClearSelectionSoft = false
	@State private var listSelection = Set<String>()

	@Environment(\.editMode) private var editMode

	private var inEditMode: Bool {
		editMode?.wrappedValue.isEditing ?? false
	}

	var body: some View {
		ZStack {
			if isLoading || isClearing {
				ProgressView()
			}
			else if !selectedPaths.isEmpty {
				List(selection: $listSelection) {
					let st = searchString.lowercased()
					Section("Files kept on device") {
						ForEach(Array(selectedPaths.enumerated()), id: \.element) { itemIndex, item in
							let item = selectedPaths[itemIndex]
							if st.isEmpty || item.lowercased().contains(st) {
								SelectiveFileView(
									path: item,
									folder: folder,
									deselect: {
										Task {
											await self.deselectIndexes(IndexSet([itemIndex]))
										}
									}
								)
								.tag(item)
								.swipeActions(allowsFullSwipe: false) {
									// Unselect button
									Button(role: .destructive) {
										Task {
											await self.deselectIndexes(IndexSet([itemIndex]))
										}
									} label: {
										Label("Do not synchronize with this device", systemImage: "pin.slash")
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
				#if os(macOS)
					.formStyle(.grouped)
				#endif
			}
			else {
				ContentUnavailableView(
					"No files selected", systemImage: "pin.slash.fill",
					description: Text(
						"To keep files on this device, navigate to a file and select 'keep on this device'. Selected files will appear here."
					))
			}
		}
		.toolbar {
			ToolbarItem {
				EditButton()
			}

			ToolbarItem(placement: .primaryAction) {
				Menu {
					Section(inEditMode ? "Remove selected files from this device" : "Remove files from this device") {
						Button(
							"All files that are available on other devices",
							systemImage: "pin.slash",
							action: {
								showConfirmClearSelectionSoft = true
							}
						)
						.help(
							"Remove the files shown in the list from this device, but do not remove them from other devices. If a file is not available on at least one other device, it will not be removed."
						)

						if !inEditMode {
							Button(
								"All files including those not available elsewhere",
								systemImage: "pin.slash",
								action: {
									showConfirmClearSelectionHard = true
								}
							)
							.help(
								"Remove the files shown in the list from this device, but do not remove them from other devices. If the file is not available on another device it will be permanently removed."
							)

							Divider()

							Button("Remove unsynchronized empty subdirectories", systemImage: "eraser") {
								self.removeUnsynchronizedEmpty()
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
		.onChange(of: appState.eventCounter) {
			// Doesn't really need to do anything, just re-render the view (it relies on folder.isIdleOrSyncing which
			// cannot be observed directly for changes)
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
				try folder.selectedPaths(true).asArray().sorted()
			}.value
		}
		catch {
			self.errorText = error.localizedDescription
			self.showError = true
			self.selectedPaths = []
		}
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
		// If we should not delete if our copy is the only one available, check availability for each file first
		if !includingLastCopy {
			for path in paths {
				let entry = try folder.getFileInformation(path)
				let peersWithFullCopy = try entry.peersWithFullCopy()
				if peersWithFullCopy.count() == 0 {
					Log.info("Not removing \(path), it is the last copy")
					paths.remove(path)
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

	private func deselectIndexes(_ pathIndexes: IndexSet) async {
		do {
			let verdicts = pathIndexes.map({ idx in selectedPaths[idx] }).reduce(into: [:]) { dict, p in
				dict[p] = false
			}
			let json = try JSONEncoder().encode(verdicts)

			try await Task.detached {
				try folder.setExplicitlySelectedJSON(json)
			}.value

			selectedPaths.remove(atOffsets: pathIndexes)
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
	@Environment(AppState.self) private var appState
	let path: String
	let folder: SushitrainFolder
	let deselect: () -> Void

	@State private var entry: SushitrainEntry? = nil
	@State private var fullyAvailableOnDevices: [SushitrainPeer]? = nil

	var body: some View {
		ZStack {
			if let file = self.entry {
				if !file.isDeleted() {
					#if os(macOS)
						HStack {
							if let fa = self.fullyAvailableOnDevices {
								Label(path, systemImage: file.systemImage).badge(
									fa.count)

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
								Label(path, systemImage: file.systemImage)
							}
						}
						.contextMenu {
							NavigationLink(
								destination: FileView(
									file: file,
									showPath: false,
									siblings: nil
								)
							) {
								Label("Show info", systemImage: file.systemImage)
							}
						}
					#else
						NavigationLink(destination: FileView(file: file, showPath: false, siblings: nil)) {
							Label(path, systemImage: file.systemImage)
						}
					#endif
				}
				else {
					Label(path, systemImage: file.systemImage).strikethrough()
				}
			}
		}
		.task {
			do {
				self.entry = try? folder.getFileInformation(path)
				if let fileEntry = self.entry {
					let availability = try await Task.detached { [fileEntry] in
						return (try fileEntry.peersWithFullCopy()).asArray()
					}.value

					self.fullyAvailableOnDevices = availability.flatMap { devID in
						if let p = self.appState.client.peer(withID: devID) {
							return [p]
						}
						return []
					}
				}
			}
			catch {
				print("Error fetching file info: \(error.localizedDescription)")
				self.entry = nil
			}
		}
	}
}
