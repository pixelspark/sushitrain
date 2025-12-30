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
	public func date() -> Date? {
		if self.unixMilliseconds() == 0 {
			return nil
		}
		return Date(timeIntervalSince1970: Double(self.unixMilliseconds()) / 1000.0)
	}
}

extension SushitrainFolder {
	static let knownGoodStates = Set([
		"idle", "syncing", "scanning", "sync-preparing", "cleaning", "sync-waiting", "scan-waiting", "clean-waiting",
	])

	var issue: String? {
		var error: NSError? = nil
		let s = self.state(&error)
		if error == nil {
			return s
		}
		return nil
	}

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
			if self.isPhotoFolder {
				return false
			}

			guard let lu = self.localNativeURL else { return nil }
			let values = try? lu.resourceValues(forKeys: [.isHiddenKey])
			return values?.isHidden
		}
		set {
			if self.isPhotoFolder {
				Log.info("Cannot change hide setting for photo folders; reaching this is a bug")
				return
			}

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

	var isSendOnlyFolder: Bool {
		return self.folderType() == SushitrainFolderTypeSendOnly
	}

	var isReceiveEncryptedFolder: Bool {
		return self.folderType() == SushitrainFolderTypeReceiveEncrypted
	}

	var isReceiveOnlyFolder: Bool {
		let ft = self.folderType()
		return ft == SushitrainFolderTypeReceiveOnly || ft == SushitrainFolderTypeReceiveEncrypted
	}

	/** A folder is 'regular' if it is backed by a file system where paths in the index correspond to paths in that file
	system.*/
	var isRegularFolder: Bool {
		// Receive-encrypted folders are not regular
		let folderType = self.folderType()
		if folderType == SushitrainFolderTypeReceiveEncrypted {
			return false
		}

		let fsType = self.filesystemType()
		return fsType == "basic" || fsType == ""
	}

	var isPhotoFolder: Bool {
		return self.filesystemType() == photoFSType
	}

	var hasEncryptedPeers: Bool {
		return (self.sharedEncryptedWithDeviceIDs()?.count() ?? 0) > 0
	}

	@MainActor
	func removeFolderAndSettings() throws {
		FolderSettingsManager.shared.removeSettingsFor(folderID: self.folderID)
		try self.remove()
	}

	@MainActor
	func unlinkFolderAndRemoveSettings() throws {
		FolderSettingsManager.shared.removeSettingsFor(folderID: self.folderID)
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

	var systemImage: String {
		if self.isReceiveEncryptedFolder {
			return "lock.circle.dotted"
		}
		if self.isReceiveOnlyFolder {
			return "arrow.forward.folder.fill.rtl"
		}
		else if self.isSendOnlyFolder {
			return "arrow.forward.folder.fill"
		}
		else if self.isPhotoFolder {
			return "photo.stack"
		}
		return "folder.fill"
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
			if let f = self.folder, f.isPhotoFolder {
				return base
			}
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
		if self.isSymlink() || self.isDirectory() || self.isArchive() {
			return false
		}

		return !Self.excludedThumbnailMIMETypes.contains(self.mimeType())
	}

	var localNativeFileURL: URL? {
		// For photo folders, there is never a local native URL
		if let f = self.folder, f.isPhotoFolder {
			return nil
		}

		var error: NSError? = nil
		if self.isLocallyPresent() {
			let path = self.localNativePath(&error)
			if error == nil {
				return URL(fileURLWithPath: path)
			}
		}
		return nil
	}

	nonisolated func isLocalOnlyCopy() async throws -> Bool {
		if !self.isLocallyPresent() {
			return false
		}

		let availability = try await Task { [self] in
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
		if let f = self.folder {
			return f.isRegularFolder && (self.isLocallyPresent() || self.isDirectory())  // Directories can be materialized
		}
		return false
	}

	@MainActor func showInFinder() throws {
		if let f = self.folder {
			if !f.isRegularFolder {
				return
			}

			if !self.isLocallyPresent() && self.isDirectory() {
				try? self.materializeSubdirectory()
			}

			if let localNativeURL = self.localNativeFileURL {
				openURLInSystemFilesApp(url: localNativeURL)
			}
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
extension SushitrainPeer: @unchecked @retroactive Sendable {}
extension SushitrainArchive: @unchecked @retroactive Sendable {}
extension SushitrainMeasurement: @unchecked @retroactive Sendable {}

#if os(macOS)
	typealias UIViewRepresentable = NSViewRepresentable
#endif

struct HTTPError: LocalizedError {
	let statusCode: Int

	var errorDescription: String? {
		switch self.statusCode {
		case 404:
			return String(localized: "This page could not be found")

		case 401:
			return String(localized: "To access this page you need to log in")

		case 403:
			return String(localized: "Access to this page was denied")

		case 500...599:
			return String(localized: "An error occured on the server (\(statusCode))")

		default:
			return String(localized: "HTTP error \(statusCode)")
		}

	}
}

struct WebView: UIViewRepresentable {
	let url: URL
	var trustFingerprints: [Data] = []
	var cookies: [HTTPCookie] = []
	var verticallyCenter: Bool = false

	@State var isOpaque: Bool = false

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

		func webView(
			_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
			completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
		) {
			// Trust specific (self-signed) certificates if we have fingerprints for them, and they match the server's
			if let serverTrust = challenge.protectionSpace.serverTrust, !self.parent.trustFingerprints.isEmpty {
				if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], certChain.count == 1 {
					let serverCertSha256Signature = certChain[0].sha256
					if self.parent.trustFingerprints.contains(where: { $0 == serverCertSha256Signature }) {
						Log.info("Certificate fingerprint matches: \(certChain[0].sha256.base64EncodedString())")
						let exceptions = SecTrustCopyExceptions(serverTrust)
						SecTrustSetExceptions(serverTrust, exceptions)
						completionHandler(.useCredential, URLCredential(trust: serverTrust))
						return
					}
					else {
						Log.warn("No match for certificate fingerprint: \(certChain[0].sha256.base64EncodedString())")
					}
				}
				else {
					Log.warn("Received empty certificate chain")
				}
			}

			// Just do the default validation
			completionHandler(.performDefaultHandling, nil)
		}

		private static func verticallyCenter(_ webView: WKWebView) async throws {
			try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(), Error>) in
				webView.evaluateJavaScript(
					"""
					 (function() {
					  document.body.style.display = "grid";
					 })()
					""",
					completionHandler: { e, err in
						if let err = err {
							cont.resume(throwing: err)
						}
						else {
							cont.resume(returning: ())
						}
					})
			}
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			if parent.verticallyCenter {
				Task {
					try await Self.verticallyCenter(webView)
					parent.isLoading = false
				}
			}
			else {
				parent.isLoading = false
			}
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
			Log.warn("WebView navigation failed: \(error.localizedDescription) \(parent.url)")
			parent.isLoading = false
			parent.error = error
		}

		func webView(
			_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
			withError error: any Error
		) {
			Log.warn("WebView provisional navigation failed: \(error.localizedDescription) \(parent.url)")
			parent.isLoading = false
			parent.error = error
		}
	}

	func makeCoordinator() -> WebViewCoordinator {
		return WebViewCoordinator(self)
	}

	private var config: WKWebViewConfiguration {
		let config = WKWebViewConfiguration()
		config.limitsNavigationsToAppBoundDomains = false
		for cookie in self.cookies {
			Log.info("Adding cookie \(cookie)")
			config.websiteDataStore.httpCookieStore.setCookie(cookie)
		}
		return config
	}

	#if os(iOS)
		func makeUIView(context: Context) -> WKWebView {
			let view = WKWebView(frame: .zero, configuration: self.config)
			view.navigationDelegate = context.coordinator
			view.isOpaque = self.isOpaque
			view.scrollView.contentInsetAdjustmentBehavior = .always
			let request = URLRequest(url: url)
			view.load(request)
			return view
		}

		func updateUIView(_ webView: WKWebView, context: Context) {
			// This sometimes 'resets' the URL to the initial URL when the user has navigated.
			// A better solution is to use .id(initialURL) on the WebView
			// if webView.url != url {
			// let request = URLRequest(url: url)
			// webView.load(request)
			// }
		}
	#endif

	#if os(macOS)
		func makeNSView(context: Context) -> WKWebView {
			let view = WKWebView(frame: CGRectZero, configuration: self.config)
			view.navigationDelegate = context.coordinator
			view.setValue(false, forKey: "drawsBackground")
			view.allowsMagnification = true
			view.underPageBackgroundColor = NSColor.clear
			let request = URLRequest(url: url)
			view.load(request)
			return view
		}

		func updateNSView(_ webView: WKWebView, context: Context) {
			// This sometimes 'resets' the URL to the initial URL when the user has navigated.
			// A better solution is to use .id(initialURL) on the WebView
			// if webView.url != url {
			//	let request = URLRequest(url: url)
			//	webView.load(request)
			// }
		}
	#endif
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

	var withoutStartingSlash: String {
		if self.first == "/" {
			return String(self.dropFirst())
		}
		return self
	}

	var lastPathComponent: String {
		return self.split(separator: "/").last.map(String.init) ?? self
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

// Run a possibly blocking task in the background (for calls into Go code)
func goTask(_ block: @Sendable @escaping () async throws -> Void) async throws {
	try await Task { @concurrent in
		dispatchPrecondition(condition: .notOnQueue(.main))
		try await block()
	}.value
}

import CommonCrypto
import UniformTypeIdentifiers

extension SecCertificate {
	var sha256: Data {
		var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
		let der = SecCertificateCopyData(self) as Data
		_ = CC_SHA256(Array(der), CC_LONG(der.count), &digest)
		return Data(digest)
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

struct EntryComparator: SortComparator {
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
				let r = compareDates(lhs.modifiedAt()?.date() ?? Date.distantPast, rhs.modifiedAt()?.date() ?? Date.distantPast)
				return order == .forward ? r : r.flipped
			case .name:
				return order == .forward
					? lhs.name().compare(rhs.name(), options: .numeric) : rhs.name().compare(lhs.name(), options: .numeric)
			case .fileExtension:
				return order == .forward
					? lhs.extension().compare(rhs.extension(), options: .numeric)
					: rhs.extension().compare(lhs.extension(), options: .numeric)
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
					? lhs.name().compare(rhs.name(), options: .numeric) : rhs.name().compare(lhs.name(), options: .numeric)

			case .fileExtension:
				return order == .forward
					? lhs.extension().compare(rhs.extension(), options: .numeric)
					: rhs.extension().compare(lhs.extension(), options: .numeric)

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

extension URL {
	// Checks if the target  has certain data protection mechanisms turned on that may
	// disallow us from accessing the folder while the device is locked
	func hasUnsupportedProtection() -> Bool {
		#if os(iOS)
			let unsupportedProtection = Set<URLFileProtection>([.complete, .completeWhenUserInactive])
		#else
			let unsupportedProtection = Set<URLFileProtection>([.complete])
		#endif

		do {
			let rv = try self.resourceValues(forKeys: [.fileProtectionKey])
			if let fp = rv.fileProtection {
				Log.info("Data protection setting for \(path) is \(fp)")

				if unsupportedProtection.contains(fp) {
					Log.warn("Directory has unsupported data protection setting: \(fp) (\(path))")
					return true
				}
			}
		}
		catch {
			Log.warn("Could not obtain file protection status for url \(path): \(error)")
		}
		return false
	}
}

extension FileManager {
	nonisolated func sizeOfFolder(path: URL) async throws -> UInt {
		let files = try self.subpathsOfDirectory(atPath: path.path(percentEncoded: false))
		var totalSize: UInt = 0
		for file in files {
			let filePath = path.appendingPathComponent(file)
			let fileDictionary = try self.attributesOfItem(atPath: filePath.path(percentEncoded: false))
			if let size = fileDictionary[FileAttributeKey.size] as? UInt {
				totalSize += size
			}
			else {
				Log.warn("No file size for path \(filePath.path) \(file) \(fileDictionary)")
			}
		}
		return totalSize
	}
}

struct SheetButton: ToolbarContent {
	enum SheetButtonRole {
		case done
		case cancel
		case add
		case save

		@available(iOS 26.0, macOS 26.0, *)
		var buttonRole: ButtonRole {
			switch self {
			case .done: return .close
			case .cancel: return .cancel
			case .add: return .confirm
			case .save: return .confirm
			}
		}

		var placement: ToolbarItemPlacement {
			switch self {
			case .add: return .confirmationAction
			case .done: return .confirmationAction
			case .cancel: return .cancellationAction
			case .save: return .confirmationAction
			}
		}
	}

	#if os(iOS)
		@Environment(\.editMode) private var editMode
	#endif

	let role: SheetButtonRole
	var isDisabled: Bool = false
	let action: () -> Void

	var body: some ToolbarContent {
		ToolbarItem(placement: self.role.placement) {
			if #available(iOS 26.0, macOS 26.0, *) {
				Button(role: self.role.buttonRole, action: self.action)
					.disabled(self.isDisabled || self.inEditMode)
			}
			else {
				self.legacyButton()
					.disabled(self.isDisabled || self.inEditMode)
			}
		}
	}

	@ViewBuilder private func legacyButton() -> some View {
		switch self.role {
		case .save:
			Button("Save", action: self.action)
		case .done:
			Button("Done", action: self.action)
		case .cancel:
			Button("Cancel", role: .cancel, action: self.action)
		case .add:
			Button("Add", action: self.action)
		}
	}

	private var inEditMode: Bool {
		#if os(macOS)
			return false
		#else
			return editMode?.wrappedValue.isEditing ?? false
		#endif
	}
}

extension Binding where Value == Bool {
	static func isNotNil<T: Sendable>(_ underlying: Binding<T?>) -> Binding<Bool> {
		return Binding(
			get: { underlying.wrappedValue != nil }, set: { underlying.wrappedValue = $0 ? underlying.wrappedValue : nil })
	}
}
