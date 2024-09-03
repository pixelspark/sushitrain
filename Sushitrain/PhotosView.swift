// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
@preconcurrency import SushitrainCore
import Photos

@MainActor
class PhotoSynchronisation: ObservableObject {
    @AppStorage("photoSyncSelectedAlbumID") var  selectedAlbumID: String = ""
    @AppStorage("photoSyncFolderID") var selectedFolderID: String = ""
    @AppStorage("photoSyncEnableBackgroundCopy") var enableBackgroundCopy: Bool = false
    @Published var isSynchronizing = false
    @Published var progressIndex: Int = 0
    @Published var progressTotal: Int = 0
    @Published var syncTask: Task<(), Error>? = nil
    
    var selectedAlbumTitle: String? {
        get {
            if !self.selectedAlbumID.isEmpty {
                if let selectedAlbum = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [self.selectedAlbumID], options: nil).firstObject {
                    return selectedAlbum.localizedTitle
                }
            }
            return nil
        }
    }
    
    var isReady: Bool { get {
        return !self.selectedAlbumID.isEmpty && !self.selectedFolderID.isEmpty
    }}
    
    @MainActor
    func cancel() {
        self.syncTask?.cancel()
        self.syncTask = nil
    }
    
    @MainActor
    func synchronize(_ appState: AppState) {
        if self.isSynchronizing {
            return
        }
        if !self.isReady {
            return
        }
        self.isSynchronizing = true
        self.progressIndex = 0
        self.progressTotal = 0
        if self.selectedAlbumID.isEmpty {
            return
        }
        
        let selectedAlbumID = self.selectedAlbumID
        let selectedFolderID = self.selectedFolderID
        let folder = appState.client.folder(withID: selectedFolderID)!
        
        self.syncTask = Task.detached(priority: .background) {
            defer {
                DispatchQueue.main.async {
                    self.isSynchronizing = false
                    self.syncTask = nil
                }
            }
            
            var err: NSError? = nil
            let folderPath = folder.localNativePath(&err)
            if let err = err {
                print("error getting path: \(err.localizedDescription)")
                return
            }
            let folderURL = URL(fileURLWithPath: folderPath)
            let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [selectedAlbumID], options: nil)
            guard let album = fetchResult.firstObject else {
                return
            }
            let isSelective = folder.isSelective()
            
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let count = assets.count
            
            assets.enumerateObjects { asset, index, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                print("Asset: \(asset.originalFilename) \(asset.localIdentifier)")
                // Update progress
                DispatchQueue.main.async {
                    self.progressIndex = index
                    self.progressTotal = count
                }
                
                var specificFolderURL = folderURL
                var inFolderURL = URL(fileURLWithPath: "/")
                if let creationDate = asset.creationDate {
                    let dateString = dateFormatter.string(from: creationDate)
                    inFolderURL = URL(filePath: dateString)
                    specificFolderURL = specificFolderURL.appending(path: dateString, directoryHint: .isDirectory)
                    try! FileManager.default.createDirectory(at: specificFolderURL, withIntermediateDirectories: true)
                }
                let fileURL = specificFolderURL.appendingPathComponent(asset.originalFilename)
                inFolderURL = inFolderURL.appendingPathComponent(asset.originalFilename)
                let inFolderPath = inFolderURL.path(percentEncoded: false)
                
                // Check if this photo was deleted before
                if let entry = try? folder.getFileInformation(inFolderPath) {
                    if entry.isDeleted() {
                        print("Entry at \(inFolderPath) was deleted, not saving")
                    }
                    else {
                        print("Entry at \(inFolderPath) exists, not saving")
                    }
                    return
                }
                
                // Save photo
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    let options = PHImageRequestOptions()
                    options.isSynchronous = true
                    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                        if let data = data {
                            try! data.write(to: fileURL)
                            if isSelective {
                                try? folder.setLocalFileExplicitlySelected(inFolderPath, toggle: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension PHAsset {
    var primaryResource: PHAssetResource? {
        let types: Set<PHAssetResourceType>

        switch mediaType {
        case .video:
            types = [.video, .fullSizeVideo]
        case .image:
            types = [.photo, .fullSizePhoto]
        case .audio:
            types = [.audio]
        case .unknown:
            types = []
        @unknown default:
            types = []
        }

        let resources = PHAssetResource.assetResources(for: self)
        let resource = resources.first { types.contains($0.type)}

        return resource ?? resources.first
    }

    var originalFilename: String {
        guard let result = primaryResource else {
            return "file"
        }

        return result.originalFilename
    }
}

struct PhotoSyncButton: View {
    @ObservedObject var appState: AppState
    @ObservedObject var photoSync: PhotoSynchronisation
    
    var body: some View {
        if photoSync.isSynchronizing {
            let progress = photoSync.progressTotal > 0 ? Float(photoSync.progressIndex) / Float(photoSync.progressTotal) : 0.0
            ProgressView(value: progress, total: 1.0) {
                Label("Copying photos...", systemImage: "photo.badge.arrow.down.fill")
                    .foregroundStyle(.orange)
                    .badge(Text("\(photoSync.progressIndex)/\(photoSync.progressTotal)"))
            }.tint(.orange)
            
            Button("Cancel") {
                photoSync.cancel()
            }
        }
        else {
            Button("Copy photos now", systemImage: "photo.badge.arrow.down.fill") {
                photoSync.synchronize(self.appState)
            }.disabled(photoSync.isSynchronizing || !photoSync.isReady)
        }
    }
}

struct PhotoSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @State private var albumPickerShown = false
    @ObservedObject var photoSync: PhotoSynchronisation
    
    var body: some View {
        Form {
            Section {
                if authorizationStatus == .authorized {
                    Picker("From album", selection: $photoSync.selectedAlbumID) {
                        Text("None").tag("")
                        ForEach(self.loadAlbums(), id: \.localIdentifier) { album in
                            Text(album.localizedTitle ?? "Unknown album").tag(album.localIdentifier)
                        }
                    }
                    .pickerStyle(.menu).disabled(photoSync.isSynchronizing)
                } else if authorizationStatus == .denied || authorizationStatus == .restricted {
                    Text("Synctrain cannot access your photo library right now")
                    Button("Review permissions in the Settings app") {
                        openAppSettings()
                    }
                } else {
                    Text("Synctrain cannot access your photo library right now")
                    Button("Allow Synctrain to access photos") {
                        PHPhotoLibrary.requestAuthorization { status in
                            DispatchQueue.main.async {
                                authorizationStatus = status
                            }
                        }
                    }
                }
                
                
                if authorizationStatus == .authorized {
                    Picker("To folder", selection: $photoSync.selectedFolderID) {
                        Text("(No folder selected)").tag("")
                        ForEach(appState.folders(), id: \.self) { option in
                            Text(option.displayName).tag(option.folderID)
                        }
                    }
                    .pickerStyle(.menu).disabled(photoSync.isSynchronizing || photoSync.selectedAlbumID.isEmpty)
                }
            } header: {
                Text("Copy photos")
            } footer: {
                if photoSync.isReady {
                    Text("Photos from the selected album will be saved in the selected folder, in sub folders by creation date. If a photo with the same file name already exists in the folder, or has been deleted from the folder before, it will not be saved again.")
                }
            }
            
            Section {
                Toggle("Copy photos periodically in the background", isOn: photoSync.$enableBackgroundCopy)
            }
            
            Section {
                PhotoSyncButton(appState: appState, photoSync: photoSync)
            }
        }
        .navigationTitle("Photos synchronization")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authorizationStatus = PHPhotoLibrary.authorizationStatus()
        }
    }
    
    func loadAlbums() -> [PHAssetCollection] {
        var albums: [PHAssetCollection] = []
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        userAlbums.enumerateObjects { (collection, _, _) in
            albums.append(collection)
        }
        
        // Fetch system albums, including 'Recents'
        let systemAlbumsOptions = PHFetchOptions()
        let systemAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .albumRegular, options: systemAlbumsOptions)
        systemAlbums.enumerateObjects { (collection, _, _) in
            if collection.assetCollectionSubtype == .smartAlbumUserLibrary || collection.assetCollectionSubtype == .smartAlbumRecentlyAdded {
                albums.append(collection)
            }
        }
        return albums
    }
    
    func openAppSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        
        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl)
        }
    }
}
