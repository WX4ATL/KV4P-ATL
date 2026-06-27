// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct kv4patlApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 620)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandMenu("Radio") {
                Button(appState.radioIsConnected ? "Disconnect Radio" : "Connect Radio") {
                    appState.toggleRadioConnection()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}
