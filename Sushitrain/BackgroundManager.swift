// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import BackgroundTasks

struct BackgroundSyncRun: Codable, Equatable {
	var started: Date
	var ended: Date?
	var taskType: BackgroundTaskType?

	var asString: String {
		if let ended = self.ended {
			if let tt = self.taskType {
				return "\(self.started.formatted()) - \(ended.formatted()) (\(tt.localizedTypeName))"
			}
			return "\(self.started.formatted()) - \(ended.formatted())"
		}
		return self.started.formatted()
	}
}

enum BackgroundTaskType: String, Codable, Equatable {
	case short = "nl.t-shaped.Sushitrain.short-background-sync"
	case long = "nl.t-shaped.Sushitrain.background-sync"

	// For some reason, this one must have the exact App bundle ID as prefix (case-sensitive)
	case continued = "nl.t-shaped.Sushitrain.continued-background-sync"

	var identifier: String {
		return self.rawValue
	}

	var localizedTypeName: String {
		switch self {
		case .short: String(localized: "short")
		case .long: String(localized: "long")
		case .continued: String(localized: "continued")
		}
	}
}

enum ContinuedTaskType {
	case time(seconds: Double)
	case timeOrFinished(seconds: Double)
}

#if os(iOS)
	@MainActor class BackgroundManager: ObservableObject {
		enum Errors: Error {
			case alreadyRunning
		}

		private static let watchdogNotificationID = "nl.t-shaped.sushitrain.watchdog-notification"

		// Time before the end of allotted background time to start ending the task to prevent forceful expiration by the OS
		private static let backgroundTimeReserve: TimeInterval = 5.6

		private var currentBackgroundTask: BGTask? = nil
		private var expireTimer: Timer? = nil
		private var isEndingBackgroundTask = false
		private var currentRun: BackgroundSyncRun? = nil
		fileprivate unowned var appState: AppState
		@Published private(set) var runningContinuedTask: ContinuedTaskType? = nil
		@Published private(set) var stopRunningContinuedTask = false

		// Using this to store background information instead of AppStorage because it comes with observers that seem to
		// trigger SwiftUI hangs when the app comes back to the foreground.
		var backgroundSyncRuns: [BackgroundSyncRun] {
			set(newValue) {
				let encoded = try! JSONEncoder().encode(newValue)
				UserDefaults.standard.setValue(encoded, forKey: "backgroundSyncRuns")
			}
			get {
				if let encoded = UserDefaults.standard.data(forKey: "backgroundSyncRuns") {
					if let runs = try? JSONDecoder().decode([BackgroundSyncRun].self, from: encoded) {
						return runs
					}
				}
				return []
			}
		}

		var lastBackgroundSyncRun: BackgroundSyncRun? {
			set(newValue) {
				let encoded = try! JSONEncoder().encode(newValue)
				UserDefaults.standard.setValue(encoded, forKey: "lastBackgroundSyncRun")
			}
			get {
				if let encoded = UserDefaults.standard.data(forKey: "lastBackgroundSyncRun") {
					return try! JSONDecoder().decode(BackgroundSyncRun.self, from: encoded)
				}
				return nil
			}
		}

		required init(appState: AppState) {
			self.appState = appState

			// Schedule background synchronization task
			// Must start on a specified queue (here we simply use main) to prevent a crash in dispatch_assert_queue
			BGTaskScheduler.shared.register(
				forTaskWithIdentifier: BackgroundTaskType.long.identifier, using: DispatchQueue.main,
				launchHandler: self.backgroundLaunchHandler)
			BGTaskScheduler.shared.register(
				forTaskWithIdentifier: BackgroundTaskType.short.identifier, using: DispatchQueue.main,
				launchHandler: self.backgroundLaunchHandler)

			if #available(iOS 26, *) {
				BGTaskScheduler.shared.register(
					forTaskWithIdentifier: BackgroundTaskType.continued.identifier, using: DispatchQueue.main,
					launchHandler: self.continuedBackgroundLaunchHandler)
				Log.info("Registered continued background task handler")
			}

			updateBackgroundRunHistory(appending: nil)
			_ = self.scheduleBackgroundSync()

			Task.detached {
				await self.rescheduleWatchdogNotification()
			}
		}

		@available(iOS 26, *) func startContinuedSync(_ type: ContinuedTaskType) throws {
			if self.runningContinuedTask != nil || self.currentBackgroundTask != nil {
				Log.warn("We're already running a continued task")
				throw Errors.alreadyRunning
			}
			self.runningContinuedTask = type

			do {
				let request = BGContinuedProcessingTaskRequest(
					identifier: BackgroundTaskType.continued.identifier,
					title: String(localized: "Synchronize files"),
					subtitle: String(localized: "About to start..."),
				)
				request.strategy = .fail
				Log.info("Scheduling continued background processing task \(request)")
				try BGTaskScheduler.shared.submit(request)
				Log.info("Scheduled continued background processing task")
			}
			catch {
				Log.warn("Failed to schedule continued background processing task: \(error.localizedDescription)")
				self.runningContinuedTask = nil
				throw error
			}
		}

		@available(iOS 26, *) func stopContinuedSync() {
			if self.runningContinuedTask != nil {
				self.stopRunningContinuedTask = true
			}
		}

		@available(iOS 26, *) private func continuedBackgroundLaunchHandler(_ task: BGTask) {
			guard let taskType = self.runningContinuedTask else {
				Log.warn("could not find task type")
				return
			}

			Log.info("Continued background task launched")
			guard let continuedTask = task as? BGContinuedProcessingTask else {
				Log.warn("received some other task than a continuous one for continuous processing")
				self.runningContinuedTask = nil
				task.setTaskCompleted(success: false)
				return
			}

			if self.currentBackgroundTask != nil {
				Log.warn("A background task is already running, not running additional one")
				self.runningContinuedTask = nil
				task.setTaskCompleted(success: false)
				return
			}

			Task {
				self.currentBackgroundTask = continuedTask
				var run = BackgroundSyncRun(started: Date.now, taskType: .continued)

				// Perform the requested continued task
				switch taskType {
				case .time(seconds: let duration), .timeOrFinished(seconds: let duration):
					let start = Date.now
					var stopWhenFinished = false
					if case .timeOrFinished(_) = taskType {
						stopWhenFinished = true
					}

					// When the system signals our task should end, ensure we end it
					var shouldContinue = true
					task.expirationHandler = {
						Log.info("Continued processing task expired")
						shouldContinue = false
					}

					do {
						while shouldContinue {
							// Stop the task if requested from inside the app (i.e. user pressed a button to cancel)
							if self.stopRunningContinuedTask {
								shouldContinue = false
								self.stopRunningContinuedTask = false
								break
							}

							// If we are finished syncing, and this is a 'until finished' task, end the task
							if stopWhenFinished && appState.isFinished {
								// Wait another second to see if we're still finished
								continuedTask.updateTitle(continuedTask.title, subtitle: String(localized: "Finishing up..."))
								try await Task.sleep(for: .seconds(1))
								if appState.isFinished {
									shouldContinue = false
									continuedTask.updateTitle(continuedTask.title, subtitle: String(localized: "Finished"))
									break
								}
							}

							// Update the task title and progress
							let remaining = Int64(duration - Date.now.timeIntervalSince(start))
							if remaining <= 0 {
								shouldContinue = false
								continuedTask.updateTitle(continuedTask.title, subtitle: String(localized: "Finished"))
							}
							else {
								// Determine subtitle
								let subtitle = self.localizedStatusText ?? String(localized: "\(remaining)s remaining...")
								continuedTask.progress.totalUnitCount = Int64(duration)
								continuedTask.progress.completedUnitCount = Int64(Date.now.timeIntervalSince(start))
								continuedTask.updateTitle(continuedTask.title, subtitle: subtitle)
								try await Task.sleep(for: .seconds(1))
							}
						}
					}
					catch {
						Log.warn("failed to sleep: \(error.localizedDescription)")
					}
				}

				// If we are now in the background, we need to sleep
				if UIApplication.shared.applicationState == .background {
					Log.info("We are backgrounded, so we're finally going to sleep")
					await appState.sleep()
				}
				task.setTaskCompleted(success: true)
				continuedTask.updateTitle(continuedTask.title, subtitle: String(localized: "Finished"))
				self.runningContinuedTask = nil
				self.currentBackgroundTask = nil
				run.ended = Date.now
				self.lastBackgroundSyncRun = run
				self.updateBackgroundRunHistory(appending: run)
				Log.info("Continued processing task done")
			}
		}

		private var localizedStatusText: String? {
			if appState.photoBackup.isBackingUp {
				return appState.photoBackup.progress.localizedDescription
			}
			else if appState.syncState.isDownloading && appState.syncState.isUploading {
				let upProgress = appState.client.getTotalUploadProgress()?.percentage ?? 0
				let downProgress = appState.client.getTotalDownloadProgress()?.percentage ?? 0
				let progress = Int((upProgress + downProgress) / 2.0 * 100.0)
				return String(localized: "Transferring files (\(progress)%)...")
			}
			else if appState.syncState.isUploading {
				if let progress = appState.client.getTotalUploadProgress() {
					return String(localized: "Sending files (\(Int(100 * progress.percentage))%")
				}
				else {
					return String(localized: "Sending files...")
				}
			}
			else if appState.syncState.isDownloading {
				if let progress = appState.client.getTotalDownloadProgress() {
					return String(localized: "Receiving files (\(Int(100 * progress.percentage))%")
				}
				else {
					return String(localized: "Receiving files...")
				}
			}
			return nil
		}

		private func backgroundLaunchHandler(_ task: BGTask) {
			Log.info("Background launch handler: \(task.identifier)")
			Task { @MainActor in
				await self.handleBackgroundSync(task: task)
			}
		}

		func inactivate() {
			if self.currentBackgroundTask == nil {
				Log.info(
					"Canceling photo back-up because we are moving to the inactive state, and we were not started from a background task."
				)
				self.appState.photoBackup.cancel()
			}
		}

		private func handleBackgroundSync(task: BGTask) async {
			guard let taskType = BackgroundTaskType(rawValue: task.identifier) else {
				Log.warn("invalid background task type identifier=\(task.identifier)")
				task.setTaskCompleted(success: false)
				return
			}

			if self.currentBackgroundTask != nil {
				Log.warn("A background task is already running, not running another")
				task.setTaskCompleted(success: false)
				return
			}

			let start = Date.now
			self.currentBackgroundTask = task
			Log.info("Start background task at \(start) \(task.identifier) type=\(taskType)")

			DispatchQueue.main.async {
				_ = self.scheduleBackgroundSync()
			}

			// Wait for app startup
			do {
				while appState.startupState != .started {
					if case .error(let msg) = appState.startupState {
						Log.info("Error in app startup: \(msg); exiting background task")
						await self.endBackgroundTask()
						return
					}

					let remaining = UIApplication.shared.backgroundTimeRemaining
					Log.info("Waiting for client startup... \(remaining) remaining")

					// iOS seems to start expiring us at 5 seconds before the end
					if remaining <= Self.backgroundTimeReserve {
						Log.info("End of our background stint is nearing, not waiting any longer")
						await self.endBackgroundTask()
						return
					}

					// Just give it some time
					try await Task.sleep(for: .milliseconds(100))
				}
			}
			catch {
				Log.warn("Caught error while waiting for client startup: \(error.localizedDescription), ending background task")
				await self.endBackgroundTask()
				return
			}

			// Perform database maintenance, if necessary
			if self.appState.maintenanceManager.isDatabaseMaintenanceRequired(warning: false) {
				do {
					try await self.appState.maintenanceManager.performDatabaseMaintenance()
				}
				catch {
					Log.warn("Database maintenance failed: \(error)")
				}
			}

			// Feed the watchdog
			Log.info("Rescheduling watchdog")
			await self.rescheduleWatchdogNotification()

			// Start photo back-up if the user has enabled it
			var photoBackupTask: Task<(), Error>? = nil
			if self.appState.photoBackup.enableBackgroundCopy && taskType == .long {
				Log.info("Start photo backup task")
				photoBackupTask = self.appState.photoBackup.backup(appState: self.appState, fullExport: false, isInBackground: true)
			}

			// Start background sync on long and short sync task (if enabled) and continued task
			if (taskType == .long && appState.userSettings.longBackgroundSyncEnabled)
				|| (taskType == .short && appState.userSettings.shortBackgroundSyncEnabled) || taskType == .continued
			{
				Log.info(
					"Start background sync, time remaining = \(UIApplication.shared.backgroundTimeRemaining)"
				)
				await self.appState.suspend(false)
				currentRun = BackgroundSyncRun(started: start, ended: nil, taskType: taskType)
				self.lastBackgroundSyncRun = currentRun
				if #available(iOS 26, *) {
					if let cg = task as? BGContinuedProcessingTask {
						cg.updateTitle(cg.title, subtitle: "Synchronizing...")
					}
				}

				expireTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
					Task { @MainActor in
						let remaining = UIApplication.shared.backgroundTimeRemaining
						Log.info("Check background time remaining: \(remaining)")
						// iOS seems to start expiring us at 5 seconds before the end
						if remaining <= Self.backgroundTimeReserve {
							Log.info("End of our background stint is nearing")
							await self.endBackgroundTask()
						}
					}
				}

				// Run to expiration
				task.expirationHandler = {
					Log.warn("Task expiration handler called identifier=\(task.identifier)")
					Task { @MainActor in
						Log.warn(
							"Background task expired (this should not happen because our timer should have expired the task first; perhaps iOS changed its mind?) Remaining = \(UIApplication.shared.backgroundTimeRemaining)"
						)
						await self.endBackgroundTask()
					}
				}
			}
			else {
				// We're just doing some photo backupping this time
				if taskType == .long {
					// When background task expires, end photo back-up
					task.expirationHandler = {
						Log.warn(
							"Photo backup task expiry with \(UIApplication.shared.backgroundTimeRemaining) remaining."
						)
						self.appState.photoBackup.cancel()
					}

					expireTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
						DispatchQueue.main.async {
							let remaining = UIApplication.shared.backgroundTimeRemaining
							Log.info(
								"Check background time remaining (photo backup): \(remaining)"
							)

							// iOS seems to start expiring us at 5 seconds before the end
							if remaining <= Self.backgroundTimeReserve {
								Log.info(
									"End of our background stint is nearing (photo backup)"
								)
								self.appState.photoBackup.cancel()
							}
						}
					}

					// Wait for photo backup to finish
					try? await photoBackupTask?.value
					Log.info("Photo backup ended gracefully")
					task.setTaskCompleted(success: true)
					self.expireTimer?.invalidate()
					self.expireTimer = nil
					self.currentBackgroundTask = nil
					Log.info("Photo backup task ended gracefully")
				}
				else {
					// Do not do any photo backup on short background refresh
					Log.info("Photo backup not started on short background refresh")
					task.setTaskCompleted(success: true)
					self.currentBackgroundTask = nil
				}
			}
		}

		private func endBackgroundTask() async {
			Log.info(
				"endBackgroundTask: expireTimer=\(expireTimer != nil), run = \(currentRun != nil) task = \(currentBackgroundTask != nil), isEndingBackgroundTask = \(isEndingBackgroundTask)"
			)
			expireTimer?.invalidate()
			expireTimer = nil

			if var run = currentRun, let task = currentBackgroundTask, !isEndingBackgroundTask {
				self.isEndingBackgroundTask = true
				run.ended = Date.now

				Log.info("Background sync stopped at \(run.ended!.debugDescription)")
				self.appState.photoBackup.cancel()

				Log.info("Suspending peers")
				await self.appState.suspend(true)

				Log.info("Setting task completed")
				task.setTaskCompleted(success: true)

				Log.info("Doing background task bookkeeping")
				self.lastBackgroundSyncRun = run
				self.updateBackgroundRunHistory(appending: run)

				Log.info("Notify user of background sync completion")
				self.notifyUserOfBackgroundSyncCompletion(start: run.started, end: run.ended!)

				Log.info("Final cleanup")
				self.isEndingBackgroundTask = false
				self.currentBackgroundTask = nil
				self.currentRun = nil
			}
		}

		private func notifyUserOfBackgroundSyncCompletion(start: Date, end: Date) {
			if self.appState.userSettings.notifyWhenBackgroundSyncCompletes {
				let duration = Int(end.timeIntervalSince(start))
				let content = UNMutableNotificationContent()
				content.title = String(localized: "Background synchronization completed")
				content.body = String(
					localized: "Background synchronization ran for \(duration) seconds")
				content.interruptionLevel = .passive
				content.sound = .none
				let uuidString = UUID().uuidString
				let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
				let request = UNNotificationRequest(
					identifier: uuidString, content: content, trigger: trigger)
				let notificationCenter = UNUserNotificationCenter.current()
				notificationCenter.add(request)
			}
		}

		func scheduleBackgroundSync() -> Bool {
			var success = true

			if appState.userSettings.longBackgroundSyncEnabled {
				let longRequest = BGProcessingTaskRequest(identifier: BackgroundTaskType.long.identifier)

				// No earlier than within 15 minutes
				longRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
				longRequest.requiresExternalPower = true
				longRequest.requiresNetworkConnectivity = true
				Log.info(
					"Scheduling next long background sync for (no later than) \(longRequest.earliestBeginDate!)"
				)

				do {
					try BGTaskScheduler.shared.submit(longRequest)
				}
				catch {
					Log.warn("Could not schedule background sync: \(error)")
					success = false
				}
			}

			if appState.userSettings.shortBackgroundSyncEnabled {
				let shortRequest = BGAppRefreshTaskRequest(identifier: BackgroundTaskType.short.identifier)
				// No earlier than within 15 minutes
				shortRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
				Log.info(
					"Scheduling next short background sync for (no later than) \(shortRequest.earliestBeginDate!))"
				)
				do {
					try BGTaskScheduler.shared.submit(shortRequest)
				}
				catch {
					Log.warn("Could not schedule short background sync: \(error)")
					success = false
				}
			}

			return success
		}

		@MainActor
		func rescheduleWatchdogNotification() async {
			Log.info("Re-schedule watchdog notification")
			let notificationCenter = UNUserNotificationCenter.current()
			UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
				Self.watchdogNotificationID
			])

			let appState = self.appState
			var interval: TimeInterval = TimeInterval(appState.userSettings.watchdogIntervalHours * 60 * 60)  // seconds
			if interval < 60.0 {
				interval = 60.0 * 60.0  // one hour minimum
			}

			if appState.userSettings.watchdogNotificationEnabled {
				let settings = await notificationCenter.notificationSettings()

				let status = settings.authorizationStatus
				if status == .authorized || status == .provisional {
					let content = UNMutableNotificationContent()
					content.title = String(localized: "Synchronisation did not run")
					content.body = String(
						localized:
							"Background synchronization last ran more than \(Int(interval / 3600)) hours ago. Open the app to synchronize."
					)
					content.interruptionLevel = .passive
					content.sound = .none
					content.badge = 1
					let trigger = UNTimeIntervalNotificationTrigger(
						timeInterval: interval, repeats: true)
					let request = UNNotificationRequest(
						identifier: Self.watchdogNotificationID, content: content,
						trigger: trigger)
					do {
						try await notificationCenter.add(request)
						Log.info("Watchdog notification added")
					}
					catch {
						Log.warn("Could not add watchdog notification: \(error.localizedDescription)")
					}
				}
				else {
					Log.warn("Watchdog not enabled or denied, not reinstalling")
				}
			}
		}

		private func updateBackgroundRunHistory(appending run: BackgroundSyncRun?) {
			var runs = self.backgroundSyncRuns

			// Remove old runs (older than 24h)
			let now = Date.now
			runs.removeAll(where: { r in
				return now.timeIntervalSince(r.started) > (24 * 60 * 60)
			})

			// Append our run
			if let run = run {
				runs.append(run)
			}
			self.backgroundSyncRuns = runs
		}
	}
#endif
