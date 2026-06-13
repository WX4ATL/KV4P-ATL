// SPDX-License-Identifier: GPL-3.0-or-later
import CoreLocation
import XCTest
@testable import kv4patl

final class ProtocolTests: XCTestCase {
    func testKissEncoderEscapesFendAndFesc() {
        let frame = KissCodec.encodeDataFrame(Data([0x11, KissConstants.fend, 0x22, KissConstants.fesc]))

        XCTAssertEqual(frame, Data([
            KissConstants.fend,
            KissConstants.commandData,
            0x11,
            KissConstants.fesc,
            KissConstants.tfend,
            0x22,
            KissConstants.fesc,
            KissConstants.tfesc,
            KissConstants.fend
        ]))
    }

    func testKissParserUnescapesDataFrameAndDispatchesAX25() {
        var frames: [KissFrame] = []
        let parser = KissParser()
        parser.onFrame = { frames.append($0) }

        parser.feed(Data([
            KissConstants.fend,
            KissConstants.commandData,
            0x11,
            KissConstants.fesc,
            KissConstants.tfend,
            0x22,
            KissConstants.fesc,
            KissConstants.tfesc,
            KissConstants.fend
        ]))

        XCTAssertEqual(frames, [.ax25(Data([0x11, KissConstants.fend, 0x22, KissConstants.fesc]))])
    }

    func testKissParserHandlesSplitAndMultipleFrames() {
        var frames: [KissFrame] = []
        let parser = KissParser()
        parser.onFrame = { frames.append($0) }

        parser.feed(Data([KissConstants.fend, KissConstants.commandData, 0x11]))
        XCTAssertTrue(frames.isEmpty)

        let vendor = KissCodec.encodeVendorFrame(command: .txAudio, payload: Data([0x33, 0x44]))
        parser.feed(Data([0x22, KissConstants.fend]) + vendor)

        XCTAssertEqual(frames, [
            .ax25(Data([0x11, 0x22])),
            .vendor(KV4PHostCommand.txAudio.rawValue, Data([0x33, 0x44]))
        ])
    }

    func testKissParserValidatesPortPrefixAndVersion() {
        var frames: [KissFrame] = []
        let parser = KissParser()
        parser.onFrame = { frames.append($0) }

        parser.feed(KissCodec.encode(command: 0x10 | KissConstants.commandData, payload: Data([0x11])))
        parser.feed(KissCodec.encode(command: KissConstants.commandSetHardware, payload: Data("BAD!\u{01}\u{06}".utf8)))
        parser.feed(KissCodec.encode(command: KissConstants.commandSetHardware, payload: Data("KV4P\u{02}\u{06}".utf8)))

        XCTAssertTrue(frames.isEmpty)
    }

    func testHostDesiredStateEncodingIsLittleEndianAndFixedLength() {
        let state = HostDesiredState(
            sequence: 0x01020304,
            memoryId: -2,
            flags: 0x1234,
            bandwidth: 1,
            txFrequency: 146.52,
            rxFrequency: 144.39,
            txTone: 7,
            squelch: 42,
            rxTone: 9
        )

        let encoded = state.encoded()

        XCTAssertEqual(encoded.count, HostDesiredState.byteLength)
        XCTAssertEqual(encoded.uint32LE(at: 0), 0x01020304)
        XCTAssertEqual(Int32(bitPattern: encoded.uint32LE(at: 4)), -2)
        XCTAssertEqual(encoded.uint16LE(at: 8), 0x1234)
        XCTAssertEqual(encoded[10], 1)
        XCTAssertEqual(encoded.float32LE(at: 11), Float32(146.52), accuracy: 0.0001)
        XCTAssertEqual(encoded.float32LE(at: 15), Float32(144.39), accuracy: 0.0001)
        XCTAssertEqual(encoded[19], 7)
        XCTAssertEqual(encoded[20], 42)
        XCTAssertEqual(encoded[21], 9)
    }

    func testDeviceStateAndHelloDecode() {
        let device = makeDeviceStateBytes()
        let state = DeviceState(data: device)

        XCTAssertEqual(state?.appliedSequence, 10)
        XCTAssertEqual(state?.memoryId, -1)
        XCTAssertEqual(state?.radioStatus, .found)
        XCTAssertEqual(state?.mode, .rx)
        XCTAssertEqual(state?.latestRSSI, 88)

        let hello = HelloFrame(data: makeFirmwareBytes() + device)
        XCTAssertEqual(hello?.firmware.version, 17)
        XCTAssertEqual(hello?.firmware.windowSize, 4096)
        XCTAssertEqual(hello?.firmware.moduleType, .vhf)
        XCTAssertEqual(hello?.state.latestRSSI, 88)
    }

    func testAX25RoundTripAndAPRSMessage() throws {
        let service = APRSService()
        let packet = try service.makeMessage(from: "WX4ATL-7", to: "BLN1CQ", body: "Hello KV4P", number: 42)
        let decoded = try AX25Packet.decodeUIFrame(packet.encodedUIFrame())
        let parsed = service.parse(packet: decoded)

        XCTAssertEqual(decoded.source.display, "WX4ATL-7")
        XCTAssertEqual(decoded.destination.display, "APRS")
        XCTAssertEqual(decoded.digipeaters.map(\.display), APRSService.defaultDigipeaters)
        XCTAssertEqual(parsed.type, .message)
        XCTAssertEqual(parsed.to, "BLN1CQ")
        XCTAssertTrue(parsed.body.contains("Hello KV4P"))
        XCTAssertTrue(parsed.body.contains("{00042"))
    }

    func testAPRSPositionRoundTrip() throws {
        let service = APRSService()
        let coordinate = CLLocationCoordinate2D(latitude: 33.7488, longitude: -84.3877)
        let packet = try service.makePosition(from: "WX4ATL", coordinate: coordinate, comment: "Atlanta")
        let parsed = service.parse(packet: packet)

        XCTAssertEqual(parsed.type, .position)
        XCTAssertEqual(parsed.latitude ?? 0, 33.7488, accuracy: 0.001)
        XCTAssertEqual(parsed.longitude ?? 0, -84.3877, accuracy: 0.001)
        XCTAssertEqual(parsed.body, "Atlanta")
    }

    func testAPRSApproximateAccuracyRoundsBeaconCoordinate() {
        let exact = CLLocationCoordinate2D(latitude: 33.7488, longitude: -84.3877)
        let approximate = APRSService.adjustedCoordinate(exact, accuracySetting: "Approx")

        XCTAssertEqual(APRSService.adjustedCoordinate(exact, accuracySetting: "Exact").latitude, 33.7488, accuracy: 0.00001)
        XCTAssertEqual(approximate.latitude, 33.75, accuracy: 0.00001)
        XCTAssertEqual(approximate.longitude, -84.39, accuracy: 0.00001)
    }

    func testAPRSSymbolSettingMapsToExpectedPacketSymbol() throws {
        let service = APRSService()
        let coordinate = CLLocationCoordinate2D(latitude: 33.7488, longitude: -84.3877)
        let packet = try service.makePosition(from: "WX4ATL", coordinate: coordinate, comment: "Car", symbol: APRSService.symbol(named: "Car"))
        let info = String(decoding: packet.information, as: UTF8.self)

        XCTAssertEqual(APRSService.symbol(named: "Phone").encodedPair, "/$")
        XCTAssertEqual(APRSService.symbol(named: "Car").encodedPair, "/>")
        XCTAssertTrue(info.contains("W>Car"))
    }

    func testDigipeatDeduperSuppressesRepeatsInsideWindow() throws {
        let service = APRSService()
        let packet = try service.makeMessage(from: "WX4ATL", to: "BLN1CQ", body: "CQ", number: 1)
        let deduper = DigipeatDeduper(window: 120)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(deduper.shouldDigipeat(packet, now: now))
        XCTAssertFalse(deduper.shouldDigipeat(packet, now: now.addingTimeInterval(30)))
        XCTAssertTrue(deduper.shouldDigipeat(packet, now: now.addingTimeInterval(121)))
    }

    func testToneHelperMatchesAndroidCtcssIndexing() {
        XCTAssertEqual(RadioToneHelper.normalize(nil), "None")
        XCTAssertEqual(RadioToneHelper.normalize("100.0"), "100")
        XCTAssertEqual(RadioToneHelper.normalize("146.25"), "146.2")
        XCTAssertEqual(RadioToneHelper.toneIndex("None"), 0)
        XCTAssertEqual(RadioToneHelper.toneIndex("100.0"), 12)
        XCTAssertEqual(RadioToneHelper.toneIndex("146.25"), 23)
        XCTAssertEqual(RadioToneHelper.toneIndex("1"), 0)
    }

    func testIMAADPCMCodecRoundTripsKV4PVoiceFrame() throws {
        let codec = IMAADPCMCodec()
        let samples = (0..<KV4PVoice.engineFrameSize).map { index in
            Float(sin(Double(index) / 16.0)) * 0.1
        }

        let frames = try codec.encode(samples)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, KV4PVoice.encodedFrameSize)

        let decoded = try codec.decode(frames[0])
        XCTAssertEqual(decoded.count, KV4PVoice.engineFrameSize)

        let concealed = try codec.decodePLC()
        XCTAssertEqual(concealed.count, KV4PVoice.engineFrameSize)

        XCTAssertNoThrow(try codec.resetEncoder())
        XCTAssertNoThrow(try codec.resetDecoder())
    }

    func testRepeaterBookUSCSVParsesOffsetAndToneMemory() {
        let csv = """
        Freq,Input,Offset,Tone,Location,State,County,Call,Use,Miles,Bearing,Mode
        146.940,146.340,-0.600,100.0,"Stone Mountain, GA",GA,DeKalb,W4XYZ,OPEN,12.3,NE,FM
        """

        let repeaters = RepeaterBookCSVParser.parse(csv, minFrequency: 144, maxFrequency: 148)
        XCTAssertEqual(repeaters.count, 1)
        XCTAssertEqual(repeaters[0].tone, "100")

        let memory = RepeaterBookCSVParser.memory(from: repeaters[0], group: "Nearby")
        XCTAssertEqual(memory.offset, .down)
        XCTAssertEqual(memory.offsetKHz, 600)
        XCTAssertEqual(memory.frequency, 146.940, accuracy: 0.0001)
        XCTAssertEqual(memory.txFrequency, 146.340, accuracy: 0.0001)
        XCTAssertEqual(memory.txTone, "100")
    }

    func testAppSettingsDecodeProvidesDefaultsForNewSplitToneFields() throws {
        let data = Data(#"{"callsign":"WX4ATL","stickyPTT":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.callsign, "WX4ATL")
        XCTAssertTrue(settings.stickyPTT)
        XCTAssertEqual(settings.directRxFrequency, "146.5200")
        XCTAssertEqual(settings.directTxFrequency, "146.5200")
        XCTAssertEqual(settings.directRxTone, "None")
        XCTAssertEqual(settings.directTxTone, "None")
        XCTAssertEqual(settings.rxAudioBoost, "High")
        XCTAssertFalse(settings.highPower)
        XCTAssertFalse(settings.blePowerDefaultMigrated)
        XCTAssertFalse(settings.rxPowerSaveEnabled)
        XCTAssertEqual(settings.rxPowerSaveProfile, "Balanced")
    }

    func testPowerSaveFlagsUseReservedHostStateBits() {
        XCTAssertEqual(RadioFlags.rxPowerSave, 1 << 13)
        XCTAssertEqual(RadioFlags.rxPowerSaveMaximum, 1 << 14)
    }

    func testRadioProtocolParsesHelloAndSendsDesiredState() throws {
        let transport = TestTransport()
        let radio = RadioProtocol()
        radio.attach(transport)

        var events: [RadioProtocolEvent] = []
        radio.eventHandler = { events.append($0) }
        radio.ingest(KissCodec.encodeVendorFrame(command: .desiredState, payload: Data()))
        radio.ingest(KissCodec.encode(command: KissConstants.commandSetHardware, payload: makeDeviceVendorPayload(command: .hello, payload: makeFirmwareBytes() + makeDeviceStateBytes())))

        guard case .hello(let hello)? = events.first else {
            return XCTFail("Expected hello event")
        }
        XCTAssertEqual(hello.firmware.version, 17)

        try radio.sendDesiredState(memoryId: -1, flags: RadioFlags.txAllowed, bandwidth: 1, tx: 146.52, rx: 146.52, txTone: 0, squelch: 0, rxTone: 0)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.priorities, [.normal])

        var sentFrames: [KissFrame] = []
        let parser = KissParser()
        parser.onFrame = { sentFrames.append($0) }
        parser.feed(transport.sent[0])

        guard case .vendor(let command, let payload)? = sentFrames.first else {
            return XCTFail("Expected desired state vendor frame")
        }
        XCTAssertEqual(command, KV4PHostCommand.desiredState.rawValue)
        XCTAssertEqual(payload.count, HostDesiredState.byteLength)

        try radio.sendDesiredState(memoryId: -1, flags: RadioFlags.txAllowed | RadioFlags.rxAudioOpen, bandwidth: 1, tx: 146.52, rx: 146.52, txTone: 0, squelch: 0, rxTone: 0, priority: .urgentDropQueued)
        XCTAssertEqual(transport.priorities.last, .urgentDropQueued)
    }

    func testRadioProtocolSendsTxAudioAsRealtimeAndReportsBackpressure() throws {
        let transport = TestTransport()
        let radio = RadioProtocol()
        radio.attach(transport)

        try radio.sendTxAudio(Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(transport.priorities.last, .realtimeAudio)

        radio.ingest(KissCodec.encode(command: KissConstants.commandSetHardware, payload: makeDeviceVendorPayload(command: .hello, payload: makeFirmwareBytes(windowSize: 3) + makeDeviceStateBytes())))
        XCTAssertThrowsError(try radio.sendTxAudio(Data(repeating: 0x44, count: 4))) { error in
            XCTAssertEqual(error as? KV4PTransportError, .flowControlBackpressure)
        }
    }

    func testSMeterUsesSA818RawRSSIRange() {
        XCTAssertEqual(AppState.calculateSMeterValue(forRSSI: 0), 0)
        XCTAssertEqual(AppState.calculateSMeterValue(forRSSI: 14), 1)
        XCTAssertEqual(AppState.calculateSMeterValue(forRSSI: 88), 6)
        XCTAssertEqual(AppState.calculateSMeterValue(forRSSI: 180), 9)
    }

    private func makeFirmwareBytes(windowSize: UInt32 = 4096) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt16(17))
        data.append(RadioStatus.found.rawValue)
        data.appendLittleEndian(windowSize)
        data.append(RfModuleType.vhf.rawValue)
        data.appendFloat32(144.0)
        data.appendFloat32(148.0)
        data.append(0x07)
        return data
    }

    private func makeDeviceStateBytes() -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(10))
        data.appendLittleEndian(UInt32(bitPattern: -1))
        data.appendLittleEndian(UInt16(RadioFlags.radioConfigValid | RadioFlags.rxAudioOpen))
        data.append(1)
        data.appendFloat32(146.52)
        data.appendFloat32(146.52)
        data.append(0)
        data.append(3)
        data.append(0)
        data.append(RadioStatus.found.rawValue)
        data.append(DeviceMode.rx.rawValue)
        data.append(0)
        data.append(88)
        return data
    }

    private func makeDeviceVendorPayload(command: KV4PDeviceCommand, payload: Data) -> Data {
        var data = KissConstants.vendorPrefix
        data.append(KissConstants.vendorVersion)
        data.append(command.rawValue)
        data.append(payload)
        return data
    }
}

private final class TestTransport: KV4PTransport {
    var eventHandler: ((KV4PTransportEvent) -> Void)?
    var state: KV4PTransportState = .connected("Test")
    var sent: [Data] = []
    var priorities: [KV4PTransportPriority] = []

    func start() {}
    func stop() {}

    func send(_ data: Data) throws {
        try send(data, priority: .normal)
    }

    func send(_ data: Data, priority: KV4PTransportPriority) throws {
        sent.append(data)
        priorities.append(priority)
    }
}
