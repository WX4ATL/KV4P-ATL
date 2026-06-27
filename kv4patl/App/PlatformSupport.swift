// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum KV4PPlatformStyle {
    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var contentBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

extension View {
    @ViewBuilder
    func kv4pDecimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func kv4pCharactersCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }

    @ViewBuilder
    func kv4pSentencesCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.sentences)
        #else
        self
        #endif
    }

    @ViewBuilder
    func kv4pInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    static var kv4pPrimaryAction: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}
