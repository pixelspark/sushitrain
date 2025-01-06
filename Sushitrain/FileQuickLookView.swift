// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI
import SushitrainCore

fileprivate class DownloadOperation: NSObject, ObservableObject, SushitrainDownloadDelegateProtocol, @unchecked Sendable  {
    @Published var error: String? = nil
    @Published var progressFraction: Double = 0.0
    @Published var downloadedFileURL: URL? = nil
    private var lock = NSLock()
    private var cancelled = false
    
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

struct FileQuickLookView: View {
    let appState: AppState
    @State var file: SushitrainEntry
    @StateObject private var downloadOperation: DownloadOperation = DownloadOperation()
    @State private var quicklookHidden = false
    @State private var filePath: URL? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            if let error = downloadOperation.error {
                ContentUnavailableView("Could not download file", systemImage: "exclamationmark.triangle", description: Text(error))
            }
            else if downloadOperation.downloadedFileURL != nil {
                ContentUnavailableView("Downloaded", systemImage: "checkmark.circle", description: Text("Tap here to view the downloaded file")).onTapGesture {
                    quicklookHidden = false
                }
            }
            else {
                ContentUnavailableView {
                    ProgressView(value: downloadOperation.progressFraction, total: 1.0)
                } description: {
                    Text("Downloading file...")
                }
            }
        }
        .quickLookPreview(Binding(get: { quicklookHidden ? nil : self.downloadOperation.downloadedFileURL }, set: {p in
            if p == nil {
                quicklookHidden = true
                dismiss()
            }
        }))
        .navigationTitle(file.fileName())
        .task {
            do {
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory:true)
                let downloadsDir = tempDir.appending(component: "Downloads-\(ProcessInfo().globallyUniqueString)")
                try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                let filePath = downloadsDir.appending(component: file.fileName())
                self.filePath = filePath
                self.file.download(filePath.path(percentEncoded: false), delegate: self.downloadOperation)
            }
            catch {
                downloadOperation.error = error.localizedDescription
            }
        }
        .onDisappear {
            self.downloadOperation.cancel()
            if let fp = filePath {
                try! FileManager.default.removeItem(at: fp)
                filePath = nil
            }
        }
    }
}

