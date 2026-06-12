// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum KissConstants {
    static let fend: UInt8 = 0xC0
    static let fesc: UInt8 = 0xDB
    static let tfend: UInt8 = 0xDC
    static let tfesc: UInt8 = 0xDD
    static let commandData: UInt8 = 0x00
    static let commandSetHardware: UInt8 = 0x06
    static let vendorPrefix = Data("KV4P".utf8)
    static let vendorVersion: UInt8 = 0x01
    static let protoMTU = 2_048
}

enum KV4PHostCommand: UInt8 {
    case txAudio = 0x07
    case desiredState = 0x0D
}

enum KV4PDeviceCommand: UInt8 {
    case debugInfo = 0x01
    case debugError = 0x02
    case debugWarn = 0x03
    case debugDebug = 0x04
    case debugTrace = 0x05
    case hello = 0x06
    case rxAudio = 0x07
    case windowUpdate = 0x09
    case deviceState = 0x0B
}

enum KissFrame: Equatable {
    case ax25(Data)
    case vendor(UInt8, Data)
}

struct KissCodec {
    static func encode(command: UInt8, payload: Data) -> Data {
        var frame = Data([KissConstants.fend, command])
        for byte in payload.prefix(KissConstants.protoMTU) {
            switch byte {
            case KissConstants.fend:
                frame.append(KissConstants.fesc)
                frame.append(KissConstants.tfend)
            case KissConstants.fesc:
                frame.append(KissConstants.fesc)
                frame.append(KissConstants.tfesc)
            default:
                frame.append(byte)
            }
        }
        frame.append(KissConstants.fend)
        return frame
    }

    static func encodeDataFrame(_ ax25: Data) -> Data {
        encode(command: KissConstants.commandData, payload: ax25)
    }

    static func encodeVendorFrame(command: KV4PHostCommand, payload: Data) -> Data {
        var vendorPayload = KissConstants.vendorPrefix
        vendorPayload.append(KissConstants.vendorVersion)
        vendorPayload.append(command.rawValue)
        vendorPayload.append(payload)
        return encode(command: KissConstants.commandSetHardware, payload: vendorPayload)
    }
}

final class KissParser {
    var onFrame: ((KissFrame) -> Void)?

    private var buffer = Data()
    private var inFrame = false
    private var escaped = false
    private var dropFrame = false

    func feed(_ data: Data) {
        for byte in data {
            process(byte)
        }
    }

    private func process(_ byte: UInt8) {
        if byte == KissConstants.fend {
            if !buffer.isEmpty, !dropFrame {
                emitFrame()
            }
            buffer.removeAll(keepingCapacity: true)
            inFrame = true
            escaped = false
            dropFrame = false
            return
        }

        guard inFrame, !dropFrame else { return }

        if escaped {
            if byte == KissConstants.tfend {
                append(KissConstants.fend)
            } else if byte == KissConstants.tfesc {
                append(KissConstants.fesc)
            } else {
                dropFrame = true
            }
            escaped = false
        } else if byte == KissConstants.fesc {
            escaped = true
        } else {
            append(byte)
        }
    }

    private func append(_ byte: UInt8) {
        guard buffer.count < KissConstants.protoMTU + 8 else {
            dropFrame = true
            return
        }
        buffer.append(byte)
    }

    private func emitFrame() {
        guard let commandByte = buffer.first else { return }
        let port = commandByte >> 4
        let command = commandByte & 0x0F
        guard port == 0 else { return }
        let payload = buffer.dropFirst()

        if command == KissConstants.commandData {
            onFrame?(.ax25(Data(payload)))
        } else if command == KissConstants.commandSetHardware {
            parseVendorPayload(Data(payload))
        }
    }

    private func parseVendorPayload(_ payload: Data) {
        guard payload.count >= 6,
              Data(payload.prefix(4)) == KissConstants.vendorPrefix,
              payload[4] == KissConstants.vendorVersion else {
            return
        }
        onFrame?(.vendor(payload[5], Data(payload.dropFirst(6))))
    }
}
