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
import CoreTransferable
import SwiftUI
import Combine

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

	var displayColor: Color {
		if self.isPaused() {
			return Color.gray
		}
		else {
			return Color.accentColor
		}
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
		}
		catch {
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

	var hasEncryptedPeers: Bool {
		return (self.sharedEncryptedWithDeviceIDs()?.count() ?? 0) > 0
	}

	@MainActor
	func removeAndRemoveBookmark() throws {
		BookmarkManager.shared.removeBookmarkFor(folderID: self.folderID)
		ExternalSharingManager.shared.removeExternalSharingFor(folderID: self.folderID)
		try self.remove()
	}

	@MainActor
	func unlinkAndRemoveBookmark() throws {
		BookmarkManager.shared.removeBookmarkFor(folderID: self.folderID)
		ExternalSharingManager.shared.removeExternalSharingFor(folderID: self.folderID)
		try self.unlink()
	}

	func listEntries(prefix: String, directories: Bool, hideDotFiles: Bool) throws -> [SushitrainEntry] {
		let list = try self.list(prefix, directories: directories, recurse: false)
		var entries: [SushitrainEntry] = []
		for i in 0..<list.count() {
			let path = list.item(at: i)
			if hideDotFiles && path.starts(with: ".") {
				continue
			}
			if let fileInfo = try? self.getFileInformation(prefix + path) {
				if fileInfo.isDirectory() || fileInfo.isDeleted() {
					continue
				}
				entries.append(fileInfo)
			}
		}
		return entries.sorted()
	}
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

extension SushitrainEntry {
	var color: Color? {
		if self.isConflictCopy() {
			return Color.red
		}
		else if self.isSymlink() {
			return Color.blue
		}
		else if self.isLocallyPresent() {
			return nil
		}
		else {
			return Color.secondary
		}
	}

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
		return self.isVideo || self.isAudio
	}

	var isImage: Bool {
		return self.mimeType().starts(with: "image/")
	}

	var isVideo: Bool {
		return self.mimeType().starts(with: "video/")
	}
	var isAudio: Bool {
		return self.mimeType().starts(with: "audio/")
	}

	var isPDF: Bool {
		return self.mimeType() == "application/pdf"
	}

	var isHTML: Bool {
		return self.mimeType() == "text/html"
	}

	var isWebPreviewable: Bool {
		if self.isPDF || self.isHTML || self.isImage {
			return true
		}

		return [
			"text/plain",
			"text/csv",
		].contains(self.mimeType())
	}

	var isStreamable: Bool {
		return self.isVideo || self.isAudio || self.isImage || self.isWebPreviewable
	}

	// Cannot make proper thumbnails for most AVI and SVG files and retrying each time is expensive
	private static let excludedThumbnailMIMETypes = [
		"video/x-msvideo", "image/svg+xml", "video/x-matroska", "video/x-ms-asf", "video/x-flv", "video/webm",
	]

	var canThumbnail: Bool {
		if self.isSymlink() || self.isDirectory() {
			return false
		}

		return !Self.excludedThumbnailMIMETypes.contains(self.mimeType())
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

	func isLocalOnlyCopy() async throws -> Bool {
		if !self.isLocallyPresent() {
			return false
		}

		let availability = try await Task.detached { [self] in
			return (try self.peersWithFullCopy()).asArray()
		}.value

		return availability.isEmpty
	}

	var thumbnailStrategy: ThumbnailStrategy {
		return self.isVideo ? .video : .image
	}

	var parentFolderName: String {
		let path = self.parentPath()
		let parts = path.split(separator: "/")
		if parts.count > 0 {
			return String(parts[parts.count - 1])
		}
		return ""
	}

	var canPreview: Bool {
		if self.isDirectory() || self.isSymlink() || self.isDeleted() {
			return false
		}

		if self.isLocallyPresent() && self.localNativeFileURL != nil {
			return true
		}
		else if self.isStreamable {
			let available = (try? self.peersWithFullCopy().count()) ?? 0 > 0
			return available
		}
		return false
	}

	// Shared functionality for swipe and toggle selection views
	var isSelectionToggleAvailable: Bool {
		if let folder = self.folder {
			return folder.isSelective()
		}
		return false
	}

	// First check to see if this action should be disabled
	var isSelectionToggleShallowDisabled: Bool {
		if self.isSymlink() {
			return true
		}
		if let folder = self.folder {
			return !folder.isSelective() || !folder.isIdleOrSyncing
		}
		return true
	}

	// Returns error message on fail
	func setSelectedFromToggle(s: Bool) async -> String? {
		do {
			if !self.isSelectionToggleShallowDisabled {
				// Check some additional things
				let isExplicitlySelected = self.isExplicitlySelected()
				if self.isSelected() && !isExplicitlySelected {
					// File is implicitly selected, do not allow changes
					return String(
						localized:
							"The synchronization setting for this item cannot be changed, because it is inside a subdirectory that is configured to be kept on this device."
					)
				}

				if !s {
					let isLocalOnlyCopy = try await self.isLocalOnlyCopy()
					if isLocalOnlyCopy {
						// We are the only remaining copy, can't deselect
						return String(
							localized:
								"The synchronization setting for this item cannot be changed, as the local copy is the only copy currently available."
						)
					}
				}

				// We can change the selection status
				try self.setExplicitlySelected(s)
			}
			else {
				if self.isSymlink() {
					return String(
						localized: "The synchronization setting for symlinks cannot be changed."
					)
				}
				else if let f = self.folder, !f.isSelective() {
					return String(
						localized: "The folder is not configured for selective synchronization."
					)
				}
				else {
					return String(
						localized: "Wait until the folder is done synchronizing and try again.")
				}

			}
		}
		catch {
			return String(
				localized:
					"The synchronization setting for this item could not be changed: \(error.localizedDescription)."
			)
		}

		return nil
	}

	var canShowInFinder: Bool {
		return self.isLocallyPresent() || self.isDirectory()  // Directories can be materialized
	}

	@MainActor func showInFinder() throws {
		if !self.isLocallyPresent() && self.isDirectory() {
			try? self.materializeSubdirectory()
		}

		if let localNativeURL = self.localNativeFileURL {
			openURLInSystemFilesApp(url: localNativeURL)
		}
	}

	var symlinkTargetURL: URL? {
		if !self.isSymlink() {
			return nil
		}

		if let targetURL = URL(string: self.symlinkTarget()),
			targetURL.scheme == "https" || targetURL.scheme == "http"
		{
			return targetURL
		}
		return nil
	}
}

extension SushitrainFolder: @retroactive Comparable {
	public static func < (lhs: SushitrainFolder, rhs: SushitrainFolder) -> Bool {
		return lhs.displayName < rhs.displayName
	}
}

extension SushitrainPeer: @retroactive Comparable {
	// Sort peers by display name, when there is a tie sort by the device ID (always unique)
	public static func < (lhs: SushitrainPeer, rhs: SushitrainPeer) -> Bool {
		let a = lhs.displayName
		let b = rhs.displayName
		if a == b {
			return lhs.deviceID() < rhs.deviceID()
		}
		return a < b
	}
}

extension SushitrainEntry: @retroactive Comparable {
	public static func < (lhs: SushitrainEntry, rhs: SushitrainEntry) -> Bool {
		return lhs.path() < rhs.path()
	}
}

extension SushitrainEntry: @retroactive Identifiable {
	public var id: String {
		return (self.folder?.folderID ?? "") + ":" + self.path()
	}
}

extension SushitrainPeer: @retroactive Identifiable {
	public var id: String {
		return self.deviceID()
	}
}

extension SushitrainFolder: @retroactive Identifiable {
	public var id: String {
		return self.folderID
	}
}

extension SushitrainChange: @retroactive Identifiable {
}

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

enum SushitrainEntryTransferableError: Error {
	case notAvailable
}

extension SushitrainEntry: @retroactive Transferable {
	static public var transferRepresentation: some TransferRepresentation {
		ProxyRepresentation { entry in
			if let url = entry.localNativeFileURL {
				return url
			}

			throw SushitrainEntryTransferableError.notAvailable
		}
		.exportingCondition { entry in
			entry.isLocallyPresent()
		}

		// This works somewhat, but must be repeated for each file type... so it cannot be made consistent
		// FileRepresentation(exportedContentType: .png, exporting: { try await $0.downloadFileToSent() }).exportingCondition({ !$0.isLocallyPresent() && $0.mimeType() == "image/png" })
		// FileRepresentation(exportedContentType: .data, exporting: { try await $0.downloadFileToSent() }).exportingCondition({ !$0.isLocallyPresent() })
	}

	//	private func downloadFileToSent() async throws -> SentTransferredFile {
	//        if let url = URL(string: self.onDemandURL()) {
	//            let (localURL, _) = try await URLSession.shared.download(from: url)
	//            return SentTransferredFile(localURL, allowAccessingOriginalFile: false)
	//        }
	//        throw SushitrainEntryTransferableError.notAvailable
	//    }
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

			func dataScanner(
				_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
				allItems: [RecognizedItem]
			) {
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
			}
			else {
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

extension SushitrainClient: @unchecked @retroactive Sendable {}
extension SushitrainChange: @unchecked @retroactive Sendable {}
extension SushitrainFolder: @unchecked @retroactive Sendable {}
extension SushitrainFolderStats: @unchecked @retroactive Sendable {}
extension SushitrainEntry: @unchecked @retroactive Sendable {}
extension SushitrainCompletion: @unchecked @retroactive Sendable {}

#if os(macOS)
	typealias UIViewRepresentable = NSViewRepresentable
#endif

struct HTTPError: Error {
	let statusCode: Int
}

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

		func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
			-> WKNavigationResponsePolicy
		{
			if let response = navigationResponse.response as? HTTPURLResponse {
				if response.statusCode != 200 {
					Log.warn("HTTP response received: \(response.statusCode)")
					parent.error = HTTPError(statusCode: response.statusCode)
				}
			}
			return .allow
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.isLoading = false
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
			Log.warn("WebView navigation failed: \(error.localizedDescription)")
			parent.isLoading = false
			parent.error = error
		}

		func webView(
			_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
			withError error: any Error
		) {
			Log.warn("WebView provisional navigation failed: \(error.localizedDescription)")
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
			view.isOpaque = false
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
			let config = WKWebViewConfiguration()
			config.limitsNavigationsToAppBoundDomains = false
			let view = WKWebView(frame: CGRectZero, configuration: config)
			view.navigationDelegate = context.coordinator
			view.setValue(false, forKey: "drawsBackground")
			view.allowsMagnification = true
			view.underPageBackgroundColor = NSColor.clear
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
	private static let defaultsKey = "bookmarksByFolderID"
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
			let url = try URL(
				resolvingBookmarkData: bookmarkData, options: [.withSecurityScope],
				bookmarkDataIsStale: &isStale)
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
		self.bookmarks = UserDefaults.standard.object(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
		Log.info("Load bookmarks: \(self.bookmarks)")
	}

	private func save() {
		Log.info("Saving bookmarks: \(self.bookmarks)")
		UserDefaults.standard.set(self.bookmarks, forKey: Self.defaultsKey)
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

extension CGImage {
	func resize(size: CGSize) -> CGImage? {
		let width = Int(size.width)
		let height = Int(size.height)

		guard let colorSpace = self.colorSpace else {
			return nil
		}
		guard
			let context = CGContext(
				data: nil, width: width, height: height, bitsPerComponent: self.bitsPerComponent,
				bytesPerRow: 0, space: colorSpace, bitmapInfo: self.alphaInfo.rawValue)
		else {
			return nil
		}

		context.interpolationQuality = .high
		context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}
}

extension CGSize {
	func fitScale(maxDimension: CGFloat) -> CGSize {
		if self.width > self.height {
			return CGSizeMake(maxDimension, floor(self.height / self.width * maxDimension))
		}
		else {
			return CGSizeMake(floor(self.width / self.height * maxDimension), maxDimension)
		}
	}
}

func writeURLToPasteboard(url: URL) {
	#if os(macOS)
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.prepareForNewContents()
		pasteboard.setString(url.absoluteString, forType: .string)
		pasteboard.setString(url.absoluteString, forType: .URL)
	#else
		UIPasteboard.general.urls = [url]
	#endif
}

func writeTextToPasteboard(_ text: String) {
	#if os(iOS)
		UIPasteboard.general.string = text
	#endif

	#if os(macOS)
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.prepareForNewContents()
		pasteboard.setString(text, forType: .string)
	#endif
}
