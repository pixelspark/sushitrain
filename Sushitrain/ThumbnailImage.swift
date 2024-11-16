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
fileprivate class ImageCache {
    static private var cache: [String: Image] = [:]
    static private var maxCacheSize = 255
    
    static subscript(cacheKey: String) -> Image? {
        get {
            ImageCache.cache[cacheKey]
        }
        set {
            while cache.count >= maxCacheSize {
                // This is a rather random way to remove items from the cache, investigate using an ordered map
                _ = ImageCache.cache.popFirst()
            }
            ImageCache.cache[cacheKey] = newValue
        }
    }
}
