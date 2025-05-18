// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct ThumbnailView: View {
	var file: SushitrainEntry

	// For some reason, environment object is not available in peek/pop on long press on iOS, so pass appState as member
	@ObservedObject var appState: AppState
	@State var showPreview = false
	var showFileName: Bool
	var showErrorMessages: Bool

	private var imageCache: ImageCache {
		return ImageCache.forFolder(file.folder)
	}

	var body: some View {
		if file.canThumbnail {
			let isLocallyPresent = file.isLocallyPresent()
			if isLocallyPresent || showPreview || self.imageCache[file.cacheKey] != nil
				|| file.size() <= appState.maxBytesForPreview
				|| (appState.previewVideos && file.isVideo)
			{
				ThumbnailImage(
					entry: file,
					content: { phase in
						switch phase {
						case .empty:
							HStack(
								alignment: .center,
								content: {
									ProgressView().controlSize(.small)
								})

						case .success(let image):
							image.resizable().scaledToFill()

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
				.frame(maxWidth: .infinity, maxHeight: 200)
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
