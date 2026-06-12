// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Identifiable {
    case voice = "Voice"
    case aprs = "APRS"
    case memories = "Memories"
    case settings = "Settings"
    case firmware = "Firmware"
    case about = "About"

    var id: String { rawValue }

    static let visibleTabs: [AppTab] = [.voice, .aprs, .memories, .settings]

    var symbol: String {
        switch self {
        case .voice: "radio"
        case .aprs: "message"
        case .memories: "list.bullet.rectangle"
        case .settings: "slider.horizontal.3"
        case .firmware: "cpu"
        case .about: "info.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var selectedTab: AppTab

    init(selectedTab: AppTab = Self.launchSelectedTab()) {
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        Group {
            if selectedTab == .about {
                NavigationStack {
                    AboutView()
                        .navigationTitle(AppTab.about.rawValue)
                }
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(AppTab.visibleTabs) { tab in
                        NavigationStack {
                            tabContent(tab)
                                .navigationTitle(tab.rawValue)
                        }
                        .tabItem { Label(tab.rawValue, systemImage: tab.symbol) }
                        .tag(tab)
                    }
                }
                .toolbarBackground(Color(.systemBackground), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .background(KeyboardDismissInstaller())
        .overlay(alignment: .topLeading) {
            RadioActivityPill()
                .padding(.leading, 12)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .voice: VoiceView()
        case .aprs: APRSChatView()
        case .memories: MemoriesView()
        case .settings: SettingsView()
        case .firmware: FirmwareView()
        case .about: AboutView()
        }
    }

    private static func launchSelectedTab() -> AppTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.compactMap({ argument -> String? in
            if argument.hasPrefix("--qa-tab=") {
                return String(argument.dropFirst("--qa-tab=".count))
            }
            return nil
        }).first else {
            return .voice
        }
        return AppTab.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .voice
    }
}

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        KeyboardDismissView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var recognizer: UITapGestureRecognizer?

        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = touch.view else { return true }
            return !view.isTextInputOrAncestor
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    final class KeyboardDismissView: UIView {
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let coordinator else { return }
            if let recognizer = coordinator.recognizer, recognizer.view === window {
                return
            }
            if let recognizer = coordinator.recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            let recognizer = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = coordinator
            window.addGestureRecognizer(recognizer)
            coordinator.recognizer = recognizer
        }
    }
}

private extension UIView {
    var isTextInputOrAncestor: Bool {
        var view: UIView? = self
        while let current = view {
            if current is UITextField || current is UITextView || current is UISearchBar {
                return true
            }
            view = current.superview
        }
        return false
    }
}
