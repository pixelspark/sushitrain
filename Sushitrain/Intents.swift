// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import AppIntents
@preconcurrency import SushitrainCore

struct SynchronizePhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy new photos"
    
    @Dependency private var appState: AppState
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await appState.photoSync.synchronize(appState, fullExport: false, isInBackground: true)
        return .result(dialog: "Copied new photos")
    }
}

struct SynchronizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Synchronize for a while"
    
    @Dependency private var appState: AppState
    
    @Parameter(title: "Time (seconds)", description: "How much time to allow for synchronization.", default: 10)
    var time: Int
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if self.time > 0 {
            try await Task.sleep(for: .seconds(self.time))
        }
        return .result(dialog: "Synchronization time elapsed")
    }
}

struct DeviceEntity: AppEntity {
    static let defaultQuery = DeviceEntityQuery()
    
    typealias DefaultQuery = DeviceEntityQuery
    
    init(peer: SushitrainPeer) {
        self.peer = peer
        self.name = peer.displayName
    }
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Device")
        )
    }
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.name)", image: DisplayRepresentation.Image(systemName: "externaldrive.fill"))
    }
    
    var peer: SushitrainPeer
    
    var id: String {
        return self.peer.id
    }
    
    @Property(title: "Name")
    var name: String
}

struct FolderEntity: AppEntity {
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
        DisplayRepresentation(title: "\(self.name)", image: DisplayRepresentation.Image(systemName: "folder.fill"))
    }
    
    var folder: SushitrainFolder
    
    var id: String {
        return self.folder.folderID
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
        return await appState.peers().map {
            DeviceEntity(peer: $0)
        }
    }
    
    @Dependency private var appState: AppState

    func entities(for identifiers: [DeviceEntity.ID]) async throws -> [DeviceEntity] {
        return await appState.peers().filter { identifiers.contains($0.id) }.map {
            DeviceEntity(peer: $0)
        }
    }
    
    func suggestedEntities() async throws -> [DeviceEntity] {
        return await appState.peers().map {
            DeviceEntity(peer: $0)
        }
    }
    
    func entities(matching string: String) async throws -> [DeviceEntity] {
        return await appState.peers().filter { $0.displayName.contains(string) }.map {
            DeviceEntity(peer: $0)
        }
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
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let sub = self.subdirectory {
            try folderEntity.folder.rescanSubdirectory(sub)
        }
        else {
            try folderEntity.folder.rescan()
        }
        return .result(dialog: "Folder rescan requested for folder '\(folderEntity.folder.displayName)'")
    }
}

enum ConfigureEnabled: String, Codable, Sendable {
    case enabled = "enabled"
    case disabled = "disabled"
    case doNotChange = "doNotChange"
}

extension ConfigureEnabled: AppEnum {
    static var caseDisplayRepresentations: [ConfigureEnabled : DisplayRepresentation] {
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
    static var caseDisplayRepresentations: [ConfigureHidden : DisplayRepresentation] {
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
    func perform() async throws -> some IntentResult & ProvidesDialog {
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
        
        return .result(dialog: "Folder configuration changed")
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
    func perform() async throws -> some IntentResult & ProvidesDialog {
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
        
        return .result(dialog: "Device configuration changed")
    }
}

struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: SynchronizePhotosIntent(),
                phrases: ["Copy new photos"],
                shortTitle: "Copy new photos",
                systemImageName: "photo.badge.arrow.down.fill"
            ),
            AppShortcut(
                intent: SynchronizeIntent(),
                phrases: ["Synchronize files"],
                shortTitle: "Synchronize",
                systemImageName: "bolt.horizontal"
            ),
            AppShortcut(
                intent: RescanIntent(),
                phrases: ["Rescan folder"],
                shortTitle: "Rescan",
                systemImageName: "arrow.clockwise.square"
            ),
            AppShortcut(
                intent: ConfigureFolderIntent(),
                phrases: ["Change folder settings"],
                shortTitle: "Configure folder",
                systemImageName: "folder.fill.badge.gearshape"
            ),
            AppShortcut(
                intent: ConfigureDeviceIntent(),
                phrases: ["Change device settings"],
                shortTitle: "Configure device",
                systemImageName: "externaldrive.fill.badge.plus"
            ),
            AppShortcut(
                intent: GetFolderIntent(),
                phrases: ["Get folder directory"],
                shortTitle: "Get folder directory",
                systemImageName: "externaldrive.fill"
            ),
            AppShortcut(
                intent: SearchInAppIntent(),
                phrases: ["Search files"],
                shortTitle: "Search for files",
                systemImageName: "magnifyingglass"
            ),
        ]
    }
}
