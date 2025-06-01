// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

struct BrowserTableView: View {
	let folder: SushitrainFolder
	let files: [SushitrainEntry]
	let subdirectories: [SushitrainEntry]
	let viewStyle: BrowserViewStyle

	@State private var selection = Set<SushitrainEntry.ID>()
	@State private var openedEntry: (SushitrainEntry, Bool)? = nil
	@State private var sortOrder = [EntryComparator(order: .forward, sortBy: .name)]
	@State private var entries: [SushitrainEntry] = []

	@SceneStorage("BrowserTableViewConfig") private var columnCustomization: TableColumnCustomization<SushitrainEntry>
	@Environment(\.openURL) private var openURL
	@EnvironmentObject var appState: AppState

	#if os(macOS)
		@Environment(\.openWindow) private var openWindow
	#endif

	private static let formatter = ByteCountFormatter()

	private func entryById(_ id: SushitrainEntry.ID) -> SushitrainEntry? {
		if let found = subdirectories.first(where: { $0.id == id }) {
			return found
		}
		if let found = files.first(where: { $0.id == id }) {
			return found
		}
		return nil
	}

	private func entriesForIds(_ ids: Set<SushitrainEntry.ID>) -> [SushitrainEntry] {
		return self.entries.filter { ids.contains($0.id) }
	}

	private func copy(_ entry: SushitrainEntry) {
		if let url = entry.localNativeFileURL as? NSURL, let refURL = url.fileReferenceURL() {
			writeURLToPasteboard(url: refURL)
		}
		else if let url = URL(string: entry.onDemandURL()) {
			writeURLToPasteboard(url: url)
		}
	}

	var body: some View {
		Table(
			of: SushitrainEntry.self,
			selection: self.$selection,
			sortOrder: $sortOrder,
			columnCustomization: $columnCustomization,
			columns: {
				// Name and icon
				TableColumn("Name", sortUsing: EntryComparator(order: .forward, sortBy: .name)) {
					(entry: SushitrainEntry) in
					EntryNameView(entry: entry, viewStyle: self.viewStyle)
						.environmentObject(self.appState)  // Needed because for some reason it does not propagate
				}
				.defaultVisibility(.visible)
				.customizationID("name")

				// File extension
				TableColumn(
					"File type", sortUsing: EntryComparator(order: .forward, sortBy: .fileExtension)
				) {
					(entry: SushitrainEntry) in
					Text(entry.extension())
						.foregroundStyle(Color.primary)
						.opacity(entry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
				}
				.width(min: 32, max: 64)
				.defaultVisibility(.hidden)
				.customizationID("extension")

				// File size
				TableColumn(
					"Size",
					sortUsing: EntryComparator(order: .forward, sortBy: .size)
				) { entry in
					if !entry.isDirectory() {
						Text(Self.formatter.string(fromByteCount: entry.size()))
							.foregroundStyle(Color.primary)
							.opacity(entry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
					}
				}
				.width(min: 100, max: 120)
				.defaultVisibility(.hidden)
				.alignment(.trailing)
				.customizationID("size")

				// Last modified date
				TableColumn(
					"Last modified",
					sortUsing: EntryComparator(order: .forward, sortBy: .lastModifiedDate)
				) { (entry: SushitrainEntry) in
					if let md = entry.modifiedAt()?.date(), !entry.isSymlink() {
						Text(md.formatted(date: .numeric, time: .shortened))
							.foregroundStyle(Color.primary)
							.opacity(entry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
					}
				}
				.width(min: 150, max: 180)
				.defaultVisibility(.hidden)
				.alignment(.leading)
				.customizationID("lastModifiedDate")

			},
			rows: {
				ForEach(entries) { entry in
					TableRow(entry).draggable(entry)
				}
			}
		)
		.task {
			await self.update()
		}
		.onChange(of: self.sortOrder, initial: false) { _, _ in
			Task {
				await self.update()
			}
		}
		.onChange(of: self.files, initial: false) { _, _ in
			Task {
				await self.update()
			}
		}
		.onChange(of: self.subdirectories, initial: false) { _, _ in
			Task {
				await self.update()
			}
		}
		.contextMenu(
			forSelectionType: SushitrainEntry.ID.self,
			menu: { items in
				if let item = items.first, items.count == 1 {
					// Single item selected
					if let oe = self.entryById(item) {
						if !oe.isDirectory() && !oe.isSymlink() {
							#if os(macOS)
								Button("Show preview", systemImage: "doc.text.magnifyingglass") {
									openWindow(
										id: "preview",
										value: Preview(folderID: self.folder.folderID, path: oe.path())
									)
								}.disabled(!oe.canPreview)

								// Copy
								Button("Copy", systemImage: "document.on.document") {
									self.copy(oe)
								}.disabled(!oe.isLocallyPresent())
							#endif

							if oe.hasExternalSharingURL {
								FileSharingLinksView(entry: oe, sync: true)
							}
						}

						// Show file in Finder
						if oe.canShowInFinder {
							Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app") {
								try? oe.showInFinder()
							}
						}

						Divider()
						ItemSelectToggleView(file: oe)

						Divider()
						Button("Show info") {
							self.openedEntry = (oe, false)
						}
					}
				}
				else {
					// Multiple items selected
					Text("\(items.count) items selected")

					MultiItemSelectToggleView(files: self.entriesForIds(items))
				}
			},
			primaryAction: self.doubleClick
		)
		.navigationDestination(
			isPresented: Binding(
				get: { self.openedEntry != nil },
				set: { self.openedEntry = $0 ? self.openedEntry : nil }),
			destination: {
				self.nextView()
			})
	}

	@ViewBuilder private func nextView() -> some View {
		if let (oe, honorTapToPreview) = openedEntry {
			if oe.isSymlink() {
				if !honorTapToPreview {
					// Just show symlink properties
					FileView(file: oe, siblings: self.entries)
				}
				else if let targetEntry = try? oe.symlinkTargetEntry() {
					// Symlink to a directory
					if targetEntry.isDirectory() {
						if let targetFolder = targetEntry.folder {
							BrowserView(folder: targetFolder, prefix: targetEntry.path() + "/")
						}
					}
					else {
						// Symlink to file
						if honorTapToPreview && appState.tapFileToPreview {
							FileViewerView(
								file: targetEntry,
								siblings: entries,
								inSheet: false,
								isShown: .constant(true)
							)
							.navigationTitle(targetEntry.fileName())
						}
						else {
							FileView(file: targetEntry, siblings: self.entries)
						}
					}
				}
				else {
					// Symlink to URL, case is handled elsewhere
					EmptyView()
				}
			}
			else if oe.isDirectory() {
				if honorTapToPreview {
					BrowserView(folder: folder, prefix: oe.path() + "/")
				}
				else {
					FileView(file: oe, siblings: self.entries)
				}
			}
			else {
				// Only on iOS
				if honorTapToPreview && appState.tapFileToPreview {
					FileViewerView(
						file: oe, siblings: entries,
						inSheet: false,
						isShown: .constant(true)
					)
					.navigationTitle(oe.fileName())
				}
				else {
					FileView(file: oe, siblings: self.entries)
				}
			}
		}
		else {
			EmptyView()
		}
	}

	private func doubleClick(_ items: Set<SushitrainEntry.ID>) {
		if let item = items.first, items.count == 1 {
			if let oe = self.entryById(item) {
				// Symlink to URLs should be opened externally
				if oe.isSymlink() {
					if let targetURL = oe.symlinkTargetURL {
						openURL(targetURL)
						return
					}
				}

				#if os(macOS)
					// Tap to preview on macOS opens a new window
					if appState.tapFileToPreview {
						if oe.canPreview {
							openWindow(
								id: "preview",
								value: Preview(
									folderID: self.folder.folderID,
									path: oe.path()
								))
							return
						}
					}
				#endif

				// Regular case: just open the entry in a next view
				self.openedEntry = (oe, true)
			}
		}
	}

	private func update() async {
		self.entries = await Task.detached {
			var a = self.subdirectories + self.files
			await a.sort(using: self.sortOrder)
			return a
		}.value
	}
}

struct MultiItemSelectToggleView: View {
	@EnvironmentObject var appState: AppState
	let files: [SushitrainEntry]

	private var isAvailable: Bool {
		return files.allSatisfy {
			$0.isSelectionToggleAvailable && !$0.isSelectionToggleShallowDisabled
		}
	}

	private var allSelected: Bool? {
		var anySelected: Bool = false
		var anyDeselected: Bool = false

		for file in files {
			if !file.isSelectionToggleAvailable || file.isSelectionToggleShallowDisabled {
				return false
			}

			let s = (file.isExplicitlySelected() || file.isSelected())
			anySelected = anySelected || s
			anyDeselected = anyDeselected || !s
		}

		switch (anySelected, anyDeselected) {
		case (true, true): return nil
		case (true, false): return true
		case (false, true): return false
		case (false, false): return false
		}

	}

	private func selectAll(_ s: Bool) async {
		// [folderID: [path: selected]]
		var filesPerFolder: [String: [String: Bool]] = [:]

		// Sort files by folder
		for file in files {
			if file.isSelected() && !file.isExplicitlySelected() {
				continue  // File is implicitly selected
			}

			if let fid = file.folder?.folderID {
				if var ff = filesPerFolder[fid] {
					ff[file.path()] = s
					filesPerFolder[fid] = ff
				}
				else {
					filesPerFolder[fid] = [file.path(): s]
				}
			}
		}

		// Batch select by folder
		do {
			for (folderID, selection) in filesPerFolder {
				if let folder = appState.client.folder(withID: folderID) {
					let json = try JSONEncoder().encode(selection)
					try folder.setExplicitlySelectedJSON(json)
				}
			}
		}
		catch {
			// We can't use our own alert since by the time we get here, the context menu is gone
			appState.alert(message: error.localizedDescription)
		}
	}

	var body: some View {
		Toggle(
			"Synchronize with this device", systemImage: "pin",
			isOn: Binding(
				get: { allSelected == true },
				set: { s in
					Task {
						await selectAll(s)
					}
				})
		)
		.disabled(!self.isAvailable)
	}
}

private struct EntryNameView: View {
	let entry: SushitrainEntry
	let viewStyle: BrowserViewStyle

	@EnvironmentObject var appState: AppState

	private var showThumbnail: Bool {
		return self.viewStyle == .thumbnailList
	}

	var body: some View {
		if self.showThumbnail && !self.entry.isDirectory() {
			// Thubmnail view shows thumbnail image next to the file name
			HStack(alignment: .center, spacing: 9.0) {
				ThumbnailView(file: entry, appState: appState, showFileName: false, showErrorMessages: false)
					.frame(width: 60, height: 40)
					.cornerRadius(6.0)
					.help(entry.fileName())

				// The entry name (grey when not locally present)
				Text(entry.fileName())
					.multilineTextAlignment(.leading)
					.foregroundStyle(entry.isConflictCopy() ? Color.red : Color.primary)
					.opacity(entry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
				Spacer()
			}
			.frame(maxWidth: .infinity)
			.padding(0)
		}
		else {
			HStack {
				Image(systemName: entry.systemImage)
					.foregroundStyle(entry.color ?? Color.accentColor)
				Text(entry.fileName())
					.multilineTextAlignment(.leading)
					.foregroundStyle(entry.isConflictCopy() ? Color.red : Color.primary)
					.opacity(entry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
				Spacer()
			}
			.frame(maxWidth: .infinity)
		}
	}
}

extension ComparisonResult {
	var flipped: ComparisonResult {
		switch self {
		case .orderedSame: return .orderedSame
		case .orderedAscending: return .orderedDescending
		case .orderedDescending: return .orderedAscending
		}
	}
}

private struct EntryComparator: SortComparator {
	typealias Compared = SushitrainEntry

	enum SortBy {
		case size
		case name
		case lastModifiedDate
		case fileExtension
	}

	var order: SortOrder
	var sortBy: SortBy

	private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
		switch (lhs, rhs) {
		case (nil, nil): return .orderedSame
		case (nil, _): return .orderedAscending
		case (_, nil): return .orderedDescending
		case (let a, let b): return a!.compare(b!)
		}
	}

	func compare(_ lhs: SushitrainEntry, _ rhs: SushitrainEntry) -> ComparisonResult {
		let ascending: ComparisonResult = order == .forward ? .orderedAscending : .orderedDescending
		let descending: ComparisonResult = order == .forward ? .orderedDescending : .orderedAscending

		switch (lhs.isDirectory(), rhs.isDirectory()) {
		// Compare directories among themselves
		case (true, true):
			switch self.sortBy {
			case .size:
				return .orderedSame  // Directories all have zero size
			case .lastModifiedDate:
				let r = compareDates(lhs.modifiedAt()?.date(), rhs.modifiedAt()?.date())
				return order == .forward ? r : r.flipped
			case .name:
				return order == .forward
					? lhs.name().compare(rhs.name()) : rhs.name().compare(lhs.name())
			case .fileExtension:
				return order == .forward
					? lhs.extension().compare(rhs.extension())
					: rhs.extension().compare(lhs.extension())
			}

		// Compare directory with file or vice versa
		case (true, false): return .orderedAscending  // This doesn't change when order is swapped
		case (false, true): return .orderedDescending  // This doesn't change when order is swapped

		// Compare entries among themselves
		case (false, false):
			switch self.sortBy {
			case .lastModifiedDate:
				let r = compareDates(lhs.modifiedAt()?.date(), rhs.modifiedAt()?.date())
				return order == .forward ? r : r.flipped

			case .name:
				return order == .forward
					? lhs.name().compare(rhs.name()) : rhs.name().compare(lhs.name())

			case .fileExtension:
				return order == .forward
					? lhs.extension().compare(rhs.extension())
					: rhs.extension().compare(lhs.extension())

			case .size:
				let sa = lhs.size()
				let sb = rhs.size()
				if sa == sb {
					return .orderedSame
				}
				else if sa < sb {
					return ascending
				}
				else {
					return descending
				}
			}
		}
	}
}
