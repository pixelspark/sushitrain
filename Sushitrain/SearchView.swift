import SwiftUI
@preconcurrency import SushitrainCore

protocol SearchViewDelegate {
    @MainActor func add(entry: SushitrainEntry)
    @MainActor func setStatus(searching: Bool)
}

class SearchResults: NSObject, ObservableObject, SushitrainSearchResultDelegateProtocol, @unchecked Sendable {
    @Published var results: [SushitrainEntry] = []
    private var cancelled = false
    var view: SearchViewDelegate
    
    init(delegate: SearchViewDelegate) {
        self.view = delegate
    }
    
    func result(_ entry: SushitrainEntry?) {
        if let entry = entry {
            DispatchQueue.main.async {
                self.add(entry: entry)
            }
        }
    }
    
    func isCancelled() -> Bool {
        return self.cancelled
    }
    
    func cancel() {
        self.cancelled = true
    }
    
    @MainActor func add(entry: SushitrainEntry) {
        view.add(entry: entry)
    }
}

struct SearchView: View, SearchViewDelegate {
    @ObservedObject var appState: SushitrainAppState
    @State private var searchText = ""
    @State private var searchResults: SearchResults? = nil
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
        List {
            ForEach(results, id: \.self) { item in
                NavigationLink(item.fileName()) {
                    FileView(file: item, folder: item.folder!, appState: appState)
                }
            }
            if searchCount > 0 {
                Text("Searching...")
            }
        }.navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search files in all folders...")
            // The below works from iOS18
            //.searchFocused($isSearchFieldFocused)
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
        if let sr = self.searchResults {
            sr.cancel()
            self.searchResults = nil
        }
    }
    
    func search() {
        self.cancelSearch()
        
        let sr = SearchResults(delegate: self)
        self.searchResults = sr
        self.results = []
        let text = self.searchText
        let appState = self.appState
        
        if !text.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    DispatchQueue.main.async {
                        sr.view.setStatus(searching: true)
                    }
                    try appState.client.search(text, delegate: sr)
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
