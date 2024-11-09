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
    
    var systemImage: String {
        return self.isConnected() ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill"
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
                Log.warn("Could not get local native URL for folder: \(error.localizedDescription)")
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
                Log.warn("Unable to set back-up excluded setting: \(error.localizedDescription)")
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
                    Log.info("Unable to set hide setting: \(error.localizedDescription)")
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
            if self.isDirectory() {
                return "questionmark.folder"
            }
            else {
                return "document.badge.ellipsis"
            }
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
        return (self.isImage && self.mimeType() != "image/svg+xml") || (!self.isDirectory() && self.isLocallyPresent())
    }
    
    var localNativeFileURL: URL? {
        var error: NSError? = nil
        if self.isLocallyPresent() {
            let path = self.localNativePath(&error)
            if error == nil {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
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
        NSWorkspace.shared.activateFileViewerSelecting([url])
    #endif
}

#if os(iOS)
    let openInFilesAppLabel = String(localized: "Open in Files app")
#endif

#if os(macOS)
    let openInFilesAppLabel = String(localized: "Show in Finder")
#endif

extension SushitrainChange: @unchecked @retroactive Sendable {}
extension SushitrainFolder: @unchecked @retroactive Sendable {}
extension SushitrainFolderStats: @unchecked @retroactive Sendable {}
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
            Log.info("Start accessing \(url)")
        }
        
        deinit {
            Log.info("Stop accessing \(url)")
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    init() {
        self.load()
    }
    
    mutating func saveBookmark(folderID: String, url: URL) throws {
        self.accessing[folderID] = try Accessor(url: url)
        #if os(macOS)
            bookmarks[folderID] = try url.bookmarkData(options: .withSecurityScope)
        #else
            bookmarks[folderID] = try url.bookmarkData(options: .minimalBookmark)
        #endif
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
        
        #if os(macOS)
            let url = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], bookmarkDataIsStale: &isStale)
        #else
            let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        #endif
        
        if isStale {
            // Refresh bookmark
            Log.info("Bookmark for \(folderID) is stale")
            do {
                #if os(macOS)
                    bookmarks[folderID] = try url.bookmarkData(options: .withSecurityScope)
                #else
                    bookmarks[folderID] = try url.bookmarkData(options: .minimalBookmark)
                #endif
                self.save()
            }
            catch {
                Log.warn("Could not refresh stale bookmark: \(error.localizedDescription)")
            }
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
        Log.info("Load bookmarks: \(self.bookmarks)")
    }
    
    private func save() {
        Log.info("Saving bookmarks: \(self.bookmarks)")
        UserDefaults.standard.set(self.bookmarks, forKey: Self.DefaultsKey)
    }
    
    mutating func removeBookmarksForFoldersNotIn(_ folderIDs: Set<String>) {
        let toRemove = self.bookmarks.keys.filter({ !folderIDs.contains($0) })
        for toRemoveKey in toRemove {
            Log.warn("Removing stale bookmark \(toRemoveKey)")
            self.bookmarks.removeValue(forKey: toRemoveKey)
        }
    }
}

final class Log {
    static func info(_ message: String) {
        SushitrainLogInfo(message)
    }
    
    static func warn(_ message: String) {
        SushitrainLogWarn(message)
    }
}

extension String {
    var withoutEndingSlash: String {
        if self.last == "/" {
            return String(self.dropLast())
        }
        return self
    }
}
