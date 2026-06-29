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
        XCTAssertEqual(hello?.firmware.frequencyRange?.lowerMHz, 144.0)
        XCTAssertEqual(hello?.firmware.frequencyRange?.upperMHz, 148.0)
        XCTAssertTrue(hello?.firmware.frequencyRange?.contains(146.52) == true)
        XCTAssertFalse(hello?.firmware.frequencyRange?.contains(440.0) == true)
        XCTAssertEqual(hello?.state.latestRSSI, 88)
    }

    func testAfskDecodeStatsParsesBell202CandidateTelemetry() throws {
        var data = Data()
        data.appendLittleEndian(UInt32(48_000))
        data.appendLittleEndian(UInt32(187))
        data.appendLittleEndian(UInt32(3))
        data.appendLittleEndian(UInt32(960))
        data.appendLittleEndian(UInt16(1234))
        data.appendLittleEndian(UInt16(12_345))
        data.appendLittleEndian(UInt16(0x1800))
        data.appendLittleEndian(UInt16(456))
        data.appendLittleEndian(UInt32(7))
        data.append(1)
        data.append(0)
        data.appendLittleEndian(Int16(0x0C80))
        data.appendLittleEndian(Int16(-0x0600))
        data.appendLittleEndian(UInt16(210))
        data.appendLittleEndian(UInt16(190))
        data.appendLittleEndian(UInt32(5))

        let stats = AfskDecodeStats(data: data)

        let decoded = try XCTUnwrap(stats)
        XCTAssertEqual(data.count, AfskDecodeStats.byteLength)
        XCTAssertEqual(decoded.audioSamplesSeen, 48_000)
        XCTAssertEqual(decoded.afskBlocksProcessed, 187)
        XCTAssertEqual(decoded.clipCount, 3)
        XCTAssertEqual(decoded.rmsLevel, 1234)
        XCTAssertEqual(decoded.peakLevel, 12_345)
        XCTAssertEqual(decoded.afskGain, 24.0, accuracy: 0.01)
        XCTAssertEqual(decoded.noiseFloorEstimate, 456)
        XCTAssertEqual(decoded.crcSuccesses, 7)
        XCTAssertEqual(decoded.bell202CandidateActive, true)
        XCTAssertEqual(try XCTUnwrap(decoded.bell202StepDb), 12.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(decoded.bell202FloorDb), -6.0, accuracy: 0.01)
        XCTAssertEqual(decoded.bell202MarkLevel, 210)
        XCTAssertEqual(decoded.bell202SpaceLevel, 190)
        XCTAssertEqual(decoded.bell202CandidateCount, 5)
    }

    func testFirmwareHelloExposesUHFFrequencyRange() {
        let firmware = FirmwareVersion(data: makeFirmwareBytes(moduleType: .uhf, minFrequency: 420.0, maxFrequency: 450.0))

        XCTAssertEqual(firmware?.moduleType, .uhf)
        XCTAssertEqual(firmware?.moduleType.displayName, "UHF")
        XCTAssertEqual(firmware?.moduleType.txLimitLabel, "70cm")
        XCTAssertEqual(firmware?.frequencyRange?.lowerMHz, 420.0)
        XCTAssertEqual(firmware?.frequencyRange?.upperMHz, 450.0)
        XCTAssertTrue(firmware?.frequencyRange?.contains(446.0) == true)
        XCTAssertFalse(firmware?.frequencyRange?.contains(146.52) == true)
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
        XCTAssertEqual(parsed.messageIdentifier, "00042")
        XCTAssertFalse(parsed.body.contains("{00042"))
    }

    func testAPRSCompactReplyAckMessageEncodingAndParsing() throws {
        let service = APRSService()
        let packet = try service.makeMessage(
            from: "WX4ATL-7",
            to: "N0CALL-1",
            body: "Hello | noisy~world{",
            identifier: "0A",
            replyAcknowledgementIdentifier: "1B"
        )
        let info = String(decoding: packet.information, as: UTF8.self)
        let context = try XCTUnwrap(service.messageContext(packet: packet))

        XCTAssertEqual(info, ":N0CALL-1 :Hello  noisyworld{0A}1B")
        XCTAssertEqual(context.source, "WX4ATL-7")
        XCTAssertEqual(context.envelope.addressee, "N0CALL-1")
        XCTAssertEqual(context.envelope.text, "Hello  noisyworld")
        XCTAssertEqual(context.envelope.rawIdentifier, "0A}1B")
        XCTAssertEqual(context.envelope.baseIdentifier, "0A")
        XCTAssertEqual(context.envelope.replyAcknowledgementIdentifier, "1B")
        XCTAssertTrue(context.envelope.requestsAcknowledgement)
    }

    func testAPRSReplyAckCapabilityMarkerWithoutPiggybackedAck() throws {
        let service = APRSService()
        let packet = try service.makeMessage(
            from: "WX4ATL-5",
            to: "N0CALL-1",
            body: "Reply ACK capable",
            identifier: "A1"
        )
        let envelope = try XCTUnwrap(service.messageContext(packet: packet)?.envelope)

        XCTAssertEqual(envelope.rawIdentifier, "A1}")
        XCTAssertEqual(envelope.baseIdentifier, "A1")
        XCTAssertNil(envelope.replyAcknowledgementIdentifier)
        XCTAssertTrue(envelope.requestsAcknowledgement)
    }

    func testAPRSAcknowledgementAndUnnumberedMessageParsing() throws {
        let service = APRSService()
        let acknowledgement = try service.makeAcknowledgement(
            from: "N0CALL-1",
            to: "WX4ATL-7",
            identifier: "0A}1B"
        )
        let ackEnvelope = try XCTUnwrap(service.messageContext(packet: acknowledgement)?.envelope)
        let unnumbered = try service.makeMessage(
            from: "N0CALL-1",
            to: "WX4ATL-7",
            body: "No ACK requested",
            identifier: nil
        )
        let unnumberedEnvelope = try XCTUnwrap(service.messageContext(packet: unnumbered)?.envelope)

        XCTAssertEqual(ackEnvelope.kind, .acknowledgement)
        XCTAssertEqual(ackEnvelope.baseIdentifier, "0A")
        XCTAssertEqual(ackEnvelope.replyAcknowledgementIdentifier, "1B")
        XCTAssertFalse(unnumberedEnvelope.requestsAcknowledgement)
        XCTAssertNil(unnumberedEnvelope.rawIdentifier)
    }

    func testAPRSThirdPartyMessagePreservesOriginalSenderForAcknowledgement() throws {
        let service = APRSService()
        let packet = try makeAPRSPacket(
            source: "IGATE",
            info: "}N0CALL-1>APRS,TCPIP,IGATE*::WX4ATL-7 :Via IGate{Z9}"
        )
        let context = try XCTUnwrap(service.messageContext(packet: packet))
        let parsed = service.parse(packet: packet)

        XCTAssertEqual(context.source, "N0CALL-1")
        XCTAssertEqual(context.envelope.baseIdentifier, "Z9")
        XCTAssertTrue(context.envelope.requestsAcknowledgement)
        XCTAssertEqual(parsed.type, .message)
        XCTAssertEqual(parsed.from, "N0CALL-1")
        XCTAssertEqual(parsed.body, "Via IGate")
    }

    func testAPRSRetryPolicyUsesRecommendedDecayingIntervals() {
        XCTAssertEqual(APRSRetryPolicy.retryIntervals, [15, 30, 60, 120, 240])
        XCTAssertEqual(APRSRetryPolicy.duplicateAcknowledgementMinimumSpacing, 30)
        XCTAssertEqual(APRSRetryPolicy.finalAcknowledgementGrace, 30)
        XCTAssertEqual(APRSService.compactMessageIdentifier(0), "00")
        XCTAssertEqual(APRSService.compactMessageIdentifier(35), "0Z")
        XCTAssertEqual(APRSService.compactMessageIdentifier(36), "10")
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

    func testAPRSPositionExtensionsAreRenderedForPacketList() throws {
        let service = APRSService()
        let parsed = service.parse(packet: try makeAPRSPacket(
            source: "WX4ATL-7",
            destination: "APAT81",
            info: "!3348.07N/08430.17W>175/000/A=000728Main HT | Messaging Capable | www.arid.club"
        ))

        XCTAssertEqual(parsed.type, .position)
        XCTAssertEqual(parsed.latitude ?? 0, 33.8012, accuracy: 0.0001)
        XCTAssertEqual(parsed.longitude ?? 0, -84.5028, accuracy: 0.0001)
        XCTAssertEqual(parsed.dataPoint("Course"), "175°")
        XCTAssertEqual(parsed.dataPoint("Speed"), "0 mph")
        XCTAssertEqual(parsed.dataPoint("Altitude"), "728 ft")
        XCTAssertEqual(parsed.body, "Main HT | Messaging Capable | www.arid.club")
        XCTAssertFalse(parsed.body.contains("175/000/A="))
    }

    func testAPRSWeatherPositionExtensionLabelsWindSpeed() throws {
        let service = APRSService()
        let parsed = service.parse(packet: try makeAPRSPacket(
            source: "WX4ATL-7",
            destination: "APAT81",
            info: "!3348.07N/08430.17W_175/004g005t077r000p000P000h50b10132Main HT weather"
        ))

        XCTAssertEqual(parsed.type, .weather)
        XCTAssertEqual(parsed.dataPoint("Wind dir"), "175°")
        XCTAssertEqual(parsed.dataPoint("Wind speed"), "5 mph")
        XCTAssertEqual(parsed.dataPoint("Gust"), "6 mph")
        XCTAssertNil(parsed.dataPoint("Course"))
        XCTAssertNil(parsed.dataPoint("Speed"))
        XCTAssertEqual(parsed.body, "Main HT weather")
    }

    func testAPRSTimestampedObjectAndItemDecodeCoordinates() throws {
        let service = APRSService()
        let object = service.parse(packet: try makeAPRSPacket(
            info: ";TEST OBJ *092345z3348.07N/08430.17W-Test object"
        ))
        let item = service.parse(packet: try makeAPRSPacket(
            info: ")WX4ATL!3348.07N/08430.17W>Item text"
        ))

        XCTAssertEqual(object.type, .object)
        XCTAssertEqual(object.latitude ?? 0, 33.8012, accuracy: 0.0001)
        XCTAssertTrue(object.body.contains("TEST OBJ"))
        XCTAssertTrue(object.body.contains("live"))
        XCTAssertTrue(object.body.contains("Test object"))
        XCTAssertEqual(item.type, .item)
        XCTAssertEqual(item.longitude ?? 0, -84.5028, accuracy: 0.0001)
        XCTAssertTrue(item.body.contains("Item text"))
    }

    func testAPRSCompressedPositionDecode() throws {
        let service = APRSService()
        let info = compressedPositionInfo(latitude: 33.8012, longitude: -84.5028, comment: "Compressed")
        let parsed = service.parse(packet: try makeAPRSPacket(info: info))

        XCTAssertEqual(parsed.type, .position)
        XCTAssertEqual(parsed.latitude ?? 0, 33.8012, accuracy: 0.0001)
        XCTAssertEqual(parsed.longitude ?? 0, -84.5028, accuracy: 0.0001)
        XCTAssertTrue(parsed.body.contains("Compressed"))
    }

    func testAPRSWeatherTelemetryGPSAndThirdPartyDecode() throws {
        let service = APRSService()
        let weather = service.parse(packet: try makeAPRSPacket(info: "_10090556c220s004g005t077r000p000P000h50b10132"))
        let weatherWithComment = service.parse(packet: try makeAPRSPacket(info: "_10090556c220s004g005t077r000p000P000h50b10132Atlanta weather"))
        let telemetry = service.parse(packet: try makeAPRSPacket(info: "T#123,111,222,333,444,555,10101010,Comment"))
        let gps = service.parse(packet: try makeAPRSPacket(info: "$GPGGA,123519,3348.070,N,08430.170,W,1,08,0.9,728.0,M,46.9,M,,*47"))
        let thirdParty = service.parse(packet: try makeAPRSPacket(info: "}WX4ATL-7>APAT81:!3348.07N/08430.17W>175/000/A=000728Main HT"))

        XCTAssertEqual(weather.type, .weather)
        XCTAssertEqual(weather.body, "")
        XCTAssertEqual(weather.dataPoint("Wind dir"), "220°")
        XCTAssertEqual(weather.dataPoint("Wind speed"), "5 mph")
        XCTAssertEqual(weather.dataPoint("Temp"), "77°F")
        XCTAssertEqual(weather.dataPoint("Pressure"), "1013.2 mb")
        XCTAssertNil(weather.dataPoint("Speed"))
        XCTAssertEqual(weatherWithComment.body, "Atlanta weather")
        XCTAssertEqual(telemetry.type, .telemetry)
        XCTAssertEqual(telemetry.dataPoint("Sequence"), "123")
        XCTAssertEqual(telemetry.dataPoint("Channels"), "111/222/333/444/555")
        XCTAssertEqual(gps.type, .gps)
        XCTAssertEqual(gps.latitude ?? 0, 33.8012, accuracy: 0.0001)
        XCTAssertTrue(gps.body.contains("GPS fix"))
        XCTAssertEqual(gps.dataPoint("Altitude"), "728.0 m")
        XCTAssertEqual(thirdParty.type, .thirdParty)
        XCTAssertEqual(thirdParty.latitude ?? 0, 33.8012, accuracy: 0.0001)
        XCTAssertTrue(thirdParty.body.contains("WX4ATL-7>APAT81"))
        XCTAssertEqual(thirdParty.dataPoint("Altitude"), "728 ft")
    }

    func testAPRSUserDefinedInvalidMaidenheadAndMicEDecode() throws {
        let service = APRSService()
        let userDefined = service.parse(packet: try makeAPRSPacket(info: "{AExperimental"))
        let invalid = service.parse(packet: try makeAPRSPacket(info: ",Test packet"))
        let maidenhead = service.parse(packet: try makeAPRSPacket(info: "[EM73uw Atlanta"))
        let micE = service.parse(packet: try makeMicEPacket())

        XCTAssertEqual(userDefined.type, .userDefined)
        XCTAssertTrue(userDefined.body.contains("user A"))
        XCTAssertEqual(invalid.type, .invalid)
        XCTAssertTrue(invalid.body.contains("invalid/test data"))
        XCTAssertEqual(maidenhead.type, .position)
        XCTAssertTrue(maidenhead.body.contains("Maidenhead EM73UW"))
        XCTAssertEqual(micE.type, .micE)
        XCTAssertEqual(micE.latitude ?? 0, 33.8012, accuracy: 0.0001)
        XCTAssertEqual(micE.longitude ?? 0, -84.5028, accuracy: 0.0001)
        XCTAssertEqual(micE.dataPoint("Format"), "Mic-E")
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

    func testAppSettingsDecodeProvidesDefaultsForNewSplitToneFields() throws {
        let data = Data(#"{"callsign":"WX4ATL","stickyPTT":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.callsign, "WX4ATL")
        XCTAssertTrue(settings.stickyPTT)
        XCTAssertEqual(settings.directRxFrequency, "146.5200")
        XCTAssertEqual(settings.directTxFrequency, "146.5200")
        XCTAssertEqual(settings.directRxTone, "None")
        XCTAssertEqual(settings.directTxTone, "None")
        XCTAssertEqual(settings.lastChannelSource, "Memory")
        XCTAssertNil(settings.lastMemoryId)
        XCTAssertEqual(settings.lastActiveRxFrequency, "146.5200")
        XCTAssertEqual(settings.lastActiveTxFrequency, "146.5200")
        XCTAssertEqual(settings.lastActiveRxTone, "None")
        XCTAssertEqual(settings.lastActiveTxTone, "None")
        XCTAssertEqual(settings.lastActiveChannelName, "National Simplex")
        XCTAssertFalse(settings.highPower)
        XCTAssertFalse(settings.blePowerDefaultMigrated)
        XCTAssertFalse(settings.rxPowerSaveEnabled)
        XCTAssertEqual(settings.rxPowerSaveProfile, "Balanced")
        XCTAssertTrue(settings.aprsMessageAcknowledgementsEnabled)
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

    private func makeFirmwareBytes(
        windowSize: UInt32 = 4096,
        moduleType: RfModuleType = .vhf,
        minFrequency: Float32 = 144.0,
        maxFrequency: Float32 = 148.0
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt16(17))
        data.append(RadioStatus.found.rawValue)
        data.appendLittleEndian(windowSize)
        data.append(moduleType.rawValue)
        data.appendFloat32(minFrequency)
        data.appendFloat32(maxFrequency)
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

    private func makeAPRSPacket(source: String = "WX4ATL-7", destination: String = "APRS", info: String) throws -> AX25Packet {
        AX25Packet(
            destination: try AX25Address(destination),
            source: try AX25Address(source),
            digipeaters: [],
            information: Data(info.utf8)
        )
    }

    private func makeMicEPacket() throws -> AX25Packet {
        var information = Data([0x60, 112, 58, 45, 28, 28, 28, 62, 47])
        information.append(Data("MicE sample".utf8))
        return AX25Packet(
            destination: try AX25Address("334X0W"),
            source: try AX25Address("WX4ATL-7"),
            digipeaters: [],
            information: information
        )
    }

    private func compressedPositionInfo(latitude: Double, longitude: Double, comment: String) -> String {
        let latValue = Int(((90.0 - latitude) * 380_926.0).rounded())
        let lonValue = Int(((longitude + 180.0) * 190_463.0).rounded())
        return "!/\(base91(latValue, length: 4))\(base91(lonValue, length: 4))>!!T\(comment)"
    }

    private func base91(_ value: Int, length: Int) -> String {
        var value = value
        var bytes = Array(repeating: UInt8(33), count: length)
        for index in stride(from: length - 1, through: 0, by: -1) {
            bytes[index] = UInt8(value % 91 + 33)
            value /= 91
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension APRSMessage {
    func dataPoint(_ label: String) -> String? {
        dataPoints.first { $0.label == label }?.value
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
