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
    @Published var results: [SushitrainEntry] = []
    private var cancelled = false
    private var lock = NSLock()
    var view: SearchViewDelegate
    static let MaxResultCount = 100
    
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
    
    var body: some View {
        SearchResultsView(
            appState: self.appState,
            searchText: $searchText,
            folder: .constant(""), 
            prefix: .constant("")
        )
        .navigationTitle("Search")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search files in all folders...")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // The below works from iOS18
        //.searchFocused($isSearchFieldFocused)
    }
}

struct SearchResultsView: View, SearchViewDelegate {
    @ObservedObject var appState: AppState
    @Binding var searchText: String
    @Binding var folder: String
    @Binding var prefix: String
    
    @State private var searchOperation: SearchOperation? = nil
    @State private var results: [SushitrainEntry] = []
    @State private var searchCount = 0
    @FocusState private var isSearchFieldFocused: Bool
    
    func add(entry: SushitrainEntry) {
        self.results.append(entry)
    }
    
    func setStatus(searching: Bool) {
        self.searchCount += (searching ? 1 : -1)
    }
    
    var body: some View {
        ZStack {
            List {                
                if !results.isEmpty {
                    Section {
                        ForEach(results, id: \.self) { (item: SushitrainEntry) in
                            if item.isDirectory() {
                                NavigationLink(destination: BrowserView(
                                    appState: appState,
                                    folder: item.folder!,
                                    prefix: "\(item.path())/"
                                )) {
                                    Label(item.fileName(), systemImage: "folder")
                                }
                            }
                            else {
                                NavigationLink(destination: FileView(file: item, folder: item.folder!, appState: self.appState, showPath: true, siblings: results)) {
                                    Label(item.fileName(), systemImage: item.isLocallyPresent() ? "doc.fill" : (item.isSelected() ? "doc.badge.ellipsis" : "doc"))
                                }
                            }
                        }
                    } header: {
                        HStack {
                            if results.count == SearchOperation.MaxResultCount {
                                Text("Search results (\(SearchOperation.MaxResultCount)+)")
                            }
                            else {
                                Text("Search results (\(results.count))")
                            }
                            Spacer()
                            if searchCount > 0 {
                                ProgressView()
                            }
                        }
                    }
                }
            }
            
            if results.isEmpty {
                if searchCount > 0 {
                    ProgressView()
                }
                else {
                    ContentUnavailableView("No files found", systemImage: "magnifyingglass", description: Text("Enter a text to search for in the search field above to search."))
                }
            }
        }
        .onChange(of: searchText) {
            self.search()
        }
        .onDisappear() {
            self.cancelSearch()
        }
        .onAppear() {
            self.isSearchFieldFocused = true
        }
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
        let folder = self.folder
        
        if !text.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    DispatchQueue.main.async {
                        sr.view.setStatus(searching: true)
                    }
                    try appState.client.search(text, delegate: sr, maxResults: SearchOperation.MaxResultCount, folderID: folder, prefix: prefix)
                    DispatchQueue.main.async {
                        sr.view.setStatus(searching: false)
                    }
                }
                catch let error {
                    print(error)
                }
            }
        }
    }
}
