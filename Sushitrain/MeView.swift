import SwiftUI
import SushitrainCore


struct MeView: View {
    @ObservedObject var appState: SushitrainAppState
    @State private var settingsShown = false
    @State private var searchShown = false
    
    var peerStatusText: String {
        return "\(self.appState.client.connectedPeerCount())/\(self.appState.peers().count - 1)"
    }
    
    var isConnected: Bool {
        return self.appState.client.connectedPeerCount() > 0
    }
    
    @State private var showAddresses = false
    
    var body: some View {
        Form {
            Section {
                if self.isConnected {
                    if self.appState.client.isTransferring() {
                        let progress = self.appState.client.getTotalDownloadProgress()
                        if let progress = progress {
                            ProgressView(value: progress.percentage, total: 1.0) {
                                Label("Downloading \(progress.filesTotal) files...", systemImage: "arrow.clockwise").foregroundStyle(.green).symbolEffect(.pulse, value: true).badge(self.peerStatusText)
                            }
                        }
                        else {
                            Label("Synchronizing files...", systemImage: "arrow.clockwise").foregroundStyle(.green).symbolEffect(.pulse, value: true).badge(self.peerStatusText)
                        }
                    }
                    else {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).badge(Text(self.peerStatusText))
                    }
                }
                else {
                    Label("Not connected", systemImage: "network.slash").badge(Text(self.peerStatusText)).foregroundColor(.gray)
                }
                
                
            }
            
            Section(header: Text("This device's identifier")) {
                Label(self.appState.localDeviceID, systemImage: "qrcode").contextMenu {
                    Button(action: {
                        UIPasteboard.general.string = self.appState.localDeviceID
                    }) {
                        Text("Copy to clipboard")
                        Image(systemName: "doc.on.doc")
                    }
                    Button(action: {
                        self.showAddresses = true
                    }) {
                        Text("Show addresses")
                    }
                }.monospaced()
            }
        }.navigationTitle("Start")
            .toolbar {
                ToolbarItem {
                    Button("Settings", systemImage: "gear", action: {
                        settingsShown = true
                    }).labelStyle(.iconOnly)
                }
                ToolbarItem {
                    Button("Search", systemImage: "magnifyingglass") {
                        searchShown = true
                    }
                }
            }
            .sheet(isPresented: $settingsShown, content: {
                NavigationStack {
                    SettingsView(appState: self.appState).toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                appState.applySettings()
                                settingsShown = false
                            }
                        })
                    })
                }
            })
            .sheet(isPresented: $searchShown) {
                NavigationStack {
                    SearchView(appState: appState).toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                self.searchShown = false
                            }
                        })
                    })
                }
            }
            .sheet(isPresented: $showAddresses) {
                NavigationStack {
                    List {
                        ForEach(Array(self.appState.listenAddresses), id: \.self) { addr in
                            Text(addr).contextMenu {
                                Button(action: {
                                    UIPasteboard.general.string = self.appState.localDeviceID
                                }) {
                                    Text("Copy to clipboard")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                        }
                    }
                    .navigationTitle("Addresses")
                    .toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                self.showAddresses = false
                            }
                        })
                    })
                }
            }
    }
}
