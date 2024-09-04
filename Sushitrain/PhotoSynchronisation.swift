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
    func synchronize(_ appState: AppState, fullExport: Bool) {
        if self.isSynchronizing {
            return
        }
        if !self.isReady {
            return
        }
        
        if self.selectedAlbumID.isEmpty {
            return
        }
        
        let selectedAlbumID = self.selectedAlbumID
        let selectedFolderID = self.selectedFolderID
        guard let folder = appState.client.folder(withID: selectedFolderID) else {
            return
        }
        
        if !folder.exists() {
            return
        }
        
        self.isSynchronizing = true
        self.progressIndex = 0
        self.progressTotal = 0
        
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
            
            let count = assets.count
            DispatchQueue.main.async {
                self.progressTotal = count
                self.progressIndex = 0
            }
            
            var videosToExport: [(PHAsset, URL, String)] = []
            var livePhotosToExport: [(PHAsset, URL, String)] = []
            var selectPaths: [String] = []
            
            assets.enumerateObjects { asset, index, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                print("Asset: \(asset.originalFilename) \(asset.localIdentifier)")
                
                // Create containing directory
                let dirInFolder = folderURL.appending(path: asset.directoryPathInFolder, directoryHint: .isDirectory)
                try! FileManager.default.createDirectory(at: dirInFolder, withIntermediateDirectories: true)
                
                let inFolderPath = asset.pathInFolder;
                
                // Check if this photo was deleted before
                if !fullExport {
                    if let entry = try? folder.getFileInformation(inFolderPath) {
                        if entry.isDeleted() {
                            print("Entry at \(inFolderPath) was deleted, not saving")
                        }
                        else {
                            print("Entry at \(inFolderPath) exists, not saving")
                        }
                        return
                    }
                }
                
                // Save asset if it doesn't exist already locally
                let fileURL = folderURL.appending(path: inFolderPath, directoryHint: .notDirectory)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    // If a video: queue video export session
                    if asset.mediaType == .video {
                        print("Requesting video export session for \(asset.originalFilename)")
                        videosToExport.append((asset, fileURL, inFolderPath))
                    }
                    else {
                        // Save image
                        let options = PHImageRequestOptions()
                        options.isSynchronous = true
                        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                            if let data = data {
                                try! data.write(to: fileURL)
                                
                                if isSelective {
                                    selectPaths.append(inFolderPath)
                                }
                                
                                DispatchQueue.main.async {
                                    self.progressIndex += 1
                                }
                            }
                        }
                    }
                }
                
                // If the image is a live photo, queue the live photo for saving as well
                if asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive) {
                    let liveInFolderPath = asset.livePhotoPathInFolder
                    let liveDirectoryURL = folderURL.appending(path: asset.livePhotoDirectoryPathInFolder, directoryHint: .isDirectory)
                    try! FileManager.default.createDirectory(at: liveDirectoryURL, withIntermediateDirectories: true)
                    let liveFileURL = folderURL.appending(path: liveInFolderPath, directoryHint: .notDirectory)
                    print("Found live photo \(asset.originalFilename) \(liveInFolderPath)")
                    
                    if !FileManager.default.fileExists(atPath: liveFileURL.path) {
                        livePhotosToExport.append((asset, liveFileURL, liveInFolderPath))
                    }
                }
            }
            
            // Export videos
            print("Starting video exports")
            for (asset, fileURL, selectPath) in videosToExport {
                if Task.isCancelled {
                    break
                }
                
                await withCheckedContinuation { resolve in
                    print("Exporting video \(asset.originalFilename)")
                    let options = PHVideoRequestOptions()
                    options.deliveryMode = .highQualityFormat
                    
                    PHImageManager.default().requestExportSession(forVideo: asset, options: options, exportPreset: AVAssetExportPresetPassthrough) { exportSession, info in
                        if let es = exportSession {
                            es.outputURL = fileURL
                            es.outputFileType = .mov
                            es.shouldOptimizeForNetworkUse = false
                            es.exportAsynchronously {
                                print("Done exporting video \(asset.originalFilename)")
                                DispatchQueue.main.async {
                                    self.progressIndex += 1
                                }
                                selectPaths.append(selectPath)
                                resolve.resume(returning: ())
                            }
                        }
                    }
                }
            }
            
            // Export live photos
            print("Exporting live photos")
            for (asset, destURL, selectPath) in livePhotosToExport {
                if Task.isCancelled {
                    break
                }
                print("Exporting live photo \(asset.originalFilename) \(selectPath)")
                
                await withCheckedContinuation { resolve in
                    // Export live photo
                    let options = PHLivePhotoRequestOptions()
                    options.deliveryMode = .highQualityFormat
                    print("RequestLivePhoto")
                    var found = false
                    PHImageManager.default().requestLivePhoto(for: asset, targetSize: CGSize(width: 1920, height: 1080), contentMode: PHImageContentMode.default, options: options) { livePhoto, info in
                        if found {
                            // The callback can be called twice
                            return
                        }
                        found = true
                        
                        guard let livePhoto = livePhoto else {
                            print("Did not receive live photo for \(asset.originalFilename)")
                            resolve.resume()
                            return
                        }
                        let assetResources = PHAssetResource.assetResources(for: livePhoto)
                        guard let videoResource = assetResources.first(where: { $0.type == .pairedVideo }) else {
                            print("Could not find paired video resource for \(asset.originalFilename) \(assetResources)")
                            resolve.resume()
                            return
                        }
                        
                        PHAssetResourceManager.default().writeData(for: videoResource, toFile: destURL, options: nil) { error in
                            if let error = error {
                                print("Failed to save \(destURL): \(error.localizedDescription)")
                            }
                            else {
                                selectPaths.append(selectPath)
                            }
                            resolve.resume()
                        }
                    }
                }
            }
            
            // Select paths
            if isSelective {
                print("Selecting paths")
                let stList = SushitrainNewListOfStrings()!
                for path in selectPaths {
                    stList.append(path)
                }
                try? folder.setLocalPathsExplicitlySelected(stList)
            }
            print("Done")
        }
    }
}

fileprivate extension PHAsset {
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
        
        return result.originalFilename.replacingOccurrences(of: "/", with: "_")
    }
    
    var directoryPathInFolder: String {
        var inFolderURL = URL(fileURLWithPath: "")
        if let creationDate = self.creationDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: creationDate)
            inFolderURL = URL(filePath: dateString)
        }
        if self.mediaType == .video {
            inFolderURL = inFolderURL.appending(path: "Video", directoryHint: .isDirectory)
        }
        return inFolderURL.path(percentEncoded: false)
    }
    
    var livePhotoDirectoryPathInFolder: String {
        return URL(fileURLWithPath: directoryPathInFolder)
            .appending(path: "Live", directoryHint: .isDirectory)
            .path(percentEncoded: false)
    }
    
    var livePhotoPathInFolder: String {
        let fileName = self.originalFilename + ".MOV"
        let url = URL(fileURLWithPath: self.livePhotoDirectoryPathInFolder).appendingPathComponent(fileName)
        return url.path(percentEncoded: false)
    }
    
    var pathInFolder: String {
        let url = URL(fileURLWithPath: self.directoryPathInFolder).appendingPathComponent(self.originalFilename)
        return url.path(percentEncoded: false)
    }
}
