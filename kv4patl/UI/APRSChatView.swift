// SPDX-License-Identifier: GPL-3.0-or-later
import MapKit
import SwiftUI

enum APRSSection: String {
    case map = "Map"
    case messages = "Messages"
    case beacons = "Beacons"
    case packets = "Packets"

    static let visibleSections: [APRSSection] = [.map, .messages, .beacons, .packets]
}

struct APRSChatView: View {
    @EnvironmentObject private var app: AppState
    @State private var recipient = APRSService.defaultRecipient
    @State private var message = ""
    @State private var composerNotice = ""
    @State private var sendInProgress = false
    @State private var section: APRSSection
    @State private var mapPosition = MapCameraPosition.automatic
    @FocusState private var focusedComposerField: ComposerField?

    init(section: APRSSection = Self.launchSection()) {
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker

            #if os(macOS)
            macSectionContent
            #else
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch section {
                    case .map:
                        mapPanel
                        beaconList
                    case .messages:
                        messageList
                    case .beacons:
                        beaconList
                    case .packets:
                        packetList
                    }
                }
                .padding()
                .frame(maxWidth: KV4PTheme.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .background(KV4PPlatformStyle.groupedBackground)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macSectionContent: some View {
        if section == .map {
            GeometryReader { proxy in
                macMapContent(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch section {
                    case .messages:
                        messageList
                    case .beacons:
                        beaconList
                    case .packets:
                        packetList
                    case .map:
                        EmptyView()
                    }
                }
                .padding()
                .frame(maxWidth: KV4PTheme.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
        }
    }

    private func macMapContent(width: CGFloat, height: CGFloat) -> some View {
        let mapHeight = max(360, height - 220)
        return HStack(alignment: .top, spacing: 16) {
            mapPanel(mapHeight: mapHeight)
                .frame(minWidth: min(420, width * 0.46), maxWidth: .infinity, alignment: .top)

            ScrollView(.vertical, showsIndicators: true) {
                beaconList
                    .frame(minWidth: min(320, width * 0.36), maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .padding(.bottom, 104)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    #endif

    private var sectionPicker: some View {
        Picker("APRS", selection: $section) {
            ForEach(APRSSection.visibleSections, id: \.self) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var mapPanel: some View {
        mapPanel(mapHeight: 280)
    }

    private func mapPanel(mapHeight: CGFloat) -> some View {
        KV4PCard("Stations", systemImage: "map") {
            HStack {
                KV4PBadge(text: "\(app.aprsStations.count) heard", systemImage: "antenna.radiowaves.left.and.right", tint: .blue)
                Spacer()
            }
            Map(position: $mapPosition) {
                ForEach(app.aprsStations) { station in
                    Annotation(station.callsign, coordinate: station.coordinate) {
                        APRSMapGlyph(symbol: station.symbol)
                    }
                }
            }
            .frame(height: mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var messageList: some View {
        packetRows(
            app.messages.filter { $0.type == .message },
            emptyTitle: "No APRS messages",
            emptySystemImage: "message",
            emptyDescription: "Inbound and outbound APRS messages will appear here."
        )
    }

    private var beaconList: some View {
        packetRows(
            app.messages.filter(isBeaconPacket),
            emptyTitle: "No APRS beacons",
            emptySystemImage: "location",
            emptyDescription: "Position, weather, and object packets will appear here and on the map."
        )
    }

    private var packetList: some View {
        packetRows(
            app.messages,
            emptyTitle: "No APRS packets",
            emptySystemImage: "doc.plaintext",
            emptyDescription: "Every decoded AX.25/APRS packet will appear here."
        )
    }

    private func packetRows(_ messages: [APRSMessage], emptyTitle: String, emptySystemImage: String, emptyDescription: String) -> some View {
        LazyVStack(spacing: 10) {
            if messages.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage, description: Text(emptyDescription))
                    .padding(.vertical, 48)
            }
            ForEach(messages.reversed()) { item in
                APRSMessageRow(message: item, localCallsign: app.settings.callsign)
            }
        }
    }

    private func isBeaconPacket(_ message: APRSMessage) -> Bool {
        if message.latitude != nil && message.longitude != nil { return true }
        switch message.type {
        case .position, .weather, .object, .item, .micE, .gps:
            return true
        default:
            return false
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    recipientField
                        .frame(maxWidth: 132)
                    messageEditor
                    sendButton
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        recipientField
                        sendButton
                    }
                    messageEditor
                }
            }
            if !composerNotice.isEmpty {
                Text(composerNotice)
                    .font(.caption)
                    .foregroundStyle(composerNotice.hasPrefix("Queued") ? Color.gray : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(composerNotice)
            }

            HStack(spacing: 12) {
                Button {
                    focusedComposerField = nil
                    app.sendPositionBeacon()
                } label: {
                    Label("Beacon", systemImage: "location.fill")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 8)

                Toggle("Digipeat", isOn: $app.settings.digipeatPackets)
                    .onChange(of: app.settings.digipeatPackets) { _, _ in app.saveSettings() }
            }
        }
        .padding()
        .frame(maxWidth: KV4PTheme.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var recipientField: some View {
        TextField("To", text: $recipient)
            .kv4pCharactersCapitalization()
            .textFieldStyle(.roundedBorder)
            .submitLabel(.next)
            .focused($focusedComposerField, equals: .recipient)
            .onSubmit {
                focusedComposerField = .message
            }
    }

    private var messageField: some View {
        TextField("Message", text: $message)
            .textFieldStyle(.plain)
            .submitLabel(.send)
            .focused($focusedComposerField, equals: .message)
            .onSubmit(sendMessage)
            .onChange(of: message) { _, newValue in
                let sanitized = APRSService.sanitizedMessageText(newValue)
                if sanitized != newValue {
                    message = sanitized
                } else if !composerNotice.isEmpty {
                    composerNotice.removeAll()
                }
            }
    }

    private var messageEditor: some View {
        HStack(spacing: 8) {
            messageField
            Text("\(message.count)/\(APRSService.maxMessageTextLength)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(message.count == APRSService.maxMessageTextLength ? .orange : .secondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityLabel("\(message.count) of \(APRSService.maxMessageTextLength) APRS message characters used")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.secondary.opacity(0.24), lineWidth: 1)
        }
    }

    private var sendButton: some View {
        Button {
            sendMessage()
        } label: {
            Image(systemName: "paperplane.fill")
                .frame(minWidth: 28)
        }
        .buttonStyle(.borderedProminent)
        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityLabel("Send APRS message")
    }

    private func sendMessage() {
        guard !sendInProgress else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            focusedComposerField = nil
            return
        }
        sendInProgress = true
        defer { sendInProgress = false }
        if app.sendAPRSMessage(to: recipient, body: trimmed) {
            let destination = APRSService.normalizedAddressee(recipient)
            message.removeAll()
            focusedComposerField = nil
            section = .messages
            composerNotice = "Queued APRS message to \(destination)."
        } else {
            let failure = app.statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
            composerNotice = failure.isEmpty ? "APRS message was not queued." : failure
        }
    }

    private enum ComposerField: Hashable {
        case recipient
        case message
    }

    private static func launchSection() -> APRSSection {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.compactMap({ argument -> String? in
            if argument.hasPrefix("--qa-aprs-section=") {
                return String(argument.dropFirst("--qa-aprs-section=".count))
            }
            return nil
        }).first else {
            return .map
        }
        return APRSSection.visibleSections.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .map
    }
}

struct APRSMapGlyph: View {
    var symbol: APRSSymbol?

    var body: some View {
        Image(systemName: symbol?.sfSymbolName ?? "diamond.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(.blue, in: Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.92), lineWidth: 2)
            }
            .shadow(radius: 2, y: 1)
    }
}

struct APRSMessageRow: View {
    var message: APRSMessage
    var localCallsign: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(message.from, systemImage: symbol)
                    .font(.headline)
                if isOutgoing {
                    Text("TX")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                }
                APRSDeliveryBadge(
                    state: message.deliveryState,
                    retriesRemaining: message.retriesRemaining
                )
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !message.body.isEmpty {
                Text(message.body)
                    .font(.body)
            }
            if !message.dataPoints.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array(message.dataPoints.enumerated()), id: \.offset) { _, point in
                        APRSDataPointChip(point: point)
                    }
                }
                .padding(.top, 2)
            }
            HStack {
                Text("to \(message.to)")
                if let relay = message.relay {
                    Text("via \(relay)")
                }
                if let lat = message.latitude, let lon = message.longitude {
                    Text(String(format: "%.4f, %.4f", lat, lon))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isOutgoing: Bool {
        !localCallsign.isEmpty && message.from.uppercased() == localCallsign.uppercased()
    }

    private var symbol: String {
        switch message.type {
        case .message: "message"
        case .position: "mappin.and.ellipse"
        case .micE: "location.north.line"
        case .weather: "cloud.sun"
        case .object: "diamond"
        case .item: "smallcircle.filled.circle"
        case .status: "text.bubble"
        case .telemetry: "waveform.path.ecg"
        case .query: "questionmark.circle"
        case .thirdParty: "arrow.triangle.branch"
        case .capability: "checklist"
        case .userDefined: "curlybraces"
        case .gps: "location.viewfinder"
        case .directionFinding: "antenna.radiowaves.left.and.right"
        case .invalid: "exclamationmark.triangle"
        case .raw: "doc.plaintext"
        }
    }
}

struct APRSDeliveryBadge: View {
    var state: APRSDeliveryState
    var retriesRemaining: Int?

    var body: some View {
        if state != .none {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                badgeContent
                    .font(.caption2.bold())
                    .foregroundStyle(foregroundColor)
            }
            .frame(width: 23, height: 23)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .help(accessibilityText)
        }
    }

    @ViewBuilder
    private var badgeContent: some View {
        switch state {
        case .pending:
            Text("\(retriesRemaining ?? 0)")
                .monospacedDigit()
        case .acknowledged:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "questionmark")
        case .acknowledgementSent:
            Image(systemName: "arrow.up")
        case .none:
            EmptyView()
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .pending: .yellow
        case .acknowledged: .green
        case .failed: .red
        case .acknowledgementSent: .blue
        case .none: .clear
        }
    }

    private var foregroundColor: Color {
        state == .pending ? .black : .white
    }

    private var accessibilityText: String {
        switch state {
        case .pending:
            "Waiting for APRS acknowledgement, \(retriesRemaining ?? 0) retries remaining"
        case .acknowledged:
            "APRS message acknowledged"
        case .failed:
            "APRS message was not acknowledged"
        case .acknowledgementSent:
            "Acknowledgement sent for received APRS message"
        case .none:
            ""
        }
    }
}

struct APRSDataPointChip: View {
    var point: APRSDataPoint

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: point.systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(point.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(point.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(tintColor)
        .background(tintColor.opacity(0.14), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tintColor.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(point.label): \(point.value)")
    }

    private var tintColor: Color {
        switch point.tint {
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        case "teal": .teal
        case "cyan": .cyan
        case "yellow": .yellow
        case "red": .red
        default: .blue
        }
    }
}
