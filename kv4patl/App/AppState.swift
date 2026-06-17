// SPDX-License-Identifier: GPL-3.0-or-later
import CoreLocation
import Foundation
import SwiftUI

private let receiveActivityUpdateIntervalSeconds: TimeInterval = 0.45
private let audioDebugUpdateIntervalSeconds: TimeInterval = 1.0

@MainActor
final class AppState: ObservableObject {
    @Published var transportState: KV4PTransportState = .idle
    @Published var firmwareVersion: FirmwareVersion?
    @Published var deviceState: DeviceState?
    @Published var settings: AppSettings
    @Published var memories: [ChannelMemory]
    @Published var messages: [APRSMessage]
    @Published var activeFrequency: Float = 146.5200
    @Published var activeMemoryName = "Welcome to"
    @Published var activeTxFrequency: Float = 146.5200
    @Published var activeRxFrequency: Float = 146.5200
    @Published var activeTxTone = "None"
    @Published var activeRxTone = "None"
    @Published var statusLine = "Radio disconnected"
    @Published var lastDebugLine = ""
    @Published var codecNotice = ""
    @Published var afskStats: AfskDecodeStats?
    @Published var isTransmitting = false
    @Published var receiveAudioActive = false
    @Published var sMeter = 0

    private let store = LocalStore()
    private let aprs = APRSService()
    private let locationProvider = APRSLocationProvider()
    private let deduper = DigipeatDeduper()
    private let audio = KV4PAudioEngine()
    private let radioProtocol = RadioProtocol()
    private let radioQueue = DispatchQueue(label: "com.blakeross.kv4patl.radio", qos: .userInitiated)
    private let transmitGate = TransmitGate()
    private let rxAudioUIUpdateGate = RXAudioUIUpdateGate()
    private var transport: KV4PTransport?
    private var messageNumber = Int.random(in: 0..<100_000)
    private var activeMemoryId: Int32 = -1
    private var lastAudioDebugDate = Date.distantPast
    private var lastReceiveActivityPublishDate = Date.distantPast
    private var lastDeviceStatePublishDate = Date.distantPast
    private var lastDeviceMode: DeviceMode?
    private var awaitingRxFrameAfterTransmit = false
    private var receiveReadyAfterTransmit = true
    private var transmitRecoveryUntil = Date.distantPast
    private var transmitRecoveryForceReadyAt = Date.distantPast
    private var lastPTTDownDate = Date.distantPast
    private var lastPTTUpDate = Date.distantPast
    private var momentaryPTTIntentActive = false
    private var stickyPTTStartArmed = false
    private var needsStateResendAfterReconnect = false
    private var queuedTransmitRequest: QueuedTransmitRequest?
    private var queuedTransmitTask: Task<Void, Never>?
    private var captureRetryTask: Task<Void, Never>?
    private var postTransmitRecoveryTask: Task<Void, Never>?
    private var beaconRestoreTask: Task<Void, Never>?
    private var autoBeaconTask: Task<Void, Never>?
    private var receiveAudioIdleTask: Task<Void, Never>?
    private var cachedBeaconLocation: CLLocation?

    var aprsStations: [APRSStation] {
        let positions = messages.compactMap { message -> APRSStation? in
            guard let latitude = message.latitude, let longitude = message.longitude else { return nil }
            return APRSStation(
                callsign: message.from,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                lastHeard: message.timestamp,
                comment: message.body,
                relay: message.relay,
                symbol: message.symbol
            )
        }

        return Dictionary(grouping: positions, by: \.callsign)
            .compactMap { $0.value.max { $0.lastHeard < $1.lastHeard } }
            .sorted { $0.lastHeard > $1.lastHeard }
    }

    init() {
        var loadedSettings = store.loadSettings()
        if !loadedSettings.blePowerDefaultMigrated {
            // Keep the migrated default conservative, but leave the user-visible
            // high-power setting available for externally powered radios.
            loadedSettings.blePowerDefaultMigrated = true
            store.saveSettings(loadedSettings)
        }
        let legacyStatusComment = ["KV4P", "HT", "iOS"].joined(separator: " ")
        if loadedSettings.aprsStatusComment.trimmingCharacters(in: .whitespacesAndNewlines) == legacyStatusComment {
            loadedSettings.aprsStatusComment = "KV4P/ATL"
            store.saveSettings(loadedSettings)
        }
        settings = loadedSettings
        audio.updateGainProfile(micBoost: loadedSettings.micGainBoost)
        memories = store.loadMemories()
        let retentionCutoff = Date().addingTimeInterval(-max(60, loadedSettings.packetRetentionSeconds))
        messages = store.loadMessages().filter { $0.timestamp >= retentionCutoff }
        if ProcessInfo.processInfo.arguments.contains("--qa-aprs-sample-packets") {
            messages = Self.makeQASampleAPRSMessages()
        }
        activeFrequency = memories.first?.frequency ?? 146.5200
        activeMemoryName = memories.first?.name ?? "Welcome to"
        activeRxFrequency = activeFrequency
        activeTxFrequency = memories.first?.txFrequency ?? activeFrequency
        activeTxTone = memories.first?.txTone ?? settings.directTxTone
        activeRxTone = memories.first?.rxTone ?? settings.directRxTone
        activeMemoryId = memories.first?.radioMemoryId ?? -1

        let audioEngine = audio
        let rxAudioUIUpdateGate = rxAudioUIUpdateGate
        radioProtocol.eventHandler = { [weak self, audioEngine, rxAudioUIUpdateGate] event in
            if case .rxAudio(let frame) = event {
                Task { @MainActor in
                    self?.handleRxAudioFrame(
                        frame,
                        audioEngine: audioEngine,
                        rxAudioUIUpdateGate: rxAudioUIUpdateGate
                    )
                }
            } else {
                Task { @MainActor in self?.handle(event) }
            }
        }
        configureAPRSBeaconing()
        if settings.autoConnectOnStartup {
            Task { @MainActor [weak self] in
                self?.connect()
            }
        }
    }

    var radioActivityLabel: String {
        if isTransmitting || deviceState?.mode == .tx { return "TX" }
        if rxSpeakerMutedForAPRSFrequency { return "IDLE" }
        if transportIsConnected && settings.squelch == 0 { return "RX" }
        if receiveAudioActive { return "RX" }
        return "IDLE"
    }

    var radioIsConnected: Bool {
        transportIsConnected
    }

    var radioFrequencyRange: RadioFrequencyRange? {
        firmwareVersion?.frequencyRange
    }

    var detectedRfModuleType: RfModuleType? {
        firmwareVersion?.moduleType
    }

    var radioModuleSummary: String {
        guard let firmwareVersion else {
            return "Unknown until radio connects"
        }
        if let range = firmwareVersion.frequencyRange {
            return "\(firmwareVersion.moduleType.displayName) \(Self.formatFrequency(range.lowerMHz))-\(Self.formatFrequency(range.upperMHz)) MHz"
        }
        return firmwareVersion.moduleType.displayName
    }

    func configuredTXRange(for moduleType: RfModuleType) -> RadioFrequencyRange {
        switch moduleType {
        case .vhf:
            return RadioFrequencyRange(
                lowerMHz: Float(settings.min2mTx) ?? 144,
                upperMHz: Float(settings.max2mTx) ?? 148
            )
        case .uhf:
            return RadioFrequencyRange(
                lowerMHz: Float(settings.min70cmTx) ?? 420,
                upperMHz: Float(settings.max70cmTx) ?? 450
            )
        }
    }

    func effectiveTXRange(for moduleType: RfModuleType) -> RadioFrequencyRange? {
        let configured = configuredTXRange(for: moduleType)
        guard configured.isValid else { return nil }
        guard firmwareVersion?.moduleType == moduleType,
              let radioFrequencyRange else {
            return configured
        }
        return configured.intersection(with: radioFrequencyRange)
    }

    func frequencyValidationMessage(rx: Float?, tx: Float?) -> String? {
        guard let rx else {
            return "Enter an RX frequency."
        }
        guard let tx else {
            return "Enter a TX frequency."
        }
        if let radioFrequencyRange, !radioFrequencyRange.contains(rx) {
            return "RX must be within \(radioModuleSummary)."
        }
        if let radioFrequencyRange, !radioFrequencyRange.contains(tx) {
            return "TX must be within \(radioModuleSummary)."
        }
        if !isTxAllowed(tx) {
            return "TX frequency is outside the configured \(detectedRfModuleType?.txLimitLabel ?? "ham band") limits."
        }
        return nil
    }

    nonisolated static func formatFrequency(_ frequency: Float) -> String {
        String(format: "%.4f", frequency)
    }

    func toggleRadioConnection() {
        radioIsConnected ? disconnect() : connect()
    }

    func connect() {
        transport?.eventHandler = nil
        transport?.stop()
        rxAudioUIUpdateGate.forceNextPlaybackReadyUpdate()
        statusLine = "Preparing BLE scan..."
        lastDebugLine = ""

        let ble = BLEKissTransport()
        let radioQueue = radioQueue
        let radioProtocol = radioProtocol
        ble.eventHandler = { [weak self, radioQueue, radioProtocol] event in
            if case .data(let data) = event {
                radioQueue.async {
                    radioProtocol.ingest(data)
                }
            } else {
                Task { @MainActor in self?.handle(event) }
            }
        }
        transport = ble
        radioQueue.async {
            radioProtocol.attach(ble)
        }
        ble.start()
    }

    func disconnect() {
        queuedTransmitTask?.cancel()
        queuedTransmitTask = nil
        captureRetryTask?.cancel()
        captureRetryTask = nil
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        autoBeaconTask?.cancel()
        autoBeaconTask = nil
        receiveAudioIdleTask?.cancel()
        receiveAudioIdleTask = nil
        receiveAudioActive = false
        queuedTransmitRequest = nil
        beaconRestoreTask?.cancel()
        beaconRestoreTask = nil
        momentaryPTTIntentActive = false
        stickyPTTStartArmed = false
        transport?.stop()
        transport = nil
        audio.stop()
    }

    func saveSettings() {
        settings.beaconIntervalSeconds = min(86_400, max(60, settings.beaconIntervalSeconds))
        settings.packetRetentionSeconds = min(604_800, max(60, settings.packetRetentionSeconds))
        store.saveSettings(settings)
        audio.updateGainProfile(micBoost: settings.micGainBoost)
        pruneStoredAPRSPackets()
        configureAPRSBeaconing()
        applySettingsToRadio()
    }

    func addMemory(_ memory: ChannelMemory) {
        guard frequencyValidationMessage(rx: memory.frequency, tx: memory.txFrequency) == nil else {
            statusLine = frequencyValidationMessage(rx: memory.frequency, tx: memory.txFrequency) ?? "Memory frequency is outside radio limits."
            return
        }
        memories.append(memory)
        store.saveMemories(memories)
    }

    func deleteMemory(_ memory: ChannelMemory) {
        memories.removeAll { $0.id == memory.id }
        store.saveMemories(memories)
    }

    func updateMemory(_ memory: ChannelMemory) {
        guard frequencyValidationMessage(rx: memory.frequency, tx: memory.txFrequency) == nil else {
            statusLine = frequencyValidationMessage(rx: memory.frequency, tx: memory.txFrequency) ?? "Memory frequency is outside radio limits."
            return
        }
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else {
            addMemory(memory)
            return
        }
        memories[index] = memory
        store.saveMemories(memories)
        if activeMemoryId == memory.radioMemoryId {
            tune(memory)
        }
    }

    func tune(_ memory: ChannelMemory) {
        if let message = frequencyValidationMessage(rx: memory.frequency, tx: memory.txFrequency) {
            statusLine = message
            return
        }
        activeFrequency = memory.frequency
        activeMemoryName = memory.name
        activeMemoryId = memory.radioMemoryId
        activeRxFrequency = memory.frequency
        activeTxFrequency = memory.txFrequency
        activeTxTone = RadioToneHelper.normalize(memory.txTone)
        activeRxTone = RadioToneHelper.normalize(memory.rxTone)
        applyMemory(memory)
    }

    func tuneFrequency(_ frequency: Float) {
        tuneDirect(rx: frequency, tx: frequency, txTone: settings.directTxTone, rxTone: settings.directRxTone)
    }

    func tuneDirect(rx: Float, tx: Float, txTone: String, rxTone: String) {
        if let message = frequencyValidationMessage(rx: rx, tx: tx) {
            statusLine = message
            return
        }
        activeFrequency = rx
        activeRxFrequency = rx
        activeTxFrequency = tx
        activeTxTone = RadioToneHelper.normalize(txTone)
        activeRxTone = RadioToneHelper.normalize(rxTone)
        activeMemoryId = -1
        activeMemoryName = "Direct"
        settings.directRxFrequency = String(format: "%.4f", rx)
        settings.directTxFrequency = String(format: "%.4f", tx)
        settings.directTxTone = activeTxTone
        settings.directRxTone = activeRxTone
        store.saveSettings(settings)
        applySettingsToRadio()
    }

    func pttDown() {
        lastPTTDownDate = Date()
        audio.logDiagnostic("PTT down. connected=\(transportIsConnected) transmitting=\(isTransmitting) recoveryReady=\(transmitRecoverySatisfied)")
        momentaryPTTIntentActive = true
        requestTransmitStart(.momentary)
    }

    private func requestTransmitStart(_ request: QueuedTransmitRequest) {
        guard transmitRequestStillWanted(request) else { return }
        guard !isTransmitting else { return }
        guard transportIsConnected else {
            statusLine = "Connect to the radio before using PTT."
            clearTransmitStartState(for: request)
            return
        }
        if let message = frequencyValidationMessage(rx: activeRxFrequency, tx: activeTxFrequency) {
            statusLine = message
            clearTransmitStartState(for: request)
            return
        }
        if !transmitRecoverySatisfied {
            preemptReceiveRecoveryForTransmit(request)
        }

        audio.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    guard self.transmitRequestStillWanted(request), self.transmitRecoverySatisfied else {
                        if self.transmitRequestStillWanted(request) {
                            self.queuedTransmitRequest = request
                            self.scheduleQueuedTransmitCheck()
                        }
                        return
                    }
                    self.clearQueuedTransmitRequest(matching: request)
                    self.beginTransmit(request)
                } else {
                    self.statusLine = "Allow microphone access before using PTT."
                    self.isTransmitting = false
                    self.clearTransmitStartState(for: request)
                    self.applySettingsToRadio(ptt: false, priority: .urgentDropQueued)
                }
            }
        }
    }

    private func beginTransmit(_ request: QueuedTransmitRequest, captureAttempt: Int = 0) {
        guard transmitRequestStillWanted(request) else {
            clearQueuedTransmitRequest(matching: request)
            return
        }
        if !transmitRecoverySatisfied {
            preemptReceiveRecoveryForTransmit(request)
        }
        guard transmitRequestStillWanted(request) else {
            clearQueuedTransmitRequest(matching: request)
            return
        }
        guard transportIsConnected else {
            queuedTransmitRequest = request
            scheduleQueuedTransmitCheck()
            return
        }
        guard !isTransmitting else { return }
        let radioQueue = radioQueue
        let radioProtocol = radioProtocol
        let transmitGate = transmitGate
        let audioEngine = audio
        let session = transmitGate.begin()
        let requestStart = lastPTTDownDate == .distantPast ? Date() : lastPTTDownDate
        do {
            postTransmitRecoveryTask?.cancel()
            postTransmitRecoveryTask = nil
            lastDebugLine = captureAttempt == 0
                ? "PTT on requested; starting microphone capture."
                : "Retrying microphone capture before PTT on, attempt \(captureAttempt + 1)."
            audio.logDiagnostic("PTT on requested; starting microphone capture attempt=\(captureAttempt + 1)")
            let commandStart = Date()
            applySettingsToRadio(ptt: true, rxAudioOpen: true, priority: .urgentDropQueued, waitUntilQueued: true)
            audio.logDiagnostic("PTT on command queued in \(Self.elapsedMS(since: commandStart)) ms; \(Self.elapsedMS(since: requestStart)) ms after button. Mic capture follows.")
            try audio.startCapture { frame in
                guard transmitGate.isActive(session) else { return }
                radioQueue.async {
                    guard transmitGate.isActive(session) else { return }
                    do {
                        try radioProtocol.sendTxAudio(frame)
                        audioEngine.noteTxAudioFrameQueued(byteCount: frame.count)
                    } catch {
                        if let transportError = error as? KV4PTransportError,
                           transportError == .flowControlBackpressure {
                            audioEngine.noteTxAudioLiveDrop(byteCount: frame.count)
                        } else {
                            audioEngine.noteTxAudioSendFailed(error)
                        }
                    }
                }
            }
            captureRetryTask?.cancel()
            captureRetryTask = nil
            if request == .sticky {
                stickyPTTStartArmed = false
            }
            receiveAudioActive = false
            receiveAudioIdleTask?.cancel()
            receiveAudioIdleTask = nil
            isTransmitting = true
            receiveReadyAfterTransmit = false
            awaitingRxFrameAfterTransmit = true
            statusLine = "Transmitting."
            lastDebugLine = "Mic capture is active after \(Self.elapsedMS(since: requestStart)) ms; PTT on was already queued. \(audio.currentRouteDebugSummary())"
        } catch {
            transmitGate.end()
            isTransmitting = false
            audio.resetCapturePathAfterFailure()
            audio.logDiagnostic("Mic capture start failed attempt=\(captureAttempt + 1): \(error.localizedDescription)")
            applySettingsToRadio(ptt: false, priority: .urgentDropQueued)
            if shouldRetryCaptureStart(request, attempt: captureAttempt) {
                scheduleCaptureStartRetry(request, attempt: captureAttempt + 1, error: error)
            } else {
                clearTransmitStartState(for: request)
                ensureReceiveAudioActive(reason: "capture start failed", resendPTTOff: true)
                statusLine = error.localizedDescription
            }
        }
    }

    func pttUp() {
        audio.logDiagnostic("PTT up. transmitting=\(isTransmitting) queued=\(String(describing: queuedTransmitRequest))")
        guard !settings.stickyPTT else { return }
        momentaryPTTIntentActive = false
        captureRetryTask?.cancel()
        captureRetryTask = nil
        if !isTransmitting {
            clearQueuedTransmitRequest(matching: .momentary)
            return
        }
        endTransmit()
    }

    func toggleStickyPTT() {
        audio.logDiagnostic("Sticky PTT toggled. transmitting=\(isTransmitting) armed=\(stickyPTTStartArmed) queued=\(String(describing: queuedTransmitRequest))")
        if isTransmitting || stickyPTTStartArmed || queuedTransmitRequest == .sticky {
            stickyPTTStartArmed = false
            clearQueuedTransmitRequest(matching: .sticky)
            captureRetryTask?.cancel()
            captureRetryTask = nil
            if !isTransmitting {
                statusLine = "Sticky PTT cancelled."
                return
            }
            endTransmit()
        } else {
            lastPTTDownDate = Date()
            stickyPTTStartArmed = true
            requestTransmitStart(.sticky)
        }
    }

    func endTransmit() {
        guard isTransmitting else {
            momentaryPTTIntentActive = false
            clearQueuedTransmitRequest()
            captureRetryTask?.cancel()
            captureRetryTask = nil
            return
        }
        isTransmitting = false
        transmitGate.end()
        lastPTTUpDate = Date()
        markReceiveRecoveryStarted()
        audio.logDiagnostic("PTT off; leaving radio RX audio requested while microphone tap is removed.")
        applySettingsToRadio(ptt: false, rxAudioOpen: true, priority: .urgentDropQueued, waitUntilQueued: true)
        lastDebugLine = "PTT off queued first; RX audio stayed requested so BLE audio remains logically open."
        if reopenReceiveAudioAfterCapture(reason: "PTT released", resendPTTOff: false) {
            statusLine = "Transmit ended. Reopening receive audio..."
        } else {
            statusLine = "Transmit ended. Recovering receive audio..."
        }
        schedulePostTransmitReceiveRecovery()
    }

    func sendAPRSMessage(to destination: String, body: String) {
        guard !settings.callsign.isEmpty else {
            statusLine = "Set your callsign before sending APRS."
            return
        }
        do {
            let packet = try aprs.makeMessage(from: settings.callsign, to: destination, body: body, number: messageNumber)
            messageNumber = (messageNumber + 1) % 100_000
            sendAX25(packet.encodedUIFrame())
            let message = APRSMessage(type: .message, from: settings.callsign, to: destination.isEmpty ? APRSService.defaultRecipient : destination, body: body, timestamp: Date())
            messages.append(message)
            saveAPRSMessages()
        } catch {
            statusLine = error.localizedDescription
        }
    }

    func preparePositionBeaconing() {
        guard settings.beaconPosition else { return }

        statusLine = "Checking iPhone location for APRS beacons..."
        lastDebugLine = "APRS beacon setting requested GPS readiness."
        refreshBeaconLocation(reason: "APRS beacon setting", sendWhenReady: false)
        configureAPRSBeaconing()
    }

    func sendPositionBeacon() {
        guard !settings.callsign.isEmpty else {
            statusLine = "Set your callsign before beaconing."
            return
        }

        if let cachedBeaconLocation,
           Date().timeIntervalSince(cachedBeaconLocation.timestamp) < Self.cachedLocationFreshnessSeconds {
            lastDebugLine = "APRS beacon using cached iPhone location; no GPS wait needed."
            sendPositionBeacon(at: cachedBeaconLocation.coordinate)
            return
        }

        statusLine = "Refreshing iPhone location for APRS beacon..."
        lastDebugLine = "APRS beacon requested a fresh GPS location."
        refreshBeaconLocation(reason: "manual APRS beacon", sendWhenReady: true)
    }

    private func refreshBeaconLocation(reason: String, sendWhenReady: Bool) {
        locationProvider.requestLocation(desiredAccuracy: desiredLocationAccuracy) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let location):
                    self.cachedBeaconLocation = location
                    let adjusted = APRSService.adjustedCoordinate(location.coordinate, accuracySetting: self.settings.aprsAccuracy)
                    self.lastDebugLine = String(format: "APRS location ready for %@ at %.4f, %.4f.", reason, adjusted.latitude, adjusted.longitude)
                    if sendWhenReady {
                        self.sendPositionBeacon(at: location.coordinate)
                    } else {
                        self.statusLine = "Location ready for APRS position beacons."
                    }
                case .failure(let error):
                    self.statusLine = error.localizedDescription
                    self.lastDebugLine = "APRS location failed during \(reason): \(error.localizedDescription)"
                }
            }
        }
    }

    func sendDemoBeacon() {
        sendPositionBeacon()
    }

    private func handle(_ event: KV4PTransportEvent) {
        switch event {
        case .state(let state):
            transportState = state
            switch state {
            case .connected(let name):
                statusLine = "Connected to \(name)"
                if needsStateResendAfterReconnect {
                    recoverAfterReconnectFromTransmit()
                } else {
                    ensureReceiveAudioActive(reason: "BLE connected", resendPTTOff: true)
                }
            case .scanning: statusLine = "Scanning for KV4P HT BLE bridge..."
            case .connecting(let name): statusLine = "Connecting to \(name)..."
            case .failed(let reason), .disconnected(let reason):
                statusLine = reason
                handleTransportLostDuringTransmit(reason: reason)
            case .idle: statusLine = "Radio idle"
            }
        case .data(let data):
            let radioQueue = radioQueue
            let radioProtocol = radioProtocol
            radioQueue.async {
                radioProtocol.ingest(data)
            }
        case .debug(let message):
            lastDebugLine = message
        case .error(let message):
            statusLine = message
        }
    }

    private func handle(_ event: RadioProtocolEvent) {
        switch event {
        case .hello(let hello):
            firmwareVersion = hello.firmware
            deviceState = hello.state
            lastDeviceMode = hello.state.mode
            receiveReadyAfterTransmit = hello.state.mode == .rx || hello.state.mode == .stopped
            if receiveReadyAfterTransmit && awaitingRxFrameAfterTransmit {
                statusLine = "Handshake complete. Waiting for RX audio..."
                lastDebugLine = "Firmware hello reported \(modeLabel(hello.state.mode)); first decoded RX audio frame is still pending."
            }
            lastDeviceStatePublishDate = Date()
            sMeter = calculateSMeter(hello.state.latestRSSI)
            if !awaitingRxFrameAfterTransmit {
                statusLine = "Handshake complete. Firmware \(hello.firmware.version)."
            }
            applySettingsToRadio()
        case .deviceState(let state):
            publishDeviceState(state)
        case .rxAudio(let frame):
            // Tests and any future direct callers still get the nonblocking path.
            handleRxAudioFrame(frame, audioEngine: audio, rxAudioUIUpdateGate: rxAudioUIUpdateGate)
        case .afskStats(let stats):
            afskStats = stats
        case .ax25(let data):
            if let packet = try? AX25Packet.decodeUIFrame(data) {
                if settings.digipeatPackets, deduper.shouldDigipeat(packet) {
                    sendAX25(packet.encodedUIFrame())
                }
                messages.append(aprs.parse(packet: packet))
                saveAPRSMessages()
            }
        case .debug(let message):
            lastDebugLine = message
        case .windowUpdate:
            break
        }
    }

    private func applyMemory(_ memory: ChannelMemory) {
        sendDesiredState(
            memoryId: memory.radioMemoryId,
            tx: memory.txFrequency,
            rx: memory.frequency,
            txTone: RadioToneHelper.toneIndex(memory.txTone),
            rxTone: RadioToneHelper.toneIndex(memory.rxTone)
        )
    }

    private func applySettingsToRadio(
        ptt: Bool? = nil,
        rxAudioOpen: Bool = true,
        priority: KV4PTransportPriority = .normal,
        waitUntilQueued: Bool = false
    ) {
        if let message = frequencyValidationMessage(rx: activeRxFrequency, tx: activeTxFrequency) {
            statusLine = message
            return
        }
        sendDesiredState(
            memoryId: activeMemoryId,
            tx: activeTxFrequency,
            rx: activeRxFrequency,
            txTone: RadioToneHelper.toneIndex(activeTxTone),
            rxTone: RadioToneHelper.toneIndex(activeRxTone),
            ptt: ptt,
            rxAudioOpen: rxAudioOpen,
            priority: priority,
            waitUntilQueued: waitUntilQueued
        )
    }

    private func sendDesiredState(
        memoryId: Int32,
        tx: Float,
        rx: Float,
        txTone: UInt8,
        rxTone: UInt8,
        ptt: Bool? = nil,
        rxAudioOpen: Bool = true,
        priority: KV4PTransportPriority = .normal,
        waitUntilQueued: Bool = false
    ) {
        // The firmware overlay slows RSSI polling for BLE so S-meter updates do
        // not monopolize the SA818 serial port during live ADPCM audio.
        var flags = RadioFlags.enableStatusReports | RadioFlags.radioConfigValid | RadioFlags.txAllowed | RadioFlags.rssiEnabled
        if rxAudioOpen { flags |= RadioFlags.rxAudioOpen }
        if settings.highPower { flags |= RadioFlags.highPower }
        if settings.filterPre { flags |= RadioFlags.filterPre }
        if settings.filterHigh { flags |= RadioFlags.filterHigh }
        if settings.filterLow { flags |= RadioFlags.filterLow }
        if ptt ?? isTransmitting { flags |= RadioFlags.pttRequested }
        if settings.rxPowerSaveEnabled {
            flags |= RadioFlags.rxPowerSave
            if settings.rxPowerSaveProfile == "Maximum" {
                flags |= RadioFlags.rxPowerSaveMaximum
            }
        }
        let state = HostDesiredState(
            sequence: 0,
            memoryId: memoryId,
            flags: flags,
            bandwidth: settings.bandwidth == "25kHz" ? 1 : 0,
            txFrequency: tx,
            rxFrequency: rx,
            txTone: txTone,
            squelch: UInt8(max(0, min(100, settings.squelch))),
            rxTone: rxTone
        )
        sendDesiredState(state, priority: priority, waitUntilQueued: waitUntilQueued)
    }

    private func sendDesiredState(
        _ state: HostDesiredState,
        priority: KV4PTransportPriority = .normal,
        waitUntilQueued: Bool = false
    ) {
        let radioQueue = radioQueue
        let radioProtocol = radioProtocol
        let work: @Sendable () -> Void = { [weak self, radioProtocol] in
            do {
                try radioProtocol.sendDesiredState(
                    memoryId: state.memoryId,
                    flags: state.flags,
                    bandwidth: state.bandwidth,
                    tx: state.txFrequency,
                    rx: state.rxFrequency,
                    txTone: state.txTone,
                    squelch: state.squelch,
                    rxTone: state.rxTone,
                    priority: priority
                )
            } catch {
                Task { @MainActor in self?.statusLine = error.localizedDescription }
            }
        }
        if waitUntilQueued {
            radioQueue.sync(execute: work)
        } else {
            radioQueue.async(execute: work)
        }
    }

    private func schedulePostTransmitReceiveRecovery() {
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = Task { [weak self] in
            for delayMS in Self.postTransmitRecoveryDelaysMS {
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                if Task.isCancelled { break }
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self,
                          !self.isTransmitting,
                          self.awaitingRxFrameAfterTransmit else {
                        return false
                    }
                    let resendPTTOff = delayMS >= Self.postTransmitPTTOffResendDelayMS
                    self.ensureReceiveAudioActive(reason: "post-PTT recovery \(delayMS) ms", resendPTTOff: resendPTTOff)
                    if delayMS >= Self.postTransmitForceReadyDelayMS {
                        self.finishReceiveRecoveryFallback(reason: "post-PTT recovery watchdog")
                        return false
                    }
                    return true
                }
                if !shouldContinue { break }
            }
            await MainActor.run { [weak self] in
                self?.postTransmitRecoveryTask = nil
            }
        }
    }

    private func sendPositionBeacon(at coordinate: CLLocationCoordinate2D) {
        guard !isTransmitting else {
            statusLine = "Wait until voice transmit ends before sending an APRS beacon."
            return
        }

        do {
            let beaconFrequency = try selectedBeaconFrequency()
            if let beaconFrequency, !isTxAllowed(beaconFrequency) {
                statusLine = String(format: "Beacon frequency %.4f is outside your TX limits.", beaconFrequency)
                return
            }

            let adjusted = APRSService.adjustedCoordinate(coordinate, accuracySetting: settings.aprsAccuracy)
            let packet = try aprs.makePosition(
                from: settings.callsign,
                coordinate: adjusted,
                comment: aprsBeaconComment,
                symbol: APRSService.symbol(named: settings.aprsIcon)
            )
            sendBeaconAX25(packet.encodedUIFrame(), targetFrequency: beaconFrequency)
            let parsed = aprs.parse(packet: packet)
            messages.append(parsed)
            saveAPRSMessages()
            statusLine = beaconStatusLine(targetFrequency: beaconFrequency)
        } catch {
            statusLine = error.localizedDescription
        }
    }

    private var aprsBeaconComment: String {
        let trimmed = settings.aprsStatusComment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KV4P/ATL" : trimmed
    }

    private func pruneStoredAPRSPackets() {
        let cutoff = Date().addingTimeInterval(-max(60, settings.packetRetentionSeconds))
        let retained = messages.filter { $0.timestamp >= cutoff }
        if retained.count != messages.count {
            messages = retained
        }
        saveAPRSMessages()
    }

    private func saveAPRSMessages() {
        store.saveMessages(messages, retentionSeconds: settings.packetRetentionSeconds)
    }

    private func configureAPRSBeaconing() {
        autoBeaconTask?.cancel()
        autoBeaconTask = nil
        guard settings.beaconPosition,
              settings.autoBeaconEnabled,
              !settings.callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let interval = min(86_400, max(60, settings.beaconIntervalSeconds))
        autoBeaconTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await MainActor.run {
                    guard let self,
                          self.settings.beaconPosition,
                          self.settings.autoBeaconEnabled else { return }
                    self.sendPositionBeacon()
                }
            }
        }
    }

    private func sendBeaconAX25(_ frame: Data, targetFrequency: Float?) {
        guard let targetFrequency else {
            sendAX25(frame)
            lastDebugLine = "APRS beacon queued on current radio frequency."
            return
        }

        lastDebugLine = String(format: "APRS beacon retuning to %.4f MHz before TX.", targetFrequency)
        sendDesiredState(
            memoryId: -1,
            tx: targetFrequency,
            rx: targetFrequency,
            txTone: 0,
            rxTone: 0,
            ptt: false,
            priority: .urgentDropQueued
        )
        sendAX25(frame, after: Self.beaconRetuneDelaySeconds)
        scheduleVoiceChannelRestoreAfterBeacon(targetFrequency)
    }

    private func selectedBeaconFrequency() throws -> Float? {
        let selected = settings.beaconFrequency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, selected != "Current" else { return nil }
        guard let frequency = Float(selected) else { throw APRSBeaconError.invalidFrequency }
        return .some(frequency)
    }

    private var rxSpeakerMutedForAPRSFrequency: Bool {
        guard settings.aprsRxMuteEnabled,
              let aprsFrequency = try? selectedBeaconFrequency() else {
            return false
        }
        return abs(activeRxFrequency - aprsFrequency) <= Self.aprsFrequencyMatchToleranceMHz
    }

    private var desiredLocationAccuracy: CLLocationAccuracy {
        settings.aprsAccuracy == "Approx" ? kCLLocationAccuracyKilometer : kCLLocationAccuracyNearestTenMeters
    }

    private func beaconStatusLine(targetFrequency: Float?) -> String {
        guard let targetFrequency else {
            return "Queued APRS position beacon on current frequency."
        }
        return String(format: "Queued APRS position beacon on %.4f MHz.", targetFrequency)
    }

    private func scheduleVoiceChannelRestoreAfterBeacon(_ targetFrequency: Float) {
        beaconRestoreTask?.cancel()
        beaconRestoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.beaconRestoreDelaySeconds * 1_000_000_000))
            await MainActor.run {
                guard let self, !self.isTransmitting else { return }
                self.lastDebugLine = String(format: "Restoring voice channel after APRS beacon on %.4f MHz.", targetFrequency)
                self.applySettingsToRadio(ptt: false, priority: .urgentDropQueued)
            }
        }
    }

    private func sendAX25(_ frame: Data, after delay: TimeInterval = 0) {
        let radioQueue = radioQueue
        let radioProtocol = radioProtocol
        let work: @Sendable () -> Void = { [weak self, radioProtocol, frame] in
            do {
                try radioProtocol.sendAX25(frame)
            } catch {
                Task { @MainActor in self?.statusLine = error.localizedDescription }
            }
        }
        if delay > 0 {
            radioQueue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            radioQueue.async(execute: work)
        }
    }

    func isTxAllowed(_ frequency: Float) -> Bool {
        if let moduleType = firmwareVersion?.moduleType {
            return effectiveTXRange(for: moduleType)?.contains(frequency) ?? false
        }
        let vhf = configuredTXRange(for: .vhf)
        let uhf = configuredTXRange(for: .uhf)
        return (vhf.isValid && vhf.contains(frequency)) || (uhf.isValid && uhf.contains(frequency))
    }

    nonisolated static func calculateSMeterValue(forRSSI rssi: UInt8) -> Int {
        guard rssi > 0 else { return 0 }
        let value = Double(rssi) / 14.0
        return max(1, min(9, Int(value.rounded())))
    }

    private func calculateSMeter(_ rssi: UInt8) -> Int {
        Self.calculateSMeterValue(forRSSI: rssi)
    }

    private func publishDeviceState(_ state: DeviceState) {
        let now = Date()
        let previousMode = lastDeviceMode ?? deviceState?.mode
        let modeChanged = previousMode != state.mode
        let shouldPublish = state != deviceState || now.timeIntervalSince(lastDeviceStatePublishDate) >= 2

        lastDeviceMode = state.mode
        if shouldPublish {
            lastDeviceStatePublishDate = now
            deviceState = state
            sMeter = calculateSMeter(state.latestRSSI)
        }

        if modeChanged {
            lastDebugLine = "Radio mode \(modeLabel(previousMode)) -> \(modeLabel(state.mode))."
            if state.mode == .tx, lastPTTDownDate != .distantPast {
                audio.logDiagnostic("Radio reported TX \(Self.elapsedMS(since: lastPTTDownDate)) ms after app PTT request.")
            } else if previousMode == .tx, state.mode == .rx, lastPTTUpDate != .distantPast {
                audio.logDiagnostic("Radio reported RX \(Self.elapsedMS(since: lastPTTUpDate)) ms after app PTT release.")
            }
        }
        if !isTransmitting, previousMode == .tx, state.mode == .rx {
            receiveReadyAfterTransmit = true
            ensureReceiveAudioActive(reason: "radio confirmed RX", resendPTTOff: false)
            if awaitingRxFrameAfterTransmit {
                statusLine = "Radio returned to RX. Waiting for audio..."
                lastDebugLine = "Radio confirmed RX after PTT; waiting for the first decoded RX audio frame."
            }
            scheduleQueuedTransmitCheck()
        }
    }

    private func recoverAfterReconnectFromTransmit() {
        needsStateResendAfterReconnect = false
        awaitingRxFrameAfterTransmit = true
        rxAudioUIUpdateGate.forceNextPlaybackReadyUpdate()
        receiveReadyAfterTransmit = true
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        transmitRecoveryUntil = .distantPast
        transmitRecoveryForceReadyAt = .distantPast
        ensureReceiveAudioActive(reason: "BLE reconnected after PTT", resendPTTOff: true)
        applySettingsToRadio(ptt: false, priority: .urgentDropQueued)
        statusLine = "Radio reconnected. Waiting for RX audio..."
        lastDebugLine = "BLE reconnected after TX/recovery; radio RX state resent and first RX audio frame is still pending."
        schedulePostTransmitReceiveRecovery()
        scheduleQueuedTransmitCheck()
    }

    private func publishAudioDebugIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastAudioDebugDate) >= audioDebugUpdateIntervalSeconds else { return }
        lastAudioDebugDate = now
        lastDebugLine = audio.playbackDebugSummary
    }

    private func handleRxAudioFrame(
        _ frame: Data,
        audioEngine: KV4PAudioEngine,
        rxAudioUIUpdateGate: RXAudioUIUpdateGate
    ) {
        let speakerMuted = rxSpeakerMutedForAPRSFrequency
        let softwareSquelchLevel = 0
        let playbackMayBeMutedByPolicy = speakerMuted || softwareSquelchLevel > 0
        audioEngine.playReceivedFrameAsync(
            frame,
            speakerMuted: speakerMuted,
            softwareSquelchLevel: softwareSquelchLevel
        ) { playbackIsReady in
            guard rxAudioUIUpdateGate.shouldScheduleMainUpdate(playbackIsReady: playbackIsReady) else { return }
            Task { @MainActor in
                self.handleRxAudioPlaybackUpdate(
                    playbackIsReady: playbackIsReady,
                    playbackMayBeMutedByPolicy: playbackMayBeMutedByPolicy,
                    speakerMuted: speakerMuted,
                    audioEngine: audioEngine
                )
            }
        }
    }

    private func handleRxAudioPlaybackUpdate(playbackIsReady: Bool, audioEngine: KV4PAudioEngine) {
        handleRxAudioPlaybackUpdate(
            playbackIsReady: playbackIsReady,
            playbackMayBeMutedByPolicy: false,
            speakerMuted: false,
            audioEngine: audioEngine
        )
    }

    private func handleRxAudioPlaybackUpdate(
        playbackIsReady: Bool,
        playbackMayBeMutedByPolicy: Bool,
        speakerMuted: Bool,
        audioEngine: KV4PAudioEngine
    ) {
        publishAudioDebugIfNeeded()
        if playbackIsReady {
            noteReceivePlaybackAfterSquelch(force: awaitingRxFrameAfterTransmit || !receiveAudioActive)
            noteRxAudioFrameAfterTransmitIfNeeded()
        } else if awaitingRxFrameAfterTransmit && playbackMayBeMutedByPolicy && !isTransmitting {
            noteRxAudioFrameArrivedButSpeakerMuted(
                reason: speakerMuted ? "Receive audio muted on APRS frequency." : "Radio RX is below iPhone squelch."
            )
        } else if awaitingRxFrameAfterTransmit && !isTransmitting {
            lastDebugLine = "RX audio packet arrived; waiting for playback buffer to arm. \(audioEngine.playbackDebugSummary)"
        }
    }

    private func noteReceivePlaybackAfterSquelch(force: Bool = false) {
        guard !isTransmitting else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastReceiveActivityPublishDate) >= receiveActivityUpdateIntervalSeconds else {
            return
        }
        lastReceiveActivityPublishDate = now
        if settings.squelch == 0 {
            if !receiveAudioActive {
                receiveAudioActive = true
            }
            if force {
                scheduleReceiveAudioIdleCheck(after: Self.receiveAudioOpenSquelchHoldSeconds)
            }
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.receiveActivitySpeakerSettleSeconds * 1_000_000_000))
            await MainActor.run {
                self?.refreshReceiveActivityFromSpeaker()
            }
        }
    }

    private func refreshReceiveActivityFromSpeaker() {
        guard !isTransmitting else { return }
        let isAudible = audio.speakerPlaybackRecentlyAudible(holdSeconds: Self.receiveAudioAudibleHoldSeconds)
        if receiveAudioActive != isAudible {
            receiveAudioActive = isAudible
        }
        if isAudible {
            scheduleReceiveAudioIdleCheck(after: Self.receiveAudioAudibleHoldSeconds)
        }
    }

    private func scheduleReceiveAudioIdleCheck(after delay: TimeInterval) {
        receiveAudioIdleTask?.cancel()
        receiveAudioIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self, !self.isTransmitting else { return }
                if self.settings.squelch == 0 && self.transportIsConnected && !self.rxSpeakerMutedForAPRSFrequency {
                    if !self.receiveAudioActive {
                        self.receiveAudioActive = true
                    }
                } else {
                    let isAudible = self.audio.speakerPlaybackRecentlyAudible(holdSeconds: Self.receiveAudioAudibleHoldSeconds)
                    if self.receiveAudioActive != isAudible {
                        self.receiveAudioActive = isAudible
                    }
                }
            }
        }
    }

    @discardableResult
    private func reopenReceiveAudioAfterCapture(reason: String, resendPTTOff: Bool) -> Bool {
        do {
            try audio.stopCaptureAndResumePlayback()
            lastDebugLine = "iPhone speaker engine reopened after \(reason); waiting before radio RX audio reopen. \(audio.playbackDebugSummary)"
            return true
        } catch {
            lastDebugLine = "iPhone speaker engine reopen failed after \(reason): \(error.localizedDescription). Trying hard restart."
            ensureReceiveAudioActive(reason: reason, resendPTTOff: resendPTTOff)
            return false
        }
    }

    private func ensureReceiveAudioActive(reason: String, resendPTTOff: Bool) {
        guard !isTransmitting else { return }
        var speakerReady = false
        do {
            try audio.startPlayback()
            speakerReady = true
            lastDebugLine = "iPhone speaker engine ready after \(reason); reopening radio RX audio. \(audio.playbackDebugSummary)"
        } catch {
            do {
                try audio.forceRestartPlayback()
                speakerReady = true
                lastDebugLine = "iPhone speaker engine hard-restarted after \(reason); reopening radio RX audio. \(audio.playbackDebugSummary)"
            } catch {
                statusLine = "Receive audio restart failed: \(error.localizedDescription)"
                lastDebugLine = "RX audio restart failed after \(reason): \(error.localizedDescription)."
            }
        }
        if speakerReady {
            let controlPriority: KV4PTransportPriority = (awaitingRxFrameAfterTransmit || resendPTTOff) ? .urgentDropQueued : .normal
            applySettingsToRadio(
                ptt: false,
                rxAudioOpen: true,
                priority: controlPriority
            )
        }
    }

    private func noteRxAudioFrameAfterTransmitIfNeeded() {
        guard awaitingRxFrameAfterTransmit, !isTransmitting else { return }
        awaitingRxFrameAfterTransmit = false
        receiveReadyAfterTransmit = true
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        statusLine = "Receive audio live."
        lastDebugLine = "RX playback armed after PTT. \(audio.playbackDebugSummary)"
        scheduleQueuedTransmitCheck()
    }

    private func noteRxAudioFrameArrivedButSpeakerMuted(reason: String) {
        guard awaitingRxFrameAfterTransmit, !isTransmitting else { return }
        awaitingRxFrameAfterTransmit = false
        receiveReadyAfterTransmit = true
        receiveAudioActive = false
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        statusLine = reason
        lastDebugLine = "\(reason) Radio audio frames are arriving, but speaker playback is muted by policy. \(audio.playbackDebugSummary)"
        scheduleQueuedTransmitCheck()
    }

    private func finishReceiveRecoveryFallback(reason: String) {
        guard awaitingRxFrameAfterTransmit, !isTransmitting else { return }
        receiveReadyAfterTransmit = true
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        applySettingsToRadio(ptt: false, priority: .urgentDropQueued)
        statusLine = "Radio RX is silent; waiting for audio frames."
        lastDebugLine = "RX control recovery completed by \(reason), but no decoded radio audio frame has arrived. Re-sent RX/PTT-off state."
        scheduleQueuedTransmitCheck()
    }

    private var transmitRecoverySatisfied: Bool {
        let now = Date()
        return now >= transmitRecoveryUntil && (receiveReadyAfterTransmit || now >= transmitRecoveryForceReadyAt)
    }

    private var nextTransmitRecoveryCheckDate: Date {
        let now = Date()
        if now < transmitRecoveryUntil {
            return transmitRecoveryUntil
        }
        if !receiveReadyAfterTransmit && now < transmitRecoveryForceReadyAt {
            return transmitRecoveryForceReadyAt
        }
        return now.addingTimeInterval(0.05)
    }

    private func markReceiveRecoveryStarted() {
        let now = Date()
        receiveReadyAfterTransmit = false
        awaitingRxFrameAfterTransmit = true
        rxAudioUIUpdateGate.forceNextPlaybackReadyUpdate()
        transmitRecoveryUntil = now.addingTimeInterval(Self.minimumRekeyRecoverySeconds)
        transmitRecoveryForceReadyAt = now.addingTimeInterval(Self.maximumRekeyRecoverySeconds)
    }

    private func preemptReceiveRecoveryForTransmit(_ request: QueuedTransmitRequest) {
        queuedTransmitRequest = nil
        queuedTransmitTask?.cancel()
        queuedTransmitTask = nil
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        receiveReadyAfterTransmit = true
        awaitingRxFrameAfterTransmit = false
        transmitRecoveryUntil = .distantPast
        transmitRecoveryForceReadyAt = .distantPast
        statusLine = "Starting transmit..."
        lastDebugLine = "PTT \(request) is preempting RX recovery so microphone capture can start now."
        audio.logDiagnostic("PTT \(request) preempted RX recovery; RX audio stays requested for duplex BLE timing.")
        applySettingsToRadio(ptt: false, rxAudioOpen: true, priority: .urgentDropQueued)
    }

    private func scheduleQueuedTransmitCheck() {
        queuedTransmitTask?.cancel()
        guard queuedTransmitRequest != nil else { return }
        let delay = max(0.05, nextTransmitRecoveryCheckDate.timeIntervalSinceNow)
        queuedTransmitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.startQueuedTransmitIfReady()
            }
        }
    }

    private func startQueuedTransmitIfReady() {
        guard let request = queuedTransmitRequest else { return }
        guard transmitRequestStillWanted(request) else {
            clearQueuedTransmitRequest(matching: request)
            return
        }
        guard transmitRecoverySatisfied else {
            scheduleQueuedTransmitCheck()
            return
        }
        queuedTransmitRequest = nil
        queuedTransmitTask?.cancel()
        queuedTransmitTask = nil
        requestTransmitStart(request)
    }

    private func shouldRetryCaptureStart(_ request: QueuedTransmitRequest, attempt: Int) -> Bool {
        attempt < Self.maximumCaptureStartRetries &&
        transmitRequestStillWanted(request) &&
        transportIsConnected
    }

    private func scheduleCaptureStartRetry(_ request: QueuedTransmitRequest, attempt: Int, error: Error) {
        captureRetryTask?.cancel()
        let delay = Self.captureStartRetryDelays[min(attempt - 1, Self.captureStartRetryDelays.count - 1)]
        statusLine = "Microphone route is not ready; retrying PTT..."
        lastDebugLine = "Mic capture start failed: \(error.localizedDescription). \(audio.currentRouteDebugSummary()). Retry \(attempt + 1) in \(String(format: "%.2f", delay)) s."
        captureRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self,
                      self.transmitRequestStillWanted(request),
                      self.transportIsConnected else {
                    return
                }
                self.beginTransmit(request, captureAttempt: attempt)
            }
        }
    }

    private var transportIsConnected: Bool {
        if case .connected = transportState {
            return true
        }
        return false
    }

    private func handleTransportLostDuringTransmit(reason: String) {
        guard isTransmitting ||
                awaitingRxFrameAfterTransmit ||
                postTransmitRecoveryTask != nil ||
                queuedTransmitRequest != nil ||
                captureRetryTask != nil ||
                stickyPTTStartArmed ||
                momentaryPTTIntentActive else { return }
        transmitGate.end()
        isTransmitting = false
        momentaryPTTIntentActive = false
        stickyPTTStartArmed = false
        clearQueuedTransmitRequest()
        captureRetryTask?.cancel()
        captureRetryTask = nil
        postTransmitRecoveryTask?.cancel()
        postTransmitRecoveryTask = nil
        audio.resetCapturePathAfterFailure()
        receiveReadyAfterTransmit = true
        awaitingRxFrameAfterTransmit = false
        needsStateResendAfterReconnect = true
        transmitRecoveryUntil = .distantPast
        transmitRecoveryForceReadyAt = .distantPast
        lastDebugLine = "BLE dropped during TX/recovery; mic capture stopped and radio state will be resent after reconnect. \(reason)"
    }

    private func transmitRequestStillWanted(_ request: QueuedTransmitRequest) -> Bool {
        switch request {
        case .momentary:
            return momentaryPTTIntentActive
        case .sticky:
            return stickyPTTStartArmed
        }
    }

    private func clearTransmitStartState(for request: QueuedTransmitRequest) {
        clearQueuedTransmitRequest(matching: request)
        captureRetryTask?.cancel()
        captureRetryTask = nil
        switch request {
        case .momentary:
            momentaryPTTIntentActive = false
        case .sticky:
            stickyPTTStartArmed = false
        }
    }

    private func clearQueuedTransmitRequest(matching request: QueuedTransmitRequest? = nil) {
        if request == nil || queuedTransmitRequest == request {
            queuedTransmitRequest = nil
            queuedTransmitTask?.cancel()
            queuedTransmitTask = nil
        }
    }

    private func modeLabel(_ mode: DeviceMode?) -> String {
        switch mode {
        case .some(.tx): return "TX"
        case .some(.rx): return "RX"
        case .some(.stopped): return "stopped"
        case .some(.unknown): return "unknown"
        case .none: return "none"
        }
    }

    private static func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private static func makeQASampleAPRSMessages() -> [APRSMessage] {
        let now = Date()
        return [
            APRSMessage(
                type: .position,
                from: "WX4ATL-7",
                to: "APAT81",
                body: "Main HT | Messaging Capable | www.arid.club",
                timestamp: now,
                latitude: 33.8012,
                longitude: -84.5028,
                symbolTable: "/",
                symbolCode: ">",
                dataPoints: [
                    APRSDataPoint(label: "Course", value: "175°", systemImage: "location.north.line", tint: "blue"),
                    APRSDataPoint(label: "Speed", value: "0 mph", systemImage: "speedometer", tint: "green"),
                    APRSDataPoint(label: "Altitude", value: "728 ft", systemImage: "mountain.2", tint: "orange")
                ]
            ),
            APRSMessage(
                type: .weather,
                from: "WX4ATL-13",
                to: "APRS",
                body: "Weather report",
                timestamp: now.addingTimeInterval(-60),
                dataPoints: [
                    APRSDataPoint(label: "Wind dir", value: "220°", systemImage: "safari", tint: "blue"),
                    APRSDataPoint(label: "Wind", value: "5 mph", systemImage: "wind", tint: "blue"),
                    APRSDataPoint(label: "Gust", value: "12 mph", systemImage: "wind.snow", tint: "blue"),
                    APRSDataPoint(label: "Temp", value: "77°F", systemImage: "thermometer.medium", tint: "orange"),
                    APRSDataPoint(label: "Humidity", value: "50%", systemImage: "humidity", tint: "cyan"),
                    APRSDataPoint(label: "Pressure", value: "1013.2 mb", systemImage: "barometer", tint: "purple")
                ]
            )
        ]
    }

    private static let minimumRekeyRecoverySeconds: TimeInterval = 0.2
    private static let maximumRekeyRecoverySeconds: TimeInterval = 0.75
    private static let postTransmitRecoveryDelaysMS = [90, 220, 520, 1_000, 1_700]
    private static let postTransmitPTTOffResendDelayMS = 1_000
    private static let postTransmitForceReadyDelayMS = 1_700
    private static let maximumCaptureStartRetries = 3
    private static let captureStartRetryDelays: [TimeInterval] = [0.18, 0.45, 0.9]
    private static let beaconRetuneDelaySeconds: TimeInterval = 0.45
    private static let beaconRestoreDelaySeconds: TimeInterval = 3.0
    private static let cachedLocationFreshnessSeconds: TimeInterval = 300
    private static let receiveActivitySpeakerSettleSeconds: TimeInterval = 0.18
    private static let receiveAudioAudibleHoldSeconds: TimeInterval = 2.6
    private static let receiveAudioOpenSquelchHoldSeconds: TimeInterval = 8.0
    private static let aprsFrequencyMatchToleranceMHz: Float = 0.001
}

private final class APRSLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pendingCompletion: ((Result<CLLocation, Error>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func requestLocation(desiredAccuracy: CLLocationAccuracy, completion: @escaping (Result<CLLocation, Error>) -> Void) {
        if pendingCompletion != nil {
            finish(.failure(APRSLocationProviderError.requestAlreadyInFlight))
        }

        pendingCompletion = completion
        manager.desiredAccuracy = desiredAccuracy
        manager.pausesLocationUpdatesAutomatically = false

        switch manager.authorizationStatus {
        case .notDetermined:
            // Manual APRS beacons only need foreground location access.
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(APRSLocationProviderError.permissionDenied))
        @unknown default:
            finish(.failure(APRSLocationProviderError.permissionDenied))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pendingCompletion != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(APRSLocationProviderError.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(APRSLocationProviderError.permissionDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(APRSLocationProviderError.noLocation))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}

private enum APRSLocationProviderError: LocalizedError {
    case noLocation
    case permissionDenied
    case requestAlreadyInFlight

    var errorDescription: String? {
        switch self {
        case .noLocation:
            return "The iPhone did not return a GPS location for the APRS beacon."
        case .permissionDenied:
            return "Allow location access to send APRS position beacons."
        case .requestAlreadyInFlight:
            return "A previous APRS location request was cancelled."
        }
    }
}

private enum APRSBeaconError: LocalizedError {
    case invalidFrequency

    var errorDescription: String? {
        "Beacon frequency setting is invalid."
    }
}

private final class TransmitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSession: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        activeSession &+= 1
        let session = activeSession
        lock.unlock()
        return session
    }

    func end() {
        lock.lock()
        activeSession &+= 1
        lock.unlock()
    }

    func isActive(_ session: UInt64) -> Bool {
        lock.lock()
        let active = activeSession == session
        lock.unlock()
        return active
    }
}

private final class RXAudioUIUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReadyUpdate = Date.distantPast
    private var lastPrerollUpdate = Date.distantPast
    private var forceNextReady = true

    func shouldScheduleMainUpdate(playbackIsReady: Bool) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        if playbackIsReady {
            if forceNextReady || now.timeIntervalSince(lastReadyUpdate) >= receiveActivityUpdateIntervalSeconds {
                forceNextReady = false
                lastReadyUpdate = now
                return true
            }
            return false
        }

        if now.timeIntervalSince(lastPrerollUpdate) >= audioDebugUpdateIntervalSeconds {
            lastPrerollUpdate = now
            return true
        }
        return false
    }

    func forceNextPlaybackReadyUpdate() {
        lock.lock()
        forceNextReady = true
        lock.unlock()
    }
}

private enum QueuedTransmitRequest: Equatable {
    case momentary
    case sticky
}

enum RadioFlags {
    static let radioConfigValid: UInt16 = 1 << 0
    static let pttRequested: UInt16 = 1 << 1
    static let rxAudioOpen: UInt16 = 1 << 2
    static let highPower: UInt16 = 1 << 3
    static let rssiEnabled: UInt16 = 1 << 4
    static let filterPre: UInt16 = 1 << 5
    static let filterHigh: UInt16 = 1 << 6
    static let filterLow: UInt16 = 1 << 7
    static let txAllowed: UInt16 = 1 << 11
    static let enableStatusReports: UInt16 = 1 << 12
    static let rxPowerSave: UInt16 = 1 << 13
    static let rxPowerSaveMaximum: UInt16 = 1 << 14
}
