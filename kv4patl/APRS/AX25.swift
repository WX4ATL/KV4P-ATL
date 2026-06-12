// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AX25Error: Error, LocalizedError {
    case invalidCallsign(String)
    case packetTooShort

    var errorDescription: String? {
        switch self {
        case .invalidCallsign(let callsign): return "Invalid AX.25 callsign: \(callsign)"
        case .packetTooShort: return "AX.25 packet is too short."
        }
    }
}

struct AX25Address: Equatable, Codable {
    var callsign: String
    var ssid: UInt8
    var hasBeenRepeated: Bool

    init(_ text: String, repeated: Bool = false) throws {
        let parts = text.uppercased().split(separator: "-", maxSplits: 1).map(String.init)
        guard let call = parts.first, (1...6).contains(call.count), call.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw AX25Error.invalidCallsign(text)
        }
        let ssid = parts.count == 2 ? UInt8(parts[1]) ?? 0 : 0
        guard ssid <= 15 else { throw AX25Error.invalidCallsign(text) }
        self.callsign = call
        self.ssid = ssid
        self.hasBeenRepeated = repeated
    }

    var display: String {
        ssid == 0 ? callsign : "\(callsign)-\(ssid)"
    }

    func encoded(last: Bool) -> Data {
        var data = Data()
        let padded = callsign.padding(toLength: 6, withPad: " ", startingAt: 0)
        for byte in padded.utf8 {
            data.append(byte << 1)
        }
        var ssidByte: UInt8 = 0x60 | ((ssid & 0x0F) << 1)
        if hasBeenRepeated { ssidByte |= 0x80 }
        if last { ssidByte |= 0x01 }
        data.append(ssidByte)
        return data
    }

    static func decode(_ data: Data, offset: Int) throws -> AX25Address {
        guard data.count >= offset + 7 else { throw AX25Error.packetTooShort }
        var callBytes: [UInt8] = []
        for index in offset..<(offset + 6) {
            let decoded = data[index] >> 1
            if decoded != 32 { callBytes.append(decoded) }
        }
        let call = String(decoding: callBytes, as: UTF8.self)
        let ssidByte = data[offset + 6]
        let ssid = (ssidByte >> 1) & 0x0F
        return try AX25Address(ssid == 0 ? call : "\(call)-\(ssid)", repeated: (ssidByte & 0x80) != 0)
    }
}

struct AX25Packet: Equatable {
    var destination: AX25Address
    var source: AX25Address
    var digipeaters: [AX25Address]
    var information: Data

    func encodedUIFrame() -> Data {
        var data = Data()
        let all = [destination, source] + digipeaters
        for (index, address) in all.enumerated() {
            data.append(address.encoded(last: index == all.count - 1))
        }
        data.append(0x03) // UI frame
        data.append(0xF0) // no layer 3 protocol
        data.append(information)
        return data
    }

    static func decodeUIFrame(_ data: Data) throws -> AX25Packet {
        guard data.count >= 16 else { throw AX25Error.packetTooShort }
        var addresses: [AX25Address] = []
        var offset = 0
        while offset + 7 <= data.count {
            addresses.append(try AX25Address.decode(data, offset: offset))
            let last = (data[offset + 6] & 0x01) != 0
            offset += 7
            if last { break }
        }
        guard addresses.count >= 2, data.count >= offset + 2 else { throw AX25Error.packetTooShort }
        return AX25Packet(
            destination: addresses[0],
            source: addresses[1],
            digipeaters: Array(addresses.dropFirst(2)),
            information: Data(data.dropFirst(offset + 2))
        )
    }
}

