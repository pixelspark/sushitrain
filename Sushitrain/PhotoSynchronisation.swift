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
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let count = assets.count
            DispatchQueue.main.async {
                self.progressTotal = count
                self.progressIndex = 0
            }
            
            var videosToExport: [(PHAsset, URL)] = []
            var selectPaths: [String] = []
            
            assets.enumerateObjects { asset, index, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                print("Asset: \(asset.originalFilename) \(asset.localIdentifier)")
                var specificFolderURL = folderURL
                var inFolderURL = URL(fileURLWithPath: "")
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
                
                // Save asset
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    // If a video: queue video export session
                    if asset.mediaType == .video {
                        print("Requesting video export session for \(asset.originalFilename)")
                        videosToExport.append((asset, fileURL))
                    }
                    else {
                        // Save image
                        let options = PHImageRequestOptions()
                        options.isSynchronous = true
                        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                            if let data = data {
                                try! data.write(to: fileURL)
                                
                                DispatchQueue.main.async {
                                    self.progressIndex += 1
                                }
                            }
                        }
                    }
                    
                    if isSelective {
                        selectPaths.append(inFolderPath)
                    }
                }
            }
            
            // Export videos
            print("Starting video exports")
            for (asset, fileURL) in videosToExport {
                if Task.isCancelled {
                    return
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
                                resolve.resume(returning: ())
                            }
                        }
                    }
                }
            }
            
            // Select paths
            print("Selecting paths")
            if isSelective {
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

        return result.originalFilename
    }
}
