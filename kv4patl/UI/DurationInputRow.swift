// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum KV4PDurationUnit: String, CaseIterable, Identifiable {
    case minutes = "Minutes"
    case hours = "Hours"
    case days = "Days"

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        }
    }
}

struct DurationInputRow: View {
    let title: String
    @Binding var seconds: Double
    let allowedRange: ClosedRange<Double>
    let defaultUnit: KV4PDurationUnit
    var footer: String?

    @State private var unit: KV4PDurationUnit
    @State private var amountText = ""
    @FocusState private var amountFocused: Bool

    init(
        title: String,
        seconds: Binding<Double>,
        allowedRange: ClosedRange<Double>,
        defaultUnit: KV4PDurationUnit,
        footer: String? = nil
    ) {
        self.title = title
        _seconds = seconds
        self.allowedRange = allowedRange
        self.defaultUnit = defaultUnit
        self.footer = footer
        _unit = State(initialValue: defaultUnit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: formattedDuration(seconds))
            HStack {
                TextField("Time", text: $amountText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($amountFocused)
                    .onChange(of: amountText) { _, _ in
                        updateSecondsFromText(allowDefault: false)
                    }

                Picker("Unit", selection: $unit) {
                    ForEach(KV4PDurationUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: unit) { _, _ in
                    if amountFocused {
                        updateSecondsFromText(allowDefault: false)
                    } else {
                        syncTextFromSeconds()
                    }
                }
            }

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if amountText.isEmpty {
                unit = defaultUnit
                syncTextFromSeconds()
            }
        }
        .onChange(of: amountFocused) { _, isFocused in
            if !isFocused {
                updateSecondsFromText(allowDefault: true)
                syncTextFromSeconds()
            }
        }
        .onChange(of: seconds) { _, _ in
            guard !amountFocused else { return }
            syncTextFromSeconds()
        }
    }

    private func updateSecondsFromText(allowDefault: Bool) {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if allowDefault {
                seconds = allowedRange.lowerBound
            }
            return
        }

        guard let amount = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            if allowDefault {
                seconds = allowedRange.lowerBound
            }
            return
        }

        seconds = clamped(amount * unit.seconds)
    }

    private func syncTextFromSeconds() {
        let amount = clamped(seconds) / unit.seconds
        if amount == floor(amount) {
            amountText = "\(Int(amount))"
        } else {
            amountText = String(format: "%.1f", amount)
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(allowedRange.upperBound, max(allowedRange.lowerBound, value))
    }

    private func formattedDuration(_ value: Double) -> String {
        let clampedValue = clamped(value)
        if clampedValue < 3_600 {
            return "\(Int(clampedValue / 60)) min"
        }
        if clampedValue < 86_400 {
            let hours = clampedValue / 3_600
            return hours == floor(hours) ? "\(Int(hours)) hr" : String(format: "%.1f hr", hours)
        }
        let days = clampedValue / 86_400
        return days == floor(days) ? "\(Int(days)) days" : String(format: "%.1f days", days)
    }
}
