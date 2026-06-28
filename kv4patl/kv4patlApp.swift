// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct kv4patlApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        #if os(macOS)
        primaryMacWindow
        #else
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
        #endif
    }

    #if os(macOS)
    private var primaryMacWindow: some Scene {
        WindowGroup("KV4P/ATL", id: "main") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            KV4PMacCommands(appState: appState)
        }
    }
    #endif
}

#if os(macOS)
private struct KV4PMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Radio") {
            Button(appState.radioIsConnected ? "Disconnect Radio" : "Connect Radio") {
                appState.toggleRadioConnection()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
#endif
