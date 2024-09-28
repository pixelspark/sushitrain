// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore
import VisionKit

struct AddDeviceView: View {
    @ObservedObject var appState: AppState
    @Binding var suggestedDeviceID: String
    @State var deviceID = ""
    @State private var showHelpAfterAdding = false
    @State private var showError = false
    @State private var errorText = ""
    @State private var showQRScanner = false
    @FocusState private var idFieldFocus: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Device identifier") {
                    TextField("", text: $deviceID, prompt: Text("XXXX-XXXX"), axis: .vertical)
                        .focused($idFieldFocus)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .foregroundColor(SushitrainIsValidDeviceID(deviceID) ? .green: .red)
                    
#if os(iOS)
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button("Scan using camera...", systemImage: "qrcode") {
                            showQRScanner = true
                        }
                    }
#endif
                }
            }
#if os(macOS)
            .formStyle(.grouped)
#endif
            .onAppear {
                idFieldFocus = true
                deviceID = suggestedDeviceID
            }
#if os(iOS)
            .sheet(isPresented: $showQRScanner, content: {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    NavigationStack {
                        QRScannerViewRepresentable (
                            scannedText: $deviceID,
                            shouldStartScanning: $showQRScanner,
                            dataToScanFor: [.barcode(symbologies: [.qr])]
                        )
                        .navigationTitle("Scan a device QR code")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(content: {
                            ToolbarItem(placement: .cancellationAction, content: {
                                Button("Cancel") {
                                    showQRScanner = false
                                }
                            })
                        })
                    }
                }
            })
#endif
            .toolbar(content: {
                ToolbarItem(placement: .confirmationAction, content: {
                    Button("Add") {
                        do {
                            try appState.client.addPeer(self.deviceID);
                            showHelpAfterAdding = true
                        }
                        catch let error {
                            showError = true
                            errorText = error.localizedDescription
                        }
                    }.disabled(deviceID.isEmpty || !SushitrainIsValidDeviceID(deviceID))
                })
                ToolbarItem(placement: .cancellationAction, content: {
                    Button("Cancel") {
                        dismiss()
                    }
                })
                
            })
            .navigationTitle("Add device")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .alert(isPresented: $showError, content: {
                Alert(title: Text("Could not add device"), message: Text(errorText), dismissButton: .default(Text("OK")))
            })
            .alert(isPresented: $showHelpAfterAdding) {
                Alert(title: Text("The device has been added"), message: Text("The device has been added. To ensure a connection, ensure the other device accepts this device, or add this device there as well."), dismissButton: .default(Text("OK")) {
                    dismiss()
                })
            }
        }
    }
}
