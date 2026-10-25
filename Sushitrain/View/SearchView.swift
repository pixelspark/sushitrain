// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct SearchResult: Identifiable, @unchecked Sendable {
	struct ID: Hashable {
		let folderID: String
		let path: String
	}

	let id: ID
	let entry: SushitrainEntry
	let folder: SushitrainFolder
	let isHidden: Bool
}

protocol SearchViewDelegate {
	@MainActor func add(results: [SearchResult], from: SearchOperation)
	@MainActor func setStatus(searching: Bool, from: SearchOperation)
}

class SearchOperation: NSObject, SushitrainSearchResultDelegateProtocol, @unchecked Sendable {
	private var cancelled = false
	private let lock = NSLock()
	let view: SearchViewDelegate
	static let maxResultCount = 100

	// Only accessed by the search worker, including finish(). Never read by the UI.
	private var pending: [SearchResult] = []
	private var hiddenFolders: [String: Bool] = [:]
	private var resultCount = 0
	private var lastDelivery = ContinuousClock.now

	init(delegate: SearchViewDelegate) {
		self.view = delegate
	}

	func result(_ entry: SushitrainEntry?) {
		guard !isCancelled(), resultCount < Self.maxResultCount,
			let entry, let folder = entry.folder
		else { return }

		// Read filesystem metadata once per folder, on the search worker.
		let hidden = hiddenFolders[folder.folderID] ?? (folder.isHidden ?? false)
		hiddenFolders[folder.folderID] = hidden
		pending.append(
			SearchResult(
				id: .init(folderID: folder.folderID, path: entry.path()),
				entry: entry, folder: folder, isHidden: hidden))
		resultCount += 1

		if pending.count >= 25 || lastDelivery.duration(to: .now) >= .milliseconds(100) {
			deliverPending()
		}
	}

	private func deliverPending() {
		guard !pending.isEmpty else { return }
		let batch = pending
		pending.removeAll(keepingCapacity: true)
		lastDelivery = .now
		DispatchQueue.main.async {
			guard !self.isCancelled() else { return }
			self.view.add(results: batch, from: self)
		}
	}

	func finish() {
		deliverPending()
		DispatchQueue.main.async {
			guard !self.isCancelled() else { return }
			self.view.setStatus(searching: false, from: self)
		}
	}

	func isCancelled() -> Bool {
		return self.lock.withLock { self.cancelled }
	}

	func cancel() {
		self.lock.withLock { self.cancelled = true }
	}
}

struct SearchView: View {
	@Environment(AppState.self) private var appState
	@State private var searchText = ""
	@FocusState private var isSearchFieldFocused
	var prefix: String = ""
	var folder: SushitrainFolder? = nil
	var initialSearchText = ""

	private var view: some View {
		SearchResultsView(
			userSettings: appState.userSettings,
			searchText: $searchText,
			folderID: .constant(self.folder?.folderID ?? ""),
			prefix: .constant(self.prefix)
		)
		.navigationTitle("Search")
		.searchable(text: $searchText, placement: .toolbar, prompt: self.prompt)
		#if os(iOS)
			.textInputAutocapitalization(.never)
		#endif
		.autocorrectionDisabled()
	}

	var body: some View {
		if #available(iOS 18, *) {
			self.view
				.searchFocused($isSearchFieldFocused)
				.onAppear {
					isSearchFieldFocused = true
					if searchText.isEmpty {
						searchText = initialSearchText
					}
				}
		}
		else {
			self.view
		}
	}

	private var prompt: String {
		if self.folder == nil {
			return String(localized: "Search files in all folders...")
		}
		else {
			if self.prefix == "" {
				return String(localized: "Search in this folder...")
			}
			else {
				return String(localized: "Search in this subdirectory...")
			}
		}
	}
}

struct SearchResultsView: View, SearchViewDelegate {
	@Environment(AppState.self) private var appState
	@ObservedObject var userSettings: AppUserSettings
	@Binding var searchText: String
	@Binding var folderID: String
	@Binding var prefix: String

	@State private var searchOperation: SearchOperation? = nil
	@State private var results: [SearchResult] = []
	@State private var isSearching = false
	@FocusState private var isSearchFieldFocused: Bool
	@State private var showHiddenFolderEntries = false

	func add(results: [SearchResult], from: SearchOperation) {
		guard from === self.searchOperation else { return }
		self.results.append(contentsOf: results.prefix(SearchOperation.maxResultCount - self.results.count))
	}

	func setStatus(searching: Bool, from: SearchOperation) {
		guard from === self.searchOperation else { return }
		self.isSearching = searching
	}

	private var visibleResults: [SearchResult] {
		results.filter { showHiddenFolderEntries || !folderID.isEmpty || !$0.isHidden }
	}

	var body: some View {
		let visibleResults = self.visibleResults
		let siblings = results.map(\.entry)
		ZStack {
			List {
				if !folderID.isEmpty {
					if let folder = appState.client.folder(withID: folderID) {
						// Encrypted file path pasted? Attempt to show decrypted path
						DecryptedFilePathsView(folder: folder, path: searchText)
					}
				}

				if !results.isEmpty {
					Section {
						ForEach(visibleResults) { result in
							SearchResultItemView(folder: result.folder, item: result.entry, siblings: siblings)
						}

						if visibleResults.isEmpty && !showHiddenFolderEntries {
							Button("Show results from hidden folders") {
								showHiddenFolderEntries = true
							}
						}
					} header: {
						HStack {
							if results.count == SearchOperation.maxResultCount {
								Text(
									"Search results (\(SearchOperation.maxResultCount)+)"
								)
							}
							else {
								Text("Search results (\(results.count))")
							}
							Spacer()
							if isSearching {
								ProgressView()
									#if os(macOS)
										.controlSize(.mini)
										.frame(maxHeight: 10)
									#endif
							}

							// Search options
							self.searchOptionsMenu()
						}
					}
				}
			}

			if searchText.isEmpty {
				ContentUnavailableView(
					"Search for files", systemImage: "magnifyingglass",
					description: Text(
						"Enter a text to search for in the search field above to search."
					))
			}
			else if results.isEmpty {
				if isSearching {
					ProgressView()
				}
				else {
					ContentUnavailableView(
						"No files found", systemImage: "magnifyingglass",
						description: Text(
							"Enter a text to search for in the search field above to search."
						))
				}
			}
		}
		.onChange(of: folderID) {
			self.search()
		}
		.onChange(of: prefix) {
			self.search()
		}
		.onChange(of: searchText) {
			self.search()
		}
		.onDisappear {
			self.cancelSearch()
		}
		.onAppear {
			self.isSearchFieldFocused = true
			self.search()
		}
	}

	private func searchOptionsMenu() -> some View {
		Menu(
			content: {
				if self.folderID == "" {
					Toggle(
						"Show results from hidden folders",
						systemImage: "eye.slash",
						isOn: $showHiddenFolderEntries
					)
				}

				Toggle("Show thumbnails", isOn: userSettings.$showThumbnailsInSearchResults)
			},
			label: {
				Image(systemName: "ellipsis.circle").accessibilityLabel(
					Text("Menu"))
			}
		)
		#if os(macOS)
			.menuStyle(.borderlessButton)
			.frame(width: 36)
		#endif
	}

	func cancelSearch() {
		self.isSearching = false
		if let sr = self.searchOperation {
			sr.cancel()
			self.searchOperation = nil
		}
	}

	func search() {
		self.cancelSearch()

		self.results = []
		guard !searchText.isEmpty else { return }

		let sr = SearchOperation(delegate: self)
		self.searchOperation = sr
		sr.view.setStatus(searching: true, from: sr)

		let text = self.searchText
		let appState = self.appState
		let prefix = self.prefix
		let folderID = self.folderID

		let client = appState.client
		DispatchQueue.global(qos: .userInitiated).async {
			if !text.isEmpty {
				do {
					try client.search(
						text,
						delegate: sr,
						maxResults: SearchOperation.maxResultCount,
						folderID: folderID,
						prefix: prefix
					)
				}
				catch let error {
					Log.info("Error searching: " + error.localizedDescription)
				}
			}

			sr.finish()
		}
	}
}

private struct SearchResultItemView: View {
	@Environment(AppState.self) var appState
	let folder: SushitrainFolder
	let item: SushitrainEntry
	let siblings: [SushitrainEntry]

	var body: some View {
		if item.isDirectory() {
			let fileName = item.path()
			NavigationLink(destination: BrowserView(folder: folder, prefix: "\(fileName)/", userSettings: appState.userSettings))
			{
				HStack(spacing: 9.0) {
					Image(systemName: item.systemImage).foregroundStyle(item.color ?? Color.accentColor)
					Text(item.fileName()).multilineTextAlignment(.leading).foregroundStyle(Color.primary).opacity(
						item.isLocallyPresent() ? 1.0 : EntryView.remoteFileOpacity)
					Spacer()
				}.frame(maxWidth: .infinity).padding(0)
			}
		}
		else {
			EntryView(
				entry: item,
				folder: nil,
				siblings: siblings,
				showThumbnail: self.appState.userSettings.showThumbnailsInSearchResults
			)
		}
	}
}
