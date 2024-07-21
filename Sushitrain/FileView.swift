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

struct FileMediaPlayer: View {
    @State private var session = AVAudioSession.sharedInstance()
    @State private var player: AVPlayer?
    @ObservedObject var appState: SushitrainAppState
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

extension SushitrainEntry {
    var isMedia: Bool {
        get {
            return self.isVideo || self.isAudio
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

struct WebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        return WKWebView()
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
}

extension SushitrainFolder {
    var isIdle: Bool {
        var error: NSError? = nil
        let s = self.state(&error)
        return s == "idle"
    }
}

struct FileView: View {
    var file: SushitrainEntry
    var folder: SushitrainFolder
    @ObservedObject var appState: SushitrainAppState
    @State var localItemURL: URL? = nil
    @State var showWebview = false
    @State var showVideoPlayer = false
    @State var showAudioPlayer = false
    let formatter = ByteCountFormatter()
    var showPath = false
    
    var body: some View {
        Form {
            Section {
                Text("File size").badge(formatter.string(fromByteCount: file.size()))
                
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
            
            Section {
                if file.isSelected() {
                    // Selective sync uses copy in working dir
                    if file.isLocallyPresent() {
                        var error: NSError? = nil
                        let localPath = file.localNativePath(&error)
                        if error == nil {
                            Button("View file", systemImage: "eye", action: {
                                localItemURL = URL(fileURLWithPath: localPath)
                            })
                            ShareLink("Share file", item: URL(fileURLWithPath: localPath))
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
                            else {
                                showAudioPlayer = true
                            }
                        }).disabled(folder.connectedPeerCount() == 0)
                    }
                    else {
                        Button("View file", systemImage: "eye", action: {
                            showWebview = true
                        }).disabled(folder.connectedPeerCount() == 0)
                    }
                }
            }
        }.navigationTitle(file.fileName())
            .quickLookPreview(self.$localItemURL)
            .fullScreenCover(isPresented: $showVideoPlayer, content: {
                FileMediaPlayer(appState: appState, file: file, visible: $showVideoPlayer)
            })
            .sheet(isPresented: $showAudioPlayer, content: {
                NavigationStack {
                    FileMediaPlayer(appState: appState, file: file, visible: $showAudioPlayer)
                        .navigationTitle(file.fileName())
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(content: {
                            ToolbarItem(placement: .confirmationAction, content: {
                                Button("Done", action: {
                                    showAudioPlayer = false
                                })
                            })
                        })
                }
            })
            .sheet(isPresented: $showWebview, content: {
                NavigationStack {
                    WebView(url: URL(string: file.onDemandURL())!)
                        .navigationTitle(file.fileName())
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(content: {
                            ToolbarItem(placement: .confirmationAction, content: {
                                Button("Done", action: {
                                    showWebview = false
                                })
                            })
                        })
                }
            })
    }
}
