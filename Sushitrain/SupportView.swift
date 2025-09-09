// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

private struct AppSupportBundle: Encodable {
	enum PrefValue: Encodable {
		case string(String)
		case int(Int)
		case double(Double)
		case boolean(Bool)
		case list([PrefValue])
		case dictionary([String: PrefValue])
		case null
		case data(Data)

		init(_ v: Any) {
			if let b = v as? Bool {
				self = .boolean(b)
			}
			else if let s = v as? String {
				self = .string(s)
			}
			else if let d = v as? Double {
				self = .double(d)
			}
			else if let n = v as? Int {
				self = .int(n)
			}
			else if let b = v as? [Any] {
				self = .list(b.map(PrefValue.init))
			}
			else if let d = v as? [String: Any] {
				self = .dictionary(PrefValue.from(d))
			}
			else if let d = v as? Data {
				self = .data(d)
			}
			else {
				self = .null
			}
		}

		func encode(to encoder: any Encoder) throws {
			switch self {
			case .string(let s): try s.encode(to: encoder)
			case .int(let s): try s.encode(to: encoder)
			case .double(let s): try s.encode(to: encoder)
			case .boolean(let s): try s.encode(to: encoder)
			case .list(let s): try s.encode(to: encoder)
			case .dictionary(let s): try s.encode(to: encoder)
			case .data(let s):
				if let utf = String(data: s, encoding: .utf8) {
					try utf.encode(to: encoder)
				}
				else {
					try s.base64EncodedString().encode(to: encoder)
				}
			case .null: return
			}
		}

		static func from(_ values: [String: Any]) -> [String: PrefValue] {
			var out: [String: PrefValue] = [:]
			for (k, v) in values {
				out[k] = PrefValue(v)
			}
			return out
		}
	}

	var appVersion: String?
	var bundleIdentifier: String?
	var bundlePath: String?
	var userSettings: [String: PrefValue]
	var secondsSinceLaunch: Double?
}

extension AppState {
	fileprivate func generateAppSupportBundle() -> AppSupportBundle {
		let mainBundle = Bundle.main

		UserDefaults.standard.dictionaryRepresentation()
		return AppSupportBundle(
			appVersion: mainBundle.buildVersionNumber,
			bundleIdentifier: mainBundle.bundleIdentifier,
			bundlePath: mainBundle.bundlePath,
			userSettings: AppSupportBundle.PrefValue.from(
				UserDefaults.standard.persistentDomain(forName: mainBundle.bundleIdentifier!) ?? [:]),
			secondsSinceLaunch: Date.now.timeIntervalSince(self.launchedAt)
		)
	}
}

private struct LogView: View {
	@Environment(AppState.self) private var appState
	@State private var lines: String = ""

	var body: some View {
		ScrollView {
			Text(self.lines)
				.textSelection(.enabled)
				.multilineTextAlignment(.leading)
				.lineLimit(nil)
				.monospaced()
				.padding()
				.fixedSize(horizontal: false, vertical: true)
		}
		.navigationTitle("Log")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.task {
			Task {
				var error: NSError? = nil
				self.lines = appState.client.getLastLogLines(&error)
			}
		}
	}
}

private struct SupportBundleView: View {
	@Environment(AppState.self) private var appState
	@State private var writingSupportBundle: Bool = false
	@State private var supportBundle: URL? = nil

	#if os(macOS)
		@State private var showSaveSupportBundle: Bool = false
	#endif

	var body: some View {
		Section {
			Text(
				"To allow others to assist you in troubleshooting, you can send them a support bundle. This bundle contains technical information about the app. **Note: while the app will redact user names, IP addresses and device IDs in the bundle, it may still contain personally identifiable information, such as folder names. Be sure to review the contents of the bundle before sending it to others.**"
			)
			.fixedSize(horizontal: false, vertical: true)
			.onDisappear {
				if let s = self.supportBundle {
					try? FileManager.default.removeItem(at: s)
				}
			}
			#if os(macOS)
				.fileImporter(isPresented: $showSaveSupportBundle, allowedContentTypes: [.directory]) { res in
					switch res {
					case .failure(let e):
						Log.warn("error selecting path: \(e)")
					case .success(let url):
						if !url.startAccessingSecurityScopedResource() {
							Log.warn("Could not start accessing folder to export support bundle to")
						}
						defer { url.stopAccessingSecurityScopedResource() }

						if let sbURL = self.supportBundle {
							let targetURL = url.appendingPathComponent(sbURL.lastPathComponent, isDirectory: false)
							Log.info("Copying support bundle  to URL \(targetURL)")
							try? FileManager.default.copyItem(at: sbURL, to: targetURL)
						}
					}
				}
			#endif

			if let s = supportBundle {
				ShareLink(item: s, subject: Text("Support bundle"), message: Text("Support bundle"), preview: self.sharePreview()) {
					Label("Share information bundle for support", systemImage: "text.page.badge.magnifyingglass")
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif

				#if os(macOS)
					Button("Save support bundle", systemImage: "text.page.badge.magnifyingglass") {
						showSaveSupportBundle = true
					}
					.buttonStyle(.link)
				#endif
			}
			else {
				Button("Generate support bundle", systemImage: "text.page.badge.magnifyingglass") {
					Task.detached {
						await self.generateSupportBundle()
					}
				}.disabled(writingSupportBundle)
					#if os(macOS)
						.buttonStyle(.link)
					#endif
			}
		}
	}

	private func generateSupportBundle() async {
		if self.supportBundle == nil && !self.writingSupportBundle {
			self.writingSupportBundle = true
			do {
				// Generate app-side bundle
				let appBundle = appState.generateAppSupportBundle()
				let encoder = JSONEncoder()
				encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
				let appBundleJSON = try encoder.encode(appBundle)

				let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
				let tempPath = tempDir.appending(
					component: "Synctrain-support-bundle-\(ProcessInfo().globallyUniqueString).zip")
				try self.appState.client.writeSupportBundle(tempPath.path(percentEncoded: false), appInfo: appBundleJSON)

				DispatchQueue.main.async {
					self.writingSupportBundle = false
					self.supportBundle = tempPath
				}
			}
			catch {
				Log.warn("cannot write support bundle: \(error.localizedDescription)")
			}
		}
	}

	private func sharePreview() -> SharePreview<Never, Never> {
		return SharePreview("Support bundle")
	}
}

struct SupportView: View {
	@Environment(AppState.self) private var appState
	@State private var showLog: Bool = false

	var body: some View {
		Form {
			Section {
				Text(
					"If you have a question about Synctrain or are experiencing issues, you may find a solution on our 'frequently asked questions' page."
				)
				.fixedSize(horizontal: false, vertical: true)

				Link(destination: URL(string: "https://t-shaped.nl/synctrain-support")!) {
					Label("View frequently asked questions", systemImage: "link")
				}
			}

			Section {
				Text(
					"If your issue remains unresolved, you may invoke the help of our community through our discussions page. Remember that this app is free software. While we do care deeply about your feedback and want to ensure the app is working correctly, we do not have the resources to provide support with your specific issue or usage of Synctrain. You can greatly increase the chance of fixing your issue by providing detailed descriptions of your issue, your configuration and usage, and what you already did to try and resolve the issue yourself. Please provide as much information as possible, including relevant settings, screenshots and error messages."
				)
				.fixedSize(horizontal: false, vertical: true)

				Link(destination: URL(string: "https://github.com/pixelspark/sushitrain/discussions/categories/q-a")!) {
					Label("Ask a question", systemImage: "link")
				}
				Link(destination: URL(string: "https://github.com/pixelspark/sushitrain/discussions/categories/ideas")!) {
					Label("Propose an idea", systemImage: "link")
				}
			}

			SupportBundleView()

			Section {
				Text(
					"Synctrain is based on Syncthing. If you have any questions about Syncthing itself, or are experiencing issues with devices running other versions of Syncthing, you may find helpful answers and discussions on the Syncthing forum."
				)
				.fixedSize(horizontal: false, vertical: true)

				Link(destination: URL(string: "https://forum.syncthing.net")!) {
					Label("Visit the Syncthing forum", systemImage: "link")
				}
			}

			Section {
				Text(
					"To diagnose any issue you may be experiencing, you may want to make use of the troubleshooting options provided in this app."
				)
				.fixedSize(horizontal: false, vertical: true)

				NavigationLink(destination: TroubleshootingView(userSettings: appState.userSettings)) {
					Label("Troubleshooting options", systemImage: "book.and.wrench")
				}

				Button("View log messages", systemImage: "heart.text.clipboard") {
					showLog = true
				}.sheet(isPresented: $showLog) {
					NavigationStack {
						LogView()
					}
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.navigationTitle("Questions, support & feedback")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}
}

struct TroubleshootingView: View {
	@ObservedObject var userSettings: AppUserSettings

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var hasMigratedLegacyDatabase = false
	@State private var hasLegacyDatabase = false
	@State private var performingDatabaseMaintenance = false
	@State private var databaseSize: Int64? = nil

	private static let formatter = ByteCountFormatter()

	var body: some View {
		Form {
			Section {
				Toggle("Enable debug logging", isOn: userSettings.$loggingToFileEnabled)
			} header: {
				Text("Logging")
			} footer: {
				if appState.userSettings.loggingToFileEnabled {
					if appState.isLoggingToFile {
						Text(
							"The app is logging to a file in the application folder, which you can share with the developers."
						)
					}
					else {
						Text(
							"After restarting the app, the app will write a log file in the application folder, which you can then share with the developers."
						)
					}
				}
				else {
					if appState.isLoggingToFile {
						Text("Restart the app to stop logging.")
					}
					else {
						Text(
							"Logging slows down the app and uses more battery. Only enable it if you are experiencing problems."
						)
					}
				}
			}

			Section {
				LabeledContent("Database type") {
					if hasLegacyDatabase {
						// This shouldn't happen because either the migration fails or the app runs, but if it does happen
						// we want to know (and therefore indicate it in the UI).
						Text("v1").foregroundStyle(.red)
					}
					else {
						Text("v2")
					}
				}

				LabeledContent("Database size") {
					if let size = self.databaseSize {
						Text(Self.formatter.string(fromByteCount: size))
					}
					else {
						Text("Unknown")
					}
				}

				if appState.userSettings.migratedToV2At > 0.0 {
					LabeledContent("Upgraded at") {
						Text(
							Date(timeIntervalSinceReferenceDate: appState.userSettings.migratedToV2At).formatted(
								date: .abbreviated, time: .shortened))
					}
				}
			} header: {
				Text("Database maintenance")
			}

			if hasLegacyDatabase {
				Section {
					Button("Restart app to remove v1 database") {
						UserDefaults.standard.set(true, forKey: "clearV1Index")
						exit(0)
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				} footer: {
					Text(
						"A legacy database is still present. If the app is functioning correctly, it is safe to manually delete this database. In order to do this, the app needs to be restarted."
					)
				}.disabled(performingDatabaseMaintenance)
			}

			if hasMigratedLegacyDatabase {
				Section {
					Button("Remove v1 database back-up") {
						self.clearMigratedLegacyDatabase()
					}
					#if os(macOS)
						.buttonStyle(.link)
					#endif
				} footer: {
					Text(
						"After a database upgrade, a copy of the old version is retained for a while. This copy may take up a significant amount of storage space. If everything is working as expected, it is safe to remove this back-up."
					)
				}.disabled(performingDatabaseMaintenance)
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
			.navigationBarBackButtonHidden(true)
			.toolbar {
				ToolbarItem(placement: .navigation) {
					Button(action: {
						dismiss()
					}) {
						Label("Back", systemImage: "arrow.left.circle")
					}
				}
			}
		#endif
		.task {
			await self.updateDatabaseInfo()
		}
		.navigationTitle("Troubleshooting")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}

	private func updateDatabaseInfo() async {
		self.hasLegacyDatabase = appState.client.hasLegacyDatabase()
		self.hasMigratedLegacyDatabase = appState.client.hasMigratedLegacyDatabase()

		let path = SushitrainApp.configDirectoryURL().appending(path: "index-v2", directoryHint: .isDirectory)
		do {
			let size = try await FileManager.default.sizeOfFolder(path: path)
			self.databaseSize = Int64(size)
			Log.info("size of database is \(size) at path \(path)")
		}
		catch {
			Log.warn("could not determine database size at path \(path): \(error.localizedDescription)")
			self.databaseSize = nil
		}
	}

	private func clearMigratedLegacyDatabase() {
		if self.performingDatabaseMaintenance {
			return
		}
		Task {
			self.performingDatabaseMaintenance = true
			do {
				try appState.client.clearMigratedLegacyDatabase()
			}
			catch {
				print("Cannot clear migrated V1 index: \(error.localizedDescription)")
			}
			await self.updateDatabaseInfo()
			self.performingDatabaseMaintenance = false
		}
	}
}
