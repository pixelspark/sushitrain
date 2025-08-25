// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import CoreImage
import CoreImage.CIFilterBuiltins

struct IdenticonView: View {
	let deviceID: String
	let cells = 5
	let cornerRadius = 5.0

	private func shouldFillRectAt(row: Int, column: Int) -> Bool {
		let deviceIDClean = deviceID.replacingOccurrences(
			of: "[\\W_]", with: "", options: [.regularExpression, .caseInsensitive])
		if deviceIDClean.isEmpty {
			return false
		}

		if let asciiBytes = deviceIDClean.data(using: .ascii) {
			let offset = row + column * cells
			if offset >= asciiBytes.count {
				return false
			}

			return asciiBytes[offset] % 2 == 0
		}
		return false
	}

	private func shouldMirrorRectAt(row: Int, column: Int) -> Bool {
		return cells % 2 != 0 && column < middleColumn
	}

	private func mirrorColumnFor(column: Int) -> Int {
		return cells - column - 1
	}

	private var middleColumn: Int {
		return (cells / 2)
	}

	var body: some View {
		Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
			let padding = size.width < 25.0 || size.height < 25.0 ? 0.0 : self.cornerRadius
			let rect = CGRect(origin: .zero, size: size)
			let paddedRect = rect.insetBy(dx: padding, dy: padding)
			let rectWidth = ceil(paddedRect.width / CGFloat(cells))
			let rectHeight = ceil(paddedRect.height / CGFloat(cells))
			context.fill(Rectangle().path(in: rect), with: .style(.windowBackground))
			context.fill(Rectangle().path(in: rect), with: .color(Color.accentColor.opacity(0.05)))

			let xOffset = -(rectWidth * CGFloat(cells) - paddedRect.width) / 2.0 + paddedRect.origin.x
			let yOffset = -(rectHeight * CGFloat(cells) - paddedRect.height) / 2.0 + paddedRect.origin.y

			context.drawLayer { context in
				context.clip(
					to: RoundedRectangle(cornerSize: CGSizeMake(self.cornerRadius / 2.0, self.cornerRadius / 2.0)).path(in: paddedRect)
				)

				for row in 0..<cells {
					for column in 0...middleColumn {
						if self.shouldFillRectAt(row: row, column: column) {
							let square = CGRect(
								x: xOffset + CGFloat(column) * rectWidth,
								y: yOffset + CGFloat(row) * rectHeight,
								width: rectWidth, height: rectHeight)
							context.fill(
								Rectangle().path(in: square), with: .color(Color.accentColor))

							if self.shouldMirrorRectAt(row: row, column: column) {
								let square = CGRect(
									x: xOffset + CGFloat(mirrorColumnFor(column: column)) * rectWidth,
									y: yOffset + CGFloat(row) * rectHeight, width: rectWidth,
									height: rectHeight)
								context.fill(
									Rectangle().path(in: square),
									with: .color(Color.accentColor))
							}
						}
					}
				}
			}
		}
		.aspectRatio(1.0, contentMode: .fit)
		.clipShape(.rect(cornerRadius: self.cornerRadius))
	}
}

struct DeviceIDView: View {
	@Environment(AppState.self) private var appState
	let device: SushitrainPeer
	@State private var qrCodeShown = false
	@State private var localAddressesShown = false

	var body: some View {
		HStack(spacing: 20.0) {
			IdenticonView(deviceID: device.deviceID()).frame(maxWidth: 40)
			Text(device.deviceID())
		}
		.onTapGesture {
			self.qrCodeShown = true
		}
		.monospaced()
		.contextMenu {
			Button(action: {
				writeTextToPasteboard(device.deviceID())
			}) {
				Text("Copy to clipboard")
				Image(systemName: "doc.on.doc")
			}

			Button(action: {
				qrCodeShown = true
			}) {
				Text("Show QR code")
				Image(systemName: "qrcode")
			}

			if self.device.isSelf() {
				Button(action: {
					self.localAddressesShown = true
				}) {
					Text("Show addresses")
				}
			}
		}
		.sheet(
			isPresented: $qrCodeShown,
			content: {
				NavigationStack {
					QRView(text: self.device.deviceID())
						.toolbar(content: {
							ToolbarItem(
								placement: .confirmationAction,
								content: {
									Button("Done") {
										self.qrCodeShown = false
									}
								})
						})
				}
			}
		)
		.sheet(isPresented: $localAddressesShown) {
			NavigationStack {
				ResolvedAddressesView()
					.navigationTitle("Addresses")
					.toolbar(content: {
						ToolbarItem(
							placement: .confirmationAction,
							content: {
								Button("Done") {
									self.localAddressesShown = false
								}
							})
					})
			}
		}
	}
}

private struct ResolvedAddressesView: View {
	@Environment(AppState.self) private var appState

	var body: some View {
		List {
			ForEach(Array(self.appState.resolvedListenAddresses), id: \.self) { addr in
				Text(addr).contextMenu {
					Button(action: {
						#if os(iOS)
							UIPasteboard.general.string = addr
						#endif

						#if os(macOS)
							let pasteboard = NSPasteboard.general
							pasteboard.clearContents()
							pasteboard.prepareForNewContents()
							pasteboard.setString(addr, forType: .string)
						#endif
					}) {
						Text("Copy to clipboard")
						Image(systemName: "doc.on.doc")
					}
				}
			}
		}
		#if os(macOS)
			.frame(minHeight: 320)
		#endif
	}
}

private struct QRView: View {
	private var text: String
	#if os(iOS)
		@State private var image: UIImage? = nil
	#elseif os(macOS)
		@State private var image: NSImage? = nil
	#endif

	init(text: String) {
		self.text = text
	}

	var body: some View {
		ZStack {
			VStack(alignment: .center, spacing: 10.0) {
				if let image = image {
					#if os(iOS)
						Image(uiImage: image)
							.resizable()
							.frame(width: 200, height: 200)
					#elseif os(macOS)
						Image(nsImage: image)
							.resizable()
							.frame(width: 200, height: 200)
					#endif
				}
				else {
					ProgressView()
				}

				Text(self.text).monospaced().contextMenu {
					Button(action: {
						#if os(iOS)
							UIPasteboard.general.string = self.text
						#endif

						#if os(macOS)
							let pasteboard = NSPasteboard.general
							pasteboard.clearContents()
							pasteboard.prepareForNewContents()
							pasteboard.setString(self.text, forType: .string)
						#endif
					}) {
						Text("Copy to clipboard")
						Image(systemName: "doc.on.doc")
					}
				}
			}
		}
		.navigationTitle("Device ID")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.onAppear {
			let filter = CIFilter.qrCodeGenerator()
			let data = text.data(using: .ascii, allowLossyConversion: false)!
			filter.message = data
			if let ciimage = filter.outputImage {
				let transform = CGAffineTransform(scaleX: 10, y: 10)
				let scaledCIImage = ciimage.transformed(by: transform)
				#if os(iOS)
					image = UIImage(data: UIImage(ciImage: scaledCIImage).pngData()!)
				#elseif os(macOS)
					image = NSImage.fromCIImage(scaledCIImage)
				#endif
			}
		}
	}
}
