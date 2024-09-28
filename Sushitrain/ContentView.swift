// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SushitrainCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("onboardingVersionShown") var onboardingVersionShown = 0
    
    @ObservedObject var appState: AppState
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @State private var showCustomConfigWarning = false
    @State private var showOnboarding = false
    @State private var route: Route? = .start
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    
    var tabbedBody: some View {
        TabView(selection: $route) {
            // Me
            NavigationStack {
                StartView(appState: appState, route: $route)
            }
            .tabItem {
                Label("Start", systemImage: self.appState.systemImage)
            }.tag(Route.start)

            // Folders
            NavigationStack {
                FoldersView(appState: appState)
                .toolbar {
                    Button("Open in Files app", systemImage: "arrow.up.forward.app", action: {
                        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        let sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                        let furl = URL(string: sharedurl)!
                        UIApplication.shared.open(furl, options: [:], completionHandler: nil)
                    }).labelStyle(.iconOnly)
                }
            }
            .tabItem {
                Label("Folders", systemImage: "folder.fill")
            }.tag(Route.folder(folderID: nil))

            // Peers
            NavigationStack {
                DevicesView(appState: appState)
            }
            .tabItem {
                Label("Devices", systemImage: "externaldrive.fill")
            }.tag(Route.devices)
        }
    }
    
    var splitBody: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            sidebar: {
                List(selection: $route) {
                    if horizontalSizeClass != .compact {
                        Section {
                            NavigationLink(value: Route.start) {
                                Label("Start", systemImage: self.appState.systemImage)
                            }
                        }
                        Section {
                            NavigationLink(value: Route.devices) {
                                Label("Devices", systemImage: "externaldrive.fill")
                            }
                        }
                    }
                    
                    FoldersSections(appState: self.appState)
                }
                .toolbar {
                    Button("Open in Files app", systemImage: "arrow.up.forward.app", action: {
                        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        let sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                        let furl = URL(string: sharedurl)!
                        UIApplication.shared.open(furl, options: [:], completionHandler: nil)
                    }).labelStyle(.iconOnly)
                }
            }, detail: {
                NavigationStack {
                    switch self.route {
                    case .start:
                        StartView(appState: self.appState, route: $route)
                        
                    case .devices:
                        DevicesView(appState: self.appState)
                        
                    case .folder(folderID: let folderID):
                        if let folderID = folderID, let folder = self.appState.client.folder(withID: folderID) {
                            if folder.exists() {
                                BrowserView(
                                    appState: self.appState,
                                    folder: folder,
                                    prefix: ""
                                ).id(folder.folderID)
                            }
                            else {
                                ContentUnavailableView("Folder was deleted", systemImage: "trash", description: Text("This folder was deleted."))
                            }
                        }
                        else {
                            ContentUnavailableView("Select a folder", systemImage: "folder").onTapGesture {
                                columnVisibility = .doubleColumn
                            }
                        }
                        
                    case nil:
                        ContentUnavailableView("Select a folder", systemImage: "folder").onTapGesture {
                            columnVisibility = .doubleColumn
                        }
                    }
                }
            })
        .navigationSplitViewStyle(.balanced)
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                self.tabbedBody
            } else {
                self.splitBody
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
                AppState.requestNotificationPermissionIfNecessary()
            }
        }
    }

    private static let currentOnboardingVersion = 1

    private func showOnboardingIfNecessary() {
        print(
            "Current onboarding version is \(Self.currentOnboardingVersion), user last saw \(self.onboardingVersionShown)"
        )
        if onboardingVersionShown < Self.currentOnboardingVersion {
            self.showOnboarding = true
            onboardingVersionShown = Self.currentOnboardingVersion
        } else {
            // Go straight on to request notification permissions
            AppState.requestNotificationPermissionIfNecessary()
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
