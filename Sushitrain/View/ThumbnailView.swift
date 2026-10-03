// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct ThumbnailView: View {
	var file: SushitrainEntry
	var showFileName: Bool
	var showErrorMessages: Bool
	var onTap: (() -> Void)?
	var scaleToFill: Bool = true
	var generateOnDemand: Bool = true

	@Environment(AppState.self) private var appState
	@State private var showPreview = false
	@State private var hasCachedThumbnail = false

	private var imageCache: ImageCache {
		return ImageCache.forFolder(file.folder)
	}

	private var thumbnailView: some View {
		ThumbnailImage(
			entry: file,
			content: { phase in
				switch phase {
				case .empty:
					HStack(alignment: .center) {
						ProgressView().controlSize(.small)
					}

				case .success(let image):
					if scaleToFill {
						image.resizable().scaledToFill()
					}
					else {
						image.resizable().scaledToFit()
					}

				case .failure(_):
					if self.showErrorMessages {
						Text("The file is currently not available for preview.")
							.padding(10)
					}
					else {
						self.iconAndTextBody
					}

				@unknown default:
					EmptyView()
				}
			}
		)
		.frame(maxWidth: .infinity)
	}

	var body: some View {
		ZStack {
			if file.canThumbnail {
				let isLocallyPresent = file.isLocallyPresent()
				if isLocallyPresent || showPreview || hasCachedThumbnail || self.imageCache.memoryImage(for: file.cacheKey) != nil
					|| (generateOnDemand
						&& (file.size() <= appState.userSettings.maxBytesForPreview
							|| (appState.userSettings.previewVideos && file.isVideo)))
				{
					if let onTap = self.onTap {
						self.thumbnailView
							.onTapGesture {
								onTap()
							}
					}
					else {
						self.thumbnailView
					}
				}
				else {
					if self.showErrorMessages {
						Button("Show preview for large files") {
							showPreview = true
						}
						.padding(10)
						#if os(macOS)
							.buttonStyle(.link)
						#endif
					}
					else {
						self.iconAndTextBody
					}
				}
			}
			else {
				self.iconAndTextBody
			}
		}
		// Ensure this task is attached to a ZStack instead of a Group, otherwise it keeps getting reattached to whatever
		// is inside the group, and runs way too often.
		.task(id: thumbnailCacheTaskID) {
			if let cacheKey = thumbnailCacheTaskID {
				self.hasCachedThumbnail = await self.imageCache.hasCachedThumbnail(for: cacheKey)
			}
			else {
				self.hasCachedThumbnail = false
			}
		}
	}

	private var thumbnailCacheTaskID: String? {
		if !file.canThumbnail {
			return nil
		}
		return file.cacheKey
	}

	private var iconAndTextBody: some View {
		VStack(alignment: .center, spacing: 6.0) {
			self.iconBody
			if self.showFileName {
				Text(file.fileName())
					.lineLimit(1)
					.padding(.horizontal, 4)
					.foregroundStyle(file.color ?? Color.accentColor)
					.multilineTextAlignment(.center)
			}
		}
	}

	private var iconBody: some View {
		Image(systemName: file.systemImage)
			.dynamicTypeSize(.large)
			.foregroundStyle(file.color ?? Color.accentColor)
	}
}
