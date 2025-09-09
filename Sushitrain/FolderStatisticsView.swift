// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import Charts

enum ProgressType: Hashable {
	case needs
	case stores
}

extension SushitrainFolderStats {
	// Progress of this device, between 0...1
	func thisDeviceProgress(progressType: ProgressType) -> Double {
		switch progressType {
		case .needs:
			if let localNeed = self.localNeed, let global = self.global, global.bytes > 0 {
				return Double(max(0, global.bytes - localNeed.bytes)) / Double(global.bytes)
			}
			return 0.0

		case .stores:
			if let localStored = self.local, let global = self.global, global.bytes > 0 {
				return Double(localStored.bytes) / Double(global.bytes)
			}
			return 0.0
		}
	}

	// Total progress of other devices, between 0...1
	func otherDevicesProgress(completions: [SushitrainCompletion], progressType: ProgressType) -> Double {
		if completions.isEmpty {
			return 1.0
		}

		if let global = self.global, global.bytes > 0 {
			var totalNeed = 0.0
			for completion in completions {
				switch progressType {
				case .needs, .stores:
					// ! FIXME: we can't know what the other devices store?
					totalNeed += Double(completion.needBytes)
				}

			}
			totalNeed /= Double(completions.count)

			return Double(max(0, Double(global.bytes) - totalNeed)) / Double(global.bytes)
		}
		return 0.0
	}
}

extension SushitrainFolder {
	func completions() throws -> [String: SushitrainCompletion] {
		var completions: [String: SushitrainCompletion] = [:]
		for deviceID in self.sharedWithDeviceIDs()?.asArray() ?? [] {
			completions[deviceID] = try self.completion(forDevice: deviceID)
		}
		return completions
	}
}

struct FolderProgressChartView: View {
	let statistics: SushitrainFolderStats
	let completions: [String: SushitrainCompletion] = [:]

	@State var progressType: ProgressType = .needs

	private let thresholdForOverlay = 0.9

	var body: some View {
		Chart {
			Plot {
				let ownPercentage = statistics.thisDeviceProgress(progressType: self.progressType)
				let otherPercentage = statistics.otherDevicesProgress(
					completions: Array(completions.values), progressType: self.progressType)

				// Other devices
				BarMark(
					xStart: .value("Percentage", 0),
					xEnd: .value("Percentage", -otherPercentage * 100.0),
				)
				.annotation(position: .overlay) {  // Places the annotation above the bar
					if otherPercentage > thresholdForOverlay {
						Text("\(Int(otherPercentage * 100.0))%").font(.caption).lineLimit(nil)
					}
					else {
						Text("")
					}
				}
				.annotation(position: .leading) {
					if otherPercentage <= thresholdForOverlay {
						Text("\(Int(ownPercentage * 100.0))%").font(.caption).lineLimit(nil)
					}
					else {
						Text("")
					}
				}
				.foregroundStyle(by: .value("Category", String(localized: "Other devices")))

				// This device
				BarMark(
					xStart: .value("Percentage", 0),
					xEnd: .value("Percentage", ownPercentage * 100.0),
				)
				.annotation(position: .overlay) {  // Places the annotation above the bar
					if ownPercentage > thresholdForOverlay {
						Text("\(Int(ownPercentage * 100.0))%").font(.caption).lineLimit(nil)
					}
					else {
						Text("")
					}
				}
				.annotation(position: .trailing) {
					if ownPercentage <= thresholdForOverlay {
						Text("\(Int(ownPercentage * 100.0))%").font(.caption).lineLimit(nil)
					}
					else {
						Text("")
					}
				}
				.foregroundStyle(by: .value("Category", String(localized: "This device")))
			}
		}
		.chartPlotStyle { plotArea in
			plotArea
				#if os(macOS)
					.background(Color.gray.opacity(0.2))
				#else
					.background(Color(.systemFill))
				#endif
				.cornerRadius(12)
		}
		.chartXAxis(.hidden)
		.chartXScale(domain: -100...100)
		.chartYScale(range: .plotDimension(endPadding: -8))
		.chartLegend(position: .bottom, spacing: 8)
		.chartLegend(.visible)
		.contextMenu {
			Picker("Show", selection: $progressType) {
				Text("What each device wants").tag(ProgressType.needs)
				Text("What each device stores").tag(ProgressType.stores)
			}.pickerStyle(.inline)
		}
	}
}

struct FolderStatisticsView: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder

	@State private var statistics: SushitrainFolderStats? = nil
	@State private var allDevices: [String: SushitrainPeer] = [:]
	@State private var completions: [String: SushitrainCompletion] = [:]
	@State private var formatter = ByteCountFormatter()
	@State private var loading = false

	private func update() async {
		if self.loading {
			return
		}

		self.loading = true
		await Task.detached {
			let peers = await appState.peers().filter({ d in !d.isSelf() })
			var dict: [String: SushitrainPeer] = [:]
			for peer in peers {
				dict[peer.deviceID()] = peer
			}
			let stats = try? self.folder.statistics()
			let completions = try? self.folder.completions()

			Task { @MainActor in
				self.allDevices = dict
				self.statistics = stats
				self.completions = completions ?? [:]
			}
		}.value
		self.loading = false
	}

	var body: some View {
		Form {
			FolderStatusView(folder: folder)

			if self.loading {
				HStack {
					Spacer()
					ProgressView().padding()
					Spacer()
				}
			}
			else if let stats = self.statistics {
				FolderProgressChartView(statistics: stats, progressType: folder.isSelective() ? .stores : .needs).frame(height: 48)

				// Global statistics
				if let g = stats.global {
					Section("Full folder") {
						// Use .formatted() here because zero is hidden in badges and that looks weird
						Text("Number of files").badge(g.files.formatted())
						Text("Number of directories").badge(g.directories.formatted())
						Text("File size").badge(formatter.string(fromByteCount: g.bytes))
					}
				}

				let totalLocal = Double(stats.global!.bytes)
				let myPercentage = Int(
					totalLocal > 0 ? (100.0 * Double(stats.local!.bytes) / totalLocal) : 100)

				if let local = stats.local {
					Section {
						NavigationLink(destination: NeededFilesView(folder: folder, device: nil)) {
							Text("Number of files").badge(local.files.formatted())
						}
						Text("Number of directories").badge(local.directories.formatted())
						Text("File size").badge(formatter.string(fromByteCount: local.bytes))
					} header: {
						HStack {
							Text("On this device: \(myPercentage)% of the full folder")
						}
					}
				}

				if !self.completions.isEmpty {
					Section {
						ForEach(completions.keys.sorted(by: >), id: \.self) { deviceID in
							let completion = completions[deviceID]!
							if let device = self.allDevices[deviceID] {
								NavigationLink(destination: NeededFilesView(folder: folder, device: device)) {
									HStack {
										Label(
											device.name(),
											systemImage: "externaldrive"
										)
										Spacer()
									}.badge(
										Text(
											"\(Int(completion.completionPct))%"
										))
								}
							}
						}
					} header: {
						Text("Other devices progress")
					} footer: {
						Text(
							"The percentage of the files a device has synchronized, relative to the part of the folder it wants to synchronize. Because devices may ignore certain files or not synchronize any files at all, the percentage does not indicate the percentage of the full folder actually present on the device."
						)
					}
				}
			}
		}
		.task {
			await self.update()
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.navigationTitle("Folder statistics: '\(self.folder.displayName)'")
	}
}

private struct NeededFilesView: View {
	@Environment(AppState.self) private var appState
	var folder: SushitrainFolder
	var device: SushitrainPeer?

	@State private var loading = false
	@State private var files: [SushitrainEntry] = []
	@State private var error: Error? = nil

	private static let fileLimit = 100

	private enum Errors: LocalizedError {
		case tooManyFiles(count: Int)

		var errorDescription: String? {
			switch self {
			case .tooManyFiles(let count):
				return String(localized: "Too many files (\(count)) to display.")
			}
		}
	}

	var body: some View {
		Group {
			if loading {
				HStack(alignment: .center) {
					VStack(alignment: .center) {
						ProgressView()
					}
				}
			}
			else if let e = error {
				ContentUnavailableView(e.localizedDescription, systemImage: "exclamationmark.triangle.fill").frame(minHeight: 300)
			}
			else if files.isEmpty {
				ContentUnavailableView(
					device == nil ? "This device has all the files it wants" : "\(device!.displayName) has all the files it wants",
					systemImage: "checkmark.circle.fill"
				)
				.frame(minHeight: 300)
			}
			else {
				List {
					ForEach(self.files) { file in
						Text(file.name())
					}
				}.frame(minHeight: 300)
					.refreshable {
						await self.update()
					}
			}
		}
		.task {
			await self.update()
		}
		.navigationTitle(device == nil ? "Files needed by this device" : "Files needed by \(device!.displayName)")
	}

	private func update() async {
		if loading {
			return
		}

		do {
			self.loading = true

			self.files = try await Task {
				var paths: [String]
				if let device = self.device {
					let completion = try folder.completion(forDevice: device.deviceID())
					if completion.needItems > Self.fileLimit {
						throw Errors.tooManyFiles(count: completion.needItems)
					}

					paths = (try folder.filesNeeded(by: device.deviceID())).asArray()
				}
				else {
					let stats = try folder.statistics()
					if let ln = stats.localNeed, ln.files > Self.fileLimit {
						throw Errors.tooManyFiles(count: ln.files)
					}
					paths = (try folder.filesNeeded()).asArray()
				}
				return paths.compactMap { try? folder.getFileInformation($0) }
			}.value
		}
		catch {
			self.error = error
			self.files = []
		}
		self.loading = false
	}
}
