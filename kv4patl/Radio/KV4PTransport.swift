// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum KV4PTransportState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case disconnected(String)
    case failed(String)
}

enum KV4PTransportEvent {
    case state(KV4PTransportState)
    case data(Data)
    case debug(String)
    case error(String)
}

enum KV4PTransportPriority: Equatable {
    case normal
    case realtimeAudio
    case urgentDropQueued
}

protocol KV4PTransport: AnyObject {
    var eventHandler: ((KV4PTransportEvent) -> Void)? { get set }
    var state: KV4PTransportState { get }

    func start()
    func stop()
    func send(_ data: Data) throws
    func send(_ data: Data, priority: KV4PTransportPriority) throws
}

extension KV4PTransport {
    func send(_ data: Data, priority: KV4PTransportPriority) throws {
        try send(data)
    }
}

enum KV4PTransportError: Error, LocalizedError {
    case notConnected
    case writeUnavailable
    case flowControlBackpressure

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Radio is not connected."
        case .writeUnavailable: return "BLE write characteristic is unavailable."
        case .flowControlBackpressure: return "Radio audio flow-control window is full."
        }
    }
}
