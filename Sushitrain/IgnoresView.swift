// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

/// View for editing the ignore file for non-selective folders (i.e. edits the *whole* ignore file)
struct IgnoresView: View {
	var folder: SushitrainFolder

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	@State var ignoreLines: [String] = []
	@State var error: ErrorMessage? = nil
	@State var loading = true
	@State var showSaveConfirmation = false

	private static let prependedLine = "# Synctrain user-defined ignore file"
	private static let defaultIgnoreLines = [
		"(?d).DS_Store", "(?d)Thumbs.db", "(?d)desktop.ini", ".AppleDB", ".AppleDesktop", ".Trashes",
		".Spotlight-V100", ".localized",
	]

	var body: some View {
		List {
			Section {
				Text(
					"This is an advanced feature and should only be used if you know what you are doing."
				)
				.bold().foregroundStyle(.red).listRowBackground(Color.clear)
			}

			Section {
				if ignoreLines.isEmpty {
					Text("No ignore patterns defined")
				}

				ForEach(Array(ignoreLines.enumerated()), id: \.offset) { idx in
					HStack {
						TextField(
							"",
							text: Binding(
								get: {
									if idx.offset < self.ignoreLines.count {
										return self.ignoreLines[idx.offset]
									}
									return ""
								},
								set: { nv in
									if idx.offset < self.ignoreLines.count {
										self.ignoreLines[idx.offset] = nv
									}
								}), prompt: Text("Pattern...")
						)
						.autocorrectionDisabled()
						#if os(iOS)
							.textInputAutocapitalization(.never)
							.keyboardType(.asciiCapable)
						#endif

						#if os(macOS)
							Button("Delete", systemImage: "trash") {
								ignoreLines.remove(at: idx.offset)
							}
							.labelStyle(.iconOnly)
							.buttonStyle(.borderless)
						#endif
					}
				}
				.onDelete(perform: { indexSet in
					ignoreLines.remove(atOffsets: indexSet)
				})
				.disabled(self.loading)

				Button("Add line", systemImage: "plus") {
					self.ignoreLines.append("")
				}.disabled(self.loading)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
			} header: {
				Text("Ignore patterns")
			} footer: {
				Text(
					"Files and subdirectories whose paths match any of the patterns above will not be synchronized with other devices. Existing items matching the patterns will not be updated. [Learn more about the pattern syntax...](https://docs.syncthing.net/users/ignoring.html#patterns)"
				)
				#if os(macOS)
					.lineLimit(3, reservesSpace: true)
				#endif
			}

			Section {
				Button("Set default patterns") {
					self.ignoreLines = Self.defaultIgnoreLines
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif

				Button("Remove all patterns", role: .destructive) {
					self.ignoreLines = []
				}.disabled(self.ignoreLines.isEmpty)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
			}.disabled(self.loading)
		}
		#if os(macOS)
			.listStyle(.inset(alternatesRowBackgrounds: true))
		#endif
		.task {
			self.update()
		}
		.navigationTitle("Files to ignore")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.toolbar {
			ToolbarItem(
				placement: .confirmationAction,
				content: {
					Button("Save") {
						showSaveConfirmation = true
					}
					.disabled(self.loading)
					.confirmationDialog(
						"Are you sure you want to save the patterns? Files and subdirectories that match the patterns will not be synchronized with other devices. If you choose to also clean the folder now, files and folders matching the patterns will be permanently removed from this device. Files may be lost if they are not available on other devices.",
						isPresented: $showSaveConfirmation, titleVisibility: .visible
					) {
						Button("Apply patterns") {
							Task {
								await self.write()
								if self.error == nil {
									self.showSaveConfirmation = false
									self.dismiss()
								}
							}
						}.disabled(self.loading)

						Button("Apply patterns and clean folder", role: .destructive) {
							Task {
								await self.applyAndClean()
								if self.error == nil {
									self.dismiss()
									self.showSaveConfirmation = false
								}
							}
						}.disabled(self.loading)
					}
				})

			SheetButton(role: .cancel) {
				dismiss()
			}
		}
		.errorAlert($error)
	}

	private func applyAndClean() async {
		self.loading = true
		await self.write()
		if self.error == nil {
			await Task {
				do {
					try await Task.detached(priority: .userInitiated) {
						try self.folder.cleanSelection()
					}.value
				}
				catch {
					Log.warn("failed to clean selection: \(error)")
					self.error = ErrorMessage(error)
				}
				self.loading = false
			}.value
		}
		else {
			self.loading = false
		}
	}

	private func write() async {
		do {
			Log.info("writing ignore lines \(self.ignoreLines)")
			if self.error == nil {
				var lines = self.ignoreLines
				lines.removeAll { $0.isEmpty }
				lines.insert(Self.prependedLine, at: 0)
				try self.folder.setIgnoreLines(SushitrainListOfStrings.from(lines))
			}
		}
		catch {
			Log.warn("failed to write ignore file: \(error)")
			self.error = ErrorMessage(error)
		}
	}

	private func update() {
		do {
			self.error = nil
			self.loading = true
			var lines = (try self.folder.ignoreLines()).asArray()
			Log.info("Got lines: \(lines)")
			if !lines.isEmpty && lines[0] == Self.prependedLine {
				lines.remove(at: 0)
			}
			self.ignoreLines = lines
		}
		catch {
			self.ignoreLines = []
			Log.warn("failed to read ignore file: \(error)")
			self.error = ErrorMessage(error)
		}
		self.loading = false
	}
}

/// View for editing global ignore patterns for a selective folder (i.e. edits part of the ignore file)
struct SelectiveIgnoresView: View {
	var folder: SushitrainFolder

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss

	@State var ignorePatterns: [String] = []
	@State var error: ErrorMessage? = nil
	@State var loading = true
	@State var showSaveConfirmation = false

	private static let defaultPatterns = [
		"(?d).DS_Store", "(?d)Thumbs.db", "(?d)desktop.ini", "(?d).AppleDB", "(?d).AppleDesktop", "(?d).Trashes",
		"(?d).Spotlight-V100", "(?d).localized",
	]

	var body: some View {
		List {
			Section {
				Text(
					"This is an advanced feature and should only be used if you know what you are doing."
				)
				.bold().foregroundStyle(.red).listRowBackground(Color.clear)
			}

			Section {
				if ignorePatterns.isEmpty {
					Text("No ignore patterns defined")
				}

				ForEach(Array(ignorePatterns.enumerated()), id: \.offset) { idx in
					HStack {
						TextField(
							"",
							text: Binding(
								get: {
									if idx.offset < self.ignorePatterns.count {
										return self.ignorePatterns[idx.offset]
									}
									return ""
								},
								set: { nv in
									if idx.offset < self.ignorePatterns.count {
										self.ignorePatterns[idx.offset] = nv
									}
								}), prompt: Text("Pattern...")
						)
						.autocorrectionDisabled()
						#if os(iOS)
							.textInputAutocapitalization(.never)
							.keyboardType(.asciiCapable)
						#endif

						#if os(macOS)
							Button("Delete", systemImage: "trash") {
								ignorePatterns.remove(at: idx.offset)
							}
							.labelStyle(.iconOnly)
							.buttonStyle(.borderless)
						#endif
					}
				}
				.onDelete(perform: { indexSet in
					ignorePatterns.remove(atOffsets: indexSet)
				})
				.disabled(self.loading)

				Button("Add line", systemImage: "plus") {
					self.ignorePatterns.append("(?d)")
				}.disabled(self.loading)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
			} header: {
				Text("Ignore patterns")
			} footer: {
				Text(
					"Files and subdirectories whose paths match any of the patterns above will not be synchronized with other devices. Existing items matching the patterns will not be updated. **When selective synchronization is enabled, ignore patterns must start with `(?d)`.** [Learn more about the pattern syntax...](https://docs.syncthing.net/users/ignoring.html#patterns)"
				)
				#if os(macOS)
					.lineLimit(3, reservesSpace: true)
				#endif
			}

			Section {
				Button("Set default patterns") {
					self.ignorePatterns = Self.defaultPatterns
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif

				Button("Remove all patterns", role: .destructive) {
					self.ignorePatterns = []
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			}.disabled(self.loading)
		}
		#if os(macOS)
			.listStyle(.inset(alternatesRowBackgrounds: true))
		#endif
		.task {
			self.update()
		}
		.navigationTitle("Files to ignore")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.toolbar {
			ToolbarItem(
				placement: .confirmationAction,
				content: {
					Button("Save") {
						showSaveConfirmation = true
					}
					.disabled(self.loading)
					.confirmationDialog(
						"Are you sure you want to save the patterns? Files and subdirectories that match the patterns will not be synchronized with other devices. If you choose to also clean the folder now, files and folders matching the patterns will be permanently removed from this device. Files may be lost if they are not available on other devices.",
						isPresented: $showSaveConfirmation, titleVisibility: .visible
					) {
						Button("Apply patterns") {
							Task {
								await self.write()
								if self.error == nil {
									self.showSaveConfirmation = false
									self.dismiss()
								}
							}
						}.disabled(self.loading)

						Button("Apply patterns and clean folder", role: .destructive) {
							Task {
								await self.applyAndClean()
								if self.error == nil {
									self.dismiss()
									self.showSaveConfirmation = false
								}
							}
						}.disabled(self.loading)
					}
				})

			SheetButton(role: .cancel) {
				dismiss()
			}
		}
		.errorAlert($error)
	}

	private func applyAndClean() async {
		self.loading = true
		await self.write()
		if self.error == nil {
			await Task {
				do {
					try await Task.detached(priority: .userInitiated) {
						try self.folder.cleanSelection()
					}.value
				}
				catch {
					Log.warn("failed to clean selection: \(error)")
					self.error = ErrorMessage(error)
				}
				self.loading = false
			}.value
		}
		else {
			self.loading = false
		}
	}

	private func write() async {
		do {
			self.loading = true
			Log.info("writing ignore patterns \(self.ignorePatterns)")
			if self.error == nil {
				var lines = self.ignorePatterns
				lines.removeAll { $0.isEmpty }
				try self.folder.setSelectiveGlobalIgnorePatterns(SushitrainListOfStrings.from(lines))
			}
		}
		catch {
			Log.warn("failed to write ignore patterns: \(error)")
			self.error = ErrorMessage(error)
		}
		self.loading = false
	}

	private func update() {
		do {
			self.error = nil
			self.loading = true
			let lines = (try self.folder.getSelectiveGlobalIgnorePatterns()).asArray()
			Log.info("Got patterns: \(lines)")
			self.ignorePatterns = lines
		}
		catch {
			self.ignorePatterns = []
			Log.warn("failed to read ignore file: \(error)")
			self.error = ErrorMessage(error)
		}
		self.loading = false
	}
}
