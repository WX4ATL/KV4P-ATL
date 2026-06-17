// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section("Radio Connection") {
                RadioStatusBanner()
                Toggle("Auto connect on app startup", isOn: $app.settings.autoConnectOnStartup)
            }

            Section("Radio") {
                Toggle("Sticky PTT", isOn: $app.settings.stickyPTT)
                    .onChange(of: app.settings.stickyPTT) { _, isSticky in
                        if !isSticky, app.isTransmitting {
                            app.endTransmit()
                        }
                }
                Toggle("High power", isOn: $app.settings.highPower)
                Toggle("RX power save", isOn: $app.settings.rxPowerSaveEnabled)
                if app.settings.rxPowerSaveEnabled {
                    Picker("Power save profile", selection: $app.settings.rxPowerSaveProfile) {
                        Text("Balanced").tag("Balanced")
                        Text("Maximum").tag("Maximum")
                    }
                }
                Picker("Bandwidth", selection: $app.settings.bandwidth) {
                    Text("25kHz").tag("25kHz")
                    Text("12.5kHz").tag("12.5kHz")
                }
                Stepper("Squelch \(app.settings.squelch)", value: $app.settings.squelch, in: 0...100)
                Picker("Mic gain boost", selection: $app.settings.micGainBoost) {
                    Text("Low").tag("Low")
                    Text("Normal").tag("Normal")
                    Text("High").tag("High")
                }
            }

            Section("Audio Filters") {
                Toggle("Pre- and de-emphasis", isOn: $app.settings.filterPre)
                Toggle("Highpass", isOn: $app.settings.filterHigh)
                Toggle("Lowpass", isOn: $app.settings.filterLow)
            }

            Section("APRS") {
                TextField("Your callsign", text: $app.settings.callsign)
                    .textInputAutocapitalization(.characters)

                VStack(alignment: .leading, spacing: 12) {
                    aprsSubheader("Location beacons")
                    Toggle("Beacon my position", isOn: $app.settings.beaconPosition)
                        .onChange(of: app.settings.beaconPosition) { _, enabled in
                            app.saveSettings()
                            if enabled {
                                app.preparePositionBeaconing()
                            }
                        }
                    Toggle("Automatic beacons", isOn: $app.settings.autoBeaconEnabled)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    aprsSubheader("Location accuracy")
                    Picker("Location accuracy", selection: $app.settings.aprsAccuracy) {
                        Text("Exact").tag("Exact")
                        Text("Approximate").tag("Approx")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 4)

                DurationInputRow(
                    title: "Beacon interval",
                    seconds: $app.settings.beaconIntervalSeconds,
                    allowedRange: 60...86_400,
                    defaultUnit: .minutes
                )

                VStack(alignment: .leading, spacing: 6) {
                    aprsSubheader("Beacon status comment")
                    TextField("Type your own status", text: $app.settings.aprsStatusComment)
                        .textInputAutocapitalization(.sentences)
                }
                .padding(.vertical, 4)

                Picker("APRS frequency", selection: $app.settings.beaconFrequency) {
                    Text("Current").tag("Current")
                    Text("144.3900").tag("144.3900")
                    Text("144.5750").tag("144.5750")
                    Text("144.8000").tag("144.8000")
                    Text("145.8250").tag("145.8250")
                }
                .onChange(of: app.settings.beaconFrequency) { _, _ in app.saveSettings() }
                Picker("APRS icon", selection: $app.settings.aprsIcon) {
                    Text("Phone").tag("Phone")
                    Text("Person").tag("Person")
                    Text("House").tag("House")
                    Text("Car").tag("Car")
                }
                Toggle("Mute RX audio on APRS frequency", isOn: $app.settings.aprsRxMuteEnabled)
                Text("When the radio is tuned to the selected APRS frequency, the iPhone speaker stays muted while APRS decode and packet logging continue in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Digipeat (mesh)", isOn: $app.settings.digipeatPackets)
                Toggle("Expose standard BLE KISS TNC", isOn: $app.settings.exposeKISSTNC)
                if app.settings.exposeKISSTNC {
                    Text("KV4P/ATL must disconnect from the radio before the BLE KISS TNC is available to other APRS apps. If KV4P/ATL reconnects while another app is using the radio, one app may be disconnected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    aprsSubheader("APRS packet retention")
                    DurationInputRow(
                        title: "Delete packets older than",
                        seconds: $app.settings.packetRetentionSeconds,
                        allowedRange: 60...604_800,
                        defaultUnit: .hours
                    )
                }
                .padding(.vertical, 4)
            }

            Section("Limits") {
                LabeledContent("Detected module", value: app.radioModuleSummary)
                if let moduleType = app.detectedRfModuleType {
                    txLimitFields(for: moduleType)
                    if let effectiveRange = app.effectiveTXRange(for: moduleType) {
                        Text("Effective TX range: \(frequencyRangeText(effectiveRange)) MHz.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Connect the radio to expose only the installed SA818 module band.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    txLimitFields(for: .vhf)
                    txLimitFields(for: .uhf)
                }
            }

            Section("Accessibility") {
                Toggle("Disable animations", isOn: $app.settings.disableAnimations)
            }

            Section("Versions") {
                LabeledContent("App version", value: "0.2.14")
                LabeledContent("Firmware version", value: app.firmwareVersion.map { "\($0.version)" } ?? "unknown")
            }

            Section("Debug") {
                LabeledContent("Radio", value: app.statusLine)
                if !app.codecNotice.isEmpty {
                    LabeledContent("Codec", value: app.codecNotice)
                }
                if !app.lastDebugLine.isEmpty {
                    Text(app.lastDebugLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let stats = app.afskStats {
                    LabeledContent("AFSK detector", value: stats.bell202CandidateActive ? "Bell 202 candidate" : "idle")
                    LabeledContent("AFSK level", value: String(format: "rms %u, peak %u, gain %.1fx", stats.rmsLevel, stats.peakLevel, stats.afskGain))
                    if let step = stats.bell202StepDb, let floor = stats.bell202FloorDb {
                        LabeledContent("Bell 202 step", value: String(format: "%.1f dB over floor %.1f dB", step, floor))
                    }
                    if let mark = stats.bell202MarkLevel, let space = stats.bell202SpaceLevel {
                        LabeledContent("Bell 202 tones", value: "1200 \(mark), 2200 \(space)")
                    }
                    if let candidateCount = stats.bell202CandidateCount {
                        LabeledContent("Bell 202 candidates", value: "\(candidateCount)")
                    }
                    LabeledContent("AFSK clips", value: "\(stats.clipCount)")
                    LabeledContent("AFSK decoded", value: "\(stats.crcSuccesses)")
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                        .navigationTitle("About")
                } label: {
                    Label("About & Sources", systemImage: "info.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: KV4PTheme.bottomPadding)
                .allowsHitTesting(false)
        }
        .onDisappear { app.saveSettings() }
        .onChange(of: app.settings) { _, _ in
            app.saveSettings()
        }
    }

    private func aprsSubheader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func txLimitFields(for moduleType: RfModuleType) -> some View {
        switch moduleType {
        case .vhf:
            TextField("Min 2m TX frequency", text: $app.settings.min2mTx)
                .keyboardType(.decimalPad)
            TextField("Max 2m TX frequency", text: $app.settings.max2mTx)
                .keyboardType(.decimalPad)
        case .uhf:
            TextField("Min 70cm TX frequency", text: $app.settings.min70cmTx)
                .keyboardType(.decimalPad)
            TextField("Max 70cm TX frequency", text: $app.settings.max70cmTx)
                .keyboardType(.decimalPad)
        }
    }

    private func frequencyRangeText(_ range: RadioFrequencyRange) -> String {
        "\(AppState.formatFrequency(range.lowerMHz))-\(AppState.formatFrequency(range.upperMHz))"
    }

}
