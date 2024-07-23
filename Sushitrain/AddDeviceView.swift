// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
import SushitrainCore

struct AddDeviceView: View {
    @State var deviceID = ""
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: AppState
    @State var showError = false
    @State var errorText = ""
    @FocusState private var idFieldFocus: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Device identifier")) {
                    TextField("XXXX-XXXX", text: $deviceID).focused($idFieldFocus).textInputAutocapitalization(.never)
                }
            }
            .onAppear {
                idFieldFocus = true
            }
            .toolbar(content: {
                ToolbarItem(placement: .confirmationAction, content: {
                    Button("Add") {
                        do {
                            try appState.client.addPeer(self.deviceID);
                            dismiss()
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
        }
    }
}
