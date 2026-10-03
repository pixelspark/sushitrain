// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI
@preconcurrency import SushitrainCore

private struct ChoiceView: View {
	var image: String
	var title: Text
	var description: Text
	let isSelected: Bool

	var body: some View {
		VStack {
			HStack(alignment: .top, spacing: 15) {
				Image(systemName: image).foregroundColor(isSelected ? Color.white : .accentColor)
					.font(.system(size: 38, weight: .light))

				VStack(alignment: .leading, spacing: 5) {
					self.title.font(.headline)
						.foregroundColor(isSelected ? Color.white : Color.primary)
						.fixedSize(horizontal: false, vertical: true)
						.multilineTextAlignment(.leading)

					self.description
						.font(.footnote)
						.foregroundColor(isSelected ? Color.white : Color.secondary)
						.fixedSize(horizontal: false, vertical: true)
						.multilineTextAlignment(.leading)
				}
			}.padding()
		}
		.background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.075))
		.clipShape(.rect(cornerRadius: 10))
	}
}

private struct ExplainView: View {
	var image: String?
	var title: Text
	var description: Text

	var body: some View {
		VStack(alignment: .center, spacing: 15) {
			if let image = self.image {
				Image(systemName: image).foregroundColor(.accentColor)
					.font(.system(size: 96.0, weight: .light))
			}
			self.title.font(.headline).fixedSize(horizontal: false, vertical: true)
			self.description.fixedSize(horizontal: false, vertical: true)
		}
	}
}

private enum OnboardingPage: Int {
	case start = 0
	case explainNoBackup = 1
	case explainResponsibility = 2
	case explainSyncthing = 3
	case privacyChoices = 4
	case finished = 5
}

private struct OnboardingExplainView: View {
	let page: OnboardingPage

	var body: some View {
		switch page {
		case .start:
			HStack {
				Spacer()
				Image("Logo")
				Spacer()
			}

			HStack(alignment: .center) {
				Text("Synchronize your files securely with your other devices.")
					.font(.headline)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}

			Text("Before we start, we need to go over a few things.")
				.fixedSize(horizontal: false, vertical: true)
				.multilineTextAlignment(.leading)

		case .explainNoBackup:
			ExplainView(
				image: "bolt.horizontal.circle",
				title: Text("Synchronization is not back-up"),
				description:
					Text(
						"When you synchronize files, all changes, including deleting files, also happen on your other devices. Do not use Synctrain for back-up purposes, and always keep a back-up of your data."
					)
			)

		case .explainResponsibility:
			ExplainView(
				image: "hand.raised.circle",
				title: Text("Your devices, your data, your responsibility"),
				description: Text(
					"You decide with which devices you share which files. This also means the app makers cannot help you access or recover any lost files."
				)
			)

		case .explainSyncthing:
			ExplainView(
				image: "gear.circle",
				title: Text("Powered by Syncthing"),
				description: Text(
					"This app is powered by Syncthing. This app is however not associated with or endorsed by Syncthing nor its developers. Please do not expect support from the Syncthing developers. Instead, contact the maker of this app if you have questions."
				)
			)

		default:
			EmptyView()
		}
	}
}

private enum PrivacyChoice {
	case useSyncthingServices
	case doNotUseSyncthingServices
	case noChoice
}

private struct PrivacyChoicesView: View {
	let page: OnboardingPage
	@Binding var choice: PrivacyChoice

	var body: some View {
		switch page {
		case .privacyChoices:
			ExplainView(
				image: nil,
				title: Text("Do you want to use Syncthing services?"),
				description: Text(
					"Synctrain can be configured to use services provided by the [Syncthing Foundation](https://syncthing.net/foundation) to be able to find and connect to other devices. When this is enabled, Synctrain will send your device ID and IP addresses to these services."
				)
			).padding(20)

			ChoiceView(
				image: "square.stack.3d.up.fill", title: Text("Use Syncthing services"),
				description:
					Text(
						"Synctrain will be able to automatically find and connect other devices on your local network as well as the internet, as long as the other devices are also configured to use Syncthing services."
					),
				isSelected: choice == .useSyncthingServices
			)
			.onTapGesture {
				choice = .useSyncthingServices
			}

			ChoiceView(
				image: "square.stack.3d.up.slash.fill", title: Text("Do not use Syncthing services"),
				description:
					Text(
						"Synctrain will be able to find and connect to other devices on your local network, but until you manually configure device addresses, discovery, STUN and/or relaying servers, it will not be able to find and connect to other devices over the internet."
					),
				isSelected: choice == .doNotUseSyncthingServices
			)
			.onTapGesture {
				choice = .doNotUseSyncthingServices
			}

		default:
			EmptyView()
		}
	}
}

private struct NextButton: View {
	let label: String

	var body: some View {
		Color.accentColor
			.frame(minHeight: 48, maxHeight: 48)
			.cornerRadius(10)
			.padding()
			.overlay(alignment: .center) {
				Text(self.label)
					.bold()
					.foregroundColor(.white)
			}
	}
}

struct OnboardingView: View {
	@Environment(AppState.self) private var appState
	@Environment(\.dismiss) private var dismiss
	@State private var page = OnboardingPage.start
	@State private var privacyChoice: PrivacyChoice = .noChoice

	let allowSkip: Bool  // Whether to allow skipping certain items, i.e. when the onboarding is not shown the first time

	var body: some View {
		GeometryReader { proxy in
			ScrollViewReader { reader in
				ScrollView(.vertical) {
					HStack {
						Spacer()
						self.contents(reader)
							.frame(maxWidth: 600, minHeight: proxy.size.height)
						Spacer()
					}
				}
			}
		}
	}

	@ViewBuilder private func contents(_ scrollViewProxy: ScrollViewProxy) -> some View {
		VStack(spacing: 20) {
			if page == .start {
				Text(
					"Welcome to Synctrain!"
				)
				.font(.title)
				.multilineTextAlignment(.center)
				.padding(.top, 20)
				.transition(.opacity)
			}

			Spacer()
			switch page {
			case .start, .explainNoBackup, .explainResponsibility, .explainSyncthing:
				OnboardingExplainView(page: page)
					.transition(.push(from: .trailing))
					.onTapGesture {
						// Scroll to the 'next' button when the user taps this (it may not be immediately obvious where
						// the 'next' button is when people have very large text sizes)
						withAnimation {
							scrollViewProxy.scrollTo("next", anchor: .bottom)
						}
					}

			case .privacyChoices:
				PrivacyChoicesView(page: page, choice: $privacyChoice)
					.transition(.push(from: .trailing))
					.onChange(of: privacyChoice) { _, _ in
						// Scroll to the 'next' button when a privacy choice is selected
						withAnimation {
							scrollViewProxy.scrollTo("next", anchor: .bottom)
						}
					}

			case .finished:
				HStack {
					Spacer()
					ProgressView().controlSize(.large)
					Spacer()
				}
			}

			Spacer()

			if page != .finished {
				NextButton(
					label: (page.rawValue == OnboardingPage.finished.rawValue - 1)
						? String(localized: "Let's get started!")
						: String(localized: "I understand!")
				)
				.id("next")
				.disabled(!canProceed)
				.opacity(canProceed ? 1.0 : 0.5)
				.onTapGesture {
					if canProceed && page.rawValue < (OnboardingPage.finished.rawValue - 1) {
						withAnimation {
							page = OnboardingPage(rawValue: page.rawValue + 1)!
							scrollViewProxy.scrollTo("contents", anchor: .top)
						}
					}
					else {
						page = .finished
						self.finish()
					}
				}
			}
		}
		.padding(.horizontal, 20)
		.id("contents")
	}

	private func finish() {
		// Apply privacy choice
		switch self.privacyChoice {
		case .useSyncthingServices:
			try! self.appState.client.setGlobalAnnounceEnabled(true)
			try! self.appState.client.setSTUNEnabled(true)
			try! self.appState.client.setRelaysEnabled(true)
			try! self.appState.client.setNATEnabled(true)
			try! self.appState.client.setAnnounceLANAddresses(true)

			// The 'default' value equals tcp://0.0.0.0:22000, quic://0.0.0.0:22000 and dynamic+https://relays.syncthing.net/endpoint
			// See https://docs.syncthing.net/users/config.html#listen-addresses
			try! self.appState.client.setListenAddresses(SushitrainListOfStrings.from(["default"]))
			appState.userSettings.appliedOnboardingPrivacyChoicesAt = Date.timeIntervalSinceReferenceDate

		case .doNotUseSyncthingServices:
			try! self.appState.client.setGlobalAnnounceEnabled(false)
			try! self.appState.client.setSTUNEnabled(false)
			try! self.appState.client.setRelaysEnabled(false)
			try! self.appState.client.setNATEnabled(false)
			try! self.appState.client.setAnnounceLANAddresses(false)

			// The 'default' value equals tcp://0.0.0.0:22000, quic://0.0.0.0:22000 and dynamic+https://relays.syncthing.net/endpoint
			// See https://docs.syncthing.net/users/config.html#listen-addresses
			// Therefore we set (only) tcp://0.0.0.0:22000, quic://0.0.0.0:22000 here to disable joining relays.
			try! self.appState.client.setListenAddresses(
				SushitrainListOfStrings.from(["tcp://0.0.0.0:22000", "quic://0.0.0.0:22000"]))
			appState.userSettings.appliedOnboardingPrivacyChoicesAt = Date.timeIntervalSinceReferenceDate

		case .noChoice:
			// Change nothing
			break
		}

		if self.appState.startupState == .onboarding {
			// Continue app startup!
			Task {
				await self.appState.start()
			}
		}
		else {
			// We are a sheet, see ourselves out
			self.dismiss()
		}
	}

	private var canProceed: Bool {
		switch self.page {
		case .privacyChoices:
			return self.allowSkip || self.privacyChoice != .noChoice
		case .start, .explainNoBackup, .explainResponsibility, .explainSyncthing:
			return true
		case .finished:
			return false
		}
	}
}
