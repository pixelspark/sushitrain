// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SushitrainCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var appState: AppState
    @Environment(\.scenePhase) var scenePhase
    @State private var showCustomConfigWarning = false
    @State private var showOnboarding = false
    @AppStorage("onboardingVersionShown") var onboardingVersionShown = 0
    @State private var tabSelection: Tab = .start
    
    enum Tab: Int {
        case start = 1
        case peers
        case folders
    }
    
    var body: some View {
        TabView(selection: $tabSelection) {
            // Me
            NavigationStack {
                MeView(appState: appState, tabSelection: $tabSelection)
            }.tabItem {
                Label("Start", systemImage: self.appState.client.isTransferring() ? "arrow.clockwise.circle.fill" : (self.appState.client.connectedPeerCount() > 0 ? "checkmark.circle.fill" : "network.slash"))
            }.tag(Tab.start)
            
            // Folders
            FoldersView(appState: appState)
                .tabItem {
                    Label("Folders", systemImage: "folder.fill")
                }.tag(Tab.folders)
            
            // Peers
            PeersView(appState: appState)
                .tabItem {
                    Label("Devices", systemImage: "network")
                }.tag(Tab.peers)
        }
        .sheet(isPresented: $showOnboarding, content: {
            OnboardingView().interactiveDismissDisabled()
        })
        .alert(isPresented: $appState.alertShown, content: {
            Alert(title: Text("Error"), message: Text(appState.alertMessage), dismissButton: .default(Text("OK")))
        })
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                break
                
            case .inactive:
                break
                
            case .active:
                self.rebindServer()
                break
                
            @unknown default:
                break
            }
        }
        .alert(isPresented: $showCustomConfigWarning) {
            Alert(title: Text("Custom configuration detected"), message: Text("You are using a custom configuration. This may be used for testing only, and at your own risk. Not all configuration options may be supported. To disable the custom configuration, remove the configuration files from the app's folder and restart the app. The makers of the app cannot be held liable for any data loss that may occur!"), dismissButton: .default(Text("I understand and agree")) {
                self.showOnboardingIfNecessary();
            })
        }
        .onAppear() {
            if self.appState.client.isUsingCustomConfiguration {
                self.showCustomConfigWarning = true
            }
            else {
                self.showOnboardingIfNecessary()
            }
        }
    }
    
    private static let currentOnboardingVersion = 1
    
    private func showOnboardingIfNecessary() {
        print("Current onboarding version is \(Self.currentOnboardingVersion), user last saw \(self.onboardingVersionShown)")
        if onboardingVersionShown < Self.currentOnboardingVersion {
            self.showOnboarding = true
            onboardingVersionShown = Self.currentOnboardingVersion
        }
    }
    
    private func rebindServer() {
        print("(Re-)activate streaming server")
        do {
            try self.appState.client.server?.listen()
        }
        catch let error {
            print("Error activating streaming server:", error)
        }
    }
}
