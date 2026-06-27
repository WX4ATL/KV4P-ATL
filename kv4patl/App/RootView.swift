// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AppTab: String, CaseIterable, Identifiable {
    case voice = "Voice"
    case aprs = "APRS"
    case memories = "Memories"
    case settings = "Settings"
    case firmware = "Firmware"
    case about = "About"

    var id: String { rawValue }

    static let visibleTabs: [AppTab] = [.voice, .aprs, .memories, .settings]
    static let macSidebarTabs: [AppTab] = [.voice, .aprs, .memories, .settings, .about]

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
        #if os(macOS)
        macRoot
        #else
        iOSRoot
        #endif
    }

    #if os(iOS)
    private var iOSRoot: some View {
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
                .toolbarBackground(KV4PPlatformStyle.contentBackground, for: .tabBar)
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
    #endif

    #if os(macOS)
    private var macRoot: some View {
        NavigationSplitView {
            List(AppTab.macSidebarTabs, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.symbol)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle("KV4P/ATL")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack {
                tabContent(selectedTab)
                    .navigationTitle(selectedTab.rawValue)
                    .toolbar {
                        ToolbarItem(placement: .status) {
                            RadioActivityPill()
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                app.toggleRadioConnection()
                            } label: {
                                Label(
                                    app.radioIsConnected ? "Disconnect" : "Connect",
                                    systemImage: app.radioIsConnected
                                        ? "antenna.radiowaves.left.and.right.slash"
                                        : "antenna.radiowaves.left.and.right"
                                )
                            }
                            .tint(app.radioIsConnected ? .red : .accentColor)
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(KeyboardDismissInstaller())
    }
    #endif

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

#if os(iOS)
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
#elseif os(macOS)
private struct KeyboardDismissInstaller: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private var eventMonitor: Any?

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func install() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard let window = event.window,
                      let contentView = window.contentView else {
                    return event
                }
                let point = contentView.convert(event.locationInWindow, from: nil)
                if !contentView.hitTest(point).isTextInputOrAncestor {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }
    }
}

private extension Optional where Wrapped == NSView {
    var isTextInputOrAncestor: Bool {
        var view = self
        while let current = view {
            if current is NSTextField || current is NSTextView {
                return true
            }
            view = current.superview
        }
        return false
    }
}
#endif
