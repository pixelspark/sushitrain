// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import Photos

struct PhotoBackupProgressView: View {
	@ObservedObject var photoBackup: PhotoBackup

	var body: some View {
		let progress = photoBackup.progress
		ProgressView(value: progress.stepProgress, total: 1.0) {
			Label(progress.localizedDescription, systemImage: "photo.badge.arrow.down.fill")
				.foregroundStyle(.orange)
				.badge(Text(progress.badgeText))
		}.tint(.orange)
	}
}

struct PhotoBackupButton: View {
	@Environment(AppState.self) private var appState
	@ObservedObject var photoBackup: PhotoBackup

	var body: some View {
		if case .finished(error: let e) = photoBackup.progress, let e = e {
			Text(e).foregroundStyle(.red)
		}

		if photoBackup.isSynchronizing {
			PhotoBackupProgressView(photoBackup: photoBackup)

			Button("Cancel") {
				photoBackup.cancel()
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif
		}
		else {
			Button("Back-up new photos", systemImage: "photo.badge.arrow.down.fill") {
				photoBackup.backup(appState: self.appState, fullExport: false, isInBackground: false)
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif
			.disabled(photoBackup.isSynchronizing || !photoBackup.isReady)
		}
	}
}

struct PhotoBackupSettingsView: View {
	@Environment(AppState.self) private var appState
	@State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
	@State private var albumPickerShown = false
	@ObservedObject var photoBackup: PhotoBackup
	@State private var folders: [SushitrainFolder] = []

	var body: some View {
		let albums = self.authorizationStatus == .authorized ? self.loadAlbums() : []

		Form {
			Section {
				if authorizationStatus == .authorized {
					Picker("From album", selection: $photoBackup.selectedAlbumID) {
						Text("None").tag("")
						ForEach(albums, id: \.localIdentifier) { album in
							Text(album.localizedTitle ?? "Unknown album").tag(
								album.localIdentifier)
						}
					}
					.pickerStyle(.menu).disabled(photoBackup.isSynchronizing)
				}
				else if authorizationStatus == .denied || authorizationStatus == .restricted {
					Text("Synctrain cannot access your photo library right now")
					#if os(iOS)
						Button("Review permissions in the Settings app") {
							openAppSettings()
						}
					#endif
				}
				else {
					Text("Synctrain cannot access your photo library right now")
					Button("Allow Synctrain to access photos") {
						PHPhotoLibrary.requestAuthorization { status in
							DispatchQueue.main.async {
								authorizationStatus = status
							}
						}
					}
				}

				if authorizationStatus == .authorized {
					Picker("To folder", selection: $photoBackup.selectedFolderID) {
						Text("(No folder selected)").tag("")
						ForEach(folders, id: \.self.folderID) { option in
							Text(option.displayName).tag(option.folderID)
						}
					}
					.pickerStyle(.menu).disabled(
						photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)
				}
			} header: {
				Text("Copy photos")
			} footer: {
				if photoBackup.isReady {
					Text(
						"Photos from the selected album will be saved in the selected folder, in sub folders by creation date. If a photo with the same file name already exists in the folder, or has been deleted from the folder before, it will not be saved again."
					)
				}
			}

			#if os(iOS)
				Section {
					Toggle(
						"Copy photos periodically in the background",
						isOn: photoBackup.$enableBackgroundCopy
					).disabled(photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)
				}
			#endif

			Section("Save the following media types") {
				Toggle(
					"Photos",
					isOn: Binding(
						get: { photoBackup.categories.contains(.photo) },
						set: { s in
							photoBackup.categories.toggle(.photo, s)
						})
				).disabled(photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)
				Toggle(
					"Live photos",
					isOn: Binding(
						get: { photoBackup.categories.contains(.livePhoto) },
						set: { s in
							photoBackup.categories.toggle(.livePhoto, s)
						})
				).disabled(photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)
				Toggle(
					"Videos",
					isOn: Binding(
						get: { photoBackup.categories.contains(.video) },
						set: { s in
							photoBackup.categories.toggle(.video, s)
						})
				).disabled(photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)
			}

			Section {
				LabeledContent {
					TextField("", text: photoBackup.$subDirectoryPath, prompt: Text("(Top level)"))
						.multilineTextAlignment(.trailing)
						#if os(iOS)
							.keyboardType(.asciiCapable)
							.autocorrectionDisabled()
							.autocapitalization(.none)
						#endif
				} label: {
					Text("Path in folder")
				}

				PhotoFolderStructureView(folderStructure: photoBackup.$folderStructure)
					.disabled(photoBackup.isSynchronizing)

				Text("Example file location in folder: ")
					+ Text("\(photoBackup.subDirectoryPath)/\(photoBackup.folderStructure.examplePath)")
					.monospaced()

			} footer: {
				Text(
					"When the folder structure is changed, photos that were already saved will be saved again in their new location."
				)
			}

			if photoBackup.folderStructure.usesTimeZone {
				Section {
					PhotoBackupTimeZoneView(timeZone: photoBackup.$timeZone)
						.disabled(photoBackup.isSynchronizing)
				} footer: {
					PhotoBackupTimeZoneExplainerView(timeZone: photoBackup.timeZone)
				}
			}

			Section {
				Picker("Add to album", selection: $photoBackup.savedAlbumID) {
					Text("None").tag("")
					ForEach(albums, id: \.localIdentifier) { album in
						Text(album.localizedTitle ?? "Unknown album").tag(album.localIdentifier)
					}
				}
				.pickerStyle(.menu)
				.disabled(
					photoBackup.isSynchronizing || self.authorizationStatus != .authorized
						|| photoBackup.selectedAlbumID.isEmpty)
			} header: {
				Text("After saving")
			} footer: {
				if photoBackup.purgeEnabled && photoBackup.purgeAfterDays <= 0 {
					Text(
						"Because of the setting below to immediately delete photos after saving, newly saved photos will not be added to this album."
					)
				}
			}

			Section {
				Toggle("Remove saved photos from source", isOn: photoBackup.$purgeEnabled)
				if photoBackup.purgeEnabled {
					Stepper(
						photoBackup.purgeAfterDays <= 0
							? "Immediately" : "After \(photoBackup.purgeAfterDays) days",
						value: photoBackup.$purgeAfterDays, in: 0...30)
				}
			} footer: {
				#if os(iOS)
					if photoBackup.purgeEnabled && photoBackup.enableBackgroundCopy {
						Text(
							"Photos will only be removed when photo back-up is started manually from inside the app, because a permission screen will be shown before the app is able to remove photos."
						)
					}
				#endif
			}.disabled(photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)

			Section {
				Toggle(
					"Do not save photos older than six months",
					isOn: Binding(
						get: {
							photoBackup.maxAgeDays > 0
						},
						set: {
							photoBackup.maxAgeDays = $0 ? 180 : 0
						}))
			} footer: {
				Text(
					"If you delete photos from the folder, this will be remembered for six months, so they will not be saved to the folder again during this time. Enable this setting to prevent these photos from being exported again after six months."
				)
			}.disabled(photoBackup.isSynchronizing || photoBackup.selectedAlbumID.isEmpty)

			Section {
				PhotoBackupButton(photoBackup: photoBackup)
			} footer: {
				Text("Saves photos in the album that have not been copied before to the folder.")
			}

			Section {
				Button("Re-copy all photos", systemImage: "photo.badge.arrow.down.fill") {
					photoBackup.backup(appState: self.appState, fullExport: true, isInBackground: false)
				}
				.disabled(photoBackup.isSynchronizing || !photoBackup.isReady)
				#if os(macOS)
					.buttonStyle(.link)
				#endif
			} footer: {
				Text(
					"Saves all photos in the album to the folder, even if the photo was saved to the folder before. This will overwrite any modifications made to the photo file in the folder."
				)
			}

			if photoBackup.lastCompletedDate > 0.0 {
				let lastDate = Date(timeIntervalSinceReferenceDate: photoBackup.lastCompletedDate)
				Section {
					Text("Last completed").badge(
						lastDate.formatted(date: .abbreviated, time: .shortened))
				}
			}
		}
		.navigationTitle("Photos synchronization")
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		#if os(iOS)
			.navigationBarTitleDisplayMode(.inline)
		#endif
		.task {
			authorizationStatus = PHPhotoLibrary.authorizationStatus()
			self.folders = await appState.folders().filter({ $0.isSuitablePhotoBackupDestination }).sorted()
		}
	}

	func loadAlbums() -> [PHAssetCollection] {
		var albums: [PHAssetCollection] = []
		let options = PHFetchOptions()
		options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
		let userAlbums = PHAssetCollection.fetchAssetCollections(
			with: .album, subtype: .albumRegular, options: options)
		userAlbums.enumerateObjects { (collection, _, _) in
			albums.append(collection)
		}

		// Fetch system albums, including 'Recents'
		let systemAlbumsOptions = PHFetchOptions()
		let systemAlbums = PHAssetCollection.fetchAssetCollections(
			with: .smartAlbum, subtype: .any, options: systemAlbumsOptions)
		systemAlbums.enumerateObjects { (collection, _, _) in
			albums.append(collection)
		}
		return albums
	}

	#if os(iOS)
		func openAppSettings() {
			guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
				return
			}

			if UIApplication.shared.canOpenURL(settingsUrl) {
				UIApplication.shared.open(settingsUrl)
			}
		}
	#endif
}

struct PhotoFolderStructureView: View {
	@Binding var folderStructure: PhotoBackupFolderStructure

	var body: some View {
		Picker("Folder structure", selection: $folderStructure) {
			Text("Single folder").tag(PhotoBackupFolderStructure.singleFolder)
			Text("Single folder (date in file name)").tag(
				PhotoBackupFolderStructure.singleFolderDatePrefixed)
			Divider()

			Text("Type").tag(PhotoBackupFolderStructure.byType)
			Text("Date").tag(PhotoBackupFolderStructure.byDate)
			Text("Date/Type").tag(PhotoBackupFolderStructure.byDateAndType)
			Divider()

			Text("Year").tag(PhotoBackupFolderStructure.byYear)
			Text("Year/Type").tag(PhotoBackupFolderStructure.byYearAndType)
			Text("Year/Month").tag(PhotoBackupFolderStructure.byYearMonth)
			Text("Year/Month/Type").tag(PhotoBackupFolderStructure.byYearMonthAndType)
			Text("Year/Month/Day").tag(PhotoBackupFolderStructure.byDateComponent)
			Text("Year/Month/Day/Type").tag(PhotoBackupFolderStructure.byDateComponentAndType)
		}
		.pickerStyle(.menu)
	}
}

struct PhotoBackupTimeZoneView: View {
	@Binding var timeZone: PhotoBackupTimeZone
	@State var localTimeZone = TimeZone.current

	var body: some View {
		Picker("Use time zone", selection: $timeZone) {
			Text("Current").tag(PhotoBackupTimeZone.current)
			Text("GMT").tag(PhotoBackupTimeZone.specific(timeZone: TimeZone.gmt.identifier))
			Text(localTimeZone.description).tag(PhotoBackupTimeZone.specific(timeZone: localTimeZone.identifier))
		}
		.pickerStyle(.menu)
	}
}

struct PhotoBackupTimeZoneExplainerView: View {
	let timeZone: PhotoBackupTimeZone

	var body: some View {
		switch timeZone {
		case .specific(timeZone: let tz):
			Text(
				"The dates in the file names/paths will always be in the '\(tz)' timezone. If a photo was taken in a different time zone and close to midnight, the day may differ. Changing this setting may cause photos to be saved once again."
			)
		case .current:
			Text(
				"The dates in the file names/paths will be in the configured time zone of your device at the time the back-up is made. This may cause items to be exported more than once when you move between time zones. Changing this setting may cause photos to be saved once again."
			)
		}
	}
}
