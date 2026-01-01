// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import UniformTypeIdentifiers

private class DownloadOperation: NSObject, ObservableObject, SushitrainDownloadDelegateProtocol, @unchecked Sendable {
	@Published var error: String? = nil
	@Published var progressFraction: Double = 0.0
	@Published var downloadedFileURL: URL? = nil
	private var lock = NSLock()
	private var cancelled = false

	deinit {
		self.cancel()
	}

	func onError(_ error: String?) {
		DispatchQueue.main.async {
			self.error = error
		}
	}

	func onFinished(_ path: String?) {
		DispatchQueue.main.async {
			if let path = path {
				self.downloadedFileURL = URL(fileURLWithPath: path)
			}
		}
	}

	func onProgress(_ fraction: Double) {
		DispatchQueue.main.async {
			self.progressFraction = fraction
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
}

/// A view that downloads an item and then performs a configurable action, such as quick look.
struct EntryDownloaderView: View {
	enum AfterDownloadAction: Identifiable {
		case quickLook(dismissAfterClose: Bool)
		case share

		var id: String {
			switch self {
			case .quickLook(dismissAfterClose: let a):
				return a ? "quickLookWithDismiss" : "quickLook"
			case .share:
				return "share"
			}
		}
	}

	let file: SushitrainDownloadableProtocol
	let action: AfterDownloadAction

	@Environment(AppState.self) private var appState

	@StateObject private var downloadOperation: DownloadOperation = DownloadOperation()
	@State private var quicklookHidden = false
	@State private var filePath: URL? = nil
	@State private var tempDirPath: URL? = nil
	@State private var showFileExporter = false
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		ZStack {
			HStack {
				Spacer()
				VStack {
					Spacer()
					if let error = downloadOperation.error {
						ContentUnavailableView(
							"Could not download file", systemImage: "exclamationmark.triangle",
							description: Text(error))
					}
					else if let downloadedFileURL = downloadOperation.downloadedFileURL {
						self.actionView(downloadedFileURL)
					}
					else {
						ContentUnavailableView {
							ProgressView(value: downloadOperation.progressFraction, total: 1.0)
						} description: {
							Text("Downloading file...")
						}
					}
					Spacer()
				}
				Spacer()
			}
		}
		.quickLookPreview(
			Binding(
				get: {
					if case .quickLook(_) = action, !quicklookHidden {
						return self.downloadOperation.downloadedFileURL
					}

					return nil
				},
				set: { p in
					if p == nil {
						quicklookHidden = true
						if case .quickLook(let dismissAfterClose) = action, dismissAfterClose {
							dismiss()
						}
					}
				})
		)
		.navigationTitle(file.fileName())
		.task {
			do {
				let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
				tempDirPath = tempDir.appending(
					component: "Downloads-\(ProcessInfo().globallyUniqueString)")
				try FileManager.default.createDirectory(
					at: tempDirPath!, withIntermediateDirectories: true)
				let filePath = tempDirPath!.appending(component: file.fileName())
				self.filePath = filePath
				self.file.download(
					filePath.path(percentEncoded: false), delegate: self.downloadOperation)
			}
			catch {
				downloadOperation.error = error.localizedDescription
			}
		}
		.onDisappear {
			self.cancelAndDeleteFiles()
		}
	}

	@ViewBuilder private func actionView(_ url: URL) -> some View {
		switch self.action {
		case .quickLook(dismissAfterClose: _):
			ContentUnavailableView(
				"Downloaded", systemImage: "checkmark.circle",
				description: Text("Tap here to view the downloaded file")
			).onTapGesture {
				quicklookHidden = false
			}

		case .share:
			ShareLink(item: url)
			Button("Save a copy...", systemImage: "square.and.arrow.down") {
				showFileExporter = true
			}
			.fileMover(isPresented: $showFileExporter, file: url) { result in
				switch result {
				case .success(_):
					dismiss()
				case .failure(let e):
					Log.warn("could not move downloaded file: \(e)")
					break
				}
			}
		}
	}

	private func cancelAndDeleteFiles() {
		self.downloadOperation.cancel()
		if let fp = filePath {
			// Remove downloaded file
			try? FileManager.default.removeItem(at: fp)
			filePath = nil

			// Remove containing temp directory
			if let tp = self.tempDirPath {
				try? FileManager.default.removeItem(at: tp)
				self.tempDirPath = nil
			}
		}
	}
}
