// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

private struct GridItemView: View {
	let size: Double
	let file: SushitrainEntry

	var body: some View {
		ZStack(alignment: .topTrailing) {
			Rectangle()
				.frame(width: size, height: size)
				.backgroundStyle(Color.primary)
				.opacity(0.05)

			ThumbnailView(file: file, showFileName: true, showErrorMessages: false)
				.frame(width: size, height: size)
		}
	}
}

struct GridScrollView<HeaderContent: View, Content: View>: View {
	let minColumns = 1
	let maxColumns = 9

	@ObservedObject var userSettings: AppUserSettings
	let header: () -> HeaderContent
	let content: (Int) -> Content

	@State private var scrollViewOffset = CGFloat.zero
	@State var magnifyBy: CGFloat = 1.0

	var body: some View {
		VStack {
			GeometryReader { reader in
				TrackingScrollView(offset: $scrollViewOffset) {
					self.header()

					self.content(userSettings.browserGridColumns)
						.scaleEffect(magnifyBy, anchor: .top)
						#if os(iOS)
							.offset(x: 0, y: (scrollViewOffset + UIScreen.main.bounds.midY) * (1 - magnifyBy))
						#else
							.offset(x: 0, y: (scrollViewOffset + reader.size.height / 2.0) * (1 - magnifyBy))
						#endif
				}
				.highPriorityGesture(magnification)
				.accessibilityZoomAction { action in
					switch action.direction {
					case .zoomIn:
						userSettings.browserGridColumns -= 1

					case .zoomOut:
						userSettings.browserGridColumns += 1
					}
					userSettings.browserGridColumns = min(maxColumns, max(minColumns, userSettings.browserGridColumns))
				}
			}
		}
	}

	// Inspired by https://stackoverflow.com/a/73058175, CC-BY-SA 4.0
	private var magnification: some Gesture {
		MagnificationGesture()
			.onChanged { state in
				if state.isNormal && state > 0.01 {
					magnifyBy = state
				}
			}
			.onEnded { state in
				if state.isNormal && state > 0.0 {
					// Determine the appropriate number of columns
					let newZoom = Double(userSettings.browserGridColumns) * 1 / state
					let newColumnCount = min(maxColumns, max(minColumns, Int(newZoom.rounded(.toNearestOrAwayFromZero))))

					withAnimation(.spring(response: 0.8)) {
						magnifyBy = 1  // reset scaleEffect
						userSettings.browserGridColumns = newColumnCount
					}
				}
				else {
					withAnimation(.spring(response: 0.8)) {
						magnifyBy = 1  // reset scaleEffect
						userSettings.browserGridColumns = maxColumns
					}
				}
			}
	}
}

struct GridFilesView: View {
	@Environment(AppState.self) private var appState

	@ObservedObject var userSettings: AppUserSettings
	var prefix: String
	var files: [SushitrainEntry]
	var subdirectories: [SushitrainEntry]
	var folder: SushitrainFolder
	let columns: Int

	var body: some View {
		let gridColumns = Array(
			repeating: GridItem(.flexible(), spacing: 1.0), count: self.columns)

		LazyVGrid(columns: gridColumns, spacing: 1.0) {
			// List subdirectories
			ForEach(subdirectories, id: \.self.id) { (subDirEntry: SushitrainEntry) in
				GeometryReader { geo in
					let fileName = subDirEntry.fileName()
					NavigationLink(
						destination: BrowserView(folder: folder, prefix: "\(self.prefix)\(fileName)/")
					) {
						GridItemView(size: geo.size.width, file: subDirEntry).id(subDirEntry.id)
					}
					.buttonStyle(PlainButtonStyle())
					.contextMenu(
						ContextMenu(menuItems: {
							if let file = try? folder.getFileInformation(
								self.prefix + fileName)
							{
								NavigationLink(destination: FileView(file: file, showPath: false, siblings: nil)) {
									Label("Subdirectory properties", systemImage: "folder.badge.gearshape")
								}
								ItemSelectToggleView(file: file)

								NavigationLink(destination: SelectiveFolderView(folder: folder, prefix: "\(self.prefix)\(fileName)/")) {
									Label("Files kept on this device", systemImage: "pin")
								}

								if file.hasExternalSharingURL { FileSharingLinksView(entry: file, sync: true) }
							}
						}))
				}
				.aspectRatio(1, contentMode: .fit)
				.clipShape(.rect)
				.contentShape(.rect())
			}

			// List files
			ForEach(files, id: \.self.id) { file in
				GeometryReader { geo in
					FileEntryLink(
						appState: appState,
						entry: file, inFolder: self.folder, siblings: files, honorTapToPreview: true
					) {
						GridItemView(size: geo.size.width, file: file)
					}
					.buttonStyle(PlainButtonStyle())
				}
				.clipShape(.rect)
				.contentShape(.rect())
				.aspectRatio(1, contentMode: .fit)
			}
		}
		.padding(.horizontal, 2)
	}
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
	typealias Value = [CGFloat]
	static let defaultValue: [CGFloat] = [0]

	static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
		value.append(contentsOf: nextValue())
	}
}

// Scroll view that is able to track the vertical position
// From iOS 18, this should be replaced with ScrollPosition/.scrollPosition as provided in SwiftUI
// Inspired by https://github.com/maxnatchanon/trackable-scroll-view
private struct TrackingScrollView<Content: View>: View {
	@Binding var offset: CGFloat
	@ViewBuilder let content: () -> Content

	var body: some View {
		GeometryReader { outsideReader in
			ScrollView([.vertical], showsIndicators: true) {
				ZStack(alignment: .top) {
					GeometryReader { insideReader in
						Color.clear
							.preference(
								key: ScrollOffsetPreferenceKey.self,
								value: [
									self.contentOffset(from: outsideReader, to: insideReader)
								])
					}
					VStack {
						self.content()
					}
				}
			}
			.onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
				self.offset = value[0]
			}
		}
	}

	private func contentOffset(from outsideReader: GeometryProxy, to insideReader: GeometryProxy) -> CGFloat {
		return outsideReader.frame(in: .global).minY - insideReader.frame(in: .global).minY
	}
}
