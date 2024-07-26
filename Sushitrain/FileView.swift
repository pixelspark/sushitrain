// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore
import QuickLook
import WebKit
import AVKit

fileprivate struct FileMediaPlayer: View {
    @State private var session = AVAudioSession.sharedInstance()
    @State private var player: AVPlayer?
    @ObservedObject var appState: AppState
    var file: SushitrainEntry
    @State var visible: Binding<Bool>
    
    private func activateSession() {
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: []
            )
        } catch _ {}
        
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch _ {}
        
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch _ {}
    }
    
    private func deactivateSession() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch let error as NSError {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
    
    var body: some View {
        VideoPlayer(player: player) {
            VStack {
                HStack {
                    if file.isVideo {
                        Image(systemName: "xmark")
                            .padding(16)
                            .foregroundStyle(.white)
                            .tint(.white)
                            .onTapGesture {
                                visible.wrappedValue = false
                            }
                        
                        if let sp = appState.streamingProgress, sp.bytesTotal > 0 && sp.bytesSent < sp.bytesTotal {
                            ProgressView(value: Float(sp.bytesSent), total: Float(sp.bytesTotal)).foregroundColor(.gray).progressViewStyle(.linear).frame(maxWidth: 64)
                        }
                    }
                    
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            let player = AVPlayer(url: URL(string: self.file.onDemandURL())!)
            // TODO: External playback requires us to use http://devicename.local:xxx/file/.. URLs rather than http://localhost.
            // Resolve using Bonjour perhaps?
            player.allowsExternalPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .automatic
            player.preventsDisplaySleepDuringVideoPlayback = file.isAudio
            activateSession()
            player.playImmediately(atRate: 1.0)
            self.player = player
        }
        .onDisappear {
            self.player?.pause()
            self.player = nil
            self.deactivateSession()
        }
        .ignoresSafeArea(file.isVideo ? .all : [])
    }
}

fileprivate extension SushitrainEntry {
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
}

fileprivate struct WebView: UIViewRepresentable {
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
}


struct BareOnDemandFileView: View {
    @ObservedObject var appState: AppState
    var file: SushitrainEntry
    @Binding var isShown: Bool
    
    var body: some View {
        if !file.isLocallyPresent() && file.isMedia {
            FileMediaPlayer(appState: appState, file: file, visible: $isShown)
        }
        else {
            OnDemandWebFileView(file: file)
        }
    }
}

struct OnDemandFileView: View {
    @ObservedObject var appState: AppState
    var file: SushitrainEntry
    @Binding var isShown: Bool
    
    var body: some View {
        NavigationStack {
            BareOnDemandFileView(appState: appState, file: file, isShown: $isShown)
            .navigationTitle(file.fileName())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .confirmationAction, content: {
                    Button("Done", action: {
                        isShown = false
                    })
                })
            })
        }
    }
}

fileprivate struct OnDemandWebFileView: View {
    var file: SushitrainEntry
    @State var isLoading: Bool = false
    @State var error: Error? = nil
    
    var body: some View {
        var pathError: NSError? = nil
        let url = file.isLocallyPresent() ? URL(fileURLWithPath: file.localNativePath(&pathError)) : URL(string: file.onDemandURL())
        ZStack {
            if let error = error {
                ContentUnavailableView("Cannot display file", systemImage: "xmark.circle", description: Text(error.localizedDescription))
            }
            else if let error = pathError {
                ContentUnavailableView("Cannot display file", systemImage: "xmark.circle", description: Text(error.localizedDescription))
            }
            else if let url = url {
                WebView(url: url, isLoading: $isLoading, error: $error)
            }
            else {
                ContentUnavailableView("Cannot display file", systemImage: "xmark.circle")
            }
        }
        .navigationTitle(file.fileName())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: {
            ToolbarItem(placement: .cancellationAction, content: {
                if isLoading {
                    ProgressView()
                }
            })
        })
    }
}

struct FileView: View {
    @State var file: SushitrainEntry
    var folder: SushitrainFolder
    @ObservedObject var appState: AppState
    @State var localItemURL: URL? = nil
    @State var showVideoPlayer = false
    @State var showPreview = false
    @State var showOnDemandPreview = false
    @State var showRemoveConfirmation = false
    let formatter = ByteCountFormatter()
    var showPath = false
    var siblings: [SushitrainEntry]? = nil
    @State var selfIndex: Int? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        if file.isDeleted() {
            ContentUnavailableView("File was deleted", systemImage: "trash", description: Text("This file was deleted."))
        }
        else {
            Form {
                Section {
                    if !file.isDirectory() {
                        Text("File size").badge(formatter.string(fromByteCount: file.size()))
                    }
                    
                    if self.folder.isSelective() {
                        Toggle("Keep on this device", systemImage: "pin", isOn: Binding(get: {
                            file.isExplicitlySelected() || file.isSelected()
                        }, set: { s in
                            try? file.setExplicitlySelected(s)
                        })).disabled(!folder.isIdle || (file.isSelected() && !file.isExplicitlySelected()))
                    }
                }
                
                if showPath {
                    Section("Location") {
                        Text("\(folder.folderID): \(file.path())")
                    }
                }
                
                if !file.isDirectory() {
                    var error: NSError? = nil
                    let localPath = file.isLocallyPresent() ? file.localNativePath(&error) : nil
                    
                    Section {
                        if file.isSelected() {
                            // Selective sync uses copy in working dir
                            if file.isLocallyPresent() {
                                if error == nil {
                                    Button("View file", systemImage: "eye", action: {
                                        localItemURL = URL(fileURLWithPath: localPath!)
                                    })
                                    ShareLink("Share file", item: URL(fileURLWithPath: localPath!))
                                }
                            }
                            else {
                                // Waiting for sync
                                let progress = self.appState.client.getDownloadProgress(forFile: self.file.path(), folder: self.folder.folderID)
                                if let progress = progress {
                                    ProgressView(value: progress.percentage, total: 1.0) {
                                        Label("Downloading file...", systemImage: "arrow.clockwise").foregroundStyle(.green).symbolEffect(.pulse, value: true)
                                    }
                                }
                                else {
                                    Label("Waiting to synchronize...", systemImage: "hourglass")
                                }
                            }
                        }
                        else {
                            if file.isMedia {
                                Button("Stream", systemImage: file.isVideo ? "tv" : "music.note", action: {
                                    if file.isVideo {
                                        showVideoPlayer = true
                                    }
                                    else if file.isAudio {
                                        showOnDemandPreview = true
                                    }
                                }).disabled(folder.connectedPeerCount() == 0)
                            }
                            else {
                                Button("View file", systemImage: "eye", action: {
                                    showOnDemandPreview = true
                                }).disabled(folder.connectedPeerCount() == 0)
                            }
                        }
                    }
                    
                    // Image preview
                    if file.isImage {
                        Section {
                            if file.isLocallyPresent() {
                                Image(uiImage: UIImage(contentsOfFile: localPath!)!)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: 200).onTapGesture {
                                        showPreview = false
                                    }
                            }
                            else if showPreview || file.size() <= appState.maxBytesForPreview {
                                AsyncImage(url: URL(string: file.onDemandURL())!) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                }
                            placeholder: {
                                HStack(alignment: .center, content: {
                                    ProgressView()
                                })
                            }
                            .frame(maxWidth: .infinity, maxHeight: 200).onTapGesture {
                                showPreview = false
                            }
                            }
                            else {
                                Button("Show preview for large files") {
                                    showPreview = true
                                }
                            }
                        }
                    }
                    
                    // Remove file
                    if file.isSelected() && file.isLocallyPresent() && folder.folderType() == SushitrainFolderTypeSendReceive {
                        Section {
                            Button("Remove file from all devices", systemImage: "trash", role: .destructive) {
                                showRemoveConfirmation = true
                            }
                            .foregroundColor(.red)
                            .confirmationDialog("Are you sure you want to remove this file from all devices?", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                                Button("Remove the file from all devices", role: .destructive) {
                                    dismiss()
                                    try! file.remove()
                                }
                            }
                        }
                    }
                }
            }.navigationTitle(file.fileName())
                .quickLookPreview(self.$localItemURL)
                .fullScreenCover(isPresented: $showVideoPlayer, content: {
                    FileMediaPlayer(appState: appState, file: file, visible: $showVideoPlayer)
                })
                .sheet(isPresented: $showOnDemandPreview, content: {
                    OnDemandFileView(appState: appState, file: file, isShown: $showOnDemandPreview)
                })
                .toolbar {
                    if let selfIndex = selfIndex, let siblings = siblings {
                        ToolbarItem(placement: .navigation) {
                            Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1)
                        }
                        ToolbarItem(placement: .navigation) {
                            Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1)
                        }
                    }
                }
                .onAppear {
                    selfIndex = self.siblings?.firstIndex(of: file)
                }
        }
    }
    
    private func next(_ offset: Int) {
        if let siblings = siblings {
            if let idx = siblings.firstIndex(of: self.file) {
                let newIndex = idx + offset
                if  newIndex >= 0 && newIndex < siblings.count {
                    file = siblings[newIndex]
                    selfIndex = self.siblings?.firstIndex(of: file)
                }
            }
        }
    }
}
