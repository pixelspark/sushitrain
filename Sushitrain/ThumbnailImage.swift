// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import QuickLookThumbnailing
import AVKit

#if os(macOS)
    extension NSImage {
        static func fromCIImage(_ ciImage: CIImage) -> NSImage {
            let rep = NSCIImageRep(ciImage: ciImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            return nsImage
        }
    }
#endif

enum ImageFetchError: Swift.Error {
    case failedToFetchImage
    case failedToDownsample
}

fileprivate func fetchQuicklookThumbnail(_ url: URL, size: CGSize) async -> AsyncImagePhase {
    #if os(iOS)
        let scale = await UIScreen.main.scale
    #else
        let scale = 1.0
    #endif
    let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
    do {
        let thumb =  try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        #if os(iOS)
            return .success(Image(uiImage: thumb.uiImage))
        #else
        return .success(Image(decorative: thumb.cgImage, scale: 1, orientation: .up))
        #endif
    }
    catch {
        return .failure(error)
    }
}

fileprivate func fetchVideoThumbnail(url: URL, maxDimensionsInPixels: Int) async -> AsyncImagePhase {
    return await (Task {
        let asset = AVURLAsset(url: url)
        let avAssetImageGenerator = AVAssetImageGenerator(asset: asset)
        avAssetImageGenerator.appliesPreferredTrackTransform = true
        let thumbnailTime = CMTimeMake(value: 2, timescale: 1)
        do {
            let (cgThumbImage, _) = try await avAssetImageGenerator.image(at: thumbnailTime)
            let thumbnailSize = CGSizeMake(CGFloat(cgThumbImage.width), CGFloat(cgThumbImage.height))
                .fitScale(maxDimension: CGFloat(maxDimensionsInPixels))
            
            if let downsampledImage = cgThumbImage.resize(size: thumbnailSize) {
                #if os(iOS)
                    return AsyncImagePhase.success(Image(uiImage: UIImage(cgImage: downsampledImage)))
                #else
                    return AsyncImagePhase.success(Image(nsImage: NSImage(cgImage: downsampledImage, size: .zero)))
                #endif
            }
            else {
                return AsyncImagePhase.empty
            }
        } catch {
            return AsyncImagePhase.failure(error)
        }
    }.value)
}

fileprivate func fetchImageThumbnail(_ url: URL, maxDimensionsInPixels: Int) async -> AsyncImagePhase {
    // For other files, fetch from URL
    let imageSourceOption = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOption) else {
        return .failure(ImageFetchError.failedToFetchImage)
    }

    let downsampledOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCache: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimensionsInPixels,
    ] as CFDictionary

    guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        downsampledOptions
    ) else {
        return .failure(ImageFetchError.failedToDownsample)
    }

    #if os(iOS)
        return .success(Image(uiImage: UIImage(cgImage: downsampledImage)))
    #else
        return .success(Image(nsImage: NSImage(cgImage: downsampledImage, size: .zero)))
    #endif

}

enum ThumbnailStrategy {
    case image
    case video
}

struct ThumbnailImage<Content>: View where Content: View {
    private let cacheKey: String
    private let url: URL
    private let content: (AsyncImagePhase) -> Content
    private let thumbnailStrategy: ThumbnailStrategy
    private let maxDimensionsInPixels = 255
    @State private var phase: AsyncImagePhase = .empty
    
    init(
        cacheKey: String,
        url: URL,
        strategy: ThumbnailStrategy,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.cacheKey = cacheKey
        self.url = url
        self.thumbnailStrategy = strategy
        self.content = content
    }
    
    var body: some View {
        self.content(phase)
            .task {
                self.phase = await fetchOrCached()
            }
            .onChange(of: url) { (ov,nv) in
                Task {
                    self.phase = await fetchOrCached()
                }
            }
    }
    
    private func fetchOrCached() async -> AsyncImagePhase {
        if let cached = ImageCache[cacheKey] {
            return .success(cached)
        }
        
        let url = self.url
        let maxDimensionsInPixels = self.maxDimensionsInPixels
        
        if url.isFileURL {
            return await Task.detached {
                return await fetchQuicklookThumbnail(url, size: CGSize(width: maxDimensionsInPixels, height: maxDimensionsInPixels))
            }.value
        }
        
        let ph = await Task.detached {
            // For local files, ask QuickLook (and bypass our cache)
            switch self.thumbnailStrategy {
            case .image:
                return await fetchImageThumbnail(url, maxDimensionsInPixels: maxDimensionsInPixels)
            case .video:
                return await fetchVideoThumbnail(url: url, maxDimensionsInPixels: maxDimensionsInPixels)
            }
        }.value
        if case .success(let image) = ph {
            ImageCache[cacheKey] = image
        }
        return ph
    }
    
    func cacheAndRender(phase: AsyncImagePhase) -> some View {
        if case .success(let image) = phase {
            ImageCache[cacheKey] = image
        }
        return content(phase)
    }
}

@MainActor
class ImageCache {
    static private var cache: [String: Image] = [:]
    static private var maxCacheSize = 255
    
    static var diskCacheEnabled: Bool = true
    static var customCacheDirectory: URL? = nil
    
    private static var cacheDirectory: URL {
        if let cc = Self.customCacheDirectory {
            return cc
        }
        return URL.cachesDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }
    
    private static func pathFor(cacheKey: String) -> URL {
        let prefixA = String(cacheKey.prefix(2))
        let prefixB = String(cacheKey.prefix(4).suffix(2))
        let fileName = cacheKey.suffix(cacheKey.count - 4)
        
        return Self.cacheDirectory
            .appendingPathComponent(prefixA, isDirectory: true)
            .appendingPathComponent(prefixB, isDirectory: true)
            .appendingPathComponent("\(fileName).jpg", isDirectory: false)
    }
    
    static func clear() {
        do {
            self.cache.removeAll()
            try FileManager.default.removeItem(at: Self.cacheDirectory)
        }
        catch {
            Log.warn("Could not clear cache: \(error.localizedDescription)")
        }
    }
    
    static func diskCacheSizeBytes() throws -> UInt {
        let files = try FileManager.default.subpathsOfDirectory(atPath: Self.cacheDirectory.path())
        var totalSize: UInt = 0
        for file in files {
            let filePath = Self.cacheDirectory.appendingPathComponent(file)
            let fileDictionary = try FileManager.default.attributesOfItem(atPath: filePath.path())
            if let size = fileDictionary[FileAttributeKey.size] as? UInt {
                totalSize += size
            }
            else {
                Log.warn("No file size for path \(filePath.path) \(file) \(fileDictionary)")
            }
        }
        return totalSize
    }
    
    static subscript(cacheKey: String) -> Image? {
        get {
            // Attempt to retrieve from memory cache first
            if let img = ImageCache.cache[cacheKey] {
                return img
            }
            
            if Self.diskCacheEnabled {
                let url = Self.pathFor(cacheKey: cacheKey)
                if FileManager.default.fileExists(atPath: url.path) {
                    #if os(iOS)
                        if let img = UIImage(contentsOfFile: url.path()) {
                            return Image(uiImage: img)
                        }
                    #elseif os(macOS)
                    if let img = NSImage(contentsOfFile: url.path()) {
                        return Image(nsImage: img)
                    }
                    #endif
                }
                return nil
            }
            
            return nil
        }
        set {
            // Memory cache (always enabled)
            while cache.count >= maxCacheSize {
                // This is a rather random way to remove items from the cache, investigate using an ordered map
                _ = ImageCache.cache.popFirst()
            }
            ImageCache.cache[cacheKey] = newValue
            
            if diskCacheEnabled {
                if let image = newValue {
                    let renderer = ImageRenderer(content: image)
                    renderer.isOpaque = true

                    #if os(iOS)
                        // We're using JPEG for now, because HEIC leads to distorted thumbnails for HDR videos
                        if let data = renderer.uiImage?.jpegData(compressionQuality: 0.9) {
                            let url = Self.pathFor(cacheKey: cacheKey)
                            let dirURL = url.deletingLastPathComponent()

                            do {
                                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                                try data.write(to: url)
                                try (url as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
                            }
                            catch {
                                Log.warn("Could not write to cache file \(url.path()): \(error.localizedDescription)")
                            }
                        }
                    #else
                        // Let's do things the more old-fashioned way on macOS
                        if let nsImage = renderer.nsImage {
                            if let tiff = nsImage.tiffRepresentation,
                                let rep = NSBitmapImageRep(data: tiff),
                                let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                                let url = Self.pathFor(cacheKey: cacheKey)
                                do {
                                    try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
                                    try jpegData.write(to: url)
                                    try (url as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
                                }
                                catch {
                                    Log.warn("Could not write to cache file \(url.path()): \(error.localizedDescription)")
                                }
                            }
                            else {
                                Log.warn("Could not generate JPEG")
                            }
                        }
                        
                        // Below is the code to do this using CoreGraphics and HEIF on macOS. This however leads to 'noise'
                        // for thumbnails that are generated from videos for some reason...
                        /*
                        if let cgImage = ImageRenderer(content: image).cgImage {
                            let url = Self.pathFor(cacheKey: cacheKey)
                            do {
                                try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
                                if let heifDest = CGImageDestinationCreateWithURL(url as CFURL, AVFileType.heic as CFString, 1, nil) {
                                    CGImageDestinationAddImage(heifDest, cgImage, nil)
                                    if CGImageDestinationFinalize(heifDest) {
                                        try (url as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
                                    }
                                    else {
                                        Log.warn("Failed writing HEIF image")
                                    }
                                }
                                else {
                                    Log.warn("Could not generate HEIF file")
                                }
                            }
                            catch {
                                Log.warn("Could not write to cache file \(url.path()): \(error.localizedDescription)")
                            }
                        }
                        */
                    #endif
                }
            }
        }
    }
}
