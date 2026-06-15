// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct VoiceView: View {
    @EnvironmentObject private var app: AppState
    @State private var rxFrequencyText = "146.5200"
    @State private var txFrequencyText = "146.5200"
    @State private var txTone = "None"
    @State private var rxTone = "None"
    @State private var isTouchingPTT = false
    @State private var activeToneSelector: ToneSelector?
    @FocusState private var focusedFrequencyField: FrequencyField?

    var body: some View {
        KV4PScreen(bottomPadding: 24) {
            frequencyPanel
            sMeter
        }
        .safeAreaInset(edge: .bottom) {
            persistentPTTBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Tune") {
                    commitFrequency()
                }
            }
        }
        .onAppear {
            syncFromApp()
        }
        .sheet(item: $activeToneSelector) { selector in
            ToneSelectionView(
                title: selector == .tx ? "TX Tone" : "RX Tone",
                selection: selector == .tx ? $txTone : $rxTone
            )
        }
    }

    private var frequencyPanel: some View {
        KV4PCard("Channel", systemImage: "radio") {
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text(app.activeMemoryName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    TextField("RX Frequency", text: $rxFrequencyText)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedFrequencyField, equals: .largeRx)
                        .onSubmit(commitFrequency)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        frequencyField("RX", placeholder: "Receive MHz", text: $rxFrequencyText, field: .rx)
                        frequencyField("TX", placeholder: "Transmit MHz", text: $txFrequencyText, field: .tx)
                    }
                    VStack(spacing: 10) {
                        frequencyField("RX", placeholder: "Receive MHz", text: $rxFrequencyText, field: .rx)
                        frequencyField("TX", placeholder: "Transmit MHz", text: $txFrequencyText, field: .tx)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: stepDown) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Step frequency down")

                    Button(action: commitFrequency) {
                        Label("Tune", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: stepUp) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Step frequency up")
                }

                toneControls
            }
        }
    }

    private var toneControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tones")
                .font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    tonePicker("TX", selector: .tx, selection: $txTone)
                    tonePicker("RX", selector: .rx, selection: $rxTone)
                }
                VStack(spacing: 8) {
                    tonePicker("TX", selector: .tx, selection: $txTone)
                    tonePicker("RX", selector: .rx, selection: $rxTone)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sMeter: some View {
        KV4PCard("Signal", systemImage: "chart.bar.fill") {
            HStack(alignment: .bottom, spacing: 8) {
                Text("S\(app.sMeter)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                ForEach(1...9, id: \.self) { value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(value <= app.sMeter ? Color.green : Color.secondary.opacity(0.22))
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(7 + value * 4))
                        .accessibilityLabel("S meter \(value)")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52, alignment: .bottom)
        }
    }

    private var persistentPTTBar: some View {
        VStack(spacing: 0) {
            pttButton
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: KV4PTheme.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private var pttButton: some View {
        if app.settings.stickyPTT {
            Button {
                app.toggleStickyPTT()
            } label: {
                pttLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isTransmitting ? .red : .blue)
        } else {
            pttLabel
                .foregroundStyle(.white)
                .background(app.isTransmitting ? Color.red : Color.blue, in: Capsule())
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isTouchingPTT else { return }
                            isTouchingPTT = true
                            app.pttDown()
                        }
                        .onEnded { _ in
                            guard isTouchingPTT else { return }
                            isTouchingPTT = false
                            app.pttUp()
                        }
                )
                .onDisappear {
                    guard isTouchingPTT else { return }
                    isTouchingPTT = false
                    app.pttUp()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(app.isTransmitting ? "Release to stop transmitting" : "Hold to transmit")
        }
    }

    private var pttLabel: some View {
        Text(app.isTransmitting ? "On Air" : "Push to Talk")
            .frame(maxWidth: .infinity)
            .font(.title2.weight(.bold))
            .padding(.vertical, 14)
    }

    private func frequencyField(_ title: String, placeholder: String, text: Binding<String>, field: FrequencyField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .focused($focusedFrequencyField, equals: field)
        }
    }

    private func tonePicker(_ title: String, selector: ToneSelector, selection: Binding<String>) -> some View {
        RadioTonePickerRow(title: title, selection: selection) {
            activeToneSelector = selector
        }
    }

    private func commitFrequency() {
        let rx = Float(rxFrequencyText)
        let tx = Float(txFrequencyText) ?? rx
        if let message = app.frequencyValidationMessage(rx: rx, tx: tx) {
            app.statusLine = message
            return
        }
        guard let rx, let tx else { return }
        txTone = RadioToneHelper.normalize(txTone)
        rxTone = RadioToneHelper.normalize(rxTone)
        app.tuneDirect(rx: rx, tx: tx, txTone: txTone, rxTone: rxTone)
        focusedFrequencyField = nil
    }

    private func syncFromApp() {
        rxFrequencyText = String(format: "%.4f", app.activeRxFrequency)
        txFrequencyText = String(format: "%.4f", app.activeTxFrequency)
        txTone = RadioToneHelper.normalize(app.activeTxTone)
        rxTone = RadioToneHelper.normalize(app.activeRxTone)
    }

    private func stepFrequencies(by delta: Float) {
        focusedFrequencyField = nil
        let rx = (Float(rxFrequencyText) ?? app.activeRxFrequency) + delta
        let tx = (Float(txFrequencyText) ?? app.activeTxFrequency) + delta
        if let message = app.frequencyValidationMessage(rx: rx, tx: tx) {
            app.statusLine = message
            return
        }
        rxFrequencyText = String(format: "%.4f", rx)
        txFrequencyText = String(format: "%.4f", tx)
        app.tuneDirect(rx: rx, tx: tx, txTone: txTone, rxTone: rxTone)
    }

    private func stepUp() {
        stepFrequencies(by: 0.005)
    }

    private func stepDown() {
        stepFrequencies(by: -0.005)
    }

    private enum FrequencyField: Hashable {
        case largeRx
        case rx
        case tx
    }

    private enum ToneSelector: String, Identifiable {
        case tx
        case rx

        var id: String { rawValue }
    }
}

struct RadioTonePickerRow: View {
    let title: String
    @Binding var selection: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Button(action: action) {
                HStack(spacing: 6) {
                    Text(toneDisplay(selection))
                        .font(.body.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.blue)
                .frame(minWidth: 96, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) tone")
            .accessibilityValue(toneDisplay(selection))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toneDisplay(_ tone: String) -> String {
        RadioToneHelper.normalize(tone) == "None" ? "NONE" : tone
    }
}

struct ToneSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var selection: String

    var body: some View {
        NavigationStack {
            List {
                ForEach(RadioToneHelper.validToneStrings, id: \.self) { tone in
                    Button {
                        selection = RadioToneHelper.normalize(tone)
                        dismiss()
                    } label: {
                        HStack {
                            Text(display(tone))
                                .font(.body.monospacedDigit())
                                .lineLimit(1)
                            Spacer()
                            if RadioToneHelper.normalize(tone) == RadioToneHelper.normalize(selection) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func display(_ tone: String) -> String {
        RadioToneHelper.normalize(tone) == "None" ? "NONE" : tone
    }
}
