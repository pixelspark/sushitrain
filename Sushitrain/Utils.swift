// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore
import VisionKit

extension SushitrainListOfStrings {
    public func asArray() -> [String] {
        var data: [String] = []
        for idx in 0..<self.count() {
            data.append(self.item(at: idx))
        }
        return data
    }
}

extension SushitrainPeer {
    var displayName: String {
        let name = self.name()
        if !name.isEmpty {
            return name
        }
        return self.deviceID()
    }
}

extension SushitrainDate {
    public func date() -> Date {
        return Date(timeIntervalSince1970: Double(self.unixMilliseconds()) / 1000.0)
    }
}

extension SushitrainFolder: @retroactive Comparable {
    public static func < (lhs: SushitrainFolder, rhs: SushitrainFolder) -> Bool {
        return lhs.displayName < rhs.displayName
    }
}

extension SushitrainPeer: @retroactive Comparable {
    public static func < (lhs: SushitrainPeer, rhs: SushitrainPeer) -> Bool {
        return lhs.deviceID() < rhs.deviceID()
    }
}

extension SushitrainEntry: @retroactive Comparable {
    public static func < (lhs: SushitrainEntry, rhs: SushitrainEntry) -> Bool {
        return lhs.path() < rhs.path()
    }
}

extension SushitrainPeer: @retroactive Identifiable {
}

extension SushitrainChange: @retroactive Identifiable {
}

extension SushitrainChange {
    var systemImage: String {
        switch self.action {
        case "deleted":
            return "trash"
            
        case "modified":
            fallthrough
            
        default:
            return "pencil.circle"
        }
    }
}

import SwiftUI
import Combine
struct BackgroundSyncRun: Codable, Equatable {
    var started: Date
    var ended: Date?
    
    var asString: String {
        if let ended = self.ended {
            return "\(self.started.formatted()) - \(ended.formatted())"
        }
        return self.started.formatted()
    }
}

final class PublisherObservableObject: ObservableObject {
    
    var subscriber: AnyCancellable?
    
    init(publisher: AnyPublisher<Void, Never>) {
        subscriber = publisher.sink(receiveValue: { [weak self] _ in
            self?.objectWillChange.send()
        })
    }
}

extension SushitrainFolder {
    var isIdle: Bool {
        var error: NSError? = nil
        let s = self.state(&error)
        return s == "idle"
    }
    
    // When true, the folder's selection can be changed (files may be transferring, but otherwise the folder is idle)
    var isIdleOrSyncing: Bool {
        var error: NSError? = nil
        let s = self.state(&error)
        return s == "idle" || s == "syncing"
    }
    
    var displayName: String {
        let label = self.label()
        return label.isEmpty ? self.folderID : label
    }
    
    var localNativeURL: URL? {
        get {
            var error: NSError? = nil
            let localNativePath = self.localNativePath(&error)
            
            if let error = error {
                print("Could not get local native URL for folder: \(error.localizedDescription)")
            }
            else {
                return URL(fileURLWithPath: localNativePath)
            }
            return nil
        }
    }
    
    var isExcludedFromBackup: Bool? {
        get {
            guard let lu = self.localNativeURL else { return nil }
            let values = try? lu.resourceValues(forKeys: [.isExcludedFromBackupKey])
            return values?.isExcludedFromBackup
        }
        set {
            guard var lu = self.localNativeURL else { return }
            var values = try! lu.resourceValues(forKeys: [.isExcludedFromBackupKey])
            values.isExcludedFromBackup = newValue
            try! lu.setResourceValues(values)
        }
    }
    
    var isHidden: Bool? {
        get {
            guard let lu = self.localNativeURL else { return nil }
            let values = try? lu.resourceValues(forKeys: [.isHiddenKey])
            return values?.isHidden
        }
        set {
            guard var lu = self.localNativeURL else { return }
            var values = try! lu.resourceValues(forKeys: [.isHiddenKey])
            values.isHidden = newValue
            try! lu.setResourceValues(values)
        }
    }
}

extension SushitrainEntry {
    var systemImage: String {
        if self.isSymlink() {
            return "link"
        }
        
        let base = self.isDirectory() ? "folder" : "doc"
        if self.isLocallyPresent() {
            return "\(base).fill"
        }
        else if self.isSelected() {
            return "\(base).badge.ellipsis"
        }
        else {
            return "\(base)"
        }
    }
}

struct QRScannerViewRepresentable: UIViewControllerRepresentable {
    @Binding var scannedText: String
    @Binding var shouldStartScanning: Bool
    var dataToScanFor: Set<DataScannerViewController.RecognizedDataType>
    
    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: QRScannerViewRepresentable
        
        init(_ parent: QRScannerViewRepresentable) {
            self.parent = parent
        }
        
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in allItems {
                switch item {
                case .barcode(let barcode):
                    if let text = barcode.payloadStringValue, !text.isEmpty {
                        parent.scannedText = text
                        parent.shouldStartScanning = false
                        return
                    }
                    
                default:
                    break
                }
            }
        }
    }
    
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let dataScannerVC = DataScannerViewController(
            recognizedDataTypes: dataToScanFor,
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        
        dataScannerVC.delegate = context.coordinator
        return dataScannerVC
    }
    
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if shouldStartScanning {
            try? uiViewController.startScanning()
        } else {
            uiViewController.stopScanning()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

extension Bundle {
    var releaseVersionNumber: String? {
        return self.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildVersionNumber: String? {
        return self.infoDictionary?["CFBundleVersion"] as? String
    }

}

struct OptionalObject<T: Codable>: RawRepresentable {
    let wrappedValue: T?
    
    init(_ wrappedObject: T? = nil) {
        self.wrappedValue = wrappedObject
    }
    
    init?(rawValue: String) {
        if let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode(T.self, from: data)
        {
            self.wrappedValue = result
        }
        else {
            self.wrappedValue = nil
        }
    }
    
    var rawValue: String {
        guard let data = try? JSONEncoder().encode(wrappedValue),
              let result = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return result
    }
}

// Allows all Codable Arrays to be saved using AppStorage
extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

// Allows all Codable Sets to be saved using AppStorage
extension Set: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = Set(result)
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

extension Set {
    mutating func toggle(_ element: Element, _ t: Bool) {
        if t {
            self.insert(element)
        }
        else {
            self.remove(element)
        }
    }
}
