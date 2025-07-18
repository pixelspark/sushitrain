// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SushitrainCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
	@Environment(AppState.self) private var appState
	@State var route: Route? = .start
	@Environment(\.openURL) private var openURL

	var body: some View {
		switch appState.startupState {
		case .notStarted:
			LoadingMainView(appState: appState)
		case .error(let e):
			ContentUnavailableView {
				Label("Cannot start the app", systemImage: "exclamationmark.triangle.fill")
			} description: {
				Text(e)
				Button("What do I do now?") {
					openURL(URL(string: "https://t-shaped.nl/synctrain-support#cannot-start")!)
				}
			}
		case .started:
			ContentView(route: route)
				#if os(iOS)
					.handleOpenURLInApp()
				#endif
		}
	}
}

private struct ContentView: View {
	private static let currentOnboardingVersion = 1

	@Environment(AppState.self) private var appState
	@AppStorage("onboardingVersionShown") var onboardingVersionShown = 0
	@Environment(\.scenePhase) var scenePhase
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@State private var showCustomConfigWarning = false
	@State private var showOnboarding = false
	@State var route: Route? = .start
	@State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn

	#if os(iOS)
		@State private var showSearchSheet = false
		@State private var searchSheetSearchTerm: String = ""
	#endif

	var tabbedBody: some View {
		TabView(selection: $route) {
			// Me
			NavigationStack {
				StartOrSearchView(route: $route)
			}
			.tabItem {
				Label("Start", systemImage: self.appState.syncState.systemImage)
			}.tag(Route.start)

			// Folders
			NavigationStack {
				FoldersView()
					.toolbar {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								let documentsUrl = FileManager.default.urls(
									for: .documentDirectory, in: .userDomainMask
								).first!
								openURLInSystemFilesApp(url: documentsUrl)
							}
						).labelStyle(.iconOnly)
					}
			}
			.tabItem {
				Label("Folders", systemImage: "folder.fill")
			}.tag(Route.folder(folderID: nil))

			// Peers
			NavigationStack {
				DevicesView()
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
								Label("Start", systemImage: self.appState.syncState.systemImage)
							}

							NavigationLink(value: Route.devices) {
								Label("Devices", systemImage: "externaldrive.fill")
							}
						}
					}

					FoldersSections(userSettings: appState.userSettings)
				}
				#if os(macOS)
					.contextMenu {
						FolderMetricPickerView(userSettings: appState.userSettings)
					}
				#endif
				#if os(iOS)
					.toolbar {
						Button(
							openInFilesAppLabel, systemImage: "arrow.up.forward.app",
							action: {
								let documentsUrl = FileManager.default.urls(
									for: .documentDirectory, in: .userDomainMask
								).first!
								openURLInSystemFilesApp(url: documentsUrl)
							}
						).labelStyle(.iconOnly)
					}
				#endif
			},
			detail: {
				NavigationStack {
					switch self.route {
					case .start:
						StartOrSearchView(route: $route)

					case .devices:
						DevicesView()

					case .folder(let folderID):
						if let folderID = folderID, let folder = self.appState.client.folder(withID: folderID) {
							if folder.exists() {
								BrowserView(folder: folder, prefix: "").id(folderID)
							}
							else {
								ContentUnavailableView(
									"Folder was deleted", systemImage: "trash",
									description: Text("This folder was deleted."))
							}
						}
						else {
							ContentUnavailableView("Select a folder", systemImage: "folder")
								.onTapGesture {
									columnVisibility = .doubleColumn
								}
						}

					case nil:
						ContentUnavailableView("Select a folder", systemImage: "folder")
							.onTapGesture {
								columnVisibility = .doubleColumn
							}
					}
				}
			}
		)
		.navigationSplitViewStyle(.balanced)
	}

	var body: some View {
		Group {
			if horizontalSizeClass == .compact {
				self.tabbedBody
			}
			else {
				self.splitBody
			}
		}
		.sheet(
			isPresented: $showOnboarding,
			content: {
				if #available(iOS 18, *) {
					OnboardingView()
						.interactiveDismissDisabled()
						.presentationSizing(.form.fitted(horizontal: false, vertical: true))
				}
				else {
					OnboardingView()
						.interactiveDismissDisabled()
				}
			}
		)
		#if os(iOS)
			.onChange(of: QuickActionService.shared.action) { _, newAction in
				if case .search(for: let searchFor) = newAction {
					self.route = .start
					self.searchSheetSearchTerm = searchFor
					showSearchSheet = true
					QuickActionService.shared.action = nil
				}
			}
		#endif
		.onChange(of: scenePhase) { oldPhase, newPhase in
			self.appState.onScenePhaseChange(from: oldPhase, to: newPhase)
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
			}
			else {
				self.showOnboardingIfNecessary()
			}
		}
		.onChange(of: showOnboarding) { _, shown in
			if !shown {
				// End of onboarding, request notification authorization
				AppState.requestNotificationPermissionIfNecessary()
			}
		}
		#if os(iOS)
			// Search sheet for quick action
			.sheet(isPresented: $showSearchSheet) {
				NavigationStack {
					SearchView(
						prefix: "",
						initialSearchText: self.searchSheetSearchTerm
					)
					.navigationTitle("Search")
					.navigationBarTitleDisplayMode(.inline)
					.toolbar(content: {
						ToolbarItem(
							placement: .cancellationAction,
							content: {
								Button("Cancel") {
									showSearchSheet = false
								}
							})
					})
				}
			}
		#endif
	}

	private func showOnboardingIfNecessary() {
		Log.info(
			"Current onboarding version is \(Self.currentOnboardingVersion), user last saw \(self.onboardingVersionShown)"
		)
		if onboardingVersionShown < Self.currentOnboardingVersion {
			self.showOnboarding = true
			onboardingVersionShown = Self.currentOnboardingVersion
		}
		else {
			// Go straight on to request notification permissions
			AppState.requestNotificationPermissionIfNecessary()
		}
	}
}

private struct LoadingMainView: View {
	@State var appState: AppState

	var body: some View {
		#if os(iOS)
			// Skeleton of the actual app structure, to make the app launch feel faster
			TabView {
				NavigationStack {
					LoadingView(appState: appState)
				}
				.tabItem {
					Label("Start", systemImage: "ellipsis.circle.fill")
				}

				NavigationStack {
					EmptyView()
				}
				.tabItem {
					Label("Folders", systemImage: "folder.fill")
				}.disabled(true)

				NavigationStack {
					EmptyView()
				}
				.tabItem {
					Label("Devices", systemImage: "externaldrive.fill")
				}.disabled(true)
			}
		#else
			NavigationSplitView(
				sidebar: {
					EmptyView()
				},
				detail: {
					NavigationStack {
						LoadingView(appState: appState)
							.navigationTitle("Start")
							.searchable(text: .constant(""))
					}
				}
			)
			.navigationSplitViewStyle(.balanced)
		#endif
	}
}

private struct LoadingView: View {
	@State var appState: AppState

	var body: some View {
		VStack(spacing: 10) {
			ProgressView().progressViewStyle(.circular)
			if !appState.isMigratedToNewDatabase {
				// We are likely migrating now
				Text(
					"Upgrading the database. This may take a few minutes, depending on how many files you have. Please do not close the app until this is finished."
				)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 320)
			}
		}
		#if os(iOS)
			.onAppear {
				Log.info("Asserting idle timer disable")
				UIApplication.shared.isIdleTimerDisabled = true
			}
			.onDisappear {
				Log.info("Deasserting idle timer disable")
				UIApplication.shared.isIdleTimerDisabled = false
			}
		#endif
	}
}

private struct StartOrSearchView: View {
	@Environment(AppState.self) private var appState
	@Binding var route: Route?
	@State private var searchText: String = ""
	@FocusState private var isSearchFieldFocused

	// This is needed because isSearching is not available from the parent view
	struct InnerView: View {
		@Environment(AppState.self) private var appState
		@Binding var route: Route?
		@Binding var searchText: String
		@Environment(\.isSearching) private var isSearching

		var body: some View {
			if isSearching {
				SearchResultsView(
					userSettings: appState.userSettings,
					searchText: $searchText,
					folderID: .constant(""),
					prefix: .constant("")
				)
			}
			else {
				StartView(route: $route)
			}
		}
	}

	private var view: some View {
		ZStack {
			InnerView(route: $route, searchText: $searchText)
		}
		.searchable(
			text: $searchText, placement: SearchFieldPlacement.toolbar,
			prompt: "Search all files and folders..."
		)
		#if os(iOS)
			.textInputAutocapitalization(.never)
		#endif
		.autocorrectionDisabled()
	}

	var body: some View {
		if #available(iOS 18, *) {
			self.view.searchFocused($isSearchFieldFocused)
		}
		else {
			self.view
		}
	}
}
