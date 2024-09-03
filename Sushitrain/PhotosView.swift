// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import Photos

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
                        ForEach(appState.folders().sorted(), id: \.self) { option in
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
