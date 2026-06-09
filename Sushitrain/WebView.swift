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
	@Environment(\.showToast) private var showToast

	@Binding var isLoading: Bool
	@Binding var error: Error?

	// With thanks to https://www.swiftyplace.com/blog/loading-a-web-view-in-swiftui-with-wkwebview
	class WebViewCoordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
		var parent: WebView

		init(_ parent: WebView) {
			self.parent = parent
		}

		func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
			parent.isLoading = true
		}

		func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
			-> WKNavigationActionPolicy
		{
			if navigationAction.shouldPerformDownload {
				return .download
			}
			return .allow
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

			if self.shouldDownload(navigationResponse) {
				return .download
			}
			return .allow
		}

		func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
			download.delegate = self
		}

		func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
			download.delegate = self
		}

		func webView(
			_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
			initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
		) {
			#if os(iOS)
				guard let presenter = Self.presenter(for: webView) else {
					completionHandler()
					return
				}

				let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
				alert.addAction(
					UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
						completionHandler()
					})
				presenter.present(alert, animated: true)
			#endif

			#if os(macOS)
				let alert = NSAlert()
				alert.messageText = message
				alert.addButton(withTitle: String(localized: "OK"))
				Self.run(alert: alert, for: webView) { _ in
					completionHandler()
				}
			#endif
		}

		func webView(
			_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
			initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
		) {
			#if os(iOS)
				guard let presenter = Self.presenter(for: webView) else {
					completionHandler(false)
					return
				}

				let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
				alert.addAction(
					UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
						completionHandler(false)
					})
				alert.addAction(
					UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
						completionHandler(true)
					})
				presenter.present(alert, animated: true)
			#endif

			#if os(macOS)
				let alert = NSAlert()
				alert.messageText = message
				alert.addButton(withTitle: String(localized: "OK"))
				alert.addButton(withTitle: String(localized: "Cancel"))
				Self.run(alert: alert, for: webView) { response in
					completionHandler(response == .alertFirstButtonReturn)
				}
			#endif
		}

		func webView(
			_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
			initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
		) {
			#if os(iOS)
				guard let presenter = Self.presenter(for: webView) else {
					completionHandler(nil)
					return
				}

				let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
				alert.addTextField { textField in
					textField.text = defaultText
				}
				alert.addAction(
					UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
						completionHandler(nil)
					})
				alert.addAction(
					UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
						completionHandler(alert.textFields?.first?.text)
					})
				presenter.present(alert, animated: true)
			#endif

			#if os(macOS)
				let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
				textField.stringValue = defaultText ?? ""

				let alert = NSAlert()
				alert.messageText = prompt
				alert.accessoryView = textField
				alert.addButton(withTitle: String(localized: "OK"))
				alert.addButton(withTitle: String(localized: "Cancel"))
				Self.run(alert: alert, for: webView) { response in
					completionHandler(response == .alertFirstButtonReturn ? textField.stringValue : nil)
				}
			#endif
		}

		#if os(iOS)
			private static func presenter(for webView: WKWebView) -> UIViewController? {
				let rootViewController =
					webView.window?.rootViewController
					?? UIApplication.shared.connectedScenes
					.compactMap { $0 as? UIWindowScene }
					.flatMap(\.windows)
					.last(where: { $0.isKeyWindow })?
					.rootViewController

				return topViewController(from: rootViewController)
			}

			private static func topViewController(from viewController: UIViewController?) -> UIViewController? {
				if let navigationController = viewController as? UINavigationController {
					return topViewController(from: navigationController.visibleViewController)
				}

				if let tabBarController = viewController as? UITabBarController {
					return topViewController(from: tabBarController.selectedViewController)
				}

				if let presentedViewController = viewController?.presentedViewController {
					return topViewController(from: presentedViewController)
				}

				return viewController
			}
		#endif

		#if os(macOS)
			private static func run(
				alert: NSAlert, for webView: WKWebView,
				completionHandler: @escaping @MainActor (NSApplication.ModalResponse) -> Void
			) {
				if let window = webView.window {
					alert.beginSheetModal(for: window) { response in
						completionHandler(response)
					}
				}
				else {
					completionHandler(alert.runModal())
				}
			}

			func webView(
				_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
				initiatedByFrame frame: WKFrameInfo
			) async -> [URL]? {
				let openPanel = NSOpenPanel()
				openPanel.canChooseFiles = true
				let result = await openPanel.begin()
				if result == NSApplication.ModalResponse.OK {
					if let url = openPanel.url {
						return [url]
					}
				}
				else if result == NSApplication.ModalResponse.cancel {
					return nil
				}
				return nil
			}
		#endif

		func download(
			_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
			completionHandler: @escaping @MainActor (URL?) -> Void
		) {
			do {
				let destination = try Self.downloadDestination(suggestedFilename: suggestedFilename)
				Log.info("Downloading \(response.url?.absoluteString ?? "file") to \(destination)")
				self.parent.showToast(
					Toast(title: "Downloaded '\(suggestedFilename)'", image: "square.and.arrow.down.badge.checkmark"))
				completionHandler(destination)
			}
			catch {
				Log.warn("Could not save download to Downloads folder: \(error.localizedDescription)")
				parent.error = error
				completionHandler(nil)
			}
		}

		func downloadDidFinish(_ download: WKDownload) {
			parent.isLoading = false
		}

		func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
			Log.warn("WebView download failed: \(error.localizedDescription)")
			parent.isLoading = false
			parent.error = error
		}

		private func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
			if !navigationResponse.canShowMIMEType {
				return true
			}

			if let response = navigationResponse.response as? HTTPURLResponse,
				let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition")
			{
				return contentDisposition.localizedCaseInsensitiveContains("attachment")
			}

			return false
		}

		private static func downloadDestination(suggestedFilename: String) throws -> URL {
			guard
				let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
			else {
				throw CocoaError(.fileNoSuchFile)
			}

			try FileManager.default.createDirectory(
				at: downloadsDirectory, withIntermediateDirectories: true)

			let filename = sanitizedDownloadFilename(suggestedFilename)
			return uniqueDownloadURL(in: downloadsDirectory, filename: filename)
		}

		private static func sanitizedDownloadFilename(_ filename: String) -> String {
			let lastPathComponent = (filename as NSString).lastPathComponent
			let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? String(localized: "Download") : trimmed
		}

		private static func uniqueDownloadURL(in directory: URL, filename: String) -> URL {
			let fileManager = FileManager.default
			let baseURL = directory.appendingPathComponent(filename, isDirectory: false)
			if !fileManager.fileExists(atPath: baseURL.path) {
				return baseURL
			}

			let pathExtension = baseURL.pathExtension
			let basename =
				pathExtension.isEmpty
				? baseURL.deletingPathExtension().lastPathComponent
				: String(baseURL.lastPathComponent.dropLast(pathExtension.count + 1))

			for index in 2... {
				let candidateName =
					pathExtension.isEmpty
					? "\(basename) \(index)"
					: "\(basename) \(index).\(pathExtension)"
				let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
				if !fileManager.fileExists(atPath: candidate.path) {
					return candidate
				}
			}

			return baseURL
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
			if Self.isCancelledNavigation(error) {
				parent.isLoading = false
				return
			}
			Log.warn("WebView navigation failed: \(error.localizedDescription) \(parent.url)")
			parent.isLoading = false
			parent.error = error
		}

		func webView(
			_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
			withError error: any Error
		) {
			if Self.isCancelledNavigation(error) {
				parent.isLoading = false
				return
			}
			Log.warn("WebView provisional navigation failed: \(error.localizedDescription) \(parent.url)")
			parent.isLoading = false
			parent.error = error
		}

		private static func isCancelledNavigation(_ error: any Error) -> Bool {
			let nsError = error as NSError
			return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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
			view.uiDelegate = context.coordinator
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
			view.uiDelegate = context.coordinator
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
