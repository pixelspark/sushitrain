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
        return lhs.folderID < rhs.folderID
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

/** Utility for storing arbitrary Swift Codable types as user defaults */
// Inspired by https://stackoverflow.com/questions/19720611/attempt-to-set-a-non-property-list-object-as-an-nsuserdefaults
@propertyWrapper
struct Setting<T: Codable> {
    let key: String
    let defaultValue: T
    
    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }
    
    var wrappedValue: T {
        get {
            if let jsonData = UserDefaults.standard.object(forKey: key) as? Data,
               let user = try? JSONDecoder().decode(T.self, from: jsonData) {
                return user
            }
            
            return  defaultValue
        }
        set {
            if let jsonData = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(jsonData, forKey: key)
            }
        }
    }
}

struct BackgroundSyncRun: Codable {
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
}

extension SushitrainEntry {
    var systemImage: String {
        if self.isLocallyPresent() {
            return "doc.fill"
        }
        else if self.isSelected() {
            return "doc.badge.ellipsis"
        }
        else {
            return "doc"
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
