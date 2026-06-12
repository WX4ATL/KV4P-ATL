// SPDX-License-Identifier: GPL-3.0-or-later
import CoreBluetooth
import Foundation

final class BLEKissTransport: NSObject, KV4PTransport, @unchecked Sendable {
    static var serviceUUID: CBUUID { CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") }
    static var rxUUID: CBUUID { CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") }
    static var txUUID: CBUUID { CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") }

    var eventHandler: ((KV4PTransportEvent) -> Void)?
    private(set) var state: KV4PTransportState = .idle {
        didSet { eventHandler?(.state(state)) }
    }

    private let bleQueue = DispatchQueue(label: "com.blakeross.kv4patl.ble", qos: .userInitiated)
    private let bleQueueKey = DispatchSpecificKey<Void>()
    private lazy var central = CBCentralManager(delegate: self, queue: bleQueue)
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingStart = false
    private var scanMode: ScanMode = .serviceFiltered
    private var scanFallbackWorkItem: DispatchWorkItem?
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var reconnectFallbackWorkItem: DispatchWorkItem?
    private var outgoingFrames: [OutgoingFrame] = []
    private var outgoingFrameOffset = 0
    private var writePumpWorkItem: DispatchWorkItem?
    private var lastWriteDate = Date.distantPast
    private var writeType: CBCharacteristicWriteType?
    private var waitingForWriteResponse = false
    private var reconnectAttempt = 0
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        bleQueue.setSpecific(key: bleQueueKey, value: ())
    }

    func start() {
        syncOnBLEQueue {
            pendingStart = true
            _ = central
            if central.state == .poweredOn {
                startPreferredReconnectOrScan()
            } else {
                debug("Waiting for iPhone Bluetooth to become available...")
            }
        }
    }

    func stop() {
        syncOnBLEQueue {
            pendingStart = false
            invalidateScanTimers()
            central.stopScan()
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            resetPeripheralState()
            state = .disconnected("Stopped")
        }
    }

    func send(_ data: Data) throws {
        try send(data, priority: .normal)
    }

    func send(_ data: Data, priority: KV4PTransportPriority) throws {
        try syncOnBLEQueue {
            guard case .connected = state else { throw KV4PTransportError.notConnected }
            guard peripheral != nil else { throw KV4PTransportError.notConnected }
            guard writeCharacteristic != nil else { throw KV4PTransportError.writeUnavailable }
            guard writeType != nil else { throw KV4PTransportError.writeUnavailable }

            if priority == .urgentDropQueued {
                clearOutgoingWrites()
                lastWriteDate = .distantPast
                debug("Prioritizing radio control command and dropping queued audio writes.")
            }
            outgoingFrames.append(OutgoingFrame(data: data, writeType: writeType(for: priority), priority: priority))
            if priority == .realtimeAudio {
                trimQueuedRealtimeAudioFramesIfNeeded()
            }
            pumpWrites()
        }
    }

    private func startPreferredReconnectOrScan() {
        guard pendingStart, central.state == .poweredOn else { return }
        invalidateScanTimers()
        central.stopScan()
        resetPeripheralState()

        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connectKnownPeripheral(connected, reason: "KV4P bridge is already connected to iOS; opening app session.")
            scheduleReconnectFallbackScan(after: Self.knownReconnectFallbackSeconds, reason: "Already-connected KV4P did not finish opening; scanning again for KV4P HT.")
            return
        }

        if let uuidString = defaults.string(forKey: Self.rememberedPeripheralIDKey),
           let uuid = UUID(uuidString: uuidString),
           let remembered = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connectKnownPeripheral(remembered, reason: "Reconnecting to the remembered KV4P HT.")
            scheduleReconnectFallbackScan(after: Self.knownReconnectFallbackSeconds, reason: "Remembered KV4P reconnect is taking too long; scanning again for KV4P HT.")
            return
        }

        startServiceFilteredScan()
    }

    private func startServiceFilteredScan() {
        guard pendingStart, central.state == .poweredOn else { return }
        resetPeripheralState()
        invalidateScanTimers()
        scanMode = .serviceFiltered
        state = .scanning
        debug("Scanning for the KV4P UART service...")
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        scanFallbackWorkItem = schedule(after: 4) { [weak self] in
            self?.startBroadScan(reason: "Service UUID was not advertised directly; widening scan to KV4P device names.", resetTimeout: false)
        }
        scanTimeoutWorkItem = schedule(after: 22) { [weak self] in
            self?.finishScanWithoutMatch()
        }
    }

    private func startBroadScan(reason: String, resetTimeout: Bool) {
        guard pendingStart, central.state == .poweredOn, peripheral == nil else { return }
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
        if resetTimeout {
            scanTimeoutWorkItem?.cancel()
            scanTimeoutWorkItem = schedule(after: 22) { [weak self] in
                self?.finishScanWithoutMatch()
            }
        }
        scanMode = .broad
        state = .scanning
        debug(reason)
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func finishScanWithoutMatch() {
        guard pendingStart, peripheral == nil else { return }
        central.stopScan()
        state = .failed("No KV4P BLE bridge found. Confirm the radio is powered, flashed with BLE firmware, nearby, and not connected to another device.")
        debug("Tried service-filtered and broad BLE scans for \(Self.serviceUUID.uuidString).")
    }

    private func connect(to peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        invalidateScanTimers()
        central.stopScan()
        remember(peripheral)
        self.peripheral = peripheral
        peripheral.delegate = self
        let name = displayName(for: peripheral, advertisementData: advertisementData)
        state = .connecting(name)
        debug("Found \(name) at \(RSSI.intValue) dBm. Opening BLE link...")
        central.connect(peripheral, options: connectionOptions())
    }

    private func connectKnownPeripheral(_ peripheral: CBPeripheral, reason: String) {
        invalidateScanTimers()
        central.stopScan()
        resetPeripheralState(keepPeripheral: true)
        remember(peripheral)
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(displayName(for: peripheral))
        debug(reason)
        central.connect(peripheral, options: connectionOptions())
    }

    private func resetPeripheralState(keepPeripheral: Bool = false) {
        if !keepPeripheral {
            peripheral = nil
        }
        writeCharacteristic = nil
        notifyCharacteristic = nil
        writeType = nil
        waitingForWriteResponse = false
        clearOutgoingWrites()
    }

    private func invalidateScanTimers() {
        scanFallbackWorkItem?.cancel()
        scanTimeoutWorkItem?.cancel()
        retryWorkItem?.cancel()
        reconnectFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
        scanTimeoutWorkItem = nil
        retryWorkItem = nil
        reconnectFallbackWorkItem = nil
    }

    private func retryBroadScan(after delay: TimeInterval, reason: String) {
        retryWorkItem?.cancel()
        retryWorkItem = schedule(after: delay) { [weak self] in
            guard let self, self.pendingStart, self.central.state == .poweredOn else { return }
            self.retryWorkItem = nil
            self.resetPeripheralState()
            self.startBroadScan(reason: reason, resetTimeout: true)
        }
    }

    private func retryKnownPeripheral(_ peripheral: CBPeripheral, after delay: TimeInterval, reason: String) {
        retryWorkItem?.cancel()
        retryWorkItem = schedule(after: delay) { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.pendingStart,
                  self.central.state == .poweredOn else { return }
            self.retryWorkItem = nil
            self.resetPeripheralState(keepPeripheral: true)
            self.remember(peripheral)
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting(self.displayName(for: peripheral))
            self.debug(reason)
            self.central.connect(peripheral, options: self.connectionOptions())
            self.scheduleReconnectFallbackScan(after: Self.knownReconnectFallbackSeconds, reason: "Known-device reconnect is taking too long; scanning again for KV4P HT.")
        }
    }

    private func scheduleReconnectFallbackScan(after delay: TimeInterval, reason: String) {
        reconnectFallbackWorkItem?.cancel()
        reconnectFallbackWorkItem = schedule(after: delay) { [weak self] in
            guard let self, self.pendingStart else { return }
            if case .connected = self.state { return }
            self.reconnectFallbackWorkItem = nil
            self.resetPeripheralState()
            self.startBroadScan(reason: reason, resetTimeout: true)
        }
    }

    private func advertisementMatchesTarget(_ advertisementData: [String: Any], peripheral: CBPeripheral) -> Bool {
        let serviceKeys = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey
        ]
        let advertisedServices = serviceKeys.flatMap { key in
            advertisementData[key] as? [CBUUID] ?? []
        }
        if advertisedServices.contains(Self.serviceUUID) {
            return true
        }

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        return [localName, peripheral.name]
            .compactMap { $0?.uppercased() }
            .contains { $0.contains("KV4P") }
    }

    private func displayName(for peripheral: CBPeripheral, advertisementData: [String: Any]? = nil) -> String {
        let advertisedName = advertisementData?[CBAdvertisementDataLocalNameKey] as? String
        return advertisedName ?? peripheral.name ?? "KV4P HT BLE"
    }

    private func remember(_ peripheral: CBPeripheral) {
        defaults.set(peripheral.identifier.uuidString, forKey: Self.rememberedPeripheralIDKey)
    }

    private func selectWriteType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType? {
        if characteristic.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        if characteristic.properties.contains(.write) {
            return .withResponse
        }
        return nil
    }

    private func writeType(for priority: KV4PTransportPriority) -> CBCharacteristicWriteType {
        guard priority == .urgentDropQueued,
              writeCharacteristic?.properties.contains(.write) == true else {
            return writeType ?? .withoutResponse
        }
        // PTT-off must beat stale TX audio. Use an acknowledged ATT write for
        // urgent control when the Nordic UART-compatible RX characteristic has it.
        return .withResponse
    }

    private func completeConnectionIfReady(on peripheral: CBPeripheral) {
        guard let writeType,
              writeCharacteristic != nil,
              let notifyCharacteristic,
              notifyCharacteristic.isNotifying else {
            return
        }
        if case .connected = state {
            pumpWrites()
            return
        }
        let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
        reconnectAttempt = 0
        retryWorkItem?.cancel()
        reconnectFallbackWorkItem?.cancel()
        retryWorkItem = nil
        reconnectFallbackWorkItem = nil
        state = .connected(displayName(for: peripheral))
        debug("BLE data pipe ready. Write mode: \(writeType == .withoutResponse ? "fast" : "acknowledged"), payload: \(mtu) bytes.")
        pumpWrites()
    }

    private func pumpWrites() {
        writePumpWorkItem?.cancel()
        writePumpWorkItem = nil

        guard let peripheral,
              let writeCharacteristic,
              writeType != nil,
              case .connected = state,
              !waitingForWriteResponse else {
            return
        }

        guard !outgoingFrames.isEmpty else { return }
        let activeFrame = outgoingFrames[0]
        let activeWriteType = activeFrame.writeType
        let mtu = max(20, peripheral.maximumWriteValueLength(for: activeWriteType))

        if activeWriteType == .withoutResponse {
            guard peripheral.canSendWriteWithoutResponse else {
                return
            }
            let elapsed = Date().timeIntervalSince(lastWriteDate)
            if elapsed < Self.minimumWriteSpacingSeconds {
                scheduleWritePump(after: Self.minimumWriteSpacingSeconds - elapsed)
                return
            }
        }

        let frame = activeFrame.data
        guard !frame.isEmpty else {
            outgoingFrames.removeFirst()
            outgoingFrameOffset = 0
            pumpWrites()
            return
        }
        let chunkEnd = min(frame.count, outgoingFrameOffset + mtu)
        let chunk = frame.subdata(in: outgoingFrameOffset..<chunkEnd)
        outgoingFrameOffset = chunkEnd
        if outgoingFrameOffset >= frame.count {
            outgoingFrames.removeFirst()
            outgoingFrameOffset = 0
        }

        peripheral.writeValue(chunk, for: writeCharacteristic, type: activeWriteType)
        lastWriteDate = Date()

        if activeWriteType == .withResponse {
            waitingForWriteResponse = true
            return
        }

        if !outgoingFrames.isEmpty {
            scheduleWritePump(after: Self.minimumWriteSpacingSeconds)
        }
    }

    private func scheduleWritePump(after delay: TimeInterval) {
        guard writePumpWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.writePumpWorkItem = nil
            self?.pumpWrites()
        }
        writePumpWorkItem = item
        bleQueue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
    }

    private func clearOutgoingWrites() {
        writePumpWorkItem?.cancel()
        writePumpWorkItem = nil
        outgoingFrames.removeAll(keepingCapacity: true)
        outgoingFrameOffset = 0
    }

    private func queuedRealtimeAudioBytes() -> Int {
        guard !outgoingFrames.isEmpty else { return 0 }
        return outgoingFrames.enumerated().reduce(0) { total, item in
            let (index, frame) = item
            guard frame.priority == .realtimeAudio else { return total }
            if index == 0 {
                return total + max(0, frame.data.count - outgoingFrameOffset)
            }
            return total + frame.data.count
        }
    }

    private func trimQueuedRealtimeAudioFramesIfNeeded() {
        var droppedFrames = 0
        while queuedRealtimeAudioBytes() > Self.maximumQueuedRealtimeAudioBytes, outgoingFrames.count > 1 {
            let startIndex = outgoingFrameOffset == 0 ? 0 : 1
            guard let dropIndex = outgoingFrames.indices.dropFirst(startIndex).first(where: { outgoingFrames[$0].priority == .realtimeAudio }) else {
                break
            }
            outgoingFrames.remove(at: dropIndex)
            droppedFrames += 1
        }
        if droppedFrames > 0 {
            debug("Dropped \(droppedFrames) stale queued BLE audio frame(s); kept radio control and APRS writes intact.")
        }
    }

    private func debug(_ message: String) {
        eventHandler?(.debug(message))
    }

    private func connectionOptions() -> [String: Any] {
        [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true,
            CBConnectPeripheralOptionEnableAutoReconnect: true
        ]
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        bleQueue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    private func syncOnBLEQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            return try body()
        }
        return try bleQueue.sync(execute: body)
    }

    private enum ScanMode {
        case serviceFiltered
        case broad
    }
}

extension BLEKissTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn where pendingStart:
            startPreferredReconnectOrScan()
        case .poweredOff:
            state = .failed("Bluetooth is off")
            debug("Turn on Bluetooth, then tap Connect again.")
        case .unauthorized:
            state = .failed("Bluetooth permission is not authorized")
            debug("Allow Bluetooth for KV4P/ATL in Settings.")
        case .unsupported:
            state = .failed("Bluetooth LE is unsupported on this device")
            debug("Simulator and some Macs cannot exercise the KV4P BLE radio path; use the iPhone for hardware testing.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if scanMode == .serviceFiltered || advertisementMatchesTarget(advertisementData, peripheral: peripheral) {
            connect(to: peripheral, advertisementData: advertisementData, rssi: RSSI)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        retryWorkItem?.cancel()
        reconnectFallbackWorkItem?.cancel()
        retryWorkItem = nil
        reconnectFallbackWorkItem = nil
        remember(peripheral)
        debug("BLE link opened. Discovering KV4P UART service...")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reconnectAttempt += 1
        let delay = min(Self.maximumReconnectRetryDelaySeconds, 0.25 * Double(reconnectAttempt))
        state = .disconnected(error?.localizedDescription ?? "Failed to connect; reconnecting...")
        retryKnownPeripheral(peripheral, after: delay, reason: "Known KV4P reconnect failed; trying again before broad scan.")
        scheduleReconnectFallbackScan(after: delay + Self.failedReconnectFallbackSeconds, reason: "Known KV4P reconnect failed; retrying broad KV4P scan.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(peripheral, error: error, isReconnecting: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleDisconnect(peripheral, error: error, isReconnecting: isReconnecting)
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?, isReconnecting: Bool) {
        resetPeripheralState(keepPeripheral: true)
        self.peripheral = peripheral
        peripheral.delegate = self
        let reason = error?.localizedDescription ?? "Disconnected"
        state = .disconnected(isReconnecting ? "BLE link dropped; iOS is reconnecting..." : "BLE link dropped; reconnecting...")
        debug("BLE disconnected from \(displayName(for: peripheral)): \(reason)")
        guard pendingStart else { return }
        if isReconnecting {
            scheduleReconnectFallbackScan(after: Self.systemReconnectFallbackSeconds, reason: "System auto-reconnect is taking too long; scanning again for KV4P HT.")
        } else {
            reconnectAttempt += 1
            let delay = min(Self.maximumReconnectRetryDelaySeconds, 0.18 * Double(reconnectAttempt))
            retryKnownPeripheral(peripheral, after: delay, reason: "BLE link dropped; reconnecting to the known KV4P HT.")
            scheduleReconnectFallbackScan(after: delay + Self.knownReconnectFallbackSeconds, reason: "Known KV4P reconnect is taking too long; scanning again for KV4P HT.")
        }
    }
}

private extension BLEKissTransport {
    struct OutgoingFrame {
        var data: Data
        var writeType: CBCharacteristicWriteType
        var priority: KV4PTransportPriority
    }

    static let rememberedPeripheralIDKey = "kv4patl.rememberedBLEPeripheralID"
    static let minimumWriteSpacingSeconds: TimeInterval = 0.008
    static let maximumQueuedRealtimeAudioBytes = 768
    static let maximumReconnectRetryDelaySeconds: TimeInterval = 1.2
    static let knownReconnectFallbackSeconds: TimeInterval = 2.4
    static let failedReconnectFallbackSeconds: TimeInterval = 2.0
    static let systemReconnectFallbackSeconds: TimeInterval = 2.5
}

extension BLEKissTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            state = .failed("KV4P UART service was not found on this BLE device.")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        debug("KV4P UART service found. Discovering write/notify characteristics...")
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.rxUUID {
                guard let selectedWriteType = selectWriteType(for: characteristic) else {
                    state = .failed("KV4P RX characteristic is not writable.")
                    return
                }
                writeCharacteristic = characteristic
                writeType = selectedWriteType
            } else if characteristic.uuid == Self.txUUID {
                guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                    state = .failed("KV4P TX characteristic does not support notifications.")
                    return
                }
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        guard writeCharacteristic != nil else {
            state = .failed("KV4P RX write characteristic was not found.")
            return
        }
        guard let notifyCharacteristic else {
            state = .failed("KV4P TX notify characteristic was not found.")
            return
        }
        completeConnectionIfReady(on: peripheral)
        if !notifyCharacteristic.isNotifying {
            debug("Subscribing to radio notifications...")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        guard characteristic.isNotifying else {
            state = .failed("KV4P TX notifications did not enable.")
            return
        }
        notifyCharacteristic = characteristic
        completeConnectionIfReady(on: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            eventHandler?(.error(error.localizedDescription))
            return
        }
        if characteristic.uuid == Self.txUUID, let value = characteristic.value {
            eventHandler?(.data(value))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        waitingForWriteResponse = false
        if let error {
            eventHandler?(.error(error.localizedDescription))
            return
        }
        pumpWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}
