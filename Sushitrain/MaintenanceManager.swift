// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore

@MainActor class MaintenanceManager {
	// Interval for database maintenance
	static var maintenanceInterval = Duration.seconds(60 * 60 * 24 * 7)
	static var maintenanceWarningInterval = Duration.seconds(maintenanceInterval / Duration.seconds(1.0) * 1.5)

	#if os(macOS)
		static var maintenanceActivityIdentifier = "nl.t-shaped.Sushitrain.database-maintenance"
	#endif

	private unowned var appState: AppState

	init(appState: AppState) {
		self.appState = appState
	}

	#if os(macOS)
		func scheduleDatabaseMaintenance() {
			let lastMaintenance = self.appState.client.lastMaintenanceTime()?.date() ?? Date.now
			var nextMaintenance = lastMaintenance.addingTimeInterval(
				TimeInterval(Self.maintenanceInterval / Duration.seconds(1)))

			let margin = TimeInterval(10.0)
			if nextMaintenance.timeIntervalSince(Date.now) < margin {
				nextMaintenance = Date.now.addingTimeInterval(margin)
			}

			Log.info(
				"Scheduling next database maintenance for \(nextMaintenance) (last=\(lastMaintenance)) time since last=\(Date.now.timeIntervalSince(lastMaintenance)) time to next=\(nextMaintenance.timeIntervalSince(Date.now))"
			)

			let activity = NSBackgroundActivityScheduler(identifier: Self.maintenanceActivityIdentifier)
			activity.repeats = false
			activity.qualityOfService = .background
			activity.interval = nextMaintenance.timeIntervalSince(Date.now)
			activity.tolerance = activity.interval / 2.0
			activity.schedule { completion in
				Log.info("Start background database maintenance")
				Task {
					do {
						try await self.performDatabaseMaintenance()
						Log.info("Complete background database maintenance")
					}
					catch {
						Log.warn("Background database maintenance failed: \(error)")
					}
					completion(.finished)
				}
			}
		}
	#endif

	func performDatabaseMaintenance() async throws {
		Log.info("Performing database maintenance")
		let start = Date.now

		let client = self.appState.client
		#if os(macOS)
			defer {
				self.scheduleDatabaseMaintenance()
			}
		#endif

		let _ = try await
			(Task.detached {
				try client.performMaintenanceBlocking()
			}.value)
		Log.info("Database maintenance finished in \(Date.now.timeIntervalSince(start))s")
	}

	// Returns whether database maintenance is required according to the default schedule (when warning is set to true,
	// the method returns whether the user should be warned about database maintenance)
	func isDatabaseMaintenanceRequired(warning: Bool) -> Bool {
		let interval = warning ? Self.maintenanceWarningInterval : Self.maintenanceInterval
		var last: Date? = nil
		if let l = self.appState.client.lastMaintenanceTime() {
			last = l.date()
		}
		else if self.appState.userSettings.firstRunAt > 0.0 {
			last = Date(timeIntervalSinceReferenceDate: self.appState.userSettings.firstRunAt)
		}

		if let last = last {
			return Date.now.timeIntervalSince(last) > (interval / Duration.seconds(1))
		}
		return false
	}
}
