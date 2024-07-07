import SwiftUI
import SushitrainCore

struct AddDeviceView: View {
    @State var deviceID = ""
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: SushitrainAppState
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
