import SwiftUI
import SushitrainCore

struct PeerView: View {
    var peer: SushitrainPeer
    @ObservedObject var appState: SushitrainAppState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section {
                if peer.isConnected() {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                else {
                    Label("Not connected", systemImage: "xmark.circle")
                    if let lastSeen = peer.lastSeen() {
                        Text("Last seen").badge(Text(lastSeen.date().formatted()))
                    }
                }
            }
            
            Section {
                Toggle("Enabled", isOn: Binding(get: { !peer.isPaused() }, set: {active in try? peer.setPaused(!active) }))
            } footer: {
                Text("If a device is not enabled, synchronization with this device is paused.")
            }
            
            Section {
                Toggle("Trusted", isOn: Binding(get: { !peer.isUntrusted() }, set: {trusted in try? peer.setUntrusted(!trusted) }))
            } footer: {
                Text("If a device is not trusted, an encryption password is required for each folder synchronized with the device.")
            }
            
            Section("Device ID") {
                Label(peer.deviceID(), systemImage: "qrcode").contextMenu {
                    Button(action: {
                        UIPasteboard.general.string = peer.deviceID()
                    }) {
                        Text("Copy to clipboard")
                        Image(systemName: "doc.on.doc")
                    }
                }.monospaced()
            }
            
            Section("Addresses") {
                let lastAddress = self.appState.client.getLastPeerAddress(self.peer.deviceID())
                if !lastAddress.isEmpty {
                   Text(lastAddress).contextMenu {
                       Button(action: {
                           UIPasteboard.general.string = peer.deviceID()
                       }) {
                           Text("Copy to clipboard")
                           Image(systemName: "doc.on.doc")
                       }
                   }
                }
            }
            
//            Section(header: Text("Addresses")) {
//                ForEach(peer.addresses()?.asArray() ?? [], id: \.self) { addr in
//                    Text(addr)
//                }
//            }
            
            Section {
                Button("Remove device", systemImage: "trash", role:.destructive, action: {
                    try? peer.remove()
                    dismiss()
                }).foregroundColor(.red)
            }
        }.navigationTitle(peer.name())
    }
}
