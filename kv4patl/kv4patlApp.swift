// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct kv4patlApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}

