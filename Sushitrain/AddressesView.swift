// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
import SushitrainCore

enum AddressType {
    case listening
    case device
    
    var defaultOption: String {
        switch self {
        case .listening:
            return "default"
        case .device:
            return "dynamic"
        }
    }
}

fileprivate struct AddressView: View {
    @Binding var address: String
    var addressType: AddressType
    
    var body: some View {
        Form {
            Section {
                // Type picker
                Picker("Address type", selection: Binding(get: {
                    let url = URL(string: self.address)
                    return url?.scheme ?? ""
                }, set: { (nv: String) in
                    var url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                    url.scheme = nv
                    if nv == "dynamic+https" {
                        url.path = "/relays"
                    }
                    else {
                        url.path = ""
                    }
                    
                    if nv != "relay" {
                        url.queryItems = nil
                    }
                    
                    self.address = url.string ?? ""
                }), content: {
                    switch self.addressType {
                    case .listening:
                        Text("TCP").tag("tcp")
                        Text("QUIC").tag("quic")
                        Text("Relay").tag("relay")
                        Text("Relay pool").tag("dynamic+https")
                    case .device:
                        Text("TCP").tag("tcp")
                        Text("QUIC").tag("quic")
                    }
                    
                })
                .pickerStyle(.segmented)
            }
            
            Section {
                LabeledContent {
                    TextField("", text: Binding(get: {
                        let url = URL(string: self.address)
                        return url?.host() ?? ""
                    }, set: { nv in
                        var url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                        url.host = nv
                        self.address = url.string ?? ""
                    }), prompt: Text("0.0.0.0"))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                    #endif
                }
                label: {
                    Text("IP address or host name")
                }
                
                LabeledContent {
                    TextField("", text: Binding(get: {
                        let url = URL(string: self.address)
                        if let p = url?.port {
                            return String(p)
                        }
                        return ""
                    }, set: { nv in
                        var url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                        url.port = Int(nv)
                        self.address = url.string ?? ""
                    }), prompt: Text("22000"))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                    #endif
                } label: {
                    Text("Port")
                }
                
                let urlComponents = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                
                if urlComponents.scheme == "relay" {
                    LabeledContent {
                        TextField("", text: Binding(get: {
                            let url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                            return url.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
                        }, set: { nv in
                            var url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                            var qi = url.queryItems ?? []
                            qi.removeAll(where: { $0.name == "id" })
                            qi.append(URLQueryItem(name: "id", value: nv))
                            url.queryItems = qi
                            self.address = url.string ?? ""
                        }), prompt: Text(""))
                        .multilineTextAlignment(.trailing)
                        .monospaced()
                        #if os(iOS)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                        #endif
                    }
                    label: {
                        Text("Relay ID")
                    }
                    
                    LabeledContent {
                        TextField("", text: Binding(get: {
                            let url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                            return url.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
                        }, set: { nv in
                            var url = URLComponents(url: URL(string: self.address) ?? URL(string: "tcp://")!, resolvingAgainstBaseURL: false) ?? URLComponents()
                            var qi = url.queryItems ?? []
                            qi.removeAll(where: { $0.name == "token" })
                            qi.append(URLQueryItem(name: "token", value: nv))
                            url.queryItems = qi
                            self.address = url.string ?? ""
                        }), prompt: Text(""))
                        .multilineTextAlignment(.trailing)
                        .monospaced()
                        #if os(iOS)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                        #endif
                    }
                    label: {
                        Text("Access token")
                    }
                }
            }
            Section("URL") {
                TextField("", text: $address)
                    .frame(maxWidth: .infinity)
                    .monospaced()
                    .multilineTextAlignment(.leading)
                    #if os(iOS)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                    #endif
            }
        }
        .navigationTitle(self.address)
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

struct AddressesView: View {
    @ObservedObject var appState: AppState
    @Binding var addresses: [String]
    @State var editingAddresses: [String]
    var addressType: AddressType
    
    var body: some View {
        Form {
            Section {
                Toggle("Use default addresses", isOn: Binding(get: {
                    return self.editingAddresses.contains(self.addressType.defaultOption)
                }, set: { nv in
                    if nv && !self.editingAddresses.contains(self.addressType.defaultOption) {
                        self.editingAddresses.append(self.addressType.defaultOption)
                    }
                    else {
                        self.editingAddresses.removeAll { $0 == self.addressType.defaultOption }
                    }
                }))
            } footer: {
                switch self.addressType {
                case .listening:
                    Text("When enabled, the app will listen on default addresses, and will use the default relay pool.")
                case .device:
                    Text("When enabled, the app will look up addresses for this device automatically using various discovery mechanisms.")
                }
                
            }
            
            Section("Additional addresses") {
                ForEach(Array(editingAddresses.enumerated()), id: \.offset) { idx in
                    if idx.element != addressType.defaultOption {
                        NavigationLink(destination:  AddressView(address: Binding(get: {
                            return editingAddresses[idx.offset]
                        }, set: { nv in
                            editingAddresses[idx.offset] = nv
                        }), addressType: addressType)) {
                            HStack {
                                #if os(macOS)
                                    Button("Delete", systemImage: "trash") {
                                        editingAddresses.remove(at: idx.offset)
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                #endif
                                Text(idx.element)
                                
                            }
                        }
                    }
                }
                .onDelete(perform: { indexSet in
                    editingAddresses.remove(atOffsets: indexSet)
                })
                
                Button("Add address") {
                    self.editingAddresses.append("tcp://0.0.0.0:22000")
                }.deleteDisabled(true)
                #if os(macOS)
                    .buttonStyle(.link)
                #endif
            }
        }
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
            .formStyle(.grouped)
        #endif
        .onDisappear {
            self.addresses = self.editingAddresses
        }
        .toolbar {
            #if os(iOS)
            if !editingAddresses.isEmpty {
                EditButton()
            }
            #endif
        }
    }
}
