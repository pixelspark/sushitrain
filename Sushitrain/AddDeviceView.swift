// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct AddDeviceView: View {
    @ObservedObject var appState: AppState
    @Binding var suggestedDeviceID: String
    @State var deviceID = ""
    @State private var showHelpAfterAdding = false
    @State private var showError = false
    @State private var errorText = ""
    @FocusState private var idFieldFocus: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Device identifier") {
                    TextField("XXXX-XXXX", text: $deviceID, axis: .vertical)
                        .focused($idFieldFocus)
                        .textInputAutocapitalization(.never)
                }
            }
            .onAppear {
                idFieldFocus = true
                deviceID = suggestedDeviceID
                print("Set ssi", suggestedDeviceID)
            }
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
                    }.disabled(deviceID.isEmpty)
                })
                ToolbarItem(placement: .cancellationAction, content: {
                    Button("Cancel") {
                        dismiss()
                    }
                })
                
            })
            .navigationTitle("Add device")
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
