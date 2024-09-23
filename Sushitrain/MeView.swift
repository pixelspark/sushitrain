// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import CoreImage
import CoreImage.CIFilterBuiltins

fileprivate struct QRView: View {
    private var text: String
    @State private var image: UIImage? = nil
    
    init(text: String) {
        self.text = text
    }
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 200, height: 200)
            }
            else {
                ProgressView()
            }
        }
        .navigationTitle("Device ID")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let filter = CIFilter.qrCodeGenerator()
            let data = text.data(using: .ascii, allowLossyConversion: false)!
            filter.message = data
            let ciimage = filter.outputImage!
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledCIImage = ciimage.transformed(by: transform)
            image = UIImage(data: UIImage(ciImage: scaledCIImage).pngData()!)
        }
    }
}

fileprivate struct WaitView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    
    @State private var position: CGPoint = .zero
    @State private var velocity: CGSize = CGSize(width: 1, height: 1)
    @State private var timer: Timer? = nil
    
    let spinnerSize = CGSize(width: 240, height: 70)
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .edgesIgnoringSafeArea(.all)
                
                if !appState.isFinished {
                    VStack(alignment: .leading, spacing: 10) {
                        OverallStatusView(appState: appState).frame(maxWidth: .infinity)
                        Text(velocity.height > 0 ? "Tap to close" : "The screen will stay on until finished")
                            .dynamicTypeSize(.xSmall)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(width: spinnerSize.width, height: spinnerSize.height)
                    .position(position)
                }
            }
            .statusBar(hidden: true)
            .persistentSystemOverlays(.hidden)
            .onTapGesture {
                isPresented = false
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                position = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                startTimer(in: geometry.size)
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                timer?.invalidate()
            }
        }
    }
    
    private func startTimer(in size: CGSize) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            DispatchQueue.main.async {
                if appState.isFinished {
                    self.isPresented = false
                    return
                }
                
                // Update position
                position.x += velocity.width
                position.y += velocity.height
                
                // Bounce off walls
                if position.x - spinnerSize.width / 2 <= 0 || position.x + spinnerSize.width / 2 >= size.width {
                    velocity.width *= -1
                }
                if position.y - spinnerSize.height / 2 <= 0 || position.y + spinnerSize.height / 2 >= size.height {
                    velocity.height *= -1
                }
            }
        }
    }
}

fileprivate struct OverallStatusView: View {
    @ObservedObject var appState: AppState
    
    var peerStatusText: String {
        return "\(self.appState.client.connectedPeerCount())/\(self.appState.peers().count - 1)"
    }
    
    var isConnected: Bool {
        return self.appState.client.connectedPeerCount() > 0
    }
    
    var body: some View {
        if self.isConnected {
            let isDownloading = self.appState.client.isDownloading()
            let isUploading = self.appState.client.isUploading()
            if isDownloading || isUploading {
                if isDownloading {
                    let progress = self.appState.client.getTotalDownloadProgress()
                    if let progress = progress {
                        ProgressView(value: progress.percentage, total: 1.0) {
                            Label("Receiving \(progress.filesTotal) files...", systemImage: "arrow.down")
                                .foregroundStyle(.green)
                                .symbolEffect(.pulse, value: true)
                                .badge(self.peerStatusText)
                                .frame(maxWidth: .infinity)
                        }.tint(.green)
                    }
                    else {
                        Label("Receiving files...", systemImage: "arrow.down")
                            .foregroundStyle(.green)
                            .symbolEffect(.pulse, value: true)
                            .badge(self.peerStatusText)
                            .frame(maxWidth: .infinity)
                    }
                }
                
                // Uploads
                if isUploading {
                    let upPeers = self.appState.client.uploadingToPeers()!
                    NavigationLink(destination: UploadView(appState: self.appState)) {
                        Label("Sending files...", systemImage: "arrow.up")
                            .foregroundStyle(.green)
                            .symbolEffect(.pulse, value: true)
                            .badge("\(upPeers.count())/\(self.appState.peers().count - 1)")
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            else {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).badge(Text(self.peerStatusText))
            }
        }
        else {
            Label("Not connected", systemImage: "network.slash").badge(Text(self.peerStatusText)).foregroundColor(.gray)
        }
    }
}

struct MeView: View {
    @ObservedObject var appState: AppState
    @Binding var tabSelection: ContentView.Tab
    
    @State private var settingsShown = false
    @State private var searchShown = false
    @State private var qrCodeShown = false
    @State private var foldersWithExtraFiles: [String] = []
    @State private var showWaitScreen: Bool = false
    @State private var showAddresses = false
    
    var body: some View {
        Form {
            Section {
                OverallStatusView(appState: appState).contextMenu {
                    if !self.appState.isFinished {
                        Button(action: {
                            self.showWaitScreen = true
                        }) {
                            Text("Wait for completion")
                            Image(systemName: "hourglass.circle")
                        }
                    }
                }
            }
            
            Section(header: Text("This device's identifier")) {
                Label(self.appState.localDeviceID, systemImage: "qrcode").contextMenu {
                    Button(action: {
                        UIPasteboard.general.string = self.appState.localDeviceID
                    }) {
                        Text("Copy to clipboard")
                        Image(systemName: "doc.on.doc")
                    }
                    
                    Button(action: {
                        qrCodeShown = true
                    }) {
                        Text("Show QR code")
                        Image(systemName: "qrcode")
                    }
                    
                    Button(action: {
                        self.showAddresses = true
                    }) {
                        Text("Show addresses")
                    }
                }.monospaced()
            }
            
            // Getting started
            if self.appState.peers().count == 1 {
                Section("Getting started") {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Add your first device", systemImage: "externaldrive.badge.plus").bold()
                        Text("To synchronize files, first add a remote device. Either select a device from the list below, or add manually using the device ID.")
                    }.onTapGesture {
                        tabSelection = .peers
                    }
                }
            }
            
            if self.appState.folders().count == 0 {
                Section("Getting started") {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Add your first folder", systemImage: "folder.badge.plus").bold()
                        Text("To synchronize files, add a folder. Folders that have the same folder ID on multiple devices will be synchronized with eachother.")
                    }.onTapGesture {
                        tabSelection = .folders
                    }
                }
            }
            
            if !foldersWithExtraFiles.isEmpty {
                Section("Folders that need your attention") {
                    ForEach(foldersWithExtraFiles, id: \.self) { folderID in
                        let folder = appState.client.folder(withID: folderID)!
                        NavigationLink(destination: {
                            ExtraFilesView(folder: folder, appState: appState)
                        }) {
                            Label("Folder '\(folder.displayName)' has extra files", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        }
                    }
                }
            }
            
            NavigationLink(destination:
                            ChangesView(appState: appState)) {
                Label("Recent changes", systemImage: "clock.arrow.2.circlepath").badge(appState.lastChanges.count)
            }.disabled(appState.lastChanges.isEmpty)
            
            if appState.photoSync.isReady {
                Section {
                    PhotoSyncButton(appState: appState, photoSync: appState.photoSync)
                }
            }
            
        }.navigationTitle("Start")
            .toolbar {
                ToolbarItem {
                    Button("Settings", systemImage: "gear", action: {
                        settingsShown = true
                    }).labelStyle(.iconOnly)
                }
                ToolbarItem {
                    Button("Search", systemImage: "magnifyingglass") {
                        searchShown = true
                    }
                }
            }
            .sheet(isPresented: $settingsShown, content: {
                NavigationStack {
                    SettingsView(appState: self.appState).toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                appState.applySettings()
                                settingsShown = false
                            }
                        })
                    })
                }
            })
            .sheet(isPresented: $searchShown) {
                NavigationStack {
                    SearchView(appState: appState).toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                self.searchShown = false
                            }
                        })
                    })
                }
            }
            .sheet(isPresented: $showAddresses) {
                NavigationStack {
                    List {
                        ForEach(Array(self.appState.listenAddresses), id: \.self) { addr in
                            Text(addr).contextMenu {
                                Button(action: {
                                    UIPasteboard.general.string = addr
                                }) {
                                    Text("Copy to clipboard")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                        }
                    }
                    .navigationTitle("Addresses")
                    .toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                self.showAddresses = false
                            }
                        })
                    })
                }
            }
            .sheet(isPresented: $qrCodeShown, content: {
                NavigationStack {
                    QRView(text: self.appState.localDeviceID)
                        .toolbar(content: {
                            ToolbarItem(placement: .confirmationAction, content: {
                                Button("Done") {
                                    self.qrCodeShown = false
                                }
                            })
                        })
                }
            })
            .fullScreenCover(isPresented: $showWaitScreen) {
                WaitView(appState: appState, isPresented: $showWaitScreen)
            }
            .task {
                // List folders that have extra files
                self.foldersWithExtraFiles = []
                self.foldersWithExtraFiles = await (Task.detached {
                    var myFoldersWithExtraFiles: [String] = []
                    let folders = await appState.folders()
                    for folder in folders {
                        if folder.isIdle {
                            var hasExtra: ObjCBool = false
                            let _ = try? folder.hasExtraneousFiles(&hasExtra)
                            if hasExtra.boolValue {
                                myFoldersWithExtraFiles.append(folder.folderID)
                            }
                        }
                    }
                    return myFoldersWithExtraFiles
                }).value
            }
    }
}
