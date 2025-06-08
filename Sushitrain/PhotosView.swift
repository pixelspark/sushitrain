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
	@EnvironmentObject var appState: AppState
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
				photoBackup.synchronize(appState: self.appState, fullExport: false, isInBackground: false)
			}
			#if os(macOS)
				.buttonStyle(.link)
			#endif
			.disabled(photoBackup.isSynchronizing || !photoBackup.isReady)
		}
	}
}

struct PhotoSettingsView: View {
	@EnvironmentObject var appState: AppState
	@State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
	@State private var albumPickerShown = false
	@ObservedObject var photoBackup: PhotoBackup

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
						ForEach(appState.folders().sorted(), id: \.self.folderID) { option in
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
				PhotoBackupButton(photoBackup: photoBackup)
			} footer: {
				Text("Saves photos in the album that have not been copied before to the folder.")
			}

			Section {
				Button("Re-copy all photos", systemImage: "photo.badge.arrow.down.fill") {
					photoBackup.synchronize(appState: self.appState, fullExport: true, isInBackground: false)
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
			Text("By date").tag(PhotoBackupFolderStructure.byDate)
			Text("By date (tree)").tag(PhotoBackupFolderStructure.byDateComponent)
			Text("By type").tag(PhotoBackupFolderStructure.byType)
			Text("By date (tree) and type").tag(PhotoBackupFolderStructure.byDateComponentAndType)
			Text("By date and type").tag(PhotoBackupFolderStructure.byDateAndType)
			Text("Single folder").tag(PhotoBackupFolderStructure.singleFolder)
			Text("Single folder with dates").tag(
				PhotoBackupFolderStructure.singleFolderDatePrefixed)
		}
		.pickerStyle(.menu)
	}
}
