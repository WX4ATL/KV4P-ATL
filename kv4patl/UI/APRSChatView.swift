// SPDX-License-Identifier: GPL-3.0-or-later
import MapKit
import SwiftUI

enum APRSSection: String, CaseIterable {
    case map = "Map"
    case messages = "Messages"
    case beacons = "Beacons"
    case packets = "Packets"
    case settings = "Settings"
}

struct APRSChatView: View {
    @EnvironmentObject private var app: AppState
    @State private var recipient = APRSService.defaultRecipient
    @State private var message = ""
    @State private var section: APRSSection
    @State private var mapPosition = MapCameraPosition.automatic
    @FocusState private var focusedComposerField: ComposerField?

    init(section: APRSSection = Self.launchSection()) {
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker

            ScrollView {
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
                    case .settings:
                        aprsSettingsPanel
                    }
                }
                .padding()
                .frame(maxWidth: KV4PTheme.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private var sectionPicker: some View {
        Picker("APRS", selection: $section) {
            ForEach(APRSSection.allCases, id: \.self) { section in
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
            .frame(height: 280)
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
            app.messages.filter { $0.type == .position || $0.type == .weather || $0.type == .object },
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

    private var aprsSettingsPanel: some View {
        KV4PCard("APRS Settings", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Your callsign", text: $app.settings.callsign)
                    .textInputAutocapitalization(.characters)
                    .textFieldStyle(.roundedBorder)

                Toggle("Beacon my position", isOn: $app.settings.beaconPosition)
                    .onChange(of: app.settings.beaconPosition) { _, enabled in
                        app.saveSettings()
                        if enabled { app.preparePositionBeaconing() }
                    }

                Toggle("Automatic location beacons", isOn: $app.settings.autoBeaconEnabled)

                DurationInputRow(
                    title: "Beacon interval",
                    seconds: $app.settings.beaconIntervalSeconds,
                    allowedRange: 60...86_400,
                    defaultUnit: .minutes
                )

                TextField("Beacon status comment", text: $app.settings.aprsStatusComment)
                    .textFieldStyle(.roundedBorder)

                Picker("Beacon frequency", selection: $app.settings.beaconFrequency) {
                    Text("Current frequency").tag("Current")
                    Text("144.3900").tag("144.3900")
                    Text("144.5750").tag("144.5750")
                    Text("144.8000").tag("144.8000")
                    Text("145.8250").tag("145.8250")
                }

                Picker("Position accuracy", selection: $app.settings.aprsAccuracy) {
                    Text("Exact").tag("Exact")
                    Text("Approx").tag("Approx")
                }
                .pickerStyle(.segmented)

                Picker("Map icon", selection: $app.settings.aprsIcon) {
                    Text("Phone").tag("Phone")
                    Text("Person").tag("Person")
                    Text("House").tag("House")
                    Text("Car").tag("Car")
                }

                Toggle("Digipeat packets", isOn: $app.settings.digipeatPackets)
                Toggle("Expose standard BLE KISS TNC", isOn: $app.settings.exposeKISSTNC)
                if app.settings.exposeKISSTNC {
                    Text("KV4P/ATL must disconnect from the radio before another APRS app can see the BLE KISS TNC. If KV4P/ATL reconnects while another app is using the radio, one app may be disconnected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: app.settings) { _, _ in
                app.saveSettings()
            }
        }
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

    private var composer: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    recipientField
                        .frame(maxWidth: 132)
                    messageField
                    sendButton
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        recipientField
                        sendButton
                    }
                    messageField
                }
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
            .textInputAutocapitalization(.characters)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.next)
            .focused($focusedComposerField, equals: .recipient)
            .onSubmit {
                focusedComposerField = .message
            }
    }

    private var messageField: some View {
        TextField("Message", text: $message, axis: .vertical)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.send)
            .focused($focusedComposerField, equals: .message)
            .onSubmit(sendMessage)
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
        .accessibilityLabel("Send APRS message")
    }

    private func sendMessage() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            focusedComposerField = nil
            return
        }
        app.sendAPRSMessage(to: recipient, body: trimmed)
        message.removeAll()
        focusedComposerField = nil
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
        return APRSSection.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame } ?? .map
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
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.body)
                .font(.body)
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
        case .weather: "cloud.sun"
        case .object: "diamond"
        case .item: "smallcircle.filled.circle"
        case .status: "text.bubble"
        case .telemetry: "waveform.path.ecg"
        case .query: "questionmark.circle"
        case .thirdParty: "arrow.triangle.branch"
        case .capability: "checklist"
        case .raw: "doc.plaintext"
        }
    }
}
