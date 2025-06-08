// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import Photos
@preconcurrency import SushitrainCore

struct PhotoFolderSettingsView: View {
	let folder: SushitrainFolder
	@State private var config: PhotoFSConfiguration = PhotoFSConfiguration()

	var body: some View {
		PhotoFolderConfigurationView(config: $config)
			.task {
				await self.update()
			}
			.onChange(of: config) { _, _ in
				Task {
					await self.save()
				}
			}
	}

	private func save() async {
		do {
			let serialized = try JSONEncoder().encode(self.config)
			try self.folder.setPath(String(data: serialized, encoding: .utf8))
		}
		catch {
			Log.info("Error saving album config: \(error.localizedDescription)")
		}
	}

	private func update() async {
		do {
			let path: String = self.folder.path()
			if let d = path.data(using: .utf8) {
				self.config = try JSONDecoder().decode(PhotoFSConfiguration.self, from: d)
			}
			else {
				self.config = PhotoFSConfiguration()
			}
		}
		catch {
			self.config = PhotoFSConfiguration()
		}
	}
}

struct PhotoFolderConfigurationView: View {
	@Binding var config: PhotoFSConfiguration

	@State private var editingAlbumConfig = PhotoFSAlbumConfiguration()
	@State private var addingNewAlbum = false
	@State private var editingAlbum = false
	@State private var editingDirName = ""
	@State private var editingOldDirName = ""

	var body: some View {
		Section("Albums") {
			List {
				let folderPairs = Array(config.folders)
				ForEach(folderPairs, id: \.key) { folderName, albumConfig in
					Label(folderName, systemImage: "folder.fill").onTapGesture {
						editingAlbumConfig = albumConfig
						editingOldDirName = folderName
						editingDirName = folderName
						editingAlbum = true
					}
				}
				.onDelete { idxs in
					Task {
						for idx in idxs {
							let albumName = folderPairs[idx].key
							self.config.folders.removeValue(forKey: albumName)
						}
					}
				}
				.sheet(isPresented: $editingAlbum) {
					NavigationStack {
						PhotoFolderAlbumSettingsView(config: $editingAlbumConfig, dirName: $editingDirName)
							#if os(iOS)
								.navigationBarTitleDisplayMode(.inline)
							#endif
							.toolbar {
								ToolbarItem(
									placement: .confirmationAction,
									content: {
										Button("Save") {
											if editingAlbumConfig.isValid {
												self.edit()
											}
										}
									})
							}
					}
				}.interactiveDismissDisabled()

				Button("Add album...", systemImage: "plus") {
					editingAlbumConfig = PhotoFSAlbumConfiguration()
					addingNewAlbum = true
					editingDirName = ""
				}
				#if os(macOS)
					.buttonStyle(.link)
				#endif
				.sheet(isPresented: $addingNewAlbum) {
					NavigationStack {
						PhotoFolderAlbumSettingsView(config: $editingAlbumConfig, dirName: $editingDirName)
							.navigationTitle("Add album")
							#if os(iOS)
								.navigationBarTitleDisplayMode(.inline)
							#endif
							.toolbar {
								ToolbarItem(
									placement: .confirmationAction,
									content: {
										Button("Add") {
											self.add()
										}.disabled(editingDirName.isEmpty || !editingAlbumConfig.isValid)
									})
							}
					}
				}
			}
		}
	}

	private func edit() {
		Task {
			let newName =
				editingDirName.isEmpty
				? (self.editingOldDirName.isEmpty ? self.editingAlbumConfig.albumID : editingOldDirName) : editingDirName
			self.config.folders.removeValue(forKey: self.editingOldDirName)
			self.config.folders[newName] = self.editingAlbumConfig
			editingAlbum = false
			editingOldDirName = ""
			editingDirName = ""
		}
	}

	private func add() {
		Task {
			let newName = editingDirName.isEmpty ? self.editingAlbumConfig.albumID : editingDirName
			self.config.folders[newName] = self.editingAlbumConfig
			addingNewAlbum = false
		}
	}
}

private struct PhotoFolderAlbumSettingsView: View {
	@Binding var config: PhotoFSAlbumConfiguration
	@Binding var dirName: String

	@EnvironmentObject var appState: AppState
	@State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
	@State private var albumPickerShown = false

	var body: some View {
		let albums = self.authorizationStatus == .authorized ? self.loadAlbums() : []

		Form {
			Section {
				if authorizationStatus == .authorized {
					Picker("From album", selection: $config.albumID) {
						Text("None").tag("")
						ForEach(albums, id: \.localIdentifier) { album in
							Text(album.localizedTitle ?? "Unknown album").tag(album.localIdentifier)
						}
					}
					.pickerStyle(.menu)
					.onChange(of: config.albumID) { _, newValue in
						// Set directory name to album name in case no directory name was entered yet
						if self.dirName.isEmpty {
							// Find album name
							if let albumInfo = albums.first(where: { $0.localIdentifier == newValue }) {
								self.dirName = albumInfo.localizedTitle ?? self.dirName
							}
						}
					}
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
			}

			Section {
				LabeledContent {
					TextField("", text: $dirName).monospaced().multilineTextAlignment(.trailing)
				} label: {
					Text("To subdirectory")
				}
				
				PhotoFolderStructureView(folderStructure: Binding(get: {
					self.config.folderStructure ?? PhotoBackupFolderStructure.singleFolder
				}, set: {
					self.config.folderStructure = $0
				}))
				
				Text("Example file location in folder: ")
				+ Text("\(dirName)/\((self.config.folderStructure ?? PhotoBackupFolderStructure.singleFolder).examplePath)")
					.monospaced()
			}
		}
		#if os(macOS)
			.formStyle(.grouped)
		#endif
		.task {
			authorizationStatus = PHPhotoLibrary.authorizationStatus()
		}
		.navigationTitle(dirName.isEmpty ? "Add album" : "Settings for '\(dirName)'")
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
