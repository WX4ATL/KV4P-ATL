// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct RepeaterInfo: Identifiable, Equatable {
    var id = UUID()
    var frequency: Float
    var input: Float
    var offsetMHz: Float
    var tone: String
    var location: String
    var state: String
    var county: String
    var callsign: String
    var use: String
    var miles: Float
    var bearing: String
}

enum RepeaterCSVParser {
    static func parse(_ csv: String, minFrequency: Float = 0, maxFrequency: Float = 1_000) -> [RepeaterInfo] {
        let records = splitRecords(csv)
        guard let header = records.first else { return [] }
        let isUSFormat = header.hasPrefix("Freq,Input,Offset,Tone,Location")
        let isIntlFormat = header.hasPrefix("Output Freq,Input Freq,Offset,Uplink Tone")
        guard isUSFormat || isIntlFormat else { return [] }

        return records.dropFirst().compactMap { record in
            guard !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let columns = splitLine(record)

            if isUSFormat {
                guard columns.count >= 12 else { return nil }
                let frequency = Float(columns[0]) ?? 0
                guard frequency >= minFrequency, frequency <= maxFrequency else { return nil }
                return RepeaterInfo(
                    frequency: frequency,
                    input: Float(columns[1]) ?? 0,
                    offsetMHz: Float(columns[2]) ?? 0,
                    tone: RadioToneHelper.normalize(columns[3]),
                    location: clean(columns[4]),
                    state: columns[5],
                    county: columns[6],
                    callsign: columns[7],
                    use: columns[8],
                    miles: Float(columns[9]) ?? 0,
                    bearing: columns[10]
                )
            }

            guard columns.count >= 11 else { return nil }
            let frequency = Float(columns[0]) ?? 0
            guard frequency >= minFrequency, frequency <= maxFrequency else { return nil }
            return RepeaterInfo(
                frequency: frequency,
                input: Float(columns[1]) ?? 0,
                offsetMHz: Float(columns[2]) ?? 0,
                tone: RadioToneHelper.normalize(columns[3]),
                location: clean(columns[6]),
                state: columns[8],
                county: columns[7],
                callsign: columns[5],
                use: columns[10],
                miles: 0,
                bearing: ""
            )
        }
    }

    static func memory(from repeater: RepeaterInfo, group: String) -> ChannelMemory {
        ChannelMemory(
            name: "\(repeater.callsign) - \(repeater.location)",
            group: group,
            frequency: repeater.frequency,
            offset: repeater.offsetMHz < 0 ? .down : repeater.offsetMHz > 0 ? .up : .none,
            offsetKHz: abs(Int((repeater.offsetMHz * 1_000).rounded())),
            txTone: repeater.tone,
            rxTone: "None",
            skipDuringScan: false
        )
    }

    private static func splitRecords(_ text: String) -> [String] {
        var records: [String] = []
        var current = ""
        var inQuotes = false

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "\n", !inQuotes {
                records.append(current)
                current.removeAll()
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            records.append(current)
        }
        return records
    }

    private static func splitLine(_ line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                columns.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll()
            } else {
                current.append(character)
            }
        }

        columns.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return columns
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
