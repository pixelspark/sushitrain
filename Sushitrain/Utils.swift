// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import VisionKit
import WebKit

extension SushitrainListOfStrings {
    public func asArray() -> [String] {
        var data: [String] = []
        for idx in 0..<self.count() {
            data.append(self.item(at: idx))
        }
        return data
    }
    
    static func from(_ array: [String]) -> SushitrainListOfStrings {
        let list = SushitrainNewListOfStrings()!
        for item in array {
            list.append(item)
        }
        return list
    }
}

extension SushitrainPeer {
    var displayName: String {
        let name = self.name()
        if !name.isEmpty {
            return name
        }
        return self.deviceID()
    }
}

extension SushitrainDate {
    public func date() -> Date {
        return Date(timeIntervalSince1970: Double(self.unixMilliseconds()) / 1000.0)
    }
}

extension SushitrainFolder: @retroactive Comparable {
    public static func < (lhs: SushitrainFolder, rhs: SushitrainFolder) -> Bool {
        return lhs.displayName < rhs.displayName
    }
}

extension SushitrainPeer: @retroactive Comparable {
    public static func < (lhs: SushitrainPeer, rhs: SushitrainPeer) -> Bool {
        return lhs.deviceID() < rhs.deviceID()
    }
}

extension SushitrainEntry: @retroactive Comparable {
    public static func < (lhs: SushitrainEntry, rhs: SushitrainEntry) -> Bool {
        return lhs.path() < rhs.path()
    }
}

extension SushitrainPeer: @retroactive Identifiable {
}

extension SushitrainChange: @retroactive Identifiable {
}

extension SushitrainChange {
    var systemImage: String {
        switch self.action {
        case "deleted":
            return "trash"
            
        case "modified":
            fallthrough
            
        default:
            return "pencil.circle"
        }
    }
}

import SwiftUI
import Combine
struct BackgroundSyncRun: Codable, Equatable {
    var started: Date
    var ended: Date?
    
    var asString: String {
        if let ended = self.ended {
            return "\(self.started.formatted()) - \(ended.formatted())"
        }
        return self.started.formatted()
    }
}

final class PublisherObservableObject: ObservableObject {
    
    var subscriber: AnyCancellable?
    
    init(publisher: AnyPublisher<Void, Never>) {
        subscriber = publisher.sink(receiveValue: { [weak self] _ in
            self?.objectWillChange.send()
        })
    }
}

extension SushitrainFolder {
    var isIdle: Bool {
        var error: NSError? = nil
        let s = self.state(&error)
        return s == "idle"
    }
    
    var isExternal: Bool? {
        var isExternal: ObjCBool = false
        do {
            try self.isExternal(&isExternal)
            return isExternal.boolValue
        } catch {
            return nil
        }
    }
    
    // When true, the folder's selection can be changed (files may be transferring, but otherwise the folder is idle)
    var isIdleOrSyncing: Bool {
        var error: NSError? = nil
        let s = self.state(&error)
        return s == "idle" || s == "syncing"
    }
    
    var displayName: String {
        let label = self.label()
        return label.isEmpty ? self.folderID : label
    }
    
    var localNativeURL: URL? {
        get {
            var error: NSError? = nil
            let localNativePath = self.localNativePath(&error)
            
            if let error = error {
                print("Could not get local native URL for folder: \(error.localizedDescription)")
            }
            else {
                return URL(fileURLWithPath: localNativePath)
            }
            return nil
        }
    }
    
    var isExcludedFromBackup: Bool? {
        get {
            guard let lu = self.localNativeURL else { return nil }
            let values = try? lu.resourceValues(forKeys: [.isExcludedFromBackupKey])
            return values?.isExcludedFromBackup
        }
        set {
            guard var lu = self.localNativeURL else { return }
            
            do {
                var values = try lu.resourceValues(forKeys: [.isExcludedFromBackupKey])
                values.isExcludedFromBackup = newValue
                try lu.setResourceValues(values)
            }
            catch {
                print("Unable to set back-up excluded setting: \(error.localizedDescription)")
            }
        }
    }
    
    var isHidden: Bool? {
        get {
            guard let lu = self.localNativeURL else { return nil }
            let values = try? lu.resourceValues(forKeys: [.isHiddenKey])
            return values?.isHidden
        }
        set {
            guard var lu = self.localNativeURL else { return }
            if var values = try? lu.resourceValues(forKeys: [.isHiddenKey]) {
                values.isHidden = newValue
                do {
                    try lu.setResourceValues(values)
                }
                catch {
                    print("Unable to set hide setting: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @MainActor
    func removeAndRemoveBookmark() throws {
        BookmarkManager.shared.removeBookmarkFor(folderID: self.folderID)
        try self.remove()
    }
    
    @MainActor
    func unlinkAndRemoveBookmark() throws {
        BookmarkManager.shared.removeBookmarkFor(folderID: self.folderID)
        try self.unlink()
    }
}

extension SushitrainEntry {
    var systemImage: String {
        if self.isSymlink() {
            return "link"
        }
        
        let base = self.isDirectory() ? "folder" : "document"
        if self.isLocallyPresent() {
            return "\(base).fill"
        }
        else if self.isDeleted() {
            return "trash"
        }
        else if self.isSelected() {
            return "\(base).badge.ellipsis"
        }
        else {
            return "\(base)"
        }
    }
    
    var isMedia: Bool {
        get {
            return self.isVideo || self.isAudio
        }
    }
    
    var isImage: Bool {
        get {
            return self.mimeType().starts(with: "image/")
        }
    }
    
    var isVideo: Bool {
        get {
            return self.mimeType().starts(with: "video/")
        }
    }
    var isAudio: Bool {
        get {
            return self.mimeType().starts(with: "audio/")
        }
    }
    
    var canThumbnail: Bool {
        return self.isImage && self.mimeType() != "image/svg+xml"
    }
}

#if os(iOS)
struct QRScannerViewRepresentable: UIViewControllerRepresentable {
    @Binding var scannedText: String
    @Binding var shouldStartScanning: Bool
    var dataToScanFor: Set<DataScannerViewController.RecognizedDataType>
    
    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: QRScannerViewRepresentable
        
        init(_ parent: QRScannerViewRepresentable) {
            self.parent = parent
        }
        
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in allItems {
                switch item {
                case .barcode(let barcode):
                    if let text = barcode.payloadStringValue, !text.isEmpty {
                        parent.scannedText = text
                        parent.shouldStartScanning = false
                        return
                    }
                    
                default:
                    break
                }
            }
        }
    }
    
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let dataScannerVC = DataScannerViewController(
            recognizedDataTypes: dataToScanFor,
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        
        dataScannerVC.delegate = context.coordinator
        return dataScannerVC
    }
    
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if shouldStartScanning {
            try? uiViewController.startScanning()
        } else {
            uiViewController.stopScanning()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
#endif

extension Bundle {
    var releaseVersionNumber: String? {
        return self.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildVersionNumber: String? {
        return self.infoDictionary?["CFBundleVersion"] as? String
    }

}

struct OptionalObject<T: Codable>: RawRepresentable {
    let wrappedValue: T?
    
    init(_ wrappedObject: T? = nil) {
        self.wrappedValue = wrappedObject
    }
    
    init?(rawValue: String) {
        if let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode(T.self, from: data)
        {
            self.wrappedValue = result
        }
        else {
            self.wrappedValue = nil
        }
    }
    
    var rawValue: String {
        guard let data = try? JSONEncoder().encode(wrappedValue),
              let result = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return result
    }
}

protocol Defaultable {
    init()
}

// Allows all Codable Arrays to be saved using AppStorage
extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

// Allows all Codable Sets to be saved using AppStorage
extension Set: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = Set(result)
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

extension Set {
    mutating func toggle(_ element: Element, _ t: Bool) {
        if t {
            self.insert(element)
        }
        else {
            self.remove(element)
        }
    }
}

@MainActor
func openURLInSystemFilesApp(url: URL) {
#if os(iOS)
    let sharedURL = url.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
    let furl: URL = URL(string: sharedURL)!
    UIApplication.shared.open(furl, options: [:], completionHandler: nil)
#endif
    
#if os(macOS)
    print("Open external URL", url)
    NSWorkspace.shared.activateFileViewerSelecting([url])
#endif
}

#if os(iOS)
let openInFilesAppLabel = String(localized: "Open in Files app")
#endif

#if os(macOS)
let openInFilesAppLabel = String(localized: "Show in Finder")
#endif

#if os(macOS)
extension NSImage {
    static func fromCIImage(_ ciImage: CIImage) -> NSImage {
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
#endif

struct CachedAsyncImage<Content>: View where Content: View {
    private let cacheKey: String
    private let url: URL
    private let scale: CGFloat
    private let transaction: Transaction
    private let content: (AsyncImagePhase) -> Content
    
    init(
        cacheKey: String,
        url: URL,
        scale: CGFloat = 1.0,
        transaction: Transaction = Transaction(),
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.cacheKey = cacheKey
        self.url = url
        self.scale = scale
        self.transaction = transaction
        self.content = content
    }
    
    var body: some View {
        if let cached = ImageCache[cacheKey] {
            let _ = print("cached: \(cacheKey)")
            content(.success(cached))
        }
        else {
            let _ = print("request: \(cacheKey)")
            AsyncImage(url: url, scale: scale, transaction: transaction) { phase in
                cacheAndRender(phase: phase)
            }
        }
    }
    
    func cacheAndRender(phase: AsyncImagePhase) -> some View {
        if case .success(let image) = phase {
            ImageCache[cacheKey] = image
        }
        return content(phase)
    }
}

@MainActor
fileprivate class ImageCache {
    static private var cache: [String: Image] = [:]
    static private var maxCacheSize = 64
    
    static subscript(cacheKey: String) -> Image? {
        get {
            ImageCache.cache[cacheKey]
        }
        set {
            while cache.count >= maxCacheSize {
                // This is a rather random way to remove items from the cache, investigate using an ordered map
                _ = ImageCache.cache.popFirst()
            }
            ImageCache.cache[cacheKey] = newValue
        }
    }
}

extension SushitrainChange: @unchecked @retroactive Sendable {}
extension SushitrainFolder: @unchecked @retroactive Sendable {}
extension SushitrainEntry: @unchecked @retroactive Sendable {}

#if os(macOS)
typealias UIViewRepresentable = NSViewRepresentable
#endif

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var error: Error?
    
    // With thanks to https://www.swiftyplace.com/blog/loading-a-web-view-in-swiftui-with-wkwebview
    class WebViewCoordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            parent.isLoading = false
            parent.error = error
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            parent.isLoading = false
            parent.error = error
        }
    }
    
    func makeCoordinator() -> WebViewCoordinator {
        return WebViewCoordinator(self)
    }
    
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        let request = URLRequest(url: url)
        view.load(request)
        return view
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    #endif
    
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        let request = URLRequest(url: url)
        view.load(request)
        return view
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    #endif
}

@MainActor
struct BookmarkManager {
    static var shared = BookmarkManager()
    private static let DefaultsKey = "bookmarksByFolderID"
    private var bookmarks: [String: Data] = [:]
    private var accessing: [String: Accessor] = [:]
    
    enum BookmarkManagerError: Error {
        case cannotAccess
    }
    
    class Accessor {
        var url: URL
        
        init(url: URL) throws {
            self.url = url
            if !url.startAccessingSecurityScopedResource() {
                throw BookmarkManagerError.cannotAccess
            }
            print("Start accessing \(url)")
        }
        
        deinit {
            print("Stop accessing \(url)")
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    init() {
        self.load()
    }
    
    mutating func saveBookmark(folderID: String, url: URL) throws {
        self.accessing[folderID] = try Accessor(url: url)
        bookmarks[folderID] = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        self.save()
    }
    
    mutating func removeBookmarkFor(folderID: String) {
        self.bookmarks.removeValue(forKey: folderID)
        self.accessing.removeValue(forKey: folderID)
        self.save()
    }
    
    func hasBookmarkFor(folderID: String) -> Bool {
        return self.bookmarks[folderID] != nil
    }
    
    mutating func resolveBookmark(folderID: String) throws -> URL? {
        guard let bookmarkData = bookmarks[folderID] else { return nil }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        guard !isStale else {
            print("Bookmark for \(folderID) is stale")
            self.bookmarks.removeValue(forKey: folderID)
            return nil
        }
        
        // Start accessing
        if let currentAccessor = self.accessing[folderID] {
            if currentAccessor.url != url {
                self.accessing[folderID] = try Accessor(url: url)
            }
        }
        else {
            self.accessing[folderID] = try Accessor(url: url)
        }
        return url
    }
    
    private mutating func load() {
        self.bookmarks = UserDefaults.standard.object(forKey: Self.DefaultsKey) as? [String: Data] ?? [:]
        print("Load bookmarks: \(self.bookmarks)")
    }
    
    private func save() {
        print("Saving bookmarks: \(self.bookmarks)")
        UserDefaults.standard.set(self.bookmarks, forKey: Self.DefaultsKey)
    }
    
    mutating func removeBookmarksForFoldersNotIn(_ folderIDs: Set<String>) {
        let toRemove = self.bookmarks.keys.filter({ !folderIDs.contains($0) })
        for toRemoveKey in toRemove {
            print("Removing stale bookmark \(toRemoveKey)")
            self.bookmarks.removeValue(forKey: toRemoveKey)
        }
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
