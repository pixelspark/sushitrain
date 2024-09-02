// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import Photos

@MainActor
class PhotoSynchronisation: ObservableObject {
    @AppStorage("photoSyncSelectedAlbumID") var  selectedAlbumID: String = ""
    @AppStorage("photoSyncFolderID") var selectedFolderID: String = ""
    @State var isSynchronizing = false
    
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
    func synchronize(_ appState: AppState) {
        if self.isSynchronizing {
            return
        }
        if !self.isReady {
            return
        }
        self.isSynchronizing = true
        if self.selectedAlbumID.isEmpty {
            return
        }
        
        let selectedAlbumID = self.selectedAlbumID
        let selectedFolderID = self.selectedFolderID
        
        DispatchQueue.global(qos: .background).async {
            defer {
                DispatchQueue.main.async {
                    self.isSynchronizing = false
                }
            }
            
            let folder = appState.client.folder(withID: selectedFolderID)!
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
            assets.enumerateObjects { asset, _, _ in
                print("Asset: \(asset.description)")
                
                // Save photo
                let options = PHImageRequestOptions()
                options.isSynchronous = true

                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    if let data = data {
                        let fileURL = folderURL.appendingPathComponent(asset.originalFilename)
                        try! data.write(to: fileURL)
                        if isSelective {
                            try? folder.setLocalFileExplicitlySelected(fileURL.path(), toggle: true)
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

struct PhotoSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @State private var albumPickerShown = false
    
    var body: some View {
        Form {
            Section {
                if authorizationStatus == .authorized {
                    Picker("From album", selection: $appState.photoSync.selectedAlbumID) {
                        ForEach(self.loadAlbums(), id: \.localIdentifier) { album in
                            Text(album.localizedTitle ?? "Unknown album").tag(album.localIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
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
                    Picker("To folder", selection: $appState.photoSync.selectedFolderID) {
                        Text("(No folder selected)").tag("")
                        ForEach(appState.folders(), id: \.self) { option in
                            Text(option.displayName).tag(option.folderID)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Section {
                Button("Copy photos now") {
                    appState.photoSync.synchronize(self.appState)
                }.disabled(appState.photoSync.isSynchronizing || !appState.photoSync.isReady)
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
