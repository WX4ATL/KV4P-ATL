// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ChannelMemory: Identifiable, Codable, Equatable {
    enum Offset: Int, Codable, CaseIterable {
        case none = 0
        case down = 1
        case up = 2
    }

    var id = UUID()
    var name: String
    var group: String
    var frequency: Float
    var offset: Offset
    var offsetKHz: Int
    var txTone: String
    var rxTone: String
    var skipDuringScan: Bool

    var txFrequency: Float {
        switch offset {
        case .none: return frequency
        case .down: return frequency - Float(offsetKHz) / 1_000.0
        case .up: return frequency + Float(offsetKHz) / 1_000.0
        }
    }

    var radioMemoryId: Int32 {
        let uuid = id.uuid
        let value = UInt32(uuid.0) << 24 | UInt32(uuid.1) << 16 | UInt32(uuid.2) << 8 | UInt32(uuid.3)
        return Int32(bitPattern: value == UInt32.max ? UInt32.max - 1 : value)
    }
}

struct AppSettings: Codable, Equatable {
    var callsign = ""
    var stickyPTT = false
    var disableAnimations = false
    var autoConnectOnStartup = false
    var beaconPosition = false
    var beaconFrequency = "Current"
    var aprsAccuracy = "Exact"
    var aprsIcon = "Phone"
    var digipeatPackets = false
    var autoBeaconEnabled = false
    var beaconIntervalSeconds = 600.0
    var aprsStatusComment = "KV4P/ATL"
    var exposeKISSTNC = false
    var packetRetentionSeconds = 86_400.0
    var bandwidth = "25kHz"
    var directTxFrequency = "146.5200"
    var directRxFrequency = "146.5200"
    var directTxTone = "None"
    var directRxTone = "None"
    var highPower = false
    var squelch = 0
    var filterPre = false
    var filterHigh = false
    var filterLow = false
    var min2mTx = "144"
    var max2mTx = "148"
    var min70cmTx = "420"
    var max70cmTx = "450"
    var micGainBoost = "Normal"
    var rxAudioBoost = "High"
    var blePowerDefaultMigrated = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callsign = try container.decodeIfPresent(String.self, forKey: .callsign) ?? callsign
        stickyPTT = try container.decodeIfPresent(Bool.self, forKey: .stickyPTT) ?? stickyPTT
        disableAnimations = try container.decodeIfPresent(Bool.self, forKey: .disableAnimations) ?? disableAnimations
        autoConnectOnStartup = try container.decodeIfPresent(Bool.self, forKey: .autoConnectOnStartup) ?? autoConnectOnStartup
        beaconPosition = try container.decodeIfPresent(Bool.self, forKey: .beaconPosition) ?? beaconPosition
        beaconFrequency = try container.decodeIfPresent(String.self, forKey: .beaconFrequency) ?? beaconFrequency
        aprsAccuracy = try container.decodeIfPresent(String.self, forKey: .aprsAccuracy) ?? aprsAccuracy
        aprsIcon = try container.decodeIfPresent(String.self, forKey: .aprsIcon) ?? aprsIcon
        digipeatPackets = try container.decodeIfPresent(Bool.self, forKey: .digipeatPackets) ?? digipeatPackets
        autoBeaconEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoBeaconEnabled) ?? autoBeaconEnabled
        beaconIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .beaconIntervalSeconds) ?? beaconIntervalSeconds
        aprsStatusComment = try container.decodeIfPresent(String.self, forKey: .aprsStatusComment) ?? aprsStatusComment
        exposeKISSTNC = try container.decodeIfPresent(Bool.self, forKey: .exposeKISSTNC) ?? exposeKISSTNC
        packetRetentionSeconds = try container.decodeIfPresent(Double.self, forKey: .packetRetentionSeconds) ?? packetRetentionSeconds
        bandwidth = try container.decodeIfPresent(String.self, forKey: .bandwidth) ?? bandwidth
        directTxFrequency = try container.decodeIfPresent(String.self, forKey: .directTxFrequency) ?? directTxFrequency
        directRxFrequency = try container.decodeIfPresent(String.self, forKey: .directRxFrequency) ?? directRxFrequency
        directTxTone = try container.decodeIfPresent(String.self, forKey: .directTxTone) ?? directTxTone
        directRxTone = try container.decodeIfPresent(String.self, forKey: .directRxTone) ?? directRxTone
        highPower = try container.decodeIfPresent(Bool.self, forKey: .highPower) ?? highPower
        squelch = try container.decodeIfPresent(Int.self, forKey: .squelch) ?? squelch
        filterPre = try container.decodeIfPresent(Bool.self, forKey: .filterPre) ?? filterPre
        filterHigh = try container.decodeIfPresent(Bool.self, forKey: .filterHigh) ?? filterHigh
        filterLow = try container.decodeIfPresent(Bool.self, forKey: .filterLow) ?? filterLow
        min2mTx = try container.decodeIfPresent(String.self, forKey: .min2mTx) ?? min2mTx
        max2mTx = try container.decodeIfPresent(String.self, forKey: .max2mTx) ?? max2mTx
        min70cmTx = try container.decodeIfPresent(String.self, forKey: .min70cmTx) ?? min70cmTx
        max70cmTx = try container.decodeIfPresent(String.self, forKey: .max70cmTx) ?? max70cmTx
        micGainBoost = try container.decodeIfPresent(String.self, forKey: .micGainBoost) ?? micGainBoost
        rxAudioBoost = try container.decodeIfPresent(String.self, forKey: .rxAudioBoost) ?? rxAudioBoost
        blePowerDefaultMigrated = try container.decodeIfPresent(Bool.self, forKey: .blePowerDefaultMigrated) ?? blePowerDefaultMigrated
    }
}

final class LocalStore {
    private let defaults = UserDefaults.standard

    func loadSettings() -> AppSettings {
        load(AppSettings.self, key: "settings") ?? AppSettings()
    }

    func saveSettings(_ settings: AppSettings) {
        save(settings, key: "settings")
    }

    func loadMemories() -> [ChannelMemory] {
        load([ChannelMemory].self, key: "memories") ?? [
            ChannelMemory(name: "National Simplex", group: "Favorites", frequency: 146.5200, offset: .none, offsetKHz: 600, txTone: "None", rxTone: "None", skipDuringScan: false),
            ChannelMemory(name: "APRS US", group: "APRS", frequency: 144.3900, offset: .none, offsetKHz: 600, txTone: "None", rxTone: "None", skipDuringScan: false)
        ]
    }

    func saveMemories(_ memories: [ChannelMemory]) {
        save(memories, key: "memories")
    }

    func loadMessages() -> [APRSMessage] {
        load([APRSMessage].self, key: "aprsMessages") ?? []
    }

    func saveMessages(_ messages: [APRSMessage], retentionSeconds: TimeInterval = 86_400) {
        let cutoff = Date().addingTimeInterval(-max(60, retentionSeconds))
        let retained = messages
            .filter { $0.timestamp >= cutoff }
            .suffix(500)
        save(Array(retained), key: "aprsMessages")
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
