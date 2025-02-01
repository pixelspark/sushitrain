// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

protocol SearchViewDelegate {
	@MainActor func add(entry: SushitrainEntry)
	@MainActor func setStatus(searching: Bool)
}

class SearchOperation: NSObject, ObservableObject, SushitrainSearchResultDelegateProtocol, @unchecked Sendable {
	private var cancelled = false
	private var lock = NSLock()
	var view: SearchViewDelegate
	static let maxResultCount = 100

	init(delegate: SearchViewDelegate) {
		self.view = delegate
	}

	func result(_ entry: SushitrainEntry?) {
		if let entry = entry {
			if self.isCancelled() {
				return
			}

			DispatchQueue.main.async {
				self.add(entry: entry)
			}
		}
	}

	func isCancelled() -> Bool {
		return self.lock.withLock {
			return self.cancelled
		}
	}

	func cancel() {
		self.lock.withLock {
			self.cancelled = true
		}
	}

	@MainActor private func add(entry: SushitrainEntry) {
		view.add(entry: entry)
	}
}

struct SearchView: View {
	@ObservedObject var appState: AppState
	@State private var searchText = ""
	@FocusState private var isSearchFieldFocused
	var prefix: String = ""
	var folder: SushitrainFolder? = nil
	var initialSearchText = ""

	private var view: some View {
		SearchResultsView(
			appState: self.appState,
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
					searchText = initialSearchText
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
	@ObservedObject var appState: AppState
	@Binding var searchText: String
	@Binding var folderID: String
	@Binding var prefix: String

	@State private var searchOperation: SearchOperation? = nil
	@State private var results: [SushitrainEntry] = []
	@State private var searchCount = 0
	@FocusState private var isSearchFieldFocused: Bool
	@State private var showHiddenFolderEntries = false

	func add(entry: SushitrainEntry) {
		self.results.append(entry)
	}

	func setStatus(searching: Bool) {
		self.searchCount += (searching ? 1 : -1)
	}

	private var shownFiles: Int {
		var count = 0
		for item in self.results {
			if showHiddenFolderEntries || self.folderID != ""
				|| !(item.folder?.isHidden ?? false)
			{
				count += 1
			}
		}
		return count
	}

	var body: some View {
		ZStack {
			List {
				if !results.isEmpty {
					Section {
						ForEach(results, id: \.self) { (item: SushitrainEntry) in
							if showHiddenFolderEntries || self.folderID != ""
								|| !(item.folder?.isHidden ?? false)
							{
								if item.isDirectory() {
									NavigationLink(
										destination: BrowserView(
											appState: appState,
											folder: item.folder!,
											prefix: "\(item.path())/"
										)
									) {
										Label(
											item.fileName(),
											systemImage: "folder")
									}
								}
								else {
									NavigationLink(destination: {
										[appState, results, item] in
										FileView(
											file: item, appState: appState,
											showPath: true,
											siblings: results)
									}) {
										Label(
											item.fileName(),
											systemImage:
												item.isLocallyPresent()
												? "doc.fill"
												: (item.isSelected()
													? "doc.badge.ellipsis"
													: "doc"))
									}
								}
							}
						}

						if shownFiles == 0 && !showHiddenFolderEntries {
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
							if searchCount > 0 {
								ProgressView()
									#if os(macOS)
										.controlSize(.mini)
										.frame(maxHeight: 10)
									#endif
								Spacer()
							}

							// Search options
							if self.folderID == "" {
								self.searchOptionsMenu()
							}
						}
					}
				}
			}

			if results.isEmpty {
				if searchCount > 0 {
					ProgressView()
				}
				else if searchText.isEmpty {
					ContentUnavailableView(
						"Search for files", systemImage: "magnifyingglass",
						description: Text(
							"Enter a text to search for in the search field above to search."
						))
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
		.onChange(of: searchText) {
			self.search()
		}
		.onDisappear {
			self.cancelSearch()
		}
		.onAppear {
			self.isSearchFieldFocused = true
		}
	}

	private func searchOptionsMenu() -> some View {
		Menu(
			content: {
				Toggle(
					"Show results from hidden folders",
					systemImage: "eye.slash",
					isOn: $showHiddenFolderEntries
				)
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
		if let sr = self.searchOperation {
			sr.cancel()
			self.searchOperation = nil
		}
	}

	func search() {
		self.cancelSearch()

		let sr = SearchOperation(delegate: self)
		self.searchOperation = sr
		self.results = []
		let text = self.searchText
		let appState = self.appState
		let prefix = self.prefix
		let folderID = self.folderID

		if !text.isEmpty {
			let client = appState.client
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					DispatchQueue.main.async {
						sr.view.setStatus(searching: true)
					}
					try client.search(
						text, delegate: sr, maxResults: SearchOperation.maxResultCount,
						folderID: folderID, prefix: prefix)
					DispatchQueue.main.async {
						sr.view.setStatus(searching: false)
					}
				}
				catch let error {
					Log.info("Error searching: " + error.localizedDescription)
				}
			}
		}
	}
}
