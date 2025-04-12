// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct IgnoresView: View {
	@EnvironmentObject var appState: AppState
	var folder: SushitrainFolder
	@State var ignoreLines: [String] = []
	@State var error: Error? = nil
	@State var loading = true
	@State var showUpdateCleanConfirmation = false

	private static let prependedLine = "# Synctrain user-defined ignore file"
	private static let defaultIgnoreLines = [
		"(?d).DS_Store", "(?d)Thumbs.db", "(?d)desktop.ini", ".AppleDB", ".AppleDesktop", ".Trashes",
		".Spotlight-V100",
	]

	var body: some View {
		List {
			Section {
				Text(
					"This is an advanced feature and should only be used if you know what you are doing."
				)
				.bold().foregroundStyle(.red)
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
			} header: {
				Text("Ignore patterns")
			} footer: {
				Text(
					"Files and subdirectories whose paths match any of the patterns above will not be synchronized with other devices. Existing items matching the patterns will not be updated. "
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

				Button("Remove all patterns") {
					self.ignoreLines = []
				}.disabled(self.ignoreLines.isEmpty)
					#if os(macOS)
						.buttonStyle(.link)
					#endif

				Button("Apply and clean folder") {
					showUpdateCleanConfirmation = true
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
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button("Add line", systemImage: "plus") {
					self.ignoreLines.append("")
				}
			}
		}
		.onDisappear {
			self.write()
		}
		.alert(isPresented: Binding.constant(error != nil)) {
			Alert(
				title: Text("Error loading ignore settings"),
				message: error != nil ? Text(error!.localizedDescription) : nil,
				dismissButton: .default(Text("OK")) {
					self.error = nil
				})
		}
		.confirmationDialog(
			"Are you sure you want to apply the patterns and to clean the folder? Files and subdirectories that match the patterns will be permanently removed from this device. Files may be lost if they are not available on other devices.",
			isPresented: $showUpdateCleanConfirmation, titleVisibility: .visible
		) {
			Button("Apply patterns and clean folder", role: .destructive) {
				self.applyAndClean()
			}
		}
	}

	private func applyAndClean() {
		self.loading = true
		self.write()
		if self.error == nil {
			Task {
				do {
					try await Task.detached(priority: .userInitiated) {
						try self.folder.cleanSelection()
					}.value
				}
				catch {
					self.error = error
				}
				self.loading = false
			}
		}
		else {
			self.loading = false
		}
	}

	private func write() {
		do {
			if self.error == nil {
				var lines = self.ignoreLines
				lines.removeAll { $0.isEmpty }
				lines.insert(Self.prependedLine, at: 0)
				try self.folder.setIgnoreLines(SushitrainListOfStrings.from(lines))
			}
		}
		catch {
			self.error = error
		}
	}

	private func update() {
		do {
			self.error = nil
			self.loading = true
			var lines = (try self.folder.ignoreLines()).asArray()
			if !lines.isEmpty && lines[0] == Self.prependedLine {
				lines.remove(at: 0)
			}
			self.ignoreLines = lines
		}
		catch {
			self.ignoreLines = []
			self.error = error
		}
		self.loading = false
	}
}
