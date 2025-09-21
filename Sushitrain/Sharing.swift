// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import SushitrainCore

extension SushitrainEntry: @retroactive Transferable {
	static public var transferRepresentation: some TransferRepresentation {
		FileRepresentation(exportedContentType: .data, exporting: Self.sentTransferredFile)
	}

	private static func sentTransferredFile(entry: SushitrainEntry) async throws -> SentTransferredFile {
		if let lurl = entry.localNativeFileURL {
			return SentTransferredFile(lurl, allowAccessingOriginalFile: true)
		}
		else {
			Log.info("Downloading file for export: \(entry.fileName())")
			return try await entry.downloadFileToSent()
		}
	}

	private func downloadFileToSent() async throws -> SentTransferredFile {
		let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
		let tempDirPath = tempDir.appending(
			component: "Downloads-\(ProcessInfo().globallyUniqueString)")
		try FileManager.default.createDirectory(at: tempDirPath, withIntermediateDirectories: true)
		let filePath = tempDirPath.appending(component: self.fileName())

		struct DownloadError: Error {
			let message: String
		}

		class DownloadDelegate: NSObject, SushitrainDownloadDelegateProtocol {
			let continuation: CheckedContinuation<URL, any Error>

			init(_ continuation: CheckedContinuation<URL, any Error>) {
				self.continuation = continuation
			}

			func isCancelled() -> Bool {
				return false
			}

			func onError(_ error: String?) {
				Log.warn("DownloadFileToSent: error \(error ?? "")")
				self.continuation.resume(throwing: DownloadError(message: error ?? ""))
			}

			func onFinished(_ path: String?) {
				if let p = path {
					Log.info("DownloadFileToSent: completed path=\(p)")
					self.continuation.resume(returning: URL(filePath: p, directoryHint: .notDirectory))
				}
				else {
					Log.warn("DownloadFileToSent: no path")
					self.continuation.resume(throwing: DownloadError(message: "no path"))
				}
			}

			func onProgress(_ fraction: Double) {
			}
		}

		let url = try await withCheckedThrowingContinuation { cont in
			let dlg = DownloadDelegate(cont)
			self.download(filePath.path(percentEncoded: false), delegate: dlg)
		}
		Log.info("Returning sent transferred file at: \(url)")
		return SentTransferredFile(url, allowAccessingOriginalFile: false)
	}
}

struct FileShareLink: View {
	let file: SushitrainEntry
	@State private var image: AsyncImagePhase = .empty

	var body: some View {
		self.shareLink.task {
			self.image = await ImageCache.shared.getThumbnail(file: file, forceCache: false)
		}
	}

	@ViewBuilder private var shareLink: some View {
		switch self.image {
		case .success(let img):
			ShareLink(item: file, preview: SharePreview(file.fileName(), image: img))
		case .empty, .failure(_):
			ShareLink(item: file, preview: SharePreview(file.fileName(), image: Image(systemName: file.systemImage)))
		@unknown default:
			ShareLink(item: file, preview: SharePreview(file.fileName(), image: Image(systemName: file.systemImage)))
		}
	}
}
