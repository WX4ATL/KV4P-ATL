// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum RadioStatus: UInt8, Codable, Sendable {
    case unknown = 0
    case notFound = 120
    case found = 102

    init(byte: UInt8) {
        self = RadioStatus(rawValue: byte) ?? .unknown
    }
}

enum DeviceMode: UInt8, Codable, Sendable {
    case tx = 0
    case rx = 1
    case stopped = 2
    case unknown = 255
}

enum RfModuleType: UInt8, Codable, Sendable {
    case vhf = 0
    case uhf = 1

    var displayName: String {
        switch self {
        case .vhf: "VHF"
        case .uhf: "UHF"
        }
    }

    var txLimitLabel: String {
        switch self {
        case .vhf: "2m"
        case .uhf: "70cm"
        }
    }
}

struct RadioFrequencyRange: Equatable, Sendable {
    var lowerMHz: Float
    var upperMHz: Float

    var isValid: Bool {
        lowerMHz > 0 && upperMHz > lowerMHz
    }

    func contains(_ frequency: Float) -> Bool {
        frequency >= lowerMHz && frequency <= upperMHz
    }

    func intersection(with other: RadioFrequencyRange) -> RadioFrequencyRange? {
        let lower = max(lowerMHz, other.lowerMHz)
        let upper = min(upperMHz, other.upperMHz)
        guard lower <= upper else { return nil }
        return RadioFrequencyRange(lowerMHz: lower, upperMHz: upper)
    }
}

struct HostDesiredState: Equatable, Sendable {
    static let byteLength = 22

    var sequence: UInt32
    var memoryId: Int32
    var flags: UInt16
    var bandwidth: UInt8
    var txFrequency: Float32
    var rxFrequency: Float32
    var txTone: UInt8
    var squelch: UInt8
    var rxTone: UInt8

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(UInt32(bitPattern: memoryId))
        data.appendLittleEndian(flags)
        data.append(bandwidth)
        data.appendFloat32(txFrequency)
        data.appendFloat32(rxFrequency)
        data.append(txTone)
        data.append(squelch)
        data.append(rxTone)
        return data
    }
}

struct DeviceState: Equatable, Codable, Sendable {
    static let byteLength = 26

    var appliedSequence: UInt32
    var memoryId: Int32
    var flags: UInt16
    var bandwidth: UInt8
    var txFrequency: Float32
    var rxFrequency: Float32
    var txTone: UInt8
    var squelch: UInt8
    var rxTone: UInt8
    var radioStatus: RadioStatus
    var mode: DeviceMode
    var lastError: UInt8
    var latestRSSI: UInt8

    init?(data: Data, offset: Int = 0) {
        guard data.count >= offset + Self.byteLength else { return nil }
        appliedSequence = data.uint32LE(at: offset)
        memoryId = Int32(bitPattern: data.uint32LE(at: offset + 4))
        flags = data.uint16LE(at: offset + 8)
        bandwidth = data[offset + 10]
        txFrequency = data.float32LE(at: offset + 11)
        rxFrequency = data.float32LE(at: offset + 15)
        txTone = data[offset + 19]
        squelch = data[offset + 20]
        rxTone = data[offset + 21]
        radioStatus = RadioStatus(byte: data[offset + 22])
        mode = DeviceMode(rawValue: data[offset + 23]) ?? .unknown
        lastError = data[offset + 24]
        latestRSSI = data[offset + 25]
    }
}

struct AfskDecodeStats: Equatable, Codable, Sendable {
    static let legacyByteLength = 29
    static let byteLength = 42

    var audioSamplesSeen: UInt32
    var afskBlocksProcessed: UInt32
    var clipCount: UInt32
    var sampleCount: UInt32
    var rmsLevel: UInt16
    var peakLevel: UInt16
    var afskGain: Float
    var noiseFloorEstimate: UInt16
    var crcSuccesses: UInt32
    var bell202CandidateActive: Bool
    var bell202StepDb: Float?
    var bell202FloorDb: Float?
    var bell202MarkLevel: UInt16?
    var bell202SpaceLevel: UInt16?
    var bell202CandidateCount: UInt32?

    init?(data: Data, offset: Int = 0) {
        guard data.count >= offset + Self.legacyByteLength else { return nil }
        audioSamplesSeen = data.uint32LE(at: offset)
        afskBlocksProcessed = data.uint32LE(at: offset + 4)
        clipCount = data.uint32LE(at: offset + 8)
        sampleCount = data.uint32LE(at: offset + 12)
        rmsLevel = data.uint16LE(at: offset + 16)
        peakLevel = data.uint16LE(at: offset + 18)
        afskGain = Float(data.uint16LE(at: offset + 20)) / 256.0
        noiseFloorEstimate = data.uint16LE(at: offset + 22)
        crcSuccesses = data.uint32LE(at: offset + 24)
        bell202CandidateActive = data[offset + 28] != 0

        if data.count >= offset + Self.byteLength {
            bell202StepDb = Float(data.int16LE(at: offset + 30)) / 256.0
            bell202FloorDb = Float(data.int16LE(at: offset + 32)) / 256.0
            bell202MarkLevel = data.uint16LE(at: offset + 34)
            bell202SpaceLevel = data.uint16LE(at: offset + 36)
            bell202CandidateCount = data.uint32LE(at: offset + 38)
        } else {
            bell202StepDb = nil
            bell202FloorDb = nil
            bell202MarkLevel = nil
            bell202SpaceLevel = nil
            bell202CandidateCount = nil
        }
    }
}

struct FirmwareVersion: Equatable, Codable, Sendable {
    static let byteLength = 17

    var version: UInt16
    var radioStatus: RadioStatus
    var windowSize: UInt32
    var moduleType: RfModuleType
    var minFrequency: Float32
    var maxFrequency: Float32
    var features: UInt8

    var hasHighLowPower: Bool { features & 0x01 != 0 }
    var hasPhysicalPTT: Bool { features & 0x02 != 0 }
    var hasEsp32AFSK: Bool { features & 0x04 != 0 }

    var frequencyRange: RadioFrequencyRange? {
        let range = RadioFrequencyRange(lowerMHz: minFrequency, upperMHz: maxFrequency)
        return range.isValid ? range : nil
    }

    init?(data: Data, offset: Int = 0) {
        guard data.count >= offset + Self.byteLength else { return nil }
        version = data.uint16LE(at: offset)
        radioStatus = RadioStatus(byte: data[offset + 2])
        windowSize = data.uint32LE(at: offset + 3)
        moduleType = RfModuleType(rawValue: data[offset + 7]) ?? .vhf
        minFrequency = data.float32LE(at: offset + 8)
        maxFrequency = data.float32LE(at: offset + 12)
        features = data[offset + 16]
    }
}

struct HelloFrame: Equatable, Codable, Sendable {
    static let byteLength = FirmwareVersion.byteLength + DeviceState.byteLength

    var firmware: FirmwareVersion
    var state: DeviceState

    init?(data: Data) {
        guard data.count == Self.byteLength,
              let firmware = FirmwareVersion(data: data),
              let state = DeviceState(data: data, offset: FirmwareVersion.byteLength) else {
            return nil
        }
        self.firmware = firmware
        self.state = state
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendFloat32(_ value: Float32) {
        appendLittleEndian(value.bitPattern)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
        | (UInt32(self[offset + 1]) << 8)
        | (UInt32(self[offset + 2]) << 16)
        | (UInt32(self[offset + 3]) << 24)
    }

    func float32LE(at offset: Int) -> Float32 {
        Float32(bitPattern: uint32LE(at: offset))
    }
}
