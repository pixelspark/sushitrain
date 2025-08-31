// Copyright (C) 2024-2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
import SwiftUI

private struct FeatureView: View {
	var image: String
	var title: String
	var description: String

	var body: some View {
		HStack(alignment: .top, spacing: 15) {
			Image(systemName: image).foregroundColor(.accentColor)
				.font(.system(size: 38, weight: .light))
			VStack(alignment: .leading, spacing: 5) {
				Text(self.title).bold()
				Text(self.description)
			}
		}
	}
}

private struct ExplainView: View {
	var image: String
	var title: String
	var description: String

	var body: some View {
		VStack(alignment: .center, spacing: 15) {
			Image(systemName: image).foregroundColor(.accentColor)
				.font(.system(size: 96.0, weight: .light))
			Text(self.title).bold()
			Text(self.description)
		}
	}
}

private enum OnboardingPage: Int {
	case start = 0
	case explainNoBackup = 1
	case explainResponsibility = 2
	case explainSyncthing = 3
	case finished = 4
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
					.dynamicTypeSize(.medium)
					.bold()
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}

			Text("Before we start, we need to go over a few things.")
				.multilineTextAlignment(.leading)

		case .explainNoBackup:
			ExplainView(
				image: "bolt.horizontal.circle",
				title: String(localized: "Synchronization is not back-up"),
				description: String(
					localized:
						"When you synchronize files, all changes, including deleting files, also happen on your other devices. Do not use Synctrain for back-up purposes, and always keep a back-up of your data."
				))

		case .explainResponsibility:
			ExplainView(
				image: "hand.raised.circle",
				title: String(localized: "Your devices, your data, your responsibility"),
				description: String(
					localized:
						"You decide with which devices you share which files. This also means the app makers cannot help you access or recover any lost files."
				)
			)

		case .explainSyncthing:
			ExplainView(
				image: "gear.circle",
				title: String(localized: "Powered by Syncthing"),
				description: String(
					localized:
						"This app is powered by Syncthing. This app is however not associated with or endorsed by Syncthing nor its developers. Please do not expect support from the Syncthing developers. Instead, contact the maker of this app if you have questions."
				)
			)

		default:
			EmptyView()
		}
	}
}

struct OnboardingView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var page = OnboardingPage.start

	var body: some View {
		#if os(iOS)
			GeometryReader { proxy in
				ScrollView(.vertical) {
					self.contents()
						.frame(minHeight: proxy.size.height)
				}
			}
		#else
			self.contents().padding()
		#endif
	}
	
	@ViewBuilder private func contents() -> some View {
		VStack(spacing: 20) {
			Text(
				"Welcome to Synctrain!"
			)
			.font(.largeTitle.bold())
			.multilineTextAlignment(.center)
			.padding(.top, 20)

			Spacer()
			switch page {
			case .start, .explainNoBackup, .explainResponsibility, .explainSyncthing:
				OnboardingExplainView(page: page).padding(20)

			case .finished:
				EmptyView()
			}
			Spacer()

			Color.blue
				.frame(
					minHeight: 48, maxHeight: 48
				)
				.cornerRadius(9.0)
				.padding(10)
				.overlay(alignment: .center) {
					Text(
						(page.rawValue == OnboardingPage.finished.rawValue - 1) ? "I understand, let's get started!" : "I understand!"
					)
					.bold()
					.foregroundColor(.white)

				}.onTapGesture {
					if page.rawValue < (OnboardingPage.finished.rawValue - 1) {
						withAnimation {
							page = OnboardingPage(rawValue: page.rawValue + 1)!
						}
					}
					else {
						self.dismiss()
					}
				}
		}
	}
}
