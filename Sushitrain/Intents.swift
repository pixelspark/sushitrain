// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
@preconcurrency import AppIntents
@preconcurrency import SushitrainCore
import UniformTypeIdentifiers

struct SynchronizePhotosIntent: AppIntent {
	static let title: LocalizedStringResource = "Back-up new photos"

	@Dependency private var appState: AppState

	func perform() async throws -> some IntentResult {
		await appState.photoBackup.backup(appState: appState, fullExport: false, isInBackground: true)
		return .result()
	}
}

struct SynchronizeIntent: AppIntent {
	static let title: LocalizedStringResource = "Synchronize for a while"

	@Dependency private var appState: AppState

	@Parameter(
		title: "Time (seconds)", description: "How much time to allow for synchronization.", default: 10,
		controlStyle: .field, inclusiveRange: (0, 15))
	var time: Int

	@MainActor
	func perform() async throws -> some IntentResult {
		if self.time > 0 {
			appState.awake()
			defer {
				appState.sleep()
			}
			try await Task.sleep(for: .seconds(self.time))
		}
		return .result()
	}
}

enum FileEntityQueryPredicate {
	case fileNameContains(String)
	case folderEquals(FolderEntity)
	case pathPrefix(String)
}

struct FileEntityQuery: EntityQuery, EntityPropertyQuery {
	static let sortingOptions = SortingOptions {
		SortableBy(\FileEntity.$name)
	}

	static let properties = QueryProperties {
		Property(\.$name) {
			ContainsComparator { FileEntityQueryPredicate.fileNameContains($0) }
		}
		Property(\.$folder) {
			EqualToComparator { FileEntityQueryPredicate.folderEquals($0) }
		}
		Property(\.$pathInFolder) {
			HasPrefixComparator { FileEntityQueryPredicate.pathPrefix($0) }
		}
	}

	@Dependency private var appState: AppState

	private class ResultsCollector: NSObject, SushitrainSearchResultDelegateProtocol {
		var results: [SushitrainEntry] = []

		func result(_ entry: SushitrainEntry?) {
			if let r = entry {
				results.append(r)
			}
		}

		func isCancelled() -> Bool {
			return false
		}
	}

	private enum FileEntityQueryError: LocalizedError {
		case modeNotSupported
		case queryNotSupported

		var errorDescription: String? {
			switch self {
			case .modeNotSupported:
				return String(
					localized:
						"Currently searching using multiple criteria is not supported, unless all criteria are required."
				)
			case .queryNotSupported:
				return String(
					localized:
						"Searching using multiple criteria for the same property of a file is currently not supported."
				)
			}
		}
	}

	func entities(
		matching comparators: [FileEntityQueryPredicate],
		mode: ComparatorMode,
		sortedBy: [Sort<FileEntity>],
		limit: Int?
	) async throws -> [FileEntity] {
		var searchTerm: String? = nil
		var folder: SushitrainFolder? = nil
		var prefix: String? = nil

		if mode != .and {
			throw FileEntityQueryError.modeNotSupported
		}

		// Map query to search parameters
		for c in comparators {
			switch c {
			case .fileNameContains(let s):
				if searchTerm != nil {
					throw FileEntityQueryError.queryNotSupported
				}
				searchTerm = s
			case .folderEquals(let f):
				if folder != nil {
					throw FileEntityQueryError.queryNotSupported
				}
				folder = f.folder
			case .pathPrefix(let p):
				if prefix != nil {
					throw FileEntityQueryError.queryNotSupported
				}
				prefix = p
			}
		}

		// Perform search
		let client = await appState.client
		let results = ResultsCollector()
		try client.search(
			searchTerm, delegate: results, maxResults: limit ?? -1, folderID: folder?.folderID,
			prefix: prefix)

		// Sort results
		results.results.sort(by: { (a, b) in
			for s in sortedBy {
				switch s.by {
				case \FileEntity.name:
					switch s.order {
					case .ascending: return a.name() < b.name()
					case .descending: return a.name() > b.name()
					}
				default:
					break
				}
			}
			return true
		})

		return results.results.map { FileEntity(file: $0) }
	}

	func entities(for identifiers: [DeviceEntity.ID]) async throws -> [FileEntity] {
		let client = await appState.client
		return identifiers.compactMap { urlString in
			if let url = URLComponents(string: urlString) {
				if let folder = client.folder(withID: url.host), folder.exists() {
					if let file = try? folder.getFileInformation(url.path), !file.isDeleted() {
						return FileEntity(file: file)
					}
				}
			}
			return nil
		}
	}

	func suggestedEntities() async throws -> [FileEntityQuery] {
		return []
	}
}

struct FileEntity: AppEntity {
	typealias DefaultQuery = FileEntityQuery
	static let defaultQuery = FileEntityQuery()

	var file: SushitrainEntry

	init(file: SushitrainEntry) {
		self.file = file
		self.name = file.fileName()
		self.pathInFolder = file.path()
		self.isSymlink = file.isSymlink()
		self.folder = FolderEntity(folder: file.folder!)

		if let fu = self.file.localNativeFileURL {
			self.localFile = IntentFile(fileURL: fu)
		}
	}

	@Property(title: "Name")
	var name: String

	@Property(title: "Folder")
	var folder: FolderEntity

	@Property(title: "Path in folder")
	var pathInFolder: String

	@Property(title: "Is directory")
	var isDirectory: Bool

	@Property(title: "Is symlink")
	var isSymlink: Bool

	@Property(title: "File on this device")
	var localFile: IntentFile?

	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		TypeDisplayRepresentation(
			name: LocalizedStringResource("File/folder")
		)
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(
			title: "\(self.name)", subtitle: "\(self.pathInFolder)",
			image: DisplayRepresentation.Image(systemName: self.file.systemImage))
	}

	// stfile://folderID/foo/bar/file.txt
	var id: String {
		var uc = URLComponents()
		uc.scheme = "stfile"
		uc.host = self.folder.id
		uc.path = "/" + self.file.path()
		return uc.url!.absoluteString
	}
}

struct DeviceEntity: AppEntity {
	static let defaultQuery = DeviceEntityQuery()
	typealias DefaultQuery = DeviceEntityQuery

	var peer: SushitrainPeer

	@Property(title: "Name")
	var name: String

	@Property(title: "Device ID")
	var deviceID: String

	@Property(title: "Last seen")
	var lastSeen: Date?

	@Property(title: "Enabled")
	var enabled: Bool

	@Property(title: "Is untrusted")
	var isUntrusted: Bool

	init(peer: SushitrainPeer) {
		self.peer = peer
		self.name = peer.displayName
		self.deviceID = peer.deviceID()
		self.lastSeen = peer.lastSeen()?.date() ?? nil
		self.enabled = !peer.isPaused()
		self.isUntrusted = peer.isUntrusted()
	}

	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		TypeDisplayRepresentation(
			name: LocalizedStringResource("Device")
		)
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(
			title: "\(self.name)", subtitle: "\(self.deviceID)",
			image: DisplayRepresentation.Image(systemName: "externaldrive.fill"))
	}

	var id: String {
		return self.peer.id
	}
}

struct FolderEntity: AppEntity, Equatable {
	static let defaultQuery = FolderEntityQuery()

	typealias DefaultQuery = FolderEntityQuery

	init(folder: SushitrainFolder) {
		self.folder = folder
		self.name = folder.displayName
		self.url = folder.localNativeURL
	}

	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		TypeDisplayRepresentation(
			name: LocalizedStringResource("Folder")
		)
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(
			title: "\(self.name)", subtitle: "\(self.folder.folderID)",
			image: DisplayRepresentation.Image(systemName: "folder.fill"))
	}

	var folder: SushitrainFolder

	var id: String {
		return self.folder.folderID
	}

	static func == (lhs: FolderEntity, rhs: FolderEntity) -> Bool {
		return lhs.id == rhs.id
	}

	@Property(title: "Name")
	var name: String

	@Property(title: "URL")
	var url: URL?
}

struct FolderEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
	func allEntities() async throws -> [FolderEntity] {
		return await appState.folders().map {
			FolderEntity(folder: $0)
		}
	}

	@Dependency private var appState: AppState

	func entities(for identifiers: [FolderEntity.ID]) async throws -> [FolderEntity] {
		return await appState.folders().filter { identifiers.contains($0.folderID) }.map {
			FolderEntity(folder: $0)
		}
	}

	func suggestedEntities() async throws -> [FolderEntity] {
		return await appState.folders().map {
			FolderEntity(folder: $0)
		}
	}

	func entities(matching string: String) async throws -> [FolderEntity] {
		return await appState.folders().filter { $0.displayName.contains(string) }.map {
			FolderEntity(folder: $0)
		}
	}
}

struct DeviceEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
	func allEntities() async throws -> [DeviceEntity] {
		return await appState.peers().filter { !$0.isSelf() }.map {
			DeviceEntity(peer: $0)
		}
	}

	@Dependency private var appState: AppState

	func entities(for identifiers: [DeviceEntity.ID]) async throws -> [DeviceEntity] {
		return await appState.peers().filter { !$0.isSelf() && identifiers.contains($0.id) }.map {
			DeviceEntity(peer: $0)
		}
	}

	func suggestedEntities() async throws -> [DeviceEntity] {
		return await appState.peers().filter { !$0.isSelf() }.map {
			DeviceEntity(peer: $0)
		}
	}

	func entities(matching string: String) async throws -> [DeviceEntity] {
		return await appState.peers().filter { !$0.isSelf() && $0.displayName.contains(string) }.map {
			DeviceEntity(peer: $0)
		}
	}
}

struct GetExtraneousFilesIntent: AppIntent {
	static let title: LocalizedStringResource = "Get new, unsynchronized files in folder"

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "The folder to list files in")
	var folderEntity: FolderEntity

	@MainActor
	func perform() async throws -> some ReturnsValue<[IntentFile]> {
		let files = try folderEntity.folder.extraneousFiles().asArray()
		let folderPath = folderEntity.folder.localNativeURL!
		return .result(
			value: files.compactMap { path in
				let fileURL = folderPath.appending(path: path)
				return IntentFile(fileURL: fileURL)
			})
	}
}

struct GetNeededFilesIntent: AppIntent {
	static let title: LocalizedStringResource = "Get files in folder needed by this device"

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "The folder to list files in")
	var folderEntity: FolderEntity

	@MainActor
	func perform() async throws -> some ReturnsValue<[IntentFile]> {
		let files = (try folderEntity.folder.filesNeeded()).asArray()
		let folderPath = folderEntity.folder.localNativeURL!
		return .result(
			value: files.compactMap { path in
				let fileURL = folderPath.appending(path: path)
				return IntentFile(fileURL: fileURL)
			})
	}
}

struct GetRemoteNeededFilesIntent: AppIntent {
	static let title: LocalizedStringResource = "Get files in folder needed by another device"

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "The folder to list files in")
	var folderEntity: FolderEntity

	@Parameter(title: "Device", description: "The device to list files for")
	var deviceEntity: DeviceEntity

	@MainActor
	func perform() async throws -> some ReturnsValue<[IntentFile]> {
		let files = (try folderEntity.folder.filesNeeded(by: deviceEntity.deviceID)).asArray()
		let folderPath = folderEntity.folder.localNativeURL!
		return .result(
			value: files.compactMap { path in
				let fileURL = folderPath.appending(path: path)
				return IntentFile(fileURL: fileURL)
			})
	}
}

struct RescanIntent: AppIntent {
	static let title: LocalizedStringResource = "Rescan folder"

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "The folder to rescan")
	var folderEntity: FolderEntity

	@Parameter(title: "Subdirectory", description: "The subdirectory to rescan (empty to rescan the whole folder)")
	var subdirectory: String?

	@MainActor
	func perform() async throws -> some IntentResult {
		if let sub = self.subdirectory {
			try folderEntity.folder.rescanSubdirectory(sub)
		}
		else {
			try folderEntity.folder.rescan()
		}
		return .result()
	}
}

struct RemoveEmptySubdirectoriesIntent: AppIntent {
	static let title: LocalizedStringResource = "Remove unsynchronized empty subdirectories"

	@Dependency private var appState: AppState

	@Parameter(
		title: "Folder",
		description: "Folder to remove empty unsynchronized subdirectories from. The folder must be selectively synchronized."
	)
	var folderEntity: FolderEntity

	@MainActor
	func perform() async throws -> some IntentResult {
		try folderEntity.folder.removeSuperfluousSubdirectories()
		try folderEntity.folder.removeSuperfluousSelectionEntries()
		return .result()
	}
}

struct UnselectSynchronizedFilesIntent: AppIntent {
	static let title: LocalizedStringResource = "Deselect files that are on other devices"

	enum Errors: LocalizedError {
		case invalidQuorum

		var errorDescription: String? {
			switch self {
			case .invalidQuorum:
				return String(localized: "The quorum must be a positive number.")
			}
		}
	}

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "Folder to deselect files in.")
	var folderEntity: FolderEntity

	@Parameter(
		title: "Quorum",
		description: "Minimum number of devices that need to have a copy before a file can be desynchronized.",
		default: 1, controlStyle: .field, inclusiveRange: (1, 1000))
	var quorum: Int

	@MainActor
	func perform() async throws -> some IntentResult {
		if self.quorum < 1 {
			throw Errors.invalidQuorum
		}

		let folder = folderEntity.folder
		var selectedPaths = Set(try folder.selectedPaths(true).asArray())

		for path in selectedPaths {
			let entry = try folderEntity.folder.getFileInformation(path)
			let peersWithFullCopy = try entry.peersWithFullCopy()
			let numPeersWithCopy = peersWithFullCopy.count()
			if numPeersWithCopy < self.quorum {
				Log.info(
					"Not removing \(path), there are only \(numPeersWithCopy) other devices with a copy (required: \(self.quorum).")
				selectedPaths.remove(path)
			}
		}

		let verdicts = selectedPaths.reduce(into: [:]) { dict, p in
			dict[p] = false
		}
		let json = try JSONEncoder().encode(verdicts)
		try folder.setExplicitlySelectedJSON(json)

		return .result()
	}
}

enum ConfigureEnabled: String, Codable, Sendable {
	case enabled = "enabled"
	case disabled = "disabled"
	case doNotChange = "doNotChange"
}

extension ConfigureEnabled: AppEnum {
	static var caseDisplayRepresentations: [ConfigureEnabled: DisplayRepresentation] {
		return [
			.enabled: DisplayRepresentation(title: "Enable"),
			.disabled: DisplayRepresentation(title: "Disable"),
			.doNotChange: DisplayRepresentation(title: "Do not change"),
		]
	}

	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		TypeDisplayRepresentation(
			name: LocalizedStringResource("Status")
		)
	}
}

enum ConfigureHidden: String, Codable, Sendable {
	case hidden = "hidden"
	case shown = "shown"
	case doNotChange = "doNotChange"
}

extension ConfigureHidden: AppEnum {
	static var caseDisplayRepresentations: [ConfigureHidden: DisplayRepresentation] {
		return [
			.hidden: DisplayRepresentation(title: "Hide"),
			.shown: DisplayRepresentation(title: "Show"),
			.doNotChange: DisplayRepresentation(title: "Do not change"),
		]
	}

	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		TypeDisplayRepresentation(
			name: LocalizedStringResource("Visibility")
		)
	}
}

struct ConfigureFolderIntent: AppIntent {
	static let title: LocalizedStringResource = "Configure folder(s)"

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "The folder to reconfigure")
	var folderEntities: [FolderEntity]

	@Parameter(title: "Enabled", description: "Enable synchronization", default: .doNotChange)
	var enable: ConfigureEnabled

	@Parameter(title: "Visibility", description: "Change visibility", default: .doNotChange)
	var visibility: ConfigureHidden

	@MainActor
	func perform() async throws -> some IntentResult {
		for f in self.folderEntities {
			switch self.enable {
			case .enabled:
				try f.folder.setPaused(false)
			case .disabled:
				try f.folder.setPaused(true)
			case .doNotChange:
				break
			}

			switch self.visibility {
			case .hidden:
				f.folder.isHidden = true
			case .shown:
				f.folder.isHidden = false
			case .doNotChange:
				break
			}
		}

		return .result()
	}
}

enum IntentError: Error {
	case folderNotFound
}

struct GetFolderIntent: AppIntent {
	static let title: LocalizedStringResource = "Get folder directory"

	@Dependency private var appState: AppState

	@Parameter(title: "Folder", description: "The folder for which to retrieve the directory")
	var folderEntity: FolderEntity

	@MainActor
	func perform() async throws -> some ReturnsValue<IntentFile> {
		if let url = self.folderEntity.folder.localNativeURL {
			return .result(value: IntentFile(fileURL: url))
		}

		throw IntentError.folderNotFound
	}
}

struct SearchInAppIntent: AppIntent {
	static let title: LocalizedStringResource = "Search files in app"
	static let openAppWhenRun: Bool = true

	@Dependency private var appState: AppState

	@Parameter(
		title: "Search for",
		description: "Search term",
		inputOptions: String.IntentInputOptions(keyboardType: .asciiCapable, capitalizationType: .none)
	)
	var searchFor: String

	@MainActor
	func perform() async throws -> some IntentResult {
		QuickActionService.shared.action = .search(for: searchFor)
		return .result()
	}
}

struct ConfigureDeviceIntent: AppIntent {
	static let title: LocalizedStringResource = "Configure device(s)"

	@Dependency private var appState: AppState

	@Parameter(title: "Device", description: "The device to reconfigure")
	var deviceEntities: [DeviceEntity]

	@Parameter(title: "Enabled", description: "Enable synchronization", default: .doNotChange)
	var enable: ConfigureEnabled

	@MainActor
	func perform() async throws -> some IntentResult {
		for f in self.deviceEntities {
			// TODO: check if this works correctly with device suspension
			switch self.enable {
			case .enabled:
				try f.peer.setPaused(false)
			case .disabled:
				try f.peer.setPaused(true)
			case .doNotChange:
				break
			}
		}

		return .result()
	}
}

struct GetDeviceIDIntent: AppIntent {
	static let title: LocalizedStringResource = "Get device ID"

	@Dependency private var appState: AppState

	@MainActor
	func perform() async throws -> some ReturnsValue<String> {
		return .result(value: self.appState.localDeviceID)
	}
}

struct DownloadFilesIntent: AppIntent {
	static let title: LocalizedStringResource = "Download files"

	@Parameter(title: "Files", description: "The files to download")
	var files: [FileEntity]

	@Parameter(
		title: "Maximum waiting time (seconds)",
		description:
			"How much seconds in total to wait for devices to download from to become available before giving up (seconds).",
		default: 5, controlStyle: .field, inclusiveRange: (0, 15))
	var maxWaitingTime: Int

	@Dependency private var appState: AppState

	@MainActor
	func perform() async throws -> some ReturnsValue<[IntentFile]> {
		// Reconnect to peers
		appState.awake()
		defer {
			appState.sleep()
		}

		// Time until which we can wait for peers to connect
		let deadline = Date.now.addingTimeInterval(Double(maxWaitingTime))

		// Collect all the files
		var files: [IntentFile] = []
		for file in self.files {
			if file.file.isDirectory() || file.file.isDeleted() || file.file.isSymlink() {
				continue
			}

			if let fu = file.file.localNativeFileURL {
				files.append(IntentFile(fileURL: fu))
			}
			else {
				// Wait for at least one peer to connect
				var firstTimeWaiting = false
				while maxWaitingTime <= 0 || deadline > Date.now {
					let peersNeeded = try file.file.peersWithFullCopy().asArray()
					if peersNeeded.isEmpty {
						if !firstTimeWaiting {
							Log.info("Waiting for a peer to connect...")
							firstTimeWaiting = true
						}
						try await Task.sleep(for: .milliseconds(200))
					}
					else {
						break
					}
				}

				let odu = URL(string: file.file.onDemandURL())!
				let (localURL, _) = try await URLSession.shared.download(from: odu)
				files.append(
					IntentFile(
						fileURL: localURL, filename: file.file.fileName(),
						type: UTType(mimeType: file.file.mimeType())))
			}
		}

		return .result(value: files)
	}
}

struct AppShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		return [
			AppShortcut(
				intent: SynchronizePhotosIntent(),
				phrases: ["Back-up new photos using ${applicationName}"],
				shortTitle: "Back-up new photos",
				systemImageName: "photo.badge.arrow.down.fill"
			),
			AppShortcut(
				intent: SynchronizeIntent(),
				phrases: ["Synchronize ${applicationName} files"],
				shortTitle: "Synchronize",
				systemImageName: "bolt.horizontal"
			),
			AppShortcut(
				intent: RescanIntent(),
				phrases: ["Rescan folder in ${applicationName}"],
				shortTitle: "Rescan",
				systemImageName: "arrow.clockwise.square"
			),
			AppShortcut(
				intent: SearchInAppIntent(),
				phrases: ["Search ${applicationName} files"],
				shortTitle: "Search for files",
				systemImageName: "magnifyingglass"
			),
		]
	}
}
