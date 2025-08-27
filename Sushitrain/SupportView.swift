// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

struct SupportView: View {
	@Environment(AppState.self) private var appState

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

			Section {
				Text(
					"To diagnose any issue you may be experiencing, you may want to make use of the troubleshooting options provided in this app."
				)
				.fixedSize(horizontal: false, vertical: true)

				NavigationLink(destination: TroubleshootingView(userSettings: appState.userSettings)) {
					Label("Troubleshooting options", systemImage: "book.and.wrench")
				}
			}

			Section {
				Text(
					"Synctrain is based on Syncthing. If you have any questions about Syncthing itself, or are experiencing issues with devices running other versions of Syncthing, you may find helpful answers and discussions on the Syncthing forum."
				)
				.fixedSize(horizontal: false, vertical: true)

				Link(destination: URL(string: "https://forum.syncthing.net")!) {
					Label("Visit the Syncthing forum", systemImage: "link")
				}
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.navigationTitle("Questions, support & feedback")
	}
}

struct TroubleshootingView: View {
	@ObservedObject var userSettings: AppUserSettings

	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var hasMigratedLegacyDatabase = false
	@State private var hasLegacyDatabase = false
	@State private var performingDatabaseMaintenance = false

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
			self.updateDatabaseInfo()
		}
		.navigationTitle("Troubleshooting")
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
	}

	private func updateDatabaseInfo() {
		self.hasLegacyDatabase = appState.client.hasLegacyDatabase()
		self.hasMigratedLegacyDatabase = appState.client.hasMigratedLegacyDatabase()
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
			self.updateDatabaseInfo()
			self.performingDatabaseMaintenance = false
		}
	}
}
