// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum RadioProtocolEvent: Equatable {
    case hello(HelloFrame)
    case deviceState(DeviceState)
    case rxAudio(Data)
    case ax25(Data)
    case afskStats(AfskDecodeStats)
    case debug(String)
    case windowUpdate(UInt32)
}

final class RadioProtocol: @unchecked Sendable {
    var eventHandler: ((RadioProtocolEvent) -> Void)?

    private let parser = KissParser()
    private weak var transport: KV4PTransport?
    private var flowControlWindow = 1_024
    private var desiredSequence: UInt32 = 0

    init() {
        parser.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
    }

    func attach(_ transport: KV4PTransport) {
        self.transport = transport
    }

    func ingest(_ data: Data) {
        parser.feed(data)
    }

    func sendDesiredState(_ state: HostDesiredState, priority: KV4PTransportPriority = .normal) throws {
        let frame = KissCodec.encodeVendorFrame(command: .desiredState, payload: state.encoded())
        try send(frame, priority: priority)
    }

    func sendDesiredState(memoryId: Int32, flags: UInt16, bandwidth: UInt8, tx: Float32, rx: Float32, txTone: UInt8, squelch: UInt8, rxTone: UInt8, priority: KV4PTransportPriority = .normal) throws {
        desiredSequence &+= 1
        try sendDesiredState(HostDesiredState(
            sequence: desiredSequence,
            memoryId: memoryId,
            flags: flags,
            bandwidth: bandwidth,
            txFrequency: tx,
            rxFrequency: rx,
            txTone: txTone,
            squelch: squelch,
            rxTone: rxTone
        ), priority: priority)
    }

    func sendTxAudio(_ voiceFrame: Data) throws {
        try send(KissCodec.encodeVendorFrame(command: .txAudio, payload: voiceFrame), priority: .realtimeAudio)
    }

    func sendAX25(_ packet: Data) throws {
        try send(KissCodec.encodeDataFrame(packet))
    }

    private func send(_ frame: Data, priority: KV4PTransportPriority = .normal) throws {
        if priority != .urgentDropQueued, flowControlWindow <= 0 || frame.count > flowControlWindow {
            throw KV4PTransportError.flowControlBackpressure
        }
        try transport?.send(frame, priority: priority)
        if flowControlWindow > 0 {
            flowControlWindow = max(0, flowControlWindow - frame.count)
        }
    }

    private func handle(_ frame: KissFrame) {
        switch frame {
        case .ax25(let data):
            eventHandler?(.ax25(data))
        case .vendor(let command, let payload):
            guard let command = KV4PDeviceCommand(rawValue: command) else { return }
            switch command {
            case .hello:
                if let hello = HelloFrame(data: payload) {
                    flowControlWindow = Int(hello.firmware.windowSize)
                    eventHandler?(.hello(hello))
                }
            case .deviceState:
                if let state = DeviceState(data: payload) {
                    eventHandler?(.deviceState(state))
                }
            case .rxAudio:
                eventHandler?(.rxAudio(payload))
            case .afskStats:
                if let stats = AfskDecodeStats(data: payload) {
                    eventHandler?(.afskStats(stats))
                }
            case .windowUpdate:
                guard payload.count == 4 else { return }
                let size = payload.uint32LE(at: 0)
                flowControlWindow += Int(size)
                eventHandler?(.windowUpdate(size))
            case .debugInfo, .debugError, .debugWarn, .debugDebug, .debugTrace:
                eventHandler?(.debug(String(decoding: payload, as: UTF8.self)))
            }
        }
    }
}
