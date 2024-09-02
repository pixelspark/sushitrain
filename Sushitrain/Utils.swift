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
    var label: String {
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

extension SushitrainFolder: Comparable {
    public static func < (lhs: SushitrainFolder, rhs: SushitrainFolder) -> Bool {
        return lhs.displayName < rhs.displayName
    }
}

extension SushitrainPeer: Comparable {
    public static func < (lhs: SushitrainPeer, rhs: SushitrainPeer) -> Bool {
        return lhs.deviceID() < rhs.deviceID()
    }
}

extension SushitrainEntry: Comparable {
    public static func < (lhs: SushitrainEntry, rhs: SushitrainEntry) -> Bool {
        return lhs.path() < rhs.path()
    }
}

extension SushitrainPeer: Identifiable {
}

extension SushitrainChange: Identifiable {
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

/** Utility for storing arbitrary Swift Codable types as user defaults */
// Inspired by https://stackoverflow.com/questions/19720611/attempt-to-set-a-non-property-list-object-as-an-nsuserdefaults
@propertyWrapper
class Setting<T: Codable & Equatable>: ObservableObject {
    let key: String
    let defaultValue: T
    
    private var cancellable: AnyCancellable?
    
    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
        self.wrappedValue = defaultValue
        
        // Observe changes in UserDefaults
        cancellable = UserDefaults.standard.publisher(for: \.self)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
    
    var wrappedValue: T {
        get {
            if let jsonData = UserDefaults.standard.data(forKey: key),
               let user = try? JSONDecoder().decode(T.self, from: jsonData) {
                return user
            }
            return defaultValue
        }
        set {
            if let jsonData = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(jsonData, forKey: key)
                objectWillChange.send() // Notify subscribers of the change
            }
        }
    }
    
    var projectedValue: Binding<T> {
        Binding(
            get: { self.wrappedValue },
            set: { self.wrappedValue = $0 }
        )
    }
}

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

@MainActor
enum Settings {
    @Setting("backgroundSyncRuns", defaultValue: []) static var backgroundSyncRuns: [BackgroundSyncRun]
    @Setting("lastBackgroundSyncRun", defaultValue: nil) static var lastBackgroundSyncRun: BackgroundSyncRun?
    @Setting("backgroundSyncEnabled", defaultValue: true) static var backgroundSyncEnabled: Bool
}

extension SushitrainFolder {
    var isIdle: Bool {
        var error: NSError? = nil
        let s = self.state(&error)
        return s == "idle"
    }
    
    var displayName: String {
        let label = self.label()
        return label.isEmpty ? self.folderID : label
    }
}

extension SushitrainEntry {
    var systemImage: String {
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
