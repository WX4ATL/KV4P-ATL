// SPDX-License-Identifier: GPL-3.0-or-later
import CoreBluetooth
import Foundation

private let statsOnly = CommandLine.arguments.contains("--stats-only")
private let probeTimeoutSeconds = intArgument("--timeout-seconds", defaultValue: 70)
private let audioWatchSeconds = intArgument("--watch-seconds", defaultValue: 20)
private let audioLateThresholdMS = intArgument("--late-ms", defaultValue: 90)
private let probeSquelch = max(0, min(100, intArgument("--squelch", defaultValue: 0)))
private let pttCycleMode = CommandLine.arguments.contains("--ptt-cycle")
private let probeHighPower = !CommandLine.arguments.contains("--low-power")
private let txAudioBurstMode = CommandLine.arguments.contains("--tx-audio-burst")
private let txAudioBurstFrames = max(1, intArgument("--tx-audio-frames", defaultValue: 20))
private let txAudioIntervalMS = max(20, intArgument("--tx-audio-interval-ms", defaultValue: 40))
private let aprsTNCMode = CommandLine.arguments.contains("--aprs-tnc")
private let connectionHoldSeconds = intArgument("--hold-seconds", defaultValue: 0)
private let aprsTNCClientKeepalive = CommandLine.arguments.contains("--client-keepalive")

private func intArgument(_ name: String, defaultValue: Int) -> Int {
    let arguments = CommandLine.arguments
    if let exact = arguments.first(where: { $0.hasPrefix("\(name)=") }) {
        return Int(exact.split(separator: "=", maxSplits: 1).last ?? "") ?? defaultValue
    }
    if let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) {
        return Int(arguments[index + 1]) ?? defaultValue
    }
    return defaultValue
}

private enum UUIDs {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let write = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let notify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let aprsService = CBUUID(string: "00000001-BA2A-46C9-AE49-01B0961F68BB")
    static let aprsWrite = CBUUID(string: "00000002-BA2A-46C9-AE49-01B0961F68BB")
    static let aprsNotify = CBUUID(string: "00000003-BA2A-46C9-AE49-01B0961F68BB")

    static var targetService: CBUUID { aprsTNCMode ? aprsService : service }
    static var targetWrite: CBUUID { aprsTNCMode ? aprsWrite : write }
    static var targetNotify: CBUUID { aprsTNCMode ? aprsNotify : notify }
}

private enum Kiss {
    static let fend: UInt8 = 0xC0
    static let fesc: UInt8 = 0xDB
    static let tfend: UInt8 = 0xDC
    static let tfesc: UInt8 = 0xDD
    static let setHardware: UInt8 = 0x06
    static let vendorPrefix = Data("KV4P".utf8)
    static let vendorVersion: UInt8 = 0x01
}

private final class KissParser {
    private var buffer = Data()
    private var inFrame = false
    private var escaped = false

    func feed(_ data: Data) {
        for byte in data {
            process(byte)
        }
    }

    private func process(_ byte: UInt8) {
        if byte == Kiss.fend {
            if !buffer.isEmpty {
                emit()
            }
            buffer.removeAll(keepingCapacity: true)
            inFrame = true
            escaped = false
            return
        }

        guard inFrame else { return }
        if escaped {
            if byte == Kiss.tfend {
                buffer.append(Kiss.fend)
            } else if byte == Kiss.tfesc {
                buffer.append(Kiss.fesc)
            }
            escaped = false
        } else if byte == Kiss.fesc {
            escaped = true
        } else {
            buffer.append(byte)
        }
    }

    private func emit() {
        guard let commandByte = buffer.first else { return }
        let command = commandByte & 0x0F
        let payload = Data(buffer.dropFirst())
        if !statsOnly {
            print("KISS frame command=0x\(String(command, radix: 16)) payload=\(payload.count) bytes")
        }
        guard command == Kiss.setHardware,
              payload.count >= 6,
              Data(payload.prefix(4)) == Kiss.vendorPrefix,
              payload[4] == Kiss.vendorVersion else {
            return
        }
        let vendorCommand = payload[5]
        let vendorPayload = Data(payload.dropFirst(6))
        if !statsOnly {
            print("KV4P vendor command=0x\(String(vendorCommand, radix: 16)) payload=\(vendorPayload.count) bytes")
        }
        if vendorCommand == 0x06, vendorPayload.count == 43 {
            let version = vendorPayload.uint16LE(at: 0)
            let status = vendorPayload[2]
            let window = vendorPayload.uint32LE(at: 3)
            print("HELLO decoded: firmware=\(version), radioStatus=\(status), window=\(window)")
            Probe.shared.didDecodeHello()
        } else if vendorCommand == 0x07 {
            if !statsOnly {
                print("RX_AUDIO decoded: \(vendorPayload.count) bytes")
            }
            Probe.shared.didDecodeRxAudio(frame: vendorPayload)
        } else if vendorCommand == 0x0B, vendorPayload.count >= 26 {
            let sequence = vendorPayload.uint32LE(at: 0)
            let flags = vendorPayload.uint16LE(at: 8)
            let mode = vendorPayload[23]
            let lastError = vendorPayload[24]
            print("DEVICE_STATE decoded: sequence=\(sequence), flags=0x\(String(flags, radix: 16)), mode=\(mode), error=\(lastError)")
            Probe.shared.didDecodeDeviceState(mode: mode)
        }
    }
}

private final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = Probe()

    private var central: CBCentralManager!
    private let appStateMode = CommandLine.arguments.contains("--app-state")
    private let rxAudioOpen = !CommandLine.arguments.contains("--no-rx-audio")
    private let watchAudio = CommandLine.arguments.contains("--watch-audio")
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var parser = KissParser()
    private var sentDesiredState = false
    private var rxAudioFrames = 0
    private var rxAudioBytes = 0
    private var lateRxAudioFrames = 0
    private var maxRxAudioGapMS = 0
    private var rxAudioGapsMS: [Int] = []
    private var firstRxAudioDate: Date?
    private var lastRxAudioDate: Date?
    private var collectedRxAudioFrames: [Data] = []
    private var audioWatchStarted = false
    private var collectingTxAudioSample = false
    private var helloDecoded = false
    private var pttCycleStarted = false
    private var pttOffSent = false
    private var finishing = false
    private var connectedAt: Date?
    private var timeoutWorkItem: DispatchWorkItem?
    private var helloTimeoutWorkItem: DispatchWorkItem?

    func start() {
        print("KV4P BLE probe starting. This will scan, connect, subscribe, and wait for KISS/HELLO bytes.")
        if aprsTNCMode {
            print("APRS-TNC mode enabled: scanning standard BLE KISS service \(UUIDs.aprsService.uuidString).")
            if connectionHoldSeconds > 0 {
                print("APRS-TNC hold enabled: keeping the connection open for \(connectionHoldSeconds) second(s).")
                if aprsTNCClientKeepalive {
                    print("APRS-TNC client keepalive enabled: writing idle FEND bytes once per second.")
                }
            }
        } else if connectionHoldSeconds > 0 {
            print("Main-service hold enabled: keeping the connection open for \(connectionHoldSeconds) second(s) after HELLO.")
        }
        if appStateMode {
            print("App-state mode enabled: after HELLO, the probe will send desired state. RX audio open: \(rxAudioOpen).")
        }
        if pttCycleMode {
            print("PTT-cycle mode enabled: probe will request TX, release TX, then verify RX audio resumes.")
        }
        if txAudioBurstMode {
            print("TX-audio burst mode enabled: probe will recycle \(txAudioBurstFrames) valid RX ADPCM frames into TX audio before PTT-off.")
        }
        central = CBCentralManager(delegate: self, queue: .main)
        scheduleProbeTimeout()
    }

    func finish(_ code: Int32) {
        finishing = true
        timeoutWorkItem?.cancel()
        helloTimeoutWorkItem?.cancel()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(code)
        }
    }

    func didDecodeHello() {
        helloDecoded = true
        helloTimeoutWorkItem?.cancel()
        helloTimeoutWorkItem = nil
        if appStateMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendDesiredStateIfNeeded()
            }
        } else if connectionHoldSeconds > 0 {
            print("HELLO decoded. Holding main-service connection...")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(connectionHoldSeconds)) { [weak self] in
                print("Main-service hold completed without disconnect.")
                self?.finish(0)
            }
        } else {
            finish(0)
        }
    }

    func didDecodeDeviceState(mode: UInt8) {
        if appStateMode {
            if pttCycleMode {
                handlePttCycleDeviceState(mode: mode)
                return
            }
            if watchAudio, !audioWatchStarted {
                startAudioWatch(reason: "App-state desired state was accepted")
                return
            }
            if watchAudio {
                return
            }
            print("App-state desired state was accepted and the firmware stayed connected.")
            finish(0)
        }
    }

    private func handlePttCycleDeviceState(mode: UInt8) {
        if !pttCycleStarted {
            pttCycleStarted = true
            if txAudioBurstMode {
                collectingTxAudioSample = true
                print("Initial RX state accepted. Collecting a short valid ADPCM sample before TX audio burst.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startPttTransmitWindow()
                }
            } else {
                startPttTransmitWindow()
            }
            return
        }

        if pttOffSent, mode == 1, !audioWatchStarted {
            startAudioWatch(reason: "Device reported RX after PTT release")
        }
    }

    private func startAudioWatch(reason: String) {
        audioWatchStarted = true
        print("\(reason); watching RX audio for \(audioWatchSeconds) seconds.")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(audioWatchSeconds)) { [weak self] in
            let frames = self?.rxAudioFrames ?? 0
            let bytes = self?.rxAudioBytes ?? 0
            let late = self?.lateRxAudioFrames ?? 0
            let maxGap = self?.maxRxAudioGapMS ?? 0
            let averageBytes = frames > 0 ? Double(bytes) / Double(frames) : 0
            let timing = self?.rxAudioTimingSummary() ?? "timing unavailable"
            print(String(format: "RX audio watch complete: %d frames, %d ADPCM bytes, %.1f bytes/frame, late %d, max gap %d ms, %@.", frames, bytes, averageBytes, late, maxGap, timing))
            self?.finish(frames > 0 ? 0 : 9)
        }
    }

    private func resetAudioCounters() {
        rxAudioFrames = 0
        rxAudioBytes = 0
        lateRxAudioFrames = 0
        maxRxAudioGapMS = 0
        rxAudioGapsMS.removeAll(keepingCapacity: true)
        firstRxAudioDate = nil
        lastRxAudioDate = nil
    }

    func didDecodeRxAudio(frame: Data) {
        let byteCount = frame.count
        rxAudioFrames += 1
        rxAudioBytes += byteCount
        if txAudioBurstMode,
           (!pttCycleStarted || collectingTxAudioSample),
           collectedRxAudioFrames.count < txAudioBurstFrames {
            collectedRxAudioFrames.append(frame)
        }
        let now = Date()
        if firstRxAudioDate == nil {
            firstRxAudioDate = now
        }
        if let lastRxAudioDate {
            let gapMS = Int(now.timeIntervalSince(lastRxAudioDate) * 1_000)
            rxAudioGapsMS.append(gapMS)
            maxRxAudioGapMS = max(maxRxAudioGapMS, gapMS)
            if gapMS > audioLateThresholdMS {
                lateRxAudioFrames += 1
            }
        }
        lastRxAudioDate = now
    }

    private func startPttTransmitWindow() {
        collectingTxAudioSample = false
        print("Requesting PTT on.")
        sendDesiredState(ptt: true, sequence: 2)

        let txFrames = txAudioBurstMode ? txAudioFramesForBurst() : []
        if !txFrames.isEmpty {
            let delayBeforeAudio = 250
            print("Sending \(txFrames.count) paced TX audio frame(s) after PTT-on.")
            for (index, frame) in txFrames.enumerated() {
                let delayMS = delayBeforeAudio + index * txAudioIntervalMS
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMS)) { [weak self] in
                    self?.sendTxAudio(frame)
                }
            }
        }

        let audioDurationMS = txFrames.isEmpty ? 0 : 250 + txFrames.count * txAudioIntervalMS
        let pttOffDelay = max(1_200, audioDurationMS + 300)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pttOffDelay)) { [weak self] in
            guard let self else { return }
            print("Releasing PTT and requesting RX audio reopen.")
            self.resetAudioCounters()
            self.pttOffSent = true
            self.sendDesiredState(ptt: false, sequence: 3)
        }
    }

    private func txAudioFramesForBurst() -> [Data] {
        guard !collectedRxAudioFrames.isEmpty else {
            print("No reusable RX ADPCM frames were collected; TX-audio burst will be skipped.")
            return []
        }
        return (0..<txAudioBurstFrames).map { index in
            collectedRxAudioFrames[index % collectedRxAudioFrames.count]
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Central state: \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        print("Scanning first by service UUID...")
        central.scanForPeripherals(withServices: [UUIDs.targetService], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.peripheral == nil else { return }
            print("No service-filter hit yet; broad scanning for KV4P name/service.")
            central.stopScan()
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "(unnamed)"
        let services = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey
        ].flatMap { advertisementData[$0] as? [CBUUID] ?? [] }
        let matches = services.contains(UUIDs.targetService) || name.uppercased().contains("KV4P")
        if matches || !statsOnly {
            print("Discovered \(name), RSSI=\(RSSI), services=\(services.map { $0.uuidString }.joined(separator: ","))")
        }
        guard matches, self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        print("Connecting to \(name)...")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedAt = Date()
        print("Connected. Discovering \(aprsTNCMode ? "KV4P APRS TNC" : "KV4P") service...")
        peripheral.discoverServices([UUIDs.targetService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        finish(3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let elapsed = connectedAt.map { String(format: "%.2f s", Date().timeIntervalSince($0)) } ?? "unknown duration"
        print("Disconnected after \(elapsed): \(error?.localizedDescription ?? "clean disconnect")")
        if !finishing {
            print("Unexpected disconnect before the probe finished.")
            finish(8)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("Service discovery error: \(error.localizedDescription)")
            finish(4)
            return
        }
        print("Services: \((peripheral.services ?? []).map { $0.uuid.uuidString })")
        guard let service = peripheral.services?.first(where: { $0.uuid == UUIDs.targetService }) else {
            print("\(aprsTNCMode ? "KV4P APRS TNC" : "KV4P") service missing.")
            finish(5)
            return
        }
        peripheral.discoverCharacteristics([UUIDs.targetWrite, UUIDs.targetNotify], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            print("Characteristic discovery error: \(error.localizedDescription)")
            finish(6)
            return
        }
        for characteristic in service.characteristics ?? [] {
            print("Characteristic \(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)")
            if characteristic.uuid == UUIDs.targetWrite {
                writeCharacteristic = characteristic
                writeType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            } else if characteristic.uuid == UUIDs.targetNotify {
                print("Subscribing to notifications...")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("Notify subscription error: \(error.localizedDescription)")
            finish(7)
            return
        }
        print("Notify state for \(characteristic.uuid.uuidString): \(characteristic.isNotifying)")
        if aprsTNCMode {
            guard connectionHoldSeconds > 0 else {
                print("APRS TNC service is connectable and notifications are enabled.")
                finish(0)
                return
            }
            print("APRS TNC service is connectable and notifications are enabled. Holding connection...")
            if aprsTNCClientKeepalive {
                scheduleAprsClientKeepalive()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(connectionHoldSeconds)) { [weak self] in
                print("APRS TNC hold completed without disconnect.")
                self?.finish(0)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard self?.appStateMode == false else { return }
            self?.sendDesiredStateIfNeeded()
        }
        scheduleHelloTimeout()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("Notify value error: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        if !statsOnly {
            print("RX \(value.count) bytes: \(value.hexString)")
        }
        parser.feed(value)
    }

    private func scheduleAprsClientKeepalive() {
        guard aprsTNCMode, !finishing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  !self.finishing,
                  let peripheral = self.peripheral,
                  let writeCharacteristic = self.writeCharacteristic else {
                return
            }
            let keepalive = Data([Kiss.fend, Kiss.fend])
            peripheral.writeValue(keepalive, for: writeCharacteristic, type: self.writeType)
            self.scheduleAprsClientKeepalive()
        }
    }

    private func sendDesiredStateIfNeeded() {
        guard !sentDesiredState,
              let peripheral,
              let writeCharacteristic else {
            return
        }
        sentDesiredState = true
        let frame = makeDesiredStateFrame(ptt: false, sequence: 1)
        let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
        print("Sending non-PTT desired-state probe, \(frame.count) bytes, writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse"), mtu=\(mtu), squelch=\(probeSquelch), highPower=\(probeHighPower), lateThreshold=\(audioLateThresholdMS)ms")
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            peripheral.writeValue(frame.subdata(in: offset..<end), for: writeCharacteristic, type: writeType)
            offset = end
        }
    }

    private func sendDesiredState(ptt: Bool, sequence: UInt32) {
        guard let peripheral,
              let writeCharacteristic else {
            return
        }
        let frame = makeDesiredStateFrame(ptt: ptt, sequence: sequence)
        let selectedWriteType: CBCharacteristicWriteType = (!ptt && writeCharacteristic.properties.contains(.write)) ? .withResponse : writeType
        let mtu = max(20, peripheral.maximumWriteValueLength(for: selectedWriteType))
        print("Sending \(ptt ? "PTT-on" : "PTT-off") desired state, \(frame.count) bytes, writeType=\(selectedWriteType == .withoutResponse ? "withoutResponse" : "withResponse").")
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            peripheral.writeValue(frame.subdata(in: offset..<end), for: writeCharacteristic, type: selectedWriteType)
            offset = end
        }
    }

    private func sendTxAudio(_ payload: Data) {
        guard let peripheral,
              let writeCharacteristic else {
            return
        }
        let frame = makeTxAudioFrame(payload)
        let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            peripheral.writeValue(frame.subdata(in: offset..<end), for: writeCharacteristic, type: writeType)
            offset = end
        }
    }

    private func makeDesiredStateFrame(ptt: Bool, sequence: UInt32) -> Data {
        var host = Data()
        host.appendLE(sequence)
        host.appendLE(UInt32(bitPattern: Int32(-1)))
        var flags: UInt16 = 0x0001 | 0x0800 | 0x1000
        if probeHighPower {
            flags |= 0x0008
        }
        if rxAudioOpen {
            flags |= 0x0004
        }
        if ptt {
            flags |= 0x0002
        }
        host.appendLE(flags)
        host.append(1)
        host.appendFloat32(146.5200)
        host.appendFloat32(146.5200)
        host.append(0)
        host.append(UInt8(probeSquelch))
        host.append(0)

        var payload = Kiss.vendorPrefix
        payload.append(Kiss.vendorVersion)
        payload.append(0x0D)
        payload.append(host)
        return encodeKiss(command: Kiss.setHardware, payload: payload)
    }

    private func makeTxAudioFrame(_ voiceFrame: Data) -> Data {
        var payload = Kiss.vendorPrefix
        payload.append(Kiss.vendorVersion)
        payload.append(0x07)
        payload.append(voiceFrame)
        return encodeKiss(command: Kiss.setHardware, payload: payload)
    }

    private func encodeKiss(command: UInt8, payload: Data) -> Data {
        var frame = Data([Kiss.fend, command])
        for byte in payload {
            if byte == Kiss.fend {
                frame.append(Kiss.fesc)
                frame.append(Kiss.tfend)
            } else if byte == Kiss.fesc {
                frame.append(Kiss.fesc)
                frame.append(Kiss.tfesc)
            } else {
                frame.append(byte)
            }
        }
        frame.append(Kiss.fend)
        return frame
    }

    private func scheduleProbeTimeout() {
        timeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            print("Probe timed out after \(probeTimeoutSeconds) seconds.")
            self?.finish(2)
        }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(probeTimeoutSeconds), execute: item)
    }

    private func scheduleHelloTimeout() {
        helloTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self?.helloDecoded == false else { return }
            print("No HELLO decoded 12 seconds after notifications enabled.")
            self?.finish(8)
        }
        helloTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    private func rxAudioTimingSummary() -> String {
        guard !rxAudioGapsMS.isEmpty else { return "no inter-frame gaps" }
        let sorted = rxAudioGapsMS.sorted()
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        let p99 = percentile(sorted, 0.99)
        let over80 = rxAudioGapsMS.filter { $0 > 80 }.count
        let over120 = rxAudioGapsMS.filter { $0 > 120 }.count
        let over160 = rxAudioGapsMS.filter { $0 > 160 }.count
        let fps: Double
        if let firstRxAudioDate, let lastRxAudioDate {
            let elapsed = max(0.001, lastRxAudioDate.timeIntervalSince(firstRxAudioDate))
            fps = Double(max(0, rxAudioFrames - 1)) / elapsed
        } else {
            fps = 0
        }
        return String(format: "fps %.2f, gap p50/p95/p99 %d/%d/%d ms, >80/%dms %d/%d, >120 %d, >160 %d", fps, p50, p95, p99, audioLateThresholdMS, over80, lateRxAudioFrames, over120, over160)
    }

    private func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendFloat32(_ value: Float32) {
        appendLE(value.bitPattern)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
        | (UInt32(self[offset + 1]) << 8)
        | (UInt32(self[offset + 2]) << 16)
        | (UInt32(self[offset + 3]) << 24)
    }
}

Probe.shared.start()
RunLoop.main.run()
