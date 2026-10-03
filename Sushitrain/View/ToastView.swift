// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

// Inspired by https://gist.github.com/azamsharp/debc9c77feaf98f6150f8821ff0fc8be
// and https://github.com/jordansinger/swiftui-ios-toast-notification
import SwiftUI

/// To show a toast:
/// - Have a host view with the .showsToast() view modifier
/// - In any child view: @Environment(\.showToast) private var showToast, self.showToast(Toast(title: "Hello world!"))
extension View {
	func showsToast() -> some View {
		modifier(ToastModifier())
	}
}

/// Contents of the toast to display
struct Toast {
	enum Anchor {
		case top
		case bottom
	}

	let title: LocalizedStringKey
	var image: String? = nil
	var subtitle: LocalizedStringKey? = nil
	var anchor: Anchor = .bottom
}

struct ShowToastAction {
	typealias Action = (Toast) -> Void
	let action: Action

	func callAsFunction(_ toast: Toast) {
		action(toast)
	}
}

extension EnvironmentValues {
	@Entry var showToast = ShowToastAction(action: { _ in })
}

private struct ToastModifier: ViewModifier {
	@State private var toast: Toast? = nil
	@State private var anchor: Toast.Anchor = .bottom
	@State private var dismissTask: DispatchWorkItem?

	func body(content: Content) -> some View {
		content
			.environment(
				\.showToast,
				ShowToastAction(action: { toast in
					dismissTask?.cancel()
					withAnimation(.easeInOut) {
						self.anchor = toast.anchor
						self.toast = toast
						self.dismissTask = DispatchWorkItem {
							withAnimation(.easeInOut) {
								self.toast = nil
							}
						}
						DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: self.dismissTask!)
					}
				})
			)
			.overlay(alignment: anchor == .bottom ? .bottom : .top) {
				if let toast = self.toast {
					GlassyToastView(toast: toast)
						.transition(.move(edge: anchor == .top ? .top : .bottom).combined(with: .opacity))
						.padding(anchor == .top ? .top : .bottom, 10)
						.onTapGesture {
							self.dismiss()
						}
				}
			}
	}

	private func dismiss() {
		self.dismissTask?.cancel()
		self.dismissTask = nil
		withAnimation(.easeInOut) {
			self.toast = nil
		}
	}
}

private struct GlassyToastView: View {
	let toast: Toast

	@Environment(\.colorScheme) var colorScheme

	var body: some View {
		if #available(iOS 26, macOS 26, *) {
			ToastView(toast: toast).glassEffect()
		}
		else {
			#if os(iOS)
				ToastView(toast: toast)
					.shadow(color: Color(Color.black.opacity(0.08)), radius: 8, x: 0, y: 4)
					.background(Color(colorScheme == .dark ? UIColor.secondarySystemBackground : UIColor.systemBackground))
			#else
				ToastView(toast: toast)
					.shadow(color: Color(Color.black.opacity(0.08)), radius: 8, x: 0, y: 4)
					.background(Color(NSColor.windowBackgroundColor))
			#endif
		}
	}
}

private struct ToastView: View {
	let toast: Toast

	var body: some View {
		HStack(spacing: 16) {
			if let image = self.toast.image {
				Image(systemName: image)
					.resizable()
					.scaledToFit()
					.frame(width: 28, height: 28)
			}

			VStack(alignment: .leading) {
				Text(self.toast.title)
					.lineLimit(1)
					.font(.headline)

				if let subtitle = self.toast.subtitle {
					Text(subtitle)
						.lineLimit(1)
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
			}
			.padding(self.toast.image == nil ? .horizontal : .trailing)
		}
		.padding(.horizontal)
		.frame(height: 56)
		.cornerRadius(28)
	}
}
