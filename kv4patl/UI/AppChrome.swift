// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum KV4PTheme {
    #if os(macOS)
    static let maxContentWidth: CGFloat = 1040
    #else
    static let maxContentWidth: CGFloat = 720
    #endif
    static let cardRadius: CGFloat = 8
    static let screenSpacing: CGFloat = 16
    static let bottomPadding: CGFloat = 104
}

struct KV4PScreen<Content: View>: View {
    var bottomPadding: CGFloat = KV4PTheme.bottomPadding
    private let content: Content

    init(bottomPadding: CGFloat = KV4PTheme.bottomPadding, @ViewBuilder content: () -> Content) {
        self.bottomPadding = bottomPadding
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KV4PTheme.screenSpacing) {
                content
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .frame(maxWidth: KV4PTheme.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaPadding(.bottom, bottomPadding)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .background(KV4PPlatformStyle.groupedBackground)
    }
}

struct KV4PCard<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let content: Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: KV4PTheme.cardRadius))
    }
}

struct RadioStatusBanner: View {
    @EnvironmentObject private var app: AppState
    var showsConnectButton = true

    var body: some View {
        KV4PCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: connectionSymbol)
                        .font(.title3)
                        .foregroundStyle(connectionColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.headline)
                        if shouldShowStatusLine {
                            Text(app.statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if showsConnectButton {
                        Button {
                            app.toggleRadioConnection()
                        } label: {
                            Text(isConnected ? "Disconnect" : "Connect")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(minWidth: 104)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isConnected ? .red : .blue)
                        .controlSize(.regular)
                    }
                }

                if !app.codecNotice.isEmpty && !isConnected {
                    Label(app.codecNotice, systemImage: "waveform.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = app.transportState { return true }
        return false
    }

    private var shouldShowStatusLine: Bool {
        !isConnected && !app.statusLine.isEmpty && app.statusLine != statusTitle
    }

    private var statusTitle: String {
        switch app.transportState {
        case .connected: "Radio connected"
        case .connecting: "Connecting"
        case .scanning: "Scanning"
        case .failed: "Connection needs attention"
        case .disconnected: "Radio disconnected"
        case .idle: "Radio disconnected"
        }
    }

    private var connectionSymbol: String {
        switch app.transportState {
        case .connected: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .connecting, .scanning: "antenna.radiowaves.left.and.right"
        case .disconnected, .idle: "radio"
        }
    }

    private var connectionColor: Color {
        switch app.transportState {
        case .connected: .green
        case .failed: .red
        case .connecting, .scanning: .blue
        case .disconnected, .idle: .secondary
        }
    }
}

struct RadioActivityPill: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Text(app.radioActivityLabel)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(minWidth: 46)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(activityColor, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            .accessibilityLabel("Radio state \(app.radioActivityLabel)")
    }

    private var activityColor: Color {
        switch app.radioActivityLabel {
        case "TX": .red
        case "RX": .green
        default: .gray
        }
    }
}

struct KV4PBadge: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
