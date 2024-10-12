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

fileprivate struct FileMediaPlayer<Content: View>: View {
#if os(iOS)
    @State private var session = AVAudioSession.sharedInstance()
#endif
    
    @State private var player: AVPlayer?
    @ObservedObject var appState: AppState
    var file: SushitrainEntry
    @State var visible: Binding<Bool>
    
    @ViewBuilder var videoOverlay: () -> Content
    
    private func activateSession() {
        #if os(iOS)
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
        #endif
    }
    
    private func deactivateSession() {
        #if os(iOS)
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch let error as NSError {
                print("Failed to deactivate audio session: \(error.localizedDescription)")
            }
        #endif
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
                        self.videoOverlay()
                        
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
            startPlayer()
        }
        .onDisappear {
            stopPlayer()
        }
        .onChange(of: file) {
            startPlayer()
        }
        .ignoresSafeArea(file.isVideo ? .all : [])
    }
    
    private func stopPlayer() {
        if let player = self.player {
            player.pause()
            self.player = nil
            self.deactivateSession()
        }
    }
    
    private func startPlayer() {
        self.stopPlayer()
        let player = AVPlayer(url: URL(string: self.file.onDemandURL())!)
        // TODO: External playback requires us to use http://devicename.local:xxx/file/.. URLs rather than http://localhost.
        // Resolve using Bonjour perhaps?
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .automatic
        player.preventsDisplaySleepDuringVideoPlayback = file.isAudio
        activateSession()
        player.playImmediately(atRate: 1.0)
        self.player = player
    }
}


struct BareOnDemandFileView<Content: View>: View {
    @ObservedObject var appState: AppState
    var file: SushitrainEntry
    @Binding var isShown: Bool
    
    @ViewBuilder var videoOverlay: () -> Content
    
    var body: some View {
        if !file.isLocallyPresent() && file.isMedia {
            FileMediaPlayer(appState: appState, file: file, visible: $isShown, videoOverlay: videoOverlay)
        }
        else {
        }
    }
}

struct OnDemandFileView<Content: View>: View {
    @ObservedObject var appState: AppState
    var file: SushitrainEntry
    @Binding var isShown: Bool
    @ViewBuilder var videoOverlay: () -> Content
    
    var body: some View {
        NavigationStack {
            BareOnDemandFileView(appState: appState, file: file, isShown: $isShown, videoOverlay: videoOverlay)
                .navigationTitle(file.fileName())
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
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
        Group {
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
    @State var showOnDemandPreview = false
    @State var showRemoveConfirmation = false
    @State var showDownloader = false
    let formatter = ByteCountFormatter()
    var showPath = false
    var siblings: [SushitrainEntry]? = nil
    @State var selfIndex: Int? = nil
    
    @Environment(\.dismiss) private var dismiss
    
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif
    
    var body: some View {
        if file.isDeleted() {
            ContentUnavailableView("File was deleted", systemImage: "trash", description: Text("This file was deleted."))
        }
        else {
            Form {
                // Symbolic link: show link target
                if file.isSymlink() {
                    Section("Link destination") {
                        Text(file.symlinkTarget())
                    }
                }
                
                Section {
                    if !file.isDirectory() && !file.isSymlink() {
                        Text("File size").badge(formatter.string(fromByteCount: file.size()))
                    }
                    
                    if let md = file.modifiedAt()?.date(), !file.isSymlink() {
                        Text("Last modified").badge(md.formatted(date: .abbreviated, time: .shortened))
                        
                        let mby = file.modifiedByShortDeviceID()
                        if !mby.isEmpty {
                            if let modifyingDevice = appState.client.peer(withShortID: mby) {
                                if modifyingDevice.deviceID() == appState.localDeviceID {
                                    Text("Last modified from").badge(Text("This device"))
                                }
                                else {
                                    Text("Last modified from").badge(modifyingDevice.displayName)
                                }
                            }
                        }
                    }
                    
                    if self.folder.isSelective() && !file.isSymlink() {
                        Toggle("Synchronize with this device", systemImage: "pin", isOn: Binding(get: {
                            file.isExplicitlySelected() || file.isSelected()
                        }, set: { s in
                            try? file.setExplicitlySelected(s)
                        })).disabled(!folder.isIdleOrSyncing || (file.isSelected() && !file.isExplicitlySelected()))
                    }
                } footer: {
                    if !file.isSymlink() && self.folder.isSelective() && (file.isSelected() && !file.isExplicitlySelected()) {
                        Text("This item is synchronized with this device because a parent folder is synchronized with this device.")
                    }
                }
                
                if showPath {
                    Section("Location") {
                        NavigationLink(destination: BrowserView(appState: appState, folder: folder, prefix: file.parentPath())) {
                            Label("\(folder.label()): \(file.parentPath())", systemImage: "folder")
                        }
                    }
                }
                
                if !file.isDirectory() && !file.isSymlink() {
                    #if os(macOS)
                        let openInSafariButton = Button("Open in Safari", systemImage: "safari", action: {
                            if let u = URL(string: file.onDemandURL()) {
                                openURL(u)
                            }
                        }).disabled(folder.connectedPeerCount() == 0)
                    #endif
                    
                    var error: NSError? = nil
                    let localPath = file.isLocallyPresent() ? file.localNativePath(&error) : nil
                    
                    if file.isSelected() {
                        // Selective sync uses copy in working dir
                        if file.isLocallyPresent() {
                            if error == nil {
                                Section {
                                    Button("View file", systemImage: "eye", action: {
                                        localItemURL = URL(fileURLWithPath: localPath!)
                                    })
                                    #if os(macOS)
                                        .buttonStyle(.link)
                                    #endif
                                    ShareLink("Share file", item: URL(fileURLWithPath: localPath!))
                                    #if os(macOS)
                                        .buttonStyle(.link)
                                    #endif
                                }
                            }
                        }
                        else {
                            // Waiting for sync
                            Section {
                                let progress = self.appState.client.getDownloadProgress(forFile: self.file.path(), folder: self.folder.folderID)
                                if let progress = progress {
                                    ProgressView(value: progress.percentage, total: 1.0) {
                                        Label("Downloading file...", systemImage: "arrow.clockwise")
                                            .foregroundStyle(.green)
                                            .symbolEffect(.pulse, value: true)
                                    }.tint(.green)
                                }
                                else {
                                    Label("Waiting to synchronize...", systemImage: "hourglass")
                                }
                            }
                        }
                    }
                    else {
                        let streamButton = Button("Stream", systemImage: file.isVideo ? "tv" : "music.note", action: {
                            if file.isVideo {
                                showVideoPlayer = true
                            }
                            else if file.isAudio {
                                showOnDemandPreview = true
                            }
                        }).disabled(folder.connectedPeerCount() == 0)
                        #if os(macOS)
                            .buttonStyle(.link)
                        #endif
                        
                        let quickViewButton = Button("View file", systemImage: "arrow.down.circle", action: {
                            showDownloader = true
                        }).disabled(folder.connectedPeerCount() == 0)
                        #if os(macOS)
                            .buttonStyle(.link)
                        #endif
                        
                        Section {
                            if file.isMedia {
                                // Stream button
                                #if os(macOS)
                                    HStack {
                                        streamButton
                                        quickViewButton
                                        openInSafariButton
                                    }
                                #else
                                    streamButton
                                    quickViewButton
                                #endif
                            }
                            else {
                                #if os(macOS)
                                    HStack {
                                        quickViewButton
                                        openInSafariButton
                                    }
                                #else
                                    quickViewButton
                                #endif
                            }
                        }
                    }
                    
                    
                    // Image preview
                    if file.canThumbnail {
                        Section {
                            ThumbnailView(file: file, appState: appState).padding(.all, 10).cornerRadius(8.0)
                        }
                    }
                    
                    // Remove file
                    if file.isSelected() && file.isLocallyPresent() && folder.folderType() == SushitrainFolderTypeSendReceive {
                        Section {
                            Button("Remove file from all devices", systemImage: "trash", role: .destructive) {
                                showRemoveConfirmation = true
                            }
                            #if os(macOS)
                                .buttonStyle(.link)
                            #endif
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
            }
            #if os(macOS)
                .formStyle(.grouped)
            #endif
            .navigationTitle(file.fileName())
                .quickLookPreview(self.$localItemURL)
                #if os(iOS)
                    .fullScreenCover(isPresented: $showVideoPlayer, content: {
                        FileMediaPlayer(appState: appState, file: file, visible: $showVideoPlayer, videoOverlay: {
                            if let selfIndex = selfIndex, let siblings = siblings {
                                Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1).labelStyle(.iconOnly)
                                Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1).labelStyle(.iconOnly)
                            }
                        })
                    })
                    .sheet(isPresented: $showOnDemandPreview) {
                        OnDemandFileView(appState: appState, file: file, isShown: $showOnDemandPreview, videoOverlay: {
                                if let selfIndex = selfIndex, let siblings = siblings {
                                    Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1).labelStyle(.iconOnly)
                                    Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1).labelStyle(.iconOnly)
                                }
                        })
                    }
                #elseif os(macOS)
                    .sheet(isPresented: $showVideoPlayer) {
                        NavigationStack {
                            FileMediaPlayer(appState: appState, file: file, visible: $showVideoPlayer, videoOverlay: {
                               // Empty on macOS, we already have a toolbar
                            })
                            .frame(minWidth: 640, minHeight: 480)
                            .navigationTitle(file.fileName())
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showVideoPlayer = false }
                                }
                                if let selfIndex = selfIndex, let siblings = siblings {
                                    ToolbarItemGroup(placement: .automatic) {
                                        Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1)
                                        Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1)
                                    }
                                }
                            }
                        }
                    }
                    .sheet(isPresented: $showOnDemandPreview) {
                        OnDemandFileView(appState: appState, file: file, isShown: $showOnDemandPreview, videoOverlay: {
                            // Empty on macOS, we already have a toolbar
                        })
                        .frame(minWidth: 640, minHeight: 480)
                        .navigationTitle(file.fileName())
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showOnDemandPreview = false }
                            }
                            if let selfIndex = selfIndex, let siblings = siblings {
                                ToolbarItemGroup(placement: .automatic) {
                                    Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1)
                                    Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1)
                                }
                            }
                        }
                    }
                #endif
                
                .sheet(isPresented: $showDownloader, content: {
                    NavigationStack {
                        FileQuickLookView(file: file, appState: self.appState)
                            #if os(iOS)
                                .navigationBarTitleDisplayMode(.inline)
                            #endif
                            .toolbar(content: {
                                ToolbarItem(placement: .cancellationAction, content: {
                                    Button("Cancel") {
                                        showDownloader = false
                                    }
                                })
                            })
                    }
                })
                .toolbar {
                    if let selfIndex = selfIndex, let siblings = siblings {
                        ToolbarItemGroup(placement: .navigation) {
                            Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1)
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
