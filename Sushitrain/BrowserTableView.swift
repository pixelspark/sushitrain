// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import QuickLook
@preconcurrency import SushitrainCore

private struct EntryNameView: View {
	var appState: AppState
	var entry: SushitrainEntry
	var viewStyle: BrowserViewStyle

	private var showThumbnail: Bool {
		return self.viewStyle == .thumbnailList
	}

	var body: some View {
		if self.showThumbnail && !self.entry.isDirectory() {
			// Thubmnail view shows thumbnail image next to the file name
			HStack(alignment: .center, spacing: 9.0) {
				ThumbnailView(
					file: entry, appState: appState, showFileName: false,
					showErrorMessages: false
				)
				.frame(width: 60, height: 40)
				.cornerRadius(6.0)
				.id(entry.id)
				.help(entry.fileName())

				// The entry name (grey when not locally present)
				Text(entry.fileName())
					.multilineTextAlignment(.leading)
					.foregroundStyle(Color.primary)
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
					.foregroundStyle(Color.primary)
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

struct BrowserTableView: View {
	@ObservedObject var appState: AppState
	var folder: SushitrainFolder
	var files: [SushitrainEntry] = []
	var subdirectories: [SushitrainEntry] = []
	var viewStyle: BrowserViewStyle

	@State private var selection = Set<SushitrainEntry.ID>()
	@State private var openedEntry: (SushitrainEntry, Bool)? = nil
	@State private var sortOrder = [EntryComparator(order: .forward, sortBy: .name)]
	@SceneStorage("BrowserTableViewConfig") private var columnCustomization:
		TableColumnCustomization<SushitrainEntry>

	#if os(macOS)
		@Environment(\.openWindow) private var openWindow
	#endif

	private static let formatter = ByteCountFormatter()

	private var entries: [SushitrainEntry] {
		var a = self.subdirectories + self.files
		a.sort(using: self.sortOrder)
		return a
	}

	private func entryById(_ id: SushitrainEntry.ID) -> SushitrainEntry? {
		if let found = subdirectories.first(where: { $0.id == id }) {
			return found
		}
		if let found = files.first(where: { $0.id == id }) {
			return found
		}
		return nil
	}

	var body: some View {
		Table(
			self.entries, selection: self.$selection, sortOrder: $sortOrder,
			columnCustomization: $columnCustomization
		) {
			// Name and icon
			TableColumn("Name", sortUsing: EntryComparator(order: .forward, sortBy: .name)) {
				(entry: SushitrainEntry) in
				EntryNameView(appState: self.appState, entry: entry, viewStyle: self.viewStyle)
			}
			.defaultVisibility(.visible)
			.customizationID("name")

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
			.width(max: 100)
			.defaultVisibility(.hidden)
			.alignment(.trailing)
			.customizationID("size")

			// Last modified date
			TableColumn(
				"Last modified", sortUsing: EntryComparator(order: .forward, sortBy: .lastModifiedDate)
			) { (entry: SushitrainEntry) in
				if let md = entry.modifiedAt()?.date(), !entry.isSymlink() {
					Text(md.formatted(date: .numeric, time: .shortened))
						.foregroundStyle(Color.primary)
						.opacity(entry.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
				}
			}
			.width(max: 150)
			.defaultVisibility(.hidden)
			.alignment(.trailing)
			.customizationID("lastModifiedDate")

		}
		.contextMenu(
			forSelectionType: SushitrainEntry.ID.self,
			menu: { items in
				if let item = items.first, items.count == 1 {
					if let oe = self.entryById(item) {
						if !oe.isDirectory() && !oe.isSymlink() {
							#if os(macOS)
								Button(
									"Preview",
									systemImage: "doc.text.magnifyingglass"
								) {
									openWindow(
										id: "preview",
										value: Preview(
											folderID: self.folder.folderID,
											path: oe.path()
										))
								}.disabled(!oe.canPreview)

								Divider()
							#endif
						}

						Button("Show info...") {
							if let oe = self.entryById(item) {
								self.openedEntry = (oe, false)
							}
						}
					}
				}
				else {
					Text("\(items.count) items selected")
				}
			},
			primaryAction: { items in
				if let item = items.first, items.count == 1 {
					#if os(macOS)
						if appState.tapFileToPreview {
							if let oe = self.entryById(item), oe.canPreview {
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
					if let oe = self.entryById(item) {
						self.openedEntry = (oe, true)
					}
				}
			}
		)

		.navigationDestination(
			isPresented: Binding(
				get: { self.openedEntry != nil },
				set: { self.openedEntry = $0 ? self.openedEntry : nil }),
			destination: {
				if let (oe, honorTapToPreview) = openedEntry {
					if oe.isDirectory() {
						if honorTapToPreview {
							BrowserView(
								appState: appState, folder: folder,
								prefix: oe.path() + "/")
						}
						else {
							FileView(file: oe, appState: appState)
						}
					}
					else {
						// Only on iOS
						if honorTapToPreview && appState.tapFileToPreview {
							FileViewerView(
								appState: appState, file: oe, siblings: entries,
								inSheet: false,
								isShown: .constant(true)
							)
							.navigationTitle(oe.fileName())
						}
						else {
							FileView(file: oe, appState: appState)
						}
					}
				}
				else {
					EmptyView()
				}
			})
	}
}
