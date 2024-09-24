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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum Tab: Int {
        case start = 1
        case peers
        case folders
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                TabView(selection: $tabSelection) {
                    // Me
                    NavigationStack {
                        MeView(appState: appState, tabSelection: $tabSelection)
                    }.tabItem {
                        Label("Start", systemImage: self.appState.systemImage)
                    }.tag(Tab.start)

                    // Folders
                    FoldersView(appState: appState)
                        .tabItem {
                            Label("Folders", systemImage: "folder.fill")
                        }.tag(Tab.folders)

                    // Peers
                    PeersView(appState: appState)
                        .tabItem {
                            Label("Devices", systemImage: "externaldrive.fill")
                        }.tag(Tab.peers)
                }
            } else {
                FoldersView(appState: appState)
            }
        }
        .sheet(
            isPresented: $showOnboarding,
            content: {
                OnboardingView().interactiveDismissDisabled()
            }
        )
        .alert(
            isPresented: $appState.alertShown,
            content: {
                Alert(
                    title: Text("Error"), message: Text(appState.alertMessage),
                    dismissButton: .default(Text("OK")))
            }
        )
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                try? self.appState.client.setReconnectIntervalS(60)
                self.appState.client.ignoreEvents = true
                self.appState.updateBadge()
                break

            case .inactive:
                self.appState.updateBadge()
                self.appState.client.ignoreEvents = true
                break

            case .active:
                try? self.appState.client.setReconnectIntervalS(1)
                self.rebindServer()
                self.appState.client.ignoreEvents = false
                break

            @unknown default:
                break
            }
        }
        .alert(isPresented: $showCustomConfigWarning) {
            Alert(
                title: Text("Custom configuration detected"),
                message: Text(
                    "You are using a custom configuration. This may be used for testing only, and at your own risk. Not all configuration options may be supported. To disable the custom configuration, remove the configuration files from the app's folder and restart the app. The makers of the app cannot be held liable for any data loss that may occur!"
                ),
                dismissButton: .default(Text("I understand and agree")) {
                    self.showOnboardingIfNecessary()
                })
        }
        .onAppear {
            if self.appState.client.isUsingCustomConfiguration {
                self.showCustomConfigWarning = true
            } else {
                self.showOnboardingIfNecessary()
            }
        }
        .onChange(of: showOnboarding) { _, shown in
            if !shown {
                // End of onboarding, request notification authorization
                self.requestNotificationPermissionIfNecessary()
            }
        }
    }

    private static let currentOnboardingVersion = 1

    private func requestNotificationPermissionIfNecessary() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                let options: UNAuthorizationOptions = [.badge]
                UNUserNotificationCenter.current().requestAuthorization(options: options) {
                    (status, error) in
                    print("Notifications requested: \(status) \(error?.localizedDescription ?? "")")
                }
            }
        }
    }

    private func showOnboardingIfNecessary() {
        print(
            "Current onboarding version is \(Self.currentOnboardingVersion), user last saw \(self.onboardingVersionShown)"
        )
        if onboardingVersionShown < Self.currentOnboardingVersion {
            self.showOnboarding = true
            onboardingVersionShown = Self.currentOnboardingVersion
        } else {
            // Go straight on to request notification permissions
            self.requestNotificationPermissionIfNecessary()
        }
    }

    private func rebindServer() {
        print("(Re-)activate streaming server")
        do {
            try self.appState.client.server?.listen()
        } catch let error {
            print("Error activating streaming server:", error)
        }
    }
}
