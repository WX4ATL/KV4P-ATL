// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FirmwareView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        KV4PScreen {
            firmwareStatus
            flashSequence
            Button {
                app.connect()
            } label: {
                Label("Scan for BLE bridge", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var firmwareStatus: some View {
        KV4PCard("Bridge", systemImage: "cpu") {
            VStack(spacing: 10) {
                LabeledContent("Firmware", value: app.firmwareVersion.map { "\($0.version)" } ?? "Unknown")
                LabeledContent("RF module", value: app.firmwareVersion?.moduleType == .uhf ? "UHF" : "VHF")
                LabeledContent("Radio", value: radioStatus)
                LabeledContent("Transport", value: "BLE UART / KISS")
            }
        }
    }

    private var flashSequence: some View {
        KV4PCard("Flash", systemImage: "bolt.horizontal") {
            VStack(alignment: .leading, spacing: 10) {
                flashStep("1", "Connect KV4P HT to this Mac.")
                flashStep("2", "Open the KV4P browser flasher or PlatformIO.")
                flashStep("3", "Flash the KV4P firmware plus the BLE bridge module.")
                flashStep("4", "Power the radio from iPhone USB-C or external 5V.")
                flashStep("5", "Tap Connect in the app.")
            }
        }
    }

    private func flashStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())
            Text(text)
                .foregroundStyle(.primary)
        }
    }

    private var radioStatus: String {
        switch app.firmwareVersion?.radioStatus {
        case .found: "found"
        case .notFound: "not found"
        case .unknown, nil: "unknown"
        }
    }
}
