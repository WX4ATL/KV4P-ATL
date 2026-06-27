// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import AVFoundation
import Foundation

enum KV4PMicrophonePermissionState: String {
    case granted
    case denied
    case undetermined
    case unknown

    var userMessage: String {
        switch self {
        case .granted:
            return "Microphone ready."
        case .denied:
            #if os(macOS)
            return "Enable microphone access in System Settings."
            #else
            return "Enable microphone access in iPhone Settings."
            #endif
        case .undetermined:
            return "Microphone access has not been requested yet."
        case .unknown:
            return "Microphone permission state is unknown."
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}

final class KV4PAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let captureEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackVarispeed = AVAudioUnitVarispeed()
    private let codec: VoiceCodec
    private let workQueue = DispatchQueue(label: "com.blakeross.kv4patl.audio.playback", qos: .userInitiated)
    private let workQueueKey = DispatchSpecificKey<Void>()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: KV4PVoice.engineSampleRate, channels: 1, interleaved: false)!
    private var captureBuffer: [Float] = []
    private var pendingPlaybackBuffers: [AVAudioPCMBuffer] = []
    private var scheduledPlaybackBuffers = 0
    private var bufferedPlaybackActive = false
    private var hasStartedPlaybackOnce = false
    private var playbackGeneration = 0
    private var decodedPlaybackFrames = 0
    private var playbackUnderruns = 0
    private var droppedPlaybackBuffers = 0
    private var latePlaybackFrames = 0
    private var concealedPlaybackFrames = 0
    private var largestArrivalGapMS = 0
    private var adaptiveRebufferPrerollBuffers = KV4PAudioEngine.baseRebufferPrerollBuffers
    private var consecutiveHealthyPlaybackFrames = 0
    private var consecutiveConcealmentBursts = 0
    private var lastPlaybackFrameArrival: Date?
    private var lastPlaybackError: String?
    private var inputTapInstalled = false
    private var playerAttached = false
    private var playbackVarispeedAttached = false
    private var sourceNode: AVAudioSourceNode?
    private var sourceNodeAttached = false
    private var playbackOutputMode: PlaybackOutputMode = .scheduledBuffers
    private var routeChangeObserver: NSObjectProtocol?
    private let playbackRenderLock = NSLock()
    private var playbackSampleRing = [Float](repeating: 0, count: KV4PAudioEngine.playbackSampleRingCapacity)
    private var playbackSampleHead = 0
    private var playbackSampleTail = 0
    private var playbackSampleCount = 0
    private var playbackOutputArmed = false
    private var playbackHasRenderedRealAudio = false
    private var playbackRenderStarved = false
    private var playbackRenderConcealedSamples = 0
    private var renderedRealAudioSamples = 0
    private var renderCallbackCount = 0
    private var concealmentNoiseSeed: UInt32 = 0x4B563450
    private var lastRenderedSample: Float = 0
    private var lastDecodedPeak: Float = 0
    private var lastRenderedPeak: Float = 0
    private var lastAudiblePlaybackDate = Date.distantPast
    private var playbackGraphRecoveryAttempts = 0
    private var lastPlaybackGraphRecovery = Date.distantPast
    private var lastPlaybackGraphRecoveryMessage: String?
    private var lastQueuedPlaybackHardTrim = Date.distantPast
    private var playbackRate: Float = 1.0
    private var lastPlaybackRateLog = Date.distantPast
    private var lastConsoleAudioLog = Date.distantPast
    private var lastPlaybackLifecycleLog = Date.distantPast
    private var scheduledBuffersSinceLifecycleLog = 0
    private var playedBuffersSinceLifecycleLog = 0
    private var lastSessionLogDate = Date.distantPast
    private var lastSpeakerOverrideDate = Date.distantPast
    private var lastCaptureLogDate = Date.distantPast
    private var captureTapCallbacks = 0
    private var encodedCaptureFrames = 0
    private var queuedTxAudioFrames = 0
    private var txAudioSendFailures = 0
    private var txAudioLiveDrops = 0
    private var unsupportedCaptureFormatLogCount = 0
    private var latencyCatchUpCountdown = 0
    private var latencyCatchUpDroppedSamples = 0
    private var mode: AudioMode = .stopped
    private var configuredSessionKind: AudioSessionKind?
    private var playbackGain: Float = KV4PAudioEngine.fixedPlaybackGain
    private var captureGain: Float = 1.35
    private var rxNoiseFloorRMS: Float = 0.02
    private var rxSoftwareSquelchHangFrames = 0
    private var rxSpeakerMutedFrames = 0
    private var rxSoftwareSquelchMutedFrames = 0
    private var rxProcessingSummary = "speaker open"

    init(codec: VoiceCodec = IMAADPCMCodec()) {
        self.codec = codec
        workQueue.setSpecific(key: workQueueKey, value: ())
        #if os(iOS)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification)
        }
        #endif
        logAudio("audio engine initialized; BLE GATT/KISS audio keeps RX playback warm and opens microphone capture only during PTT")
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func requestRecordPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        let permission = microphonePermissionState()
        logAudio("microphone permission request/check state=\(permission.rawValue)")
        switch permission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            logAudio("requesting microphone permission prompt")
            AVAudioApplication.requestRecordPermission { granted in
                self.logAudio("microphone permission prompt completed granted=\(granted)")
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .unknown:
            completion(false)
        }
    }

    func microphonePermissionState() -> KV4PMicrophonePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .unknown
        }
    }

    func startPlayback() throws {
        try syncOnWorkQueue {
            try preparePlaybackEngine(forcePlayback: true)
        }
    }

    func stop() {
        syncOnWorkQueue {
            if inputTapInstalled {
                captureEngine.inputNode.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            captureEngine.stop()
            captureEngine.reset()
            playbackGeneration &+= 1
            pendingPlaybackBuffers.removeAll(keepingCapacity: true)
            scheduledPlaybackBuffers = 0
            bufferedPlaybackActive = false
            hasStartedPlaybackOnce = false
            clearPlaybackSampleRing()
            resetPlaybackStats()
            player.stop()
            engine.stop()
            mode = .stopped
            configuredSessionKind = nil
            deactivateAudioSessionForModeSwitch()
        }
    }

    func stopCaptureAndResumePlayback() throws {
        try syncOnWorkQueue {
            teardownInputTap()
            captureBuffer.removeAll(keepingCapacity: true)
            mode = .playback
            try configureSessionForRadioAudio(requiresInput: false)
            // ADPCM frames are independent enough to keep the receive decoder
            // warm across PTT. Do not clear the speaker queue here; the whole
            // point of the BLE build is to stop rebuilding RX/TX audio streams.
            try preparePlaybackEngine(forcePlayback: false)
            logAudio("capture stopped; receive playback stream left warm \(playbackDebugSummaryOnWorkQueue)")
        }
    }

    func forceRestartPlayback() throws {
        try syncOnWorkQueue {
            teardownInputTap()
            captureBuffer.removeAll(keepingCapacity: true)
            try codec.resetDecoder()
            resetReceivePlaybackQueue(stopPlayer: true)
            try preparePlaybackEngine(forcePlayback: true)
            setPlaybackOutputArmed(false)
            logAudio("receive playback soft-restarted \(playbackDebugSummaryOnWorkQueue)")
        }
    }

    func startCapture(onFrame: @escaping (Data) -> Void) throws {
        try syncOnWorkQueue {
            logAudio("capture start requested. engineRunning=\(engine.isRunning) mode=\(modeLabel) \(describeAudioRoute())")
            if mode != .capture {
                teardownInputTap()
                try codec.resetEncoder()
                try configureSessionForRadioAudio(requiresInput: true)
                ensurePlayerAttached()
                mode = .capture
                logAudio("capture path armed for mic input \(compactRouteSummary())")
            }

            captureBuffer.removeAll()
            resetCaptureStats()
            let input = captureEngine.inputNode
            if inputTapInstalled {
                input.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            if captureEngine.isRunning {
                captureEngine.stop()
            }
            captureEngine.reset()
            var format = captureFormat(for: input)
            if format == nil {
                try configureSessionForRadioAudio(requiresInput: true)
                Thread.sleep(forTimeInterval: Self.inputRouteSettleDelaySeconds)
                format = captureFormat(for: input)
            }
            guard let format else {
                logAudio("capture format unavailable. inputOutput=\(describeFormat(input.outputFormat(forBus: 0))) route=\(describeAudioRoute())")
                throw AudioCodecError.captureUnavailable
            }
            try installInputTap(on: input, diagnosticFormat: format, onFrame: onFrame)
            inputTapInstalled = true
            logAudio("mic tap installed sampleRate=\(format.sampleRate) channels=\(format.channelCount) captureEngineRunningBeforeStart=\(captureEngine.isRunning) \(compactRouteSummary())")

            try startCaptureEngineForLiveMicrophoneInput()
            scheduleCaptureStartWatchdog()
        }
    }

    private func installInputTap(
        on input: AVAudioInputNode,
        diagnosticFormat: AVAudioFormat,
        onFrame: @escaping (Data) -> Void
    ) throws {
        var errorMessage: NSString?
        // Input node taps must use the node's own output format. Supplying a
        // different or inferred format can fail with Core Audio -10868.
        let installed = KV4PInstallAudioTap(input, 0, 512, diagnosticFormat, { [weak self] buffer, _ in
            self?.consume(buffer, onFrame: onFrame)
        }, &errorMessage)
        if installed {
            return
        }

        logAudio("mic tap install rejected by Core Audio: \(errorMessage as String? ?? "unknown"). diagnosticFormat=\(describeFormat(diagnosticFormat)) route=\(describeAudioRoute())")
        throw AudioCodecError.captureUnavailable
    }

    private func startCaptureEngineForLiveMicrophoneInput() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? AVAudioApplication.shared.setInputMuted(false)
        #endif
        try configureSessionForRadioAudio(requiresInput: true)
        captureEngine.prepare()
        try captureEngine.start()
        #if os(iOS)
        logAudio("capture engine started with live microphone input requested. \(describeAudioRoute(session))")
        #else
        logAudio("capture engine started with live microphone input requested. \(describeAudioRoute())")
        #endif
    }

    private func scheduleCaptureStartWatchdog() {
        workQueue.asyncAfter(deadline: .now() + Self.captureStartWatchdogDelaySeconds) { [weak self] in
            guard let self, self.inputTapInstalled, self.mode == .capture else { return }
            if self.captureTapCallbacks == 0 {
                self.logAudio("mic input watchdog: tap installed but no microphone callbacks yet. captureEngineRunning=\(self.captureEngine.isRunning) \(self.describeAudioRoute())")
            } else {
                self.logAudio("mic input watchdog: live callbacks=\(self.captureTapCallbacks) encodedTX=\(self.encodedCaptureFrames)")
            }
        }
    }

    func logDiagnostic(_ message: String) {
        syncOnWorkQueue {
            logAudio(message)
        }
    }

    func noteTxAudioFrameQueued(byteCount: Int) {
        workQueue.async { [weak self] in
            guard let self else { return }
            queuedTxAudioFrames += 1
            if queuedTxAudioFrames <= 3 || queuedTxAudioFrames % 25 == 0 {
                logAudio("TX audio frame queued count=\(queuedTxAudioFrames) bytes=\(byteCount)")
            }
        }
    }

    func noteTxAudioSendFailed(_ error: Error) {
        workQueue.async { [weak self] in
            guard let self else { return }
            txAudioSendFailures += 1
            logAudio("TX audio send failed count=\(txAudioSendFailures): \(error.localizedDescription)")
        }
    }

    func noteTxAudioLiveDrop(byteCount: Int) {
        workQueue.async { [weak self] in
            guard let self else { return }
            txAudioLiveDrops += 1
            if txAudioLiveDrops <= 3 || txAudioLiveDrops % 25 == 0 {
                logAudio("TX audio live-drop count=\(txAudioLiveDrops) bytes=\(byteCount); radio window full")
            }
        }
    }

    func updateGainProfile(micBoost: String) {
        syncOnWorkQueue {
            playbackGain = Self.fixedPlaybackGain
            captureGain = Self.gainMultiplier(for: micBoost, normal: 1.35, high: 1.75)
            logAudio("gain profile rx=fixed \(String(format: "%.2f", playbackGain))x mic=\(micBoost) \(String(format: "%.2f", captureGain))x")
        }
    }

    func resetCapturePathAfterFailure() {
        syncOnWorkQueue {
            teardownInputTap()
            captureBuffer.removeAll(keepingCapacity: true)
            mode = .playback
            logAudio("capture path reset after failure; engine preserved \(compactRouteSummary())")
        }
    }

    func currentRouteDebugSummary() -> String {
        syncOnWorkQueue {
            describeAudioRoute()
        }
    }

    #if os(iOS)
    private func handleAudioRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        workQueue.async { [weak self] in
            guard let self else { return }
            let reason = rawReason.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            let reasonLabel = reason.map { "\($0)" } ?? "unknown"
            let session = AVAudioSession.sharedInstance()
            logAudio("audio route changed reason=\(reasonLabel) \(describeAudioRoute(session))")
            guard mode != .stopped else { return }
            do {
                try configureSessionForRadioAudio(requiresInput: mode == .capture)
                configurePlaybackOutputForCurrentRoute(forceReconnect: true)
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
            } catch {
                logAudio("audio route reconfigure failed after route change: \(error.localizedDescription)")
            }
        }
    }
    #endif

    func playReceivedFrame(_ frame: Data, speakerMuted: Bool = false, softwareSquelchLevel: Int = 0) throws {
        try syncOnWorkQueue {
            _ = try playReceivedFrameOnWorkQueue(
                frame,
                speakerMuted: speakerMuted,
                softwareSquelchLevel: softwareSquelchLevel
            )
        }
    }

    func playReceivedFrameAsync(
        _ frame: Data,
        speakerMuted: Bool = false,
        softwareSquelchLevel: Int = 0,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let playbackIsReady: Bool
            do {
                playbackIsReady = try self.playReceivedFrameOnWorkQueue(
                    frame,
                    speakerMuted: speakerMuted,
                    softwareSquelchLevel: softwareSquelchLevel
                )
            } catch {
                self.lastPlaybackError = "\(error.localizedDescription), frameBytes=\(frame.count)"
                completion?(false)
                return
            }
            completion?(playbackIsReady)
        }
    }

    private func playReceivedFrameOnWorkQueue(
        _ frame: Data,
        speakerMuted: Bool,
        softwareSquelchLevel: Int
    ) throws -> Bool {
        let gapMS = recordPlaybackFrameArrival()
        let samples = try codec.decode(frame)
        let processed = processReceivedSpeakerSamples(
            samples,
            speakerMuted: speakerMuted,
            softwareSquelchLevel: softwareSquelchLevel
        )
        lastDecodedPeak = processed.peak
        lastPlaybackError = nil
        consecutiveConcealmentBursts = 0
        guard processed.shouldPlay else {
            logAudioProgressIfNeeded(reason: processed.reason)
            return false
        }
        try enqueueConcealmentForArrivalGapIfNeeded(gapMS)
        try enqueuePlaybackSamples(processed.samples)
        logAudioProgressIfNeeded(reason: "rx-frame")
        return playbackOutputReady()
    }

    var playbackDebugSummary: String {
        syncOnWorkQueue {
            playbackDebugSummaryOnWorkQueue
        }
    }

    func speakerPlaybackRecentlyAudible(holdSeconds: TimeInterval) -> Bool {
        syncOnWorkQueue {
            Date().timeIntervalSince(lastAudiblePlaybackDate) <= holdSeconds
        }
    }

    private var playbackDebugSummaryOnWorkQueue: String {
        let queued = playbackQueuedFrameCount()
        let queuedLatencyMS = queued * Self.frameDurationMS
        let catchUpFrames = (latencyCatchUpDroppedSamples + KV4PVoice.engineFrameSize - 1) / KV4PVoice.engineFrameSize
        let renderStats = playbackRenderStats()
        var summary = "RX audio \(decodedPlaybackFrames) frames, rendered \(renderStats.frames), cb \(renderStats.callbacks), queued \(queued) (~\(queuedLatencyMS) ms), rate \(String(format: "%.3f", playbackRate))x, late \(latePlaybackFrames), underruns \(playbackUnderruns), conceal \(concealedPlaybackFrames), catchup \(catchUpFrames), drops \(droppedPlaybackBuffers), max gap \(largestArrivalGapMS) ms, buffer \(adaptiveRebufferPrerollBuffers), mic \(inputTapInstalled ? "on" : "off"), mode \(modeLabel), out \(playbackOutputMode.rawValue), peak d/r \(formatPeak(lastDecodedPeak))/\(formatPeak(renderStats.peak)), proc \(rxProcessingSummary), \(compactRouteSummary())"
        if let lastPlaybackGraphRecoveryMessage {
            summary += ", graph \(playbackGraphRecoveryAttempts): \(lastPlaybackGraphRecoveryMessage)"
        }
        if let lastPlaybackError {
            summary += ", error \(lastPlaybackError)"
        }
        return summary
    }

    private var modeLabel: String {
        switch mode {
        case .stopped: "stopped"
        case .playback: "playback"
        case .capture: "capture"
        }
    }

    func playTestTone() throws {
        try syncOnWorkQueue {
            let frameCount = Int(KV4PVoice.engineSampleRate * 0.35)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let channel = buffer.floatChannelData![0]
            for index in 0..<frameCount {
                let fade = min(1, min(Float(index) / 600, Float(frameCount - index) / 600))
                channel[index] = sin(Float(index) * 2 * .pi * 880 / Float(KV4PVoice.engineSampleRate)) * 0.28 * fade
            }
            try preparePlaybackEngine(forcePlayback: true)
            ensurePlayerAttached()
            if !player.isPlaying {
                player.play()
            }
            player.scheduleBuffer(buffer)
        }
    }

    private func enqueuePlaybackBuffer(_ buffer: AVAudioPCMBuffer, allowLowWatermarkRefill: Bool = true) throws {
        try preparePlaybackEngine(forcePlayback: false)
        ensurePlayerAttached()
        pendingPlaybackBuffers.append(buffer)

        if pendingPlaybackBuffers.count > Self.maximumQueuedPlaybackBuffers {
            let overflow = pendingPlaybackBuffers.count - Self.maximumQueuedPlaybackBuffers
            pendingPlaybackBuffers.removeFirst(overflow)
            droppedPlaybackBuffers += overflow
        }
        trimQueuedPlaybackBacklogIfNeeded()

        if !bufferedPlaybackActive {
            let target = hasStartedPlaybackOnce ? adaptiveRebufferPrerollBuffers : initialPlaybackPrerollTarget
            let queuedFrames = playbackQueuedFrameCount()
            guard queuedFrames >= target || shouldForceArmPlayback(queuedFrames: queuedFrames) else {
                try recoverSilentPlaybackGraphIfNeeded(queuedFrames: queuedFrames)
                return
            }
            bufferedPlaybackActive = true
            hasStartedPlaybackOnce = true
            setPlaybackOutputArmed(true)
        }

        schedulePendingPlaybackBuffers()
        updatePlaybackRateForQueuedFrames(playbackQueuedFrameCount())
        if !player.isPlaying {
            player.play()
        }
        scheduledBuffersSinceLifecycleLog += 1
        logPlaybackLifecycleIfNeeded()
        if allowLowWatermarkRefill {
            refillLowPlaybackWatermarkIfNeeded()
        }
        try recoverSilentPlaybackGraphIfNeeded(queuedFrames: playbackQueuedFrameCount())
    }

    private func enqueuePlaybackSamples(_ samples: [Float], allowLowWatermarkRefill: Bool = true) throws {
        guard !samples.isEmpty else { return }
        try preparePlaybackEngine(forcePlayback: false)
        if playbackOutputMode == .sourceRing {
            appendPlaybackSamples(samples)
            let queuedFrames = playbackQueuedFrameCount()
            if !playbackOutputIsArmed() {
                let target = hasStartedPlaybackOnce ? adaptiveRebufferPrerollBuffers : initialPlaybackPrerollTarget
                guard queuedFrames >= target || shouldForceArmPlayback(queuedFrames: queuedFrames) else {
                    return
                }
                bufferedPlaybackActive = true
                hasStartedPlaybackOnce = true
                setPlaybackOutputArmed(true)
            }
            updatePlaybackRateForQueuedFrames(queuedFrames)
            if allowLowWatermarkRefill {
                refillLowPlaybackWatermarkIfNeeded()
            }
            return
        }

        guard let buffer = makePlaybackBuffer(samples: samples) else { return }
        try enqueuePlaybackBuffer(buffer, allowLowWatermarkRefill: allowLowWatermarkRefill)
    }

    private func schedulePendingPlaybackBuffers() {
        while bufferedPlaybackActive,
              scheduledPlaybackBuffers < Self.maximumScheduledPlaybackBuffers,
              !pendingPlaybackBuffers.isEmpty {
            let buffer = pendingPlaybackBuffers.removeFirst()
            scheduledPlaybackBuffers += 1
            let generation = playbackGeneration
            let frameCount = Int(buffer.frameLength)
            let peak = bufferPeak(buffer)
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let audioEngine = self else { return }
                audioEngine.workQueue.async {
                    audioEngine.playbackBufferFinished(generation: generation, frameCount: frameCount, peak: peak)
                }
            }
        }
    }

    private func playbackBufferFinished(generation: Int, frameCount: Int, peak: Float) {
        guard generation == playbackGeneration else { return }
        recordPlayedBuffer(frameCount: frameCount, peak: peak)
        playedBuffersSinceLifecycleLog += 1
        logPlaybackLifecycleIfNeeded()
        scheduledPlaybackBuffers = max(0, scheduledPlaybackBuffers - 1)
        schedulePendingPlaybackBuffers()
        updatePlaybackRateForQueuedFrames(playbackQueuedFrameCount())
        refillLowPlaybackWatermarkIfNeeded()
        if scheduledPlaybackBuffers == 0, pendingPlaybackBuffers.isEmpty {
            bufferedPlaybackActive = false
            playbackUnderruns += 1
            consecutiveHealthyPlaybackFrames = 0
            adaptiveRebufferPrerollBuffers = min(maximumAdaptiveRebufferPrerollTarget, adaptiveRebufferPrerollBuffers + 2)
            updatePlaybackRateForQueuedFrames(0, force: true)
            try? scheduleUnderrunConcealmentBurst()
        }
    }

    private func refillLowPlaybackWatermarkIfNeeded() {
        guard bufferedPlaybackActive else { return }
        let queuedFrames = playbackQueuedFrameCount()
        let minimumContinuousBuffers = minimumContinuousPlaybackTarget
        guard queuedFrames > 0, queuedFrames < minimumContinuousBuffers else { return }
        let framesNeeded = minimumContinuousBuffers - queuedFrames
        let framesToConceal = min(Self.lowWatermarkConcealmentFrames, framesNeeded)
        guard framesToConceal > 0 else { return }
        try? enqueueConcealmentFrames(framesToConceal)
    }

    private func recordPlaybackFrameArrival() -> Int? {
        decodedPlaybackFrames += 1
        let now = Date()
        var recordedGapMS: Int?
        if let lastPlaybackFrameArrival {
            let gapMS = Int(now.timeIntervalSince(lastPlaybackFrameArrival) * 1_000)
            recordedGapMS = gapMS
            largestArrivalGapMS = max(largestArrivalGapMS, gapMS)
            if gapMS > lateFrameThresholdTargetMS {
                latePlaybackFrames += 1
                consecutiveHealthyPlaybackFrames = 0
                let gapFrames = max(baseRebufferPrerollTarget, min(maximumAdaptiveRebufferPrerollTarget, (gapMS + Self.frameDurationMS - 1) / Self.frameDurationMS + 1))
                adaptiveRebufferPrerollBuffers = max(adaptiveRebufferPrerollBuffers, gapFrames)
            } else {
                consecutiveHealthyPlaybackFrames += 1
                if consecutiveHealthyPlaybackFrames >= healthyFramesBeforePrerollStepDownTarget,
                   adaptiveRebufferPrerollBuffers > baseRebufferPrerollTarget {
                    adaptiveRebufferPrerollBuffers -= 1
                    consecutiveHealthyPlaybackFrames = 0
                }
            }
        }
        lastPlaybackFrameArrival = now
        return recordedGapMS
    }

    private func enqueueConcealmentForArrivalGapIfNeeded(_ gapMS: Int?) throws {
        guard let gapMS, gapMS > lateFrameThresholdTargetMS else { return }
        let missingFrames = max(0, (gapMS + (Self.frameDurationMS / 2)) / Self.frameDurationMS - 1)
        guard missingFrames > 0 else { return }

        let queuedFrames = playbackQueuedFrameCount()
        let framesToConceal = min(Self.maximumConcealmentFramesPerGap, max(0, missingFrames - queuedFrames + 1))
        guard framesToConceal > 0 else { return }
        try enqueueConcealmentFrames(framesToConceal)
    }

    private func scheduleUnderrunConcealmentBurst() throws {
        guard consecutiveConcealmentBursts < Self.maximumConsecutiveConcealmentBursts else { return }
        consecutiveConcealmentBursts += 1
        bufferedPlaybackActive = true
        hasStartedPlaybackOnce = true
        try enqueueConcealmentFrames(Self.underrunConcealmentBurstFrames)
        setPlaybackOutputArmed(true)
    }

    private func enqueueConcealmentFrames(_ count: Int) throws {
        guard count > 0 else { return }
        for _ in 0..<count {
            let samples = try codec.decodePLC()
            try enqueuePlaybackSamples(samples, allowLowWatermarkRefill: false)
            concealedPlaybackFrames += 1
        }
    }

    private func processReceivedSpeakerSamples(
        _ samples: [Float],
        speakerMuted: Bool,
        softwareSquelchLevel: Int
    ) -> RXSpeakerProcessingResult {
        let rms = rmsLevel(samples)
        let peak = peakLevel(samples)
        let squelchLevel = max(0, min(100, softwareSquelchLevel))
        let squelchOpen = speakerMuted ? false : softwareSquelchOpen(
            rms: rms,
            peak: peak,
            squelchLevel: squelchLevel
        )

        let likelyNoiseOnly = speakerMuted
            ? isLikelyNoiseOnly(rms: rms, peak: peak)
            : (!squelchOpen || isLikelyNoiseOnly(rms: rms, peak: peak))
        updateReceiveNoiseFloor(rms: rms, likelyNoiseOnly: likelyNoiseOnly)

        if speakerMuted {
            rxSpeakerMutedFrames += 1
            rxProcessingSummary = "muted APRS \(rxSpeakerMutedFrames), rms \(formatPeak(rms)), noise \(formatPeak(rxNoiseFloorRMS))"
            return RXSpeakerProcessingResult(samples: samples, shouldPlay: false, peak: peak, reason: "rx-speaker-muted")
        }

        guard squelchOpen else {
            rxSoftwareSquelchMutedFrames += 1
            rxProcessingSummary = "squelch closed \(rxSoftwareSquelchMutedFrames), rms \(formatPeak(rms)), noise \(formatPeak(rxNoiseFloorRMS))"
            return RXSpeakerProcessingResult(samples: samples, shouldPlay: false, peak: peak, reason: "rx-software-squelch")
        }

        rxProcessingSummary = "speaker open, rms \(formatPeak(rms)), noise \(formatPeak(rxNoiseFloorRMS))"
        return RXSpeakerProcessingResult(samples: samples, shouldPlay: true, peak: peak, reason: "rx-frame")
    }

    private func softwareSquelchOpen(rms: Float, peak: Float, squelchLevel: Int) -> Bool {
        guard squelchLevel > 0 else {
            rxSoftwareSquelchHangFrames = Self.softwareSquelchHangFrameCount
            return true
        }

        let rmsThreshold = softwareSquelchRMSThreshold(for: squelchLevel)
        let peakThreshold = max(rmsThreshold * 3.0, 0.09)
        let signalDetected = rms >= rmsThreshold || peak >= peakThreshold
        if signalDetected {
            rxSoftwareSquelchHangFrames = Self.softwareSquelchHangFrameCount
            return true
        }

        if rxSoftwareSquelchHangFrames > 0 {
            rxSoftwareSquelchHangFrames -= 1
            return true
        }

        return false
    }

    private func softwareSquelchRMSThreshold(for squelchLevel: Int) -> Float {
        let normalized = Float(max(1, min(100, squelchLevel))) / 100.0
        let baseline = max(rxNoiseFloorRMS, 0.018)
        let dynamicThreshold = baseline * (1.55 + normalized * 2.25)
        let absoluteThreshold = 0.018 + normalized * 0.05
        return min(0.22, max(dynamicThreshold, absoluteThreshold))
    }

    private func isLikelyNoiseOnly(rms: Float, peak: Float) -> Bool {
        let floor = max(rxNoiseFloorRMS, 0.004)
        return rms <= floor * 1.35 && peak <= max(0.12, floor * 6.0)
    }

    private func updateReceiveNoiseFloor(rms: Float, likelyNoiseOnly: Bool) {
        guard rms.isFinite, rms > 0 else { return }
        let sample = min(max(rms, 0.001), 0.3)
        let alpha: Float
        if sample < rxNoiseFloorRMS {
            alpha = 0.12
        } else if likelyNoiseOnly {
            alpha = 0.035
        } else {
            alpha = 0.003
        }
        rxNoiseFloorRMS = rxNoiseFloorRMS * (1.0 - alpha) + sample * alpha
    }

    private func makePlaybackBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() {
            channel[index] = Self.softLimit(sample * playbackGain)
        }
        return buffer
    }

    private func bufferPeak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var peak = Float(0)
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[index]))
        }
        return peak
    }

    private func appendPlaybackSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        var droppedSamples = 0
        playbackRenderLock.lock()
        for sample in samples {
            if playbackSampleCount == Self.playbackSampleRingCapacity {
                playbackSampleTail = (playbackSampleTail + 1) % Self.playbackSampleRingCapacity
                playbackSampleCount -= 1
                droppedSamples += 1
            }
            playbackSampleRing[playbackSampleHead] = Self.softLimit(sample * playbackGain)
            playbackSampleHead = (playbackSampleHead + 1) % Self.playbackSampleRingCapacity
            playbackSampleCount += 1
        }
        trimExcessPlaybackLatencyLocked()
        if playbackSampleCount > 0 {
            playbackRenderStarved = false
        }
        playbackRenderLock.unlock()

        if droppedSamples > 0 {
            droppedPlaybackBuffers += max(1, (droppedSamples + KV4PVoice.engineFrameSize - 1) / KV4PVoice.engineFrameSize)
        }
    }

    private func playbackQueuedFrameCount() -> Int {
        playbackRenderLock.lock()
        let sampleCount = playbackSampleCount
        playbackRenderLock.unlock()
        let sourceFrames = (sampleCount + KV4PVoice.engineFrameSize - 1) / KV4PVoice.engineFrameSize
        return sourceFrames + pendingPlaybackBuffers.count + scheduledPlaybackBuffers
    }

    private func playbackRenderStats() -> (frames: Int, callbacks: Int, peak: Float) {
        playbackRenderLock.lock()
        let frames = renderedRealAudioSamples / KV4PVoice.engineFrameSize
        let callbacks = renderCallbackCount
        let peak = lastRenderedPeak
        playbackRenderLock.unlock()
        return (frames, callbacks, peak)
    }

    private func recordPlayedBuffer(frameCount: Int, peak: Float) {
        playbackRenderLock.lock()
        playbackOutputArmed = true
        playbackHasRenderedRealAudio = true
        renderedRealAudioSamples += max(0, frameCount)
        renderCallbackCount += 1
        playbackRenderStarved = false
        lastRenderedPeak = max(lastRenderedPeak * Self.renderPeakDecay, peak)
        playbackRenderLock.unlock()
        if peak >= Self.audiblePlaybackPeakThreshold {
            lastAudiblePlaybackDate = Date()
        }
    }

    private func clearPlaybackSampleRing() {
        playbackRenderLock.lock()
        playbackSampleHead = 0
        playbackSampleTail = 0
        playbackSampleCount = 0
        playbackOutputArmed = false
        playbackHasRenderedRealAudio = false
        playbackRenderStarved = false
        playbackRenderConcealedSamples = 0
        renderedRealAudioSamples = 0
        renderCallbackCount = 0
        latencyCatchUpCountdown = 0
        lastRenderedSample = 0
        lastRenderedPeak = 0
        playbackRenderLock.unlock()
    }

    private func setPlaybackOutputArmed(_ armed: Bool) {
        playbackRenderLock.lock()
        playbackOutputArmed = armed
        if !armed {
            playbackRenderStarved = false
        }
        playbackRenderLock.unlock()
    }

    private func playbackOutputReady() -> Bool {
        playbackRenderLock.lock()
        let ready = playbackOutputArmed && playbackHasRenderedRealAudio
        playbackRenderLock.unlock()
        return ready
    }

    private func playbackOutputIsArmed() -> Bool {
        playbackRenderLock.lock()
        let armed = playbackOutputArmed
        playbackRenderLock.unlock()
        return armed
    }

    private func renderPlayback(frameCount: AVAudioFrameCount, outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        let frames = Int(frameCount)
        guard frames > 0 else { return noErr }

        playbackRenderLock.lock()
        renderCallbackCount += 1
        for frame in 0..<frames {
            let sample = nextRenderSampleLocked()
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                data.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
        let concealedFrames = playbackRenderConcealedSamples / KV4PVoice.engineFrameSize
        if concealedFrames > 0 {
            concealedPlaybackFrames += concealedFrames
            playbackRenderConcealedSamples %= KV4PVoice.engineFrameSize
        }
        playbackRenderLock.unlock()
        return noErr
    }

    private func nextRenderSampleLocked() -> Float {
        if playbackOutputArmed, playbackSampleCount > 0 {
            let sample = playbackSampleRing[playbackSampleTail]
            playbackSampleTail = (playbackSampleTail + 1) % Self.playbackSampleRingCapacity
            playbackSampleCount -= 1
            playbackHasRenderedRealAudio = true
            renderedRealAudioSamples += 1
            playbackRenderStarved = false
            lastRenderedSample = sample
            lastRenderedPeak = max(lastRenderedPeak * Self.renderPeakDecay, abs(sample))
            dropCatchUpSampleIfNeededLocked()
            return sample
        }

        guard playbackOutputArmed, playbackHasRenderedRealAudio else {
            return 0
        }

        // The audio callback is the last safety net: it must never block or
        // wait for BLE. If decoded/PLC audio is late, render a tiny comfort
        // noise floor instead of letting the hardware output go silent.
        if !playbackRenderStarved {
            playbackUnderruns += 1
            playbackRenderStarved = true
        }
        playbackRenderConcealedSamples += 1
        concealmentNoiseSeed = concealmentNoiseSeed &* 1_664_525 &+ 1_013_904_223
        let noiseUnit = Float(Int(concealmentNoiseSeed & 0xffff) - 32_768) / 32_768.0
        lastRenderedSample *= Self.renderFallbackDecay
        let sample = lastRenderedSample + noiseUnit * Self.renderComfortNoiseAmplitude
        return max(-1, min(1, sample))
    }

    private func resetPlaybackStats() {
        decodedPlaybackFrames = 0
        playbackUnderruns = 0
        droppedPlaybackBuffers = 0
        latePlaybackFrames = 0
        concealedPlaybackFrames = 0
        largestArrivalGapMS = 0
        adaptiveRebufferPrerollBuffers = baseRebufferPrerollTarget
        consecutiveHealthyPlaybackFrames = 0
        consecutiveConcealmentBursts = 0
        lastPlaybackFrameArrival = nil
        lastPlaybackError = nil
        lastDecodedPeak = 0
        lastRenderedPeak = 0
        lastAudiblePlaybackDate = .distantPast
        playbackGraphRecoveryAttempts = 0
        lastPlaybackGraphRecovery = .distantPast
        lastPlaybackGraphRecoveryMessage = nil
        lastQueuedPlaybackHardTrim = .distantPast
        updatePlaybackRateForQueuedFrames(0, force: true)
        latencyCatchUpCountdown = 0
        latencyCatchUpDroppedSamples = 0
    }

    private func resetCaptureStats() {
        captureTapCallbacks = 0
        encodedCaptureFrames = 0
        queuedTxAudioFrames = 0
        txAudioSendFailures = 0
        unsupportedCaptureFormatLogCount = 0
        lastCaptureLogDate = .distantPast
    }

    private func recordCaptureTap(peak: Float, encodedFrames: Int) {
        captureTapCallbacks += 1
        encodedCaptureFrames += encodedFrames
        let callbacks = captureTapCallbacks
        let encoded = encodedCaptureFrames
        let now = Date()
        let shouldLog = callbacks <= 3 ||
            encoded <= 3 && encodedFrames > 0 ||
            now.timeIntervalSince(lastCaptureLogDate) >= 0.75
        guard shouldLog else { return }
        lastCaptureLogDate = now
        workQueue.async { [weak self] in
            self?.logAudio("mic tap callback count=\(callbacks) encodedTX=\(encoded) peak=\(String(format: "%.3f", peak))")
        }
    }

    private func resetReceivePlaybackQueue(stopPlayer: Bool) {
        playbackGeneration &+= 1
        pendingPlaybackBuffers.removeAll(keepingCapacity: true)
        scheduledPlaybackBuffers = 0
        bufferedPlaybackActive = false
        hasStartedPlaybackOnce = false
        if stopPlayer {
            player.stop()
        }
        clearPlaybackSampleRing()
        resetPlaybackStats()
    }

    private func shouldForceArmPlayback(queuedFrames: Int) -> Bool {
        queuedFrames >= Self.minimumEmergencyStartupPrerollBuffers &&
        decodedPlaybackFrames >= Self.forceArmAfterDecodedFrames &&
        playbackRenderStats().frames == 0
    }

    private func recoverSilentPlaybackGraphIfNeeded(queuedFrames: Int) throws {
        guard queuedFrames > 0,
              decodedPlaybackFrames >= Self.forceArmAfterDecodedFrames,
              playbackRenderStats().frames == 0 else {
            return
        }

        let renderStats = playbackRenderStats()
        let wasArmed = playbackOutputIsArmed()
        setPlaybackOutputArmed(true)
        if renderStats.callbacks > 0, !wasArmed {
            lastPlaybackGraphRecoveryMessage = "force-armed scheduled playback"
            logAudio("force armed scheduled playback queued=\(queuedFrames) callbacks=\(renderStats.callbacks)")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastPlaybackGraphRecovery) >= Self.playbackGraphRecoveryIntervalSeconds else {
            return
        }
        guard mode != .capture else {
            lastPlaybackGraphRecoveryMessage = "speaker graph recovery deferred while mic capture is active"
            return
        }
        lastPlaybackGraphRecovery = now
        playbackGraphRecoveryAttempts += 1
        logAudio("recovering silent player graph queued=\(queuedFrames) pending=\(pendingPlaybackBuffers.count) scheduled=\(scheduledPlaybackBuffers) callbacks=\(renderStats.callbacks) playing=\(player.isPlaying)")
        try restartPlayerPreservingQueue()
        lastPlaybackGraphRecoveryMessage = "restarted player queue with \(queuedFrames) queued frame(s)"
    }

    private func restartPlayerPreservingQueue() throws {
        teardownInputTap()
        player.stop()
        scheduledPlaybackBuffers = 0
        bufferedPlaybackActive = false
        mode = .playback
        try configureSessionForRadioAudio(requiresInput: false)
        ensurePlayerAttached()
        setPlaybackOutputArmed(!pendingPlaybackBuffers.isEmpty)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !pendingPlaybackBuffers.isEmpty {
            bufferedPlaybackActive = true
            hasStartedPlaybackOnce = true
            schedulePendingPlaybackBuffers()
            player.play()
        }
        logAudio("restarted player queue pending=\(pendingPlaybackBuffers.count) scheduled=\(scheduledPlaybackBuffers) playing=\(player.isPlaying)")
    }

    private func trimQueuedPlaybackBacklogIfNeeded() {
        let queuedBuffers = pendingPlaybackBuffers.count + scheduledPlaybackBuffers
        guard queuedBuffers > liveQueuedPlaybackHardCapTargetBuffers else { return }
        let now = Date()
        guard now.timeIntervalSince(lastQueuedPlaybackHardTrim) >= Self.liveQueuedPlaybackHardTrimCooldownSeconds else {
            return
        }
        lastQueuedPlaybackHardTrim = now

        let oldGeneration = playbackGeneration
        playbackGeneration &+= 1
        player.stop()
        scheduledPlaybackBuffers = 0
        bufferedPlaybackActive = false

        let keepPending = min(liveQueuedPlaybackTrimTargetBuffers, pendingPlaybackBuffers.count)
        let pendingToDrop = pendingPlaybackBuffers.count - keepPending
        if pendingToDrop > 0 {
            pendingPlaybackBuffers.removeFirst(pendingToDrop)
        }

        let scheduledDropped = max(0, queuedBuffers - pendingPlaybackBuffers.count - pendingToDrop)
        let droppedBuffers = pendingToDrop + scheduledDropped
        if droppedBuffers > 0 {
            droppedPlaybackBuffers += droppedBuffers
            latencyCatchUpDroppedSamples += droppedBuffers * KV4PVoice.engineFrameSize
            lastPlaybackGraphRecoveryMessage = "trimmed \(droppedBuffers) stale live buffer(s)"
        }

        if oldGeneration != playbackGeneration {
            logAudio("trimmed stale RX playback backlog queued=\(queuedBuffers) dropped=\(droppedBuffers) kept=\(pendingPlaybackBuffers.count)")
        }
        updatePlaybackRateForQueuedFrames(playbackQueuedFrameCount(), force: true)
    }

    private func updatePlaybackRateForQueuedFrames(_ queuedFrames: Int, force: Bool = false) {
        let desiredRate = desiredPlaybackRate(forQueuedFrames: queuedFrames)
        let maxStep = force ? Self.livePlaybackMaxCatchUpRate - 1.0 : Self.livePlaybackRateStep
        let delta = desiredRate - playbackRate
        let nextRate: Float
        if abs(delta) <= maxStep {
            nextRate = desiredRate
        } else {
            nextRate = playbackRate + (delta > 0 ? maxStep : -maxStep)
        }

        guard force || abs(nextRate - playbackRate) >= Self.livePlaybackMinimumRateChange else { return }
        playbackRate = nextRate
        playbackVarispeed.rate = nextRate

        let now = Date()
        if force || now.timeIntervalSince(lastPlaybackRateLog) >= Self.playbackRateLogIntervalSeconds {
            lastPlaybackRateLog = now
            logAudio("RX live catchup rate=\(String(format: "%.3f", nextRate))x queued=\(queuedFrames)")
        }
    }

    private func desiredPlaybackRate(forQueuedFrames queuedFrames: Int) -> Float {
        let rateTargetBuffers = livePlaybackRateTargetBufferCount
        guard queuedFrames > rateTargetBuffers else { return 1.0 }
        let excessFrames = min(
            queuedFrames - rateTargetBuffers,
            Self.livePlaybackRateFullScaleExcessBuffers
        )
        let ratio = Float(excessFrames) / Float(Self.livePlaybackRateFullScaleExcessBuffers)
        return 1.0 + ratio * (Self.livePlaybackMaxCatchUpRate - 1.0)
    }

    private func trimExcessPlaybackLatencyLocked() {
        let hardCapSamples = liveLatencyHardCapTargetBuffers * KV4PVoice.engineFrameSize
        guard playbackSampleCount > hardCapSamples else { return }
        let targetSamples = liveLatencyTrimTargetBufferCount * KV4PVoice.engineFrameSize
        dropPlaybackSamplesLocked(playbackSampleCount - targetSamples)
        latencyCatchUpCountdown = 0
    }

    private func dropCatchUpSampleIfNeededLocked() {
        let softCapSamples = liveLatencySoftCapTargetBuffers * KV4PVoice.engineFrameSize
        guard playbackSampleCount > softCapSamples else {
            latencyCatchUpCountdown = 0
            return
        }

        latencyCatchUpCountdown -= 1
        guard latencyCatchUpCountdown <= 0 else { return }
        let fastCapSamples = liveLatencyFastCatchUpTargetBuffers * KV4PVoice.engineFrameSize
        latencyCatchUpCountdown = playbackSampleCount > fastCapSamples
            ? liveLatencyFastCatchUpStrideCount
            : liveLatencySlowCatchUpStrideCount
        dropPlaybackSamplesLocked(1)
    }

    private func dropPlaybackSamplesLocked(_ count: Int) {
        let samplesToDrop = min(max(0, count), playbackSampleCount)
        guard samplesToDrop > 0 else { return }
        playbackSampleTail = (playbackSampleTail + samplesToDrop) % Self.playbackSampleRingCapacity
        playbackSampleCount -= samplesToDrop
        latencyCatchUpDroppedSamples += samplesToDrop
    }

    private func preparePlaybackEngine(forcePlayback: Bool = false) throws {
        if forcePlayback {
            teardownInputTap()
            mode = .playback
        } else if mode == .stopped {
            mode = .playback
        }
        try configureSessionForRadioAudio(requiresInput: mode == .capture)
        configurePlaybackOutputForCurrentRoute(forceReconnect: forcePlayback)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            logAudio("engine started mode=\(modeLabel) route=\(compactRouteSummary())")
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, onFrame: @escaping (Data) -> Void) {
        let micSamples = captureSamples(from: buffer)
        guard !micSamples.isEmpty else {
            unsupportedCaptureFormatLogCount += 1
            if unsupportedCaptureFormatLogCount <= 3 || unsupportedCaptureFormatLogCount % 25 == 0 {
                logAudio("mic tap callback had no readable PCM samples count=\(unsupportedCaptureFormatLogCount) format=\(describeFormat(buffer.format))")
            }
            recordCaptureTap(peak: 0, encodedFrames: 0)
            return
        }

        var peak = Float(0)
        var encodedFramesThisBuffer = 0
        for rawSample in micSamples {
            let sample = Self.softLimit(rawSample * captureGain)
            peak = max(peak, abs(sample))
            captureBuffer.append(sample)
            if captureBuffer.count == KV4PVoice.engineFrameSize {
                if let frames = try? codec.encode(captureBuffer) {
                    encodedFramesThisBuffer += frames.count
                    frames.forEach(onFrame)
                }
                captureBuffer.removeAll(keepingCapacity: true)
            }
        }
        recordCaptureTap(peak: peak, encodedFrames: encodedFramesThisBuffer)
    }

    private func captureSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(format.channelCount))
        guard frameCount > 0 else { return [] }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            return readCaptureSamples(buffer: buffer, channelCount: channelCount) { pointer, index in
                pointer.assumingMemoryBound(to: Float.self)[index]
            }
        case .pcmFormatFloat64:
            return readCaptureSamples(buffer: buffer, channelCount: channelCount) { pointer, index in
                Float(pointer.assumingMemoryBound(to: Double.self)[index])
            }
        case .pcmFormatInt16:
            return readCaptureSamples(buffer: buffer, channelCount: channelCount) { pointer, index in
                Float(pointer.assumingMemoryBound(to: Int16.self)[index]) / Float(Int16.max)
            }
        case .pcmFormatInt32:
            return readCaptureSamples(buffer: buffer, channelCount: channelCount) { pointer, index in
                Float(pointer.assumingMemoryBound(to: Int32.self)[index]) / Float(Int32.max)
            }
        case .otherFormat:
            return []
        @unknown default:
            return []
        }
    }

    private func readCaptureSamples(
        buffer: AVAudioPCMBuffer,
        channelCount: Int,
        sampleAt: (UnsafeMutableRawPointer, Int) -> Float
    ) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let isInterleaved = buffer.format.isInterleaved
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard frameCount > 0, !buffers.isEmpty else { return [] }

        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            var sum = Float(0)
            var readableChannels = 0
            for channelIndex in 0..<channelCount {
                let bufferIndex = isInterleaved ? 0 : min(channelIndex, buffers.count - 1)
                guard let data = buffers[bufferIndex].mData else { continue }
                let sampleIndex = isInterleaved ? (frameIndex * channelCount) + channelIndex : frameIndex
                sum += sampleAt(data, sampleIndex)
                readableChannels += 1
            }
            if readableChannels > 0 {
                samples.append(sum / Float(readableChannels))
            }
        }
        return samples
    }

    private func configureSessionForRadioAudio(requiresInput: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let targetCategory: AVAudioSession.Category = requiresInput ? .playAndRecord : .playback
        let targetMode: AVAudioSession.Mode = .default
        let targetOptions: AVAudioSession.CategoryOptions = requiresInput
            ? [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
            : [.mixWithOthers]
        let targetKind: AudioSessionKind = requiresInput ? .capture : .playback

        try applyAudioSessionCategory(
            session,
            category: targetCategory,
            mode: targetMode,
            options: targetOptions,
            kind: targetKind
        )
        if requiresInput {
            preferBuiltInInputIfAvailable(session)
        }
        try? session.setPreferredSampleRate(KV4PVoice.engineSampleRate)
        try? session.setPreferredIOBufferDuration(Self.preferredIOBufferDurationSeconds)
        var lastError: Error?
        for attempt in 0..<Self.audioSessionActivationAttempts {
            do {
                if requiresInput {
                    preferBuiltInInputIfAvailable(session)
                }
                try session.setActive(true)
                if requiresInput {
                    preferBuiltInInputIfAvailable(session)
                    try? session.setPreferredInputNumberOfChannels(1)
                }
                guard session.sampleRate > 0, session.outputNumberOfChannels > 0 else {
                    throw AudioCodecError.playbackUnavailable
                }
                guard !requiresInput || waitForInputRoute(session) else {
                    throw AudioCodecError.captureUnavailable
                }
                let now = Date()
                if requiresInput || now.timeIntervalSince(lastSessionLogDate) >= 2 {
                    lastSessionLogDate = now
                    logAudio("session active requiresInput=\(requiresInput) \(describeAudioRoute(session))")
                }
                return
            } catch {
                lastError = error
                if attempt + 1 < Self.audioSessionActivationAttempts {
                    Thread.sleep(forTimeInterval: Self.audioSessionRetryDelaySeconds)
                    try? applyAudioSessionCategory(
                        session,
                        category: targetCategory,
                        mode: targetMode,
                        options: targetOptions,
                        kind: targetKind
                    )
                }
            }
        }
        throw lastError ?? (requiresInput ? AudioCodecError.captureUnavailable : AudioCodecError.playbackUnavailable)
        #else
        let targetKind: AudioSessionKind = requiresInput ? .capture : .playback
        if configuredSessionKind != targetKind {
            configuredSessionKind = targetKind
            logAudio("macOS Core Audio mode set kind=\(targetKind.rawValue)")
        }
        #endif
    }

    #if os(iOS)
    private func applyAudioSessionCategory(
        _ session: AVAudioSession,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        kind: AudioSessionKind
    ) throws {
        let hasRequiredOptions = session.categoryOptions.intersection(options) == options

        guard configuredSessionKind != kind ||
              session.category != category ||
              session.mode != mode ||
              !hasRequiredOptions else {
            return
        }

        // RX audio should look like ordinary media playback to iOS. Only PTT
        // temporarily enters playAndRecord, then returns to playback so CarPlay,
        // Bluetooth accessories, other audio apps, and other microphones are
        // not held in a call-style route.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(category, mode: mode, options: options)
        configuredSessionKind = kind
        logAudio("audio session category set kind=\(kind.rawValue) category=\(category.rawValue) mode=\(mode.rawValue) options=\(options.rawValue)")
    }

    private func forceSpeakerOutput(_ session: AVAudioSession) {
        let currentOutput = session.currentRoute.outputs.first?.portType
        guard currentOutput != .builtInSpeaker else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpeakerOverrideDate) >= 1 else { return }
        lastSpeakerOverrideDate = now
        do {
            try session.overrideOutputAudioPort(.speaker)
            let output = session.currentRoute.outputs.first?.portType
            if output != .builtInSpeaker {
                logAudio("speaker override requested; current output remains \(output?.rawValue ?? "none")")
            }
        } catch {
            logAudio("speaker override failed: \(error.localizedDescription)")
        }
    }
    #endif

    private func captureFormat(for input: AVAudioInputNode) -> AVAudioFormat? {
        let hardwareFormat = input.outputFormat(forBus: 0)
        if hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 {
            return hardwareFormat
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : KV4PVoice.engineSampleRate
        let channelCount = AVAudioChannelCount(max(1, session.inputNumberOfChannels))
        guard channelCount > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )
        #else
        return nil
        #endif
    }

    private func deactivateAudioSessionForModeSwitch() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func ensurePlayerAttached(forceReconnect: Bool = false) {
        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        if !playbackVarispeedAttached {
            engine.attach(playbackVarispeed)
            playbackVarispeed.rate = playbackRate
            playbackVarispeedAttached = true
        }

        let playerConnections = engine.outputConnectionPoints(for: player, outputBus: 0)
        let rateConnections = engine.outputConnectionPoints(for: playbackVarispeed, outputBus: 0)
        guard forceReconnect || playerConnections.isEmpty || rateConnections.isEmpty else { return }
        if !playerConnections.isEmpty {
            engine.disconnectNodeOutput(player)
        }
        if !rateConnections.isEmpty {
            engine.disconnectNodeOutput(playbackVarispeed)
        }
        engine.connect(player, to: playbackVarispeed, format: playbackFormat)
        engine.connect(playbackVarispeed, to: engine.mainMixerNode, format: playbackFormat)
    }

    private func ensureSourceAttached(forceReconnect: Bool = false) {
        if sourceNode == nil {
            sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, outputData in
                guard let self else { return noErr }
                return self.renderPlayback(frameCount: frameCount, outputData: outputData)
            }
        }
        guard let sourceNode else { return }
        if !sourceNodeAttached {
            engine.attach(sourceNode)
            sourceNodeAttached = true
        }

        let connectionPoints = engine.outputConnectionPoints(for: sourceNode, outputBus: 0)
        guard forceReconnect || connectionPoints.isEmpty else { return }
        if !connectionPoints.isEmpty {
            engine.disconnectNodeOutput(sourceNode)
        }
        engine.connect(sourceNode, to: engine.mainMixerNode, format: playbackFormat)
    }

    private func disconnectSourceOutput() {
        guard let sourceNode else { return }
        let connectionPoints = engine.outputConnectionPoints(for: sourceNode, outputBus: 0)
        guard !connectionPoints.isEmpty else { return }
        engine.disconnectNodeOutput(sourceNode)
    }

    private func configurePlaybackOutputForCurrentRoute(forceReconnect: Bool = false) {
        let desiredMode = preferredPlaybackOutputMode()
        let switchingMode = desiredMode != playbackOutputMode

        if switchingMode {
            logAudio("playback output switching \(playbackOutputMode.rawValue) -> \(desiredMode.rawValue) \(compactRouteSummary())")
            if desiredMode == .sourceRing {
                player.stop()
                pendingPlaybackBuffers.removeAll(keepingCapacity: true)
                scheduledPlaybackBuffers = 0
                clearPlaybackSampleRing()
                bufferedPlaybackActive = false
            } else {
                setPlaybackOutputArmed(false)
                clearPlaybackSampleRing()
                bufferedPlaybackActive = false
                disconnectSourceOutput()
            }
            playbackOutputMode = desiredMode
            adaptiveRebufferPrerollBuffers = baseRebufferPrerollTarget
        }

        switch desiredMode {
        case .scheduledBuffers:
            ensurePlayerAttached(forceReconnect: forceReconnect || switchingMode)
        case .sourceRing:
            ensureSourceAttached(forceReconnect: forceReconnect || switchingMode)
        }
    }

    private func preferredPlaybackOutputMode() -> PlaybackOutputMode {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.contains { isBufferedWirelessOutput($0.portType) } ? .sourceRing : .scheduledBuffers
        #else
        return .scheduledBuffers
        #endif
    }

    #if os(iOS)
    private func preferredPlaybackOutputMode(for session: AVAudioSession) -> PlaybackOutputMode {
        session.currentRoute.outputs.contains { isBufferedWirelessOutput($0.portType) } ? .sourceRing : .scheduledBuffers
    }

    private func isBufferedWirelessOutput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .carAudio, .airPlay:
            return true
        default:
            return false
        }
    }

    private func preferBuiltInInputIfAvailable(_ session: AVAudioSession) {
        guard let inputs = session.availableInputs else { return }
        let preferredInput = inputs.first { $0.portType == .builtInMic } ?? inputs.first
        if let preferredInput {
            try? session.setPreferredInput(preferredInput)
        }
    }

    private func waitForInputRoute(_ session: AVAudioSession) -> Bool {
        let deadline = Date().addingTimeInterval(Self.inputRouteReadyTimeoutSeconds)
        while Date() < deadline {
            if session.inputNumberOfChannels > 0 {
                return true
            }
            preferBuiltInInputIfAvailable(session)
            Thread.sleep(forTimeInterval: Self.inputRoutePollSeconds)
        }
        return session.inputNumberOfChannels > 0
    }

    private func describeAudioRoute(_ session: AVAudioSession = AVAudioSession.sharedInstance()) -> String {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let availableInputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",") ?? "none"
        return "route in[\(inputs.isEmpty ? "none" : inputs)] out[\(outputs.isEmpty ? "none" : outputs)] available[\(availableInputs)] inputChannels=\(session.inputNumberOfChannels) outputChannels=\(session.outputNumberOfChannels) sampleRate=\(Int(session.sampleRate)) io=\(Int(session.ioBufferDuration * 1_000))ms category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
    }
    #else
    private func describeAudioRoute() -> String {
        let input = captureEngine.inputNode.outputFormat(forBus: 0)
        let output = engine.outputNode.outputFormat(forBus: 0)
        return "macOS Core Audio input[\(describeFormat(input))] output[\(describeFormat(output))]"
    }
    #endif

    private func describeFormat(_ format: AVAudioFormat) -> String {
        "sampleRate=\(format.sampleRate) channels=\(format.channelCount) common=\(format.commonFormat.rawValue)"
    }

    private func compactRouteSummary() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        return "out \(output), cat \(session.category.rawValue), sess \(session.mode.rawValue), sr \(Int(session.sampleRate)), io \(Int(session.ioBufferDuration * 1_000)) ms, vol \(String(format: "%.2f", session.outputVolume))"
        #else
        return "macOS Core Audio, \(describeFormat(engine.outputNode.outputFormat(forBus: 0)))"
        #endif
    }

    private static func gainMultiplier(for setting: String, normal: Float, high: Float) -> Float {
        switch setting {
        case "Low": return 1.0
        case "High": return high
        default: return normal
        }
    }

    private static func softLimit(_ sample: Float) -> Float {
        let limited = sample / (1.0 + max(0, abs(sample) - 0.75) * 1.6)
        return max(-0.98, min(0.98, limited))
    }

    private func logAudioProgressIfNeeded(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastConsoleAudioLog) >= Self.audioProgressLogIntervalSeconds else { return }
        lastConsoleAudioLog = now
        logAudio("\(reason): \(playbackDebugSummaryOnWorkQueue)")
    }

    private func logPlaybackLifecycleIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPlaybackLifecycleLog) >= Self.playbackLifecycleLogIntervalSeconds else { return }
        let scheduled = scheduledBuffersSinceLifecycleLog
        let played = playedBuffersSinceLifecycleLog
        guard scheduled > 0 || played > 0 else { return }
        lastPlaybackLifecycleLog = now
        scheduledBuffersSinceLifecycleLog = 0
        playedBuffersSinceLifecycleLog = 0
        logAudio("playback lifecycle aggregate scheduled=\(scheduled) played=\(played) \(playbackDebugSummaryOnWorkQueue)")
    }

    private func logAudio(_ message: String) {
        let line = "[KV4P-AUDIO] \(Date()) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        appendAudioLogLine(line)
    }

    private func appendAudioLogLine(_ line: String) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(Self.audioLogFileName) else {
            return
        }

        let data = Data(line.utf8)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumAudioLogBytes {
                try? FileManager.default.removeItem(at: url)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            FileHandle.standardError.write(Data("[KV4P-AUDIO] log write failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func peakLevel(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    private func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Double(0)) { partial, sample in
            partial + Double(sample * sample)
        }
        return Float(sqrt(sumSquares / Double(samples.count)))
    }

    private func formatPeak(_ peak: Float) -> String {
        String(format: "%.3f", peak)
    }

    private func teardownInputTap() {
        if inputTapInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        captureEngine.stop()
        captureEngine.reset()
    }

    private func syncOnWorkQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil {
            return try body()
        }
        return try workQueue.sync(execute: body)
    }

    private enum AudioMode {
        case stopped
        case playback
        case capture
    }

    private enum AudioSessionKind: String {
        case playback
        case capture
    }

    private enum PlaybackOutputMode: String {
        case scheduledBuffers = "scheduled"
        case sourceRing = "source-ring"
    }

    private struct RXSpeakerProcessingResult {
        var samples: [Float]
        var shouldPlay: Bool
        var peak: Float
        var reason: String
    }


    private var usesWirelessPlaybackProfile: Bool {
        playbackOutputMode == .sourceRing
    }

    private var initialPlaybackPrerollTarget: Int {
        usesWirelessPlaybackProfile ? Self.wirelessInitialPlaybackPrerollBuffers : Self.initialPlaybackPrerollBuffers
    }

    private var baseRebufferPrerollTarget: Int {
        usesWirelessPlaybackProfile ? Self.wirelessBaseRebufferPrerollBuffers : Self.baseRebufferPrerollBuffers
    }

    private var minimumContinuousPlaybackTarget: Int {
        usesWirelessPlaybackProfile ? Self.wirelessMinimumContinuousPlaybackBuffers : Self.minimumContinuousPlaybackBuffers
    }

    private var maximumAdaptiveRebufferPrerollTarget: Int {
        usesWirelessPlaybackProfile ? Self.wirelessMaximumAdaptiveRebufferPrerollBuffers : Self.maximumAdaptiveRebufferPrerollBuffers
    }

    private var healthyFramesBeforePrerollStepDownTarget: Int {
        usesWirelessPlaybackProfile ? Self.wirelessHealthyFramesBeforePrerollStepDown : Self.healthyFramesBeforePrerollStepDown
    }

    private var lateFrameThresholdTargetMS: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLateFrameThresholdMS : Self.lateFrameThresholdMS
    }

    private var livePlaybackRateTargetBufferCount: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLivePlaybackRateTargetBuffers : Self.livePlaybackRateTargetBuffers
    }

    private var liveQueuedPlaybackHardCapTargetBuffers: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveQueuedPlaybackHardCapBuffers : Self.liveQueuedPlaybackHardCapBuffers
    }

    private var liveQueuedPlaybackTrimTargetBuffers: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveQueuedPlaybackTrimTargetBuffers : Self.liveQueuedPlaybackTrimTargetBuffers
    }

    private var liveLatencySoftCapTargetBuffers: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveLatencySoftCapBuffers : Self.liveLatencySoftCapBuffers
    }

    private var liveLatencyFastCatchUpTargetBuffers: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveLatencyFastCatchUpBuffers : Self.liveLatencyFastCatchUpBuffers
    }

    private var liveLatencyHardCapTargetBuffers: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveLatencyHardCapBuffers : Self.liveLatencyHardCapBuffers
    }

    private var liveLatencyTrimTargetBufferCount: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveLatencyTrimTargetBuffers : Self.liveLatencyTrimTargetBuffers
    }

    private var liveLatencySlowCatchUpStrideCount: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveLatencySlowCatchUpStride : Self.liveLatencySlowCatchUpStride
    }

    private var liveLatencyFastCatchUpStrideCount: Int {
        usesWirelessPlaybackProfile ? Self.wirelessLiveLatencyFastCatchUpStride : Self.liveLatencyFastCatchUpStride
    }

    private static let initialPlaybackPrerollBuffers = 2
    private static let baseRebufferPrerollBuffers = 3
    private static let minimumEmergencyStartupPrerollBuffers = 1
    private static let forceArmAfterDecodedFrames = 4
    private static let playbackGraphRecoveryIntervalSeconds: TimeInterval = 0.75
    private static let minimumContinuousPlaybackBuffers = 2
    private static let maximumAdaptiveRebufferPrerollBuffers = 6
    private static let healthyFramesBeforePrerollStepDown = 75
    private static let frameDurationMS = KV4PVoice.frameDurationMS
    private static let maximumConcealmentFramesPerGap = 2
    private static let underrunConcealmentBurstFrames = 2
    private static let lowWatermarkConcealmentFrames = 1
    private static let maximumConsecutiveConcealmentBursts = 4
    private static let softwareSquelchHangFrameCount = 14
    private static let fixedPlaybackGain: Float = 1.55
    private static let maximumScheduledPlaybackBuffers = 6
    private static let maximumQueuedPlaybackBuffers = 18
    private static let lateFrameThresholdMS = 90
    private static let playbackSampleRingCapacity = KV4PVoice.engineFrameSize * 64
    // Keep RX audio close to live time. BLE delivery can arrive in bursts, so
    // drift the player very slightly faster before resorting to emergency trim.
    private static let livePlaybackRateTargetBuffers = 4
    private static let livePlaybackRateFullScaleExcessBuffers = 8
    private static let livePlaybackMaxCatchUpRate: Float = 1.065
    private static let livePlaybackRateStep: Float = 0.006
    private static let livePlaybackMinimumRateChange: Float = 0.0005
    private static let playbackRateLogIntervalSeconds: TimeInterval = 2.5
    private static let liveQueuedPlaybackHardCapBuffers = 36
    private static let liveQueuedPlaybackTrimTargetBuffers = 8
    private static let liveQueuedPlaybackHardTrimCooldownSeconds: TimeInterval = 5.0
    private static let liveLatencySoftCapBuffers = 10
    private static let liveLatencyFastCatchUpBuffers = 16
    private static let liveLatencyHardCapBuffers = 28
    private static let liveLatencyTrimTargetBuffers = 12
    private static let liveLatencySlowCatchUpStride = 36
    private static let liveLatencyFastCatchUpStride = 18
    private static let wirelessInitialPlaybackPrerollBuffers = 6
    private static let wirelessBaseRebufferPrerollBuffers = 6
    private static let wirelessMinimumContinuousPlaybackBuffers = 4
    private static let wirelessMaximumAdaptiveRebufferPrerollBuffers = 12
    private static let wirelessHealthyFramesBeforePrerollStepDown = 120
    private static let wirelessLateFrameThresholdMS = 150
    private static let wirelessLivePlaybackRateTargetBuffers = 8
    private static let wirelessLiveQueuedPlaybackHardCapBuffers = 60
    private static let wirelessLiveQueuedPlaybackTrimTargetBuffers = 14
    private static let wirelessLiveLatencySoftCapBuffers = 18
    private static let wirelessLiveLatencyFastCatchUpBuffers = 28
    private static let wirelessLiveLatencyHardCapBuffers = 44
    private static let wirelessLiveLatencyTrimTargetBuffers = 16
    private static let wirelessLiveLatencySlowCatchUpStride = 48
    private static let wirelessLiveLatencyFastCatchUpStride = 24
    private static let renderFallbackDecay: Float = 0.992
    private static let renderPeakDecay: Float = 0.995
    private static let renderComfortNoiseAmplitude: Float = 0.0018
    private static let audiblePlaybackPeakThreshold: Float = 0.004
    private static let preferredIOBufferDurationSeconds: TimeInterval = 0.01
    private static let audioSessionActivationAttempts = 5
    private static let audioSessionRetryDelaySeconds: TimeInterval = 0.18
    private static let inputRouteReadyTimeoutSeconds: TimeInterval = 0.6
    private static let inputRoutePollSeconds: TimeInterval = 0.05
    private static let inputRouteSettleDelaySeconds: TimeInterval = 0.08
    private static let captureStartWatchdogDelaySeconds: TimeInterval = 0.35
    private static let audioProgressLogIntervalSeconds: TimeInterval = 2.0
    private static let playbackLifecycleLogIntervalSeconds: TimeInterval = 5.0
    private static let audioLogFileName = "kv4p_audio_debug.log"
    private static let maximumAudioLogBytes = 2_000_000
}
