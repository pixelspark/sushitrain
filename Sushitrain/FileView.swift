// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import QuickLook
import AVKit

fileprivate struct FileMediaPlayer<Content: View>: View {
    #if os(iOS)
        @State private var session = AVAudioSession.sharedInstance()
    #endif
    
    @State private var player: AVPlayer?
    
    let appState: AppState
    var file: SushitrainEntry
    @Binding var visible: Bool
    
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
                Log.warn("Failed to deactivate audio session: \(error.localizedDescription)")
            }
        #endif
    }
    
    var body: some View {
        ZStack {
            if let player = self.player {
                VideoPlayer(player: player) {
                    VStack {
                        HStack {
                            if file.isVideo || file.isAudio {
                                HStack {
                                    Image(systemName: "xmark")
                                        .foregroundStyle(.white)
                                        .tint(.white)
                                        .onTapGesture {
                                            visible = false
                                        }
                                }
                                
                                if let sp = appState.streamingProgress, sp.bytesTotal > 0 && sp.bytesSent < sp.bytesTotal {
                                    Spacer()
                                    ProgressView(value: Float(sp.bytesSent), total: Float(sp.bytesTotal))
                                        .foregroundColor(.gray)
                                        .progressViewStyle(.linear)
                                        .frame(maxWidth: 64)
                                }
                                
                                Spacer()
                                
                                self.videoOverlay()
                                    .foregroundStyle(.white)
                                    .tint(.white)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        
                        Spacer()
                    }
                }
            }
            else {
                Rectangle()
                    .scaledToFill()
                    .foregroundStyle(.black)
                    .onTapGesture {
                        visible = false
                    }
            }
        }
        .background(.black)
        .onAppear {
            Task {
                await startPlayer()
            }
        }
        .onDisappear {
            stopPlayer()
        }
        .onChange(of: file) {
            Task {
                await startPlayer()
            }
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
    
    private func startPlayer() async {
        self.stopPlayer()
        do {
            let url = file.localNativeFileURL ?? URL(string: self.file.onDemandURL())!
            let avAsset = AVURLAsset(url: url)
            if try await avAsset.load(.isPlayable) {
                let player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                // TODO: External playback requires us to use http://devicename.local:xxx/file/.. URLs rather than http://localhost.
                // Resolve using Bonjour perhaps?
                player.allowsExternalPlayback = false
                player.audiovisualBackgroundPlaybackPolicy = .automatic
                player.preventsDisplaySleepDuringVideoPlayback = !file.isAudio
                activateSession()
                player.playImmediately(atRate: 1.0)
                self.player = player
            }
            else {
                self.visible = false
            }
        }
        catch {
            Log.warn("Error starting player: \(error.localizedDescription)")
        }
    }
}

struct FileViewerView<Content: View>: View {
    let appState: AppState
    var file: SushitrainEntry
    @Binding var isShown: Bool
    @ViewBuilder var videoOverlay: () -> Content
    
    var body: some View {
        if file.isVideo || file.isAudio {
            FileMediaPlayer(appState: appState, file: file, visible: $isShown, videoOverlay: videoOverlay)
        }
        else if file.isImage {
            let url = file.localNativeFileURL ?? URL(string: self.file.onDemandURL())!
            VStack {
                #if os(iOS)
                    HStack {
                            Image(systemName: "xmark")
                                .foregroundStyle(.white)
                                .tint(.white)
                                .onTapGesture {
                                    isShown = false
                                }
                            Spacer()
                        
                        self.videoOverlay()
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                #endif
                
                WebView(url: url, isLoading: Binding.constant(false), error: Binding.constant(nil))
                    .backgroundStyle(.black)
                    .background(.black)
                    .ignoresSafeArea()
                    
            }.background(.black)
        }
    }
}

struct FileViewerSheetView<Content: View>: View {
    let appState: AppState
    var file: SushitrainEntry
    @Binding var isShown: Bool
    @ViewBuilder var videoOverlay: () -> Content
    
    var body: some View {
        NavigationStack {
            FileViewerView(appState: appState, file: file, isShown: $isShown, videoOverlay: videoOverlay)
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

struct FileViewerSheetNextPreviousView: View {
    let appState: AppState
    @State var file: SushitrainEntry
    let siblings: [SushitrainEntry]
    @Binding var isShown: Bool
    @State private var selfIndex: Int? = nil
    
    var body: some View {
        Group {
            #if os(iOS)
                FileViewerSheetView(appState: appState, file: file, isShown: $isShown, videoOverlay: {
                    if let selfIndex = selfIndex {
                        Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1).labelStyle(.iconOnly)
                        Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1).labelStyle(.iconOnly)
                    }
                })
            #elseif os(macOS)
                NavigationStack {
                    FileViewerView(appState: appState, file: file, isShown: $isShown, videoOverlay: {
                        // Empty on macOS, we already have a toolbar
                    })
                    .presentationSizing(.fitted)
                    .frame(minWidth: 640, minHeight: 480)
                    .navigationTitle(file.fileName())
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShown = false }
                        }
                        if let selfIndex = selfIndex {
                            ToolbarItemGroup(placement: .automatic) {
                                Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1)
                                Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1)
                            }
                        }
                    }
                }
            #endif
        }
        .onAppear {
            selfIndex = self.siblings.firstIndex(of: file)
        }
    }
    
    private func next(_ offset: Int) {
        if let idx = siblings.firstIndex(of: self.file) {
            let newIndex = idx + offset
            if  newIndex >= 0 && newIndex < siblings.count {
                file = siblings[newIndex]
                selfIndex = self.siblings.firstIndex(of: file)
            }
        }
    }
}

struct FileView: View {
    @State private var file: SushitrainEntry
    private let appState: AppState
    private var showPath = false
    private var siblings: [SushitrainEntry]? = nil
    private var folder: SushitrainFolder
        
    @State private var localItemURL: URL? = nil
    @State private var showFullScreenViewer = false
    @State private var showSheetViewer = false
    @State private var showRemoveConfirmation = false
    @State private var showDownloader = false
    @State private var selfIndex: Int? = nil
    @State private var fullyAvailableOnDevices: [SushitrainPeer]? = nil
    @State private var availabilityError: Error? = nil
    
    private static let formatter = ByteCountFormatter()
    
    @Environment(\.dismiss) private var dismiss
    
    #if os(macOS)
        @Environment(\.openURL) private var openURL
    #endif
    
    init(file: SushitrainEntry, appState: AppState, showPath: Bool = false, siblings: [SushitrainEntry]? = nil) {
        self.file = file
        self.appState = appState
        self.showPath = showPath
        self.siblings = siblings
        self.folder = file.folder!
    }
    
    var localIsOnlyCopy: Bool {
        return file.isLocallyPresent() && (self.fullyAvailableOnDevices == nil || self.fullyAvailableOnDevices!.isEmpty)
    }
    
    var body: some View {
        if file.isDeleted() {
            ContentUnavailableView("File was deleted", systemImage: "trash", description: Text("This file was deleted."))
        }
        else {
            var error: NSError? = nil
            let localPath = file.isLocallyPresent() ? file.localNativePath(&error) : nil
            
            Form {
                // Symbolic link: show link target
                if file.isSymlink() {
                    Section("Link destination") {
                        Text(file.symlinkTarget())
                    }
                }
                
                Section {
                    if !file.isDirectory() && !file.isSymlink() {
                        Text("File size").badge(Self.formatter.string(fromByteCount: file.size()))
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
                        let isExplicitlySelected = file.isExplicitlySelected()
                        Toggle("Synchronize with this device", systemImage: "pin", isOn: Binding(get: {
                            file.isExplicitlySelected() || file.isSelected()
                        }, set: { s in
                            try? file.setExplicitlySelected(s)
                        }))
                        .disabled(!folder.isIdleOrSyncing || (file.isSelected() && !isExplicitlySelected) || (isExplicitlySelected && localIsOnlyCopy))
                    }
                } footer: {
                    if !file.isSymlink() && self.folder.isSelective() && (file.isSelected() && !file.isExplicitlySelected()) {
                        Text("This item is synchronized with this device because a parent folder is synchronized with this device.")
                    }
                    
                    if !file.isSymlink() {
                        if file.isExplicitlySelected() {
                            if localIsOnlyCopy {
                                if self.folder.connectedPeerCount() > 0 {
                                    Text("There are currently no other devices connected that have a full copy of this file.")
                                }
                                else {
                                    Text("There are currently no other devices connected, so it can't be established that this file is fully available on at least one other device.")
                                }
                            }
                        }
                        else {
                            if self.folder.connectedPeerCount() == 0 {
                                Text("When you select this file, it will not become immediately available on this device, because there are no other devices connected to download the file from.")
                            }
                            else if (self.fullyAvailableOnDevices == nil || self.fullyAvailableOnDevices!.isEmpty) {
                                Text("When you select this file, it will not become immediately available on this device, because none of the currently connected devices have a full copy of the file that can be downloaded.")
                            }
                        }
                    }
                }
                
                // Devices that have this file
                if !self.file.isSymlink() {
                    if let availability = self.fullyAvailableOnDevices {
                        if availability.isEmpty && self.folder.connectedPeerCount() > 0 {
                            Label("This file it not fully available on any connected device", systemImage: "externaldrive.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    else {
                        if let err = self.availabilityError {
                            Label(
                                "Could not determine file availability: \(err)", systemImage: "externaldrive.trianglebadge.exclamationmark"
                            ).foregroundStyle(.orange)
                        }
                        else {
                            Label(
                                "Checking availability on other devices...", systemImage: "externaldrive.badge.questionmark"
                            ).foregroundStyle(.gray)
                        }
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
                        })
                        .buttonStyle(.link)
                        .disabled(folder.connectedPeerCount() == 0)
                    #endif
                    
                    // Image preview
                    if file.canThumbnail {
                        Section {
                            ThumbnailView(file: file, appState: appState, showFileName: false, showErrorMessages: true)
                                .id(file.id)
                                .padding(.all, 10)
                                .cornerRadius(8.0)
                                .onTapGesture {
                                    #if os(macOS)
                                        // On macOS prefer local QuickLook
                                        if file.isLocallyPresent() {
                                            localItemURL = URL(fileURLWithPath: localPath!)
                                        }
                                        else if file.isVideo || file.isImage {
                                            showFullScreenViewer = true
                                        }
                                    #elseif os(iOS)
                                        // On iOS prefer streaming view over QuickLook
                                        if file.isVideo || file.isImage {
                                            showFullScreenViewer = true
                                        }
                                        else if file.isLocallyPresent() {
                                            localItemURL = URL(fileURLWithPath: localPath!)
                                        }
                                    #endif
                                }
                        }
                    }
                    
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
                                DownloadProgressView(appState: appState, file: file, folder: folder)
                            }
                        }
                    }
                    else {
                        let streamButton = Button("Stream", systemImage: file.isVideo ? "tv" : "music.note", action: {
                            if file.isVideo {
                                showFullScreenViewer = true
                            }
                            else if file.isAudio {
                                showSheetViewer = true
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
                    
                    // Devices that have this file
                    if let availability = self.fullyAvailableOnDevices {
                        if !availability.isEmpty {
                            Section("This file is fully available on") {
                                ForEach(availability, id: \.self) { device in
                                    Label(device.displayName, systemImage: "externaldrive")
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
                            #if os(macOS)
                                .buttonStyle(.link)
                            #endif
                            .foregroundColor(.red)
                            .confirmationDialog(self.localIsOnlyCopy ? "Are you sure you want to remove this file from all devices? The local copy of this file is the only one currently available on any device. This will remove the last copy. It will not be possible to recover the file after removing it." : "Are you sure you want to remove this file from all devices?", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                                Button("Remove the file from all devices", role: .destructive) {
                                    dismiss()
                                    try? file.remove()
                                }
                            }
                        }
                    }
                }
                
                if file.isDirectory() {
                    // Devices that have this folder and all its contents
                    if let availability = self.fullyAvailableOnDevices {
                        if !availability.isEmpty {
                            Section("This subdirectory and all its contents are fully available on") {
                                List(availability, id: \.self) { device in
                                    Label(device.displayName, systemImage: "externaldrive")
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
                    .fullScreenCover(isPresented: $showFullScreenViewer, content: {
                        FileViewerView(appState: appState, file: file, isShown: $showFullScreenViewer, videoOverlay: {
                            if let selfIndex = selfIndex, let siblings = siblings {
                                Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1)
                                    .labelStyle(.iconOnly)
                                    .padding([.trailing, .bottom, .top], 12)
                                Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1)
                                    .labelStyle(.iconOnly)
                                    .padding([.trailing, .bottom, .top],  12)
                            }
                        })
                        // Swipe up and down for next/previous
                        .gesture(DragGesture(minimumDistance: 20, coordinateSpace: .global).onEnded { value in
                            if let selfIndex = selfIndex, let siblings = siblings {
                                let verticalAmount = value.translation.height
                                
                                if verticalAmount < 0 && selfIndex <= siblings.count {
                                    next(1)
                                }
                                else if verticalAmount > 0 && selfIndex > 0 {
                                    next(-1)
                                }
                            }
                        })
                    })
                    .sheet(isPresented: $showSheetViewer) {
                        FileViewerSheetView(appState: appState, file: file, isShown: $showSheetViewer, videoOverlay: {
                            if let selfIndex = selfIndex, let siblings = siblings {
                                Button("Previous", systemImage: "chevron.up") { next(-1) }.disabled(selfIndex < 1).labelStyle(.iconOnly)
                                Button("Next", systemImage: "chevron.down") { next(1) }.disabled(selfIndex >= siblings.count - 1).labelStyle(.iconOnly)
                            }
                        })
                    }
                #elseif os(macOS)
                    .sheet(isPresented: $showFullScreenViewer) {
                        NavigationStack {
                            FileViewerView(appState: appState, file: file, isShown: $showFullScreenViewer, videoOverlay: {
                               // Empty on macOS, we already have a toolbar
                            })
                            .presentationSizing(.fitted)
                            .frame(minWidth: 640, minHeight: 480)
                            .navigationTitle(file.fileName())
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showFullScreenViewer = false }
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
                    .sheet(isPresented: $showSheetViewer) {
                        FileViewerSheetView(appState: appState, file: file, isShown: $showSheetViewer, videoOverlay: {
                            // Empty on macOS, we already have a toolbar
                        })
                        .presentationSizing(.fitted)
                        .frame(minWidth: 640, minHeight: 480)
                        .navigationTitle(file.fileName())
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSheetViewer = false }
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
                        FileQuickLookView(appState: self.appState, file: file)
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
                    
                    #if os(macOS)
                        ToolbarItem(id: "open-in-finder", placement: .primaryAction) {
                            Button(openInFilesAppLabel, systemImage: "arrow.up.forward.app", action: {
                                if let localPathActual = localPath {
                                    openURLInSystemFilesApp(url: URL(fileURLWithPath: localPathActual))
                                }
                            })
                            .labelStyle(.iconOnly)
                            .disabled(localPath == nil)
                        }
                    #endif
                }
                .onAppear {
                    selfIndex = self.siblings?.firstIndex(of: file)
                }
                .task {
                    let fileEntry = self.file
                    do {
                        self.fullyAvailableOnDevices = nil
                        self.availabilityError = nil
                        let availability = try await Task.detached { [fileEntry] in
                            return (try fileEntry.peersWithFullCopy()).asArray()
                        }.value
                        
                        self.fullyAvailableOnDevices = availability.flatMap { devID in
                            if let p = self.appState.client.peer(withID: devID) {
                                return [p]
                            }
                            return []
                        }
                    }
                    catch {
                        self.availabilityError = error
                        self.fullyAvailableOnDevices = nil
                    }
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

fileprivate struct DownloadProgressView: View {
    let appState: AppState
    let file: SushitrainEntry
    let folder: SushitrainFolder
    
    @State private var lastProgress: (Date, SushitrainProgress)? = nil
    @State private var progress: (Date, SushitrainProgress)? = nil
    
    var body: some View {
        Group {
            if let (date, progress) = self.progress {
                ProgressView(value: progress.percentage, total: 1.0) {
                    VStack {
                        HStack {
                            Label("Downloading file...", systemImage: "arrow.clockwise")
                                .foregroundStyle(.green)
                                .symbolEffect(.pulse, value: true)
                            Spacer()
                        }
                        
                        if let (lastDate, lastProgress) = self.lastProgress {
                            HStack {
                                let diffBytes = progress.bytesDone - lastProgress.bytesDone
                                let diffTime = date.timeIntervalSince(lastDate)
                                let speed = Int64(Double(diffBytes) / Double(diffTime))
                                let formatter = ByteCountFormatter()
                                
                                Spacer()
                                Text("\(formatter.string(fromByteCount: speed))/s").foregroundStyle(.green)

                                if speed > 0 {
                                    let secondsToGo = (progress.bytesTotal - progress.bytesDone) / speed
                                    Text("\(secondsToGo) seconds").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }.tint(.green)
            }
            else {
                Label("Waiting to synchronize...", systemImage: "hourglass")
            }
        }
        .task {
            self.updateProgress()
        }
        .onChange(of: self.appState.eventCounter) {
            self.updateProgress()
        }
    }
    
    private func updateProgress() {
        self.lastProgress = self.progress
        if let p = self.appState.client.getDownloadProgress(forFile: self.file.path(), folder: self.folder.folderID) {
            self.progress = (Date.now, p)
        }
        else {
            self.progress = nil
        }
    }
}
