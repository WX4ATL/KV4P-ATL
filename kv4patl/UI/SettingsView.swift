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
                Picker("Bandwidth", selection: $app.settings.bandwidth) {
                    Text("25kHz").tag("25kHz")
                    Text("12.5kHz").tag("12.5kHz")
                }
                Stepper("Squelch \(app.settings.squelch)", value: $app.settings.squelch, in: 0...100)
                Picker("RX audio boost", selection: $app.settings.rxAudioBoost) {
                    Text("Low").tag("Low")
                    Text("Normal").tag("Normal")
                    Text("High").tag("High")
                }
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
                Toggle("Beacon my position", isOn: $app.settings.beaconPosition)
                    .onChange(of: app.settings.beaconPosition) { _, enabled in
                        app.saveSettings()
                        if enabled {
                            app.preparePositionBeaconing()
                        }
                    }
                Toggle("Automatic beacons", isOn: $app.settings.autoBeaconEnabled)
                DurationInputRow(
                    title: "Beacon interval",
                    seconds: $app.settings.beaconIntervalSeconds,
                    allowedRange: 60...86_400,
                    defaultUnit: .minutes
                )
                TextField("Custom beacon status comment", text: $app.settings.aprsStatusComment)
                    .textInputAutocapitalization(.sentences)
                Picker("Beacon to frequency", selection: $app.settings.beaconFrequency) {
                    Text("Current").tag("Current")
                    Text("144.3900").tag("144.3900")
                    Text("144.5750").tag("144.5750")
                    Text("144.8000").tag("144.8000")
                    Text("145.8250").tag("145.8250")
                }
                .onChange(of: app.settings.beaconFrequency) { _, _ in app.saveSettings() }
                Picker("My position accuracy", selection: $app.settings.aprsAccuracy) {
                    Text("Exact").tag("Exact")
                    Text("Approx").tag("Approx")
                }
                Picker("My position icon", selection: $app.settings.aprsIcon) {
                    Text("Phone").tag("Phone")
                    Text("Person").tag("Person")
                    Text("House").tag("House")
                    Text("Car").tag("Car")
                }
                Toggle("Digipeat (mesh)", isOn: $app.settings.digipeatPackets)
                Toggle("Expose standard BLE KISS TNC", isOn: $app.settings.exposeKISSTNC)
                if app.settings.exposeKISSTNC {
                    Text("KV4P/ATL must disconnect from the radio before the BLE KISS TNC is available to other APRS apps. If KV4P/ATL reconnects while another app is using the radio, one app may be disconnected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("APRS Packet Retention") {
                DurationInputRow(
                    title: "Delete packets older than",
                    seconds: $app.settings.packetRetentionSeconds,
                    allowedRange: 60...604_800,
                    defaultUnit: .hours
                )
            }

            Section("Limits") {
                TextField("Min 2m TX frequency", text: $app.settings.min2mTx)
                    .keyboardType(.decimalPad)
                TextField("Max 2m TX frequency", text: $app.settings.max2mTx)
                    .keyboardType(.decimalPad)
                TextField("Min 70cm TX frequency", text: $app.settings.min70cmTx)
                    .keyboardType(.decimalPad)
                TextField("Max 70cm TX frequency", text: $app.settings.max70cmTx)
                    .keyboardType(.decimalPad)
            }

            Section("Accessibility") {
                Toggle("Disable animations", isOn: $app.settings.disableAnimations)
            }

            Section("Versions") {
                LabeledContent("App version", value: "0.2.0")
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
        .safeAreaPadding(.bottom, 96)
        .onDisappear { app.saveSettings() }
        .onChange(of: app.settings) { _, _ in
            app.saveSettings()
        }
    }

}
