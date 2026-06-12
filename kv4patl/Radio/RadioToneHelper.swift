// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum RadioToneHelper {
    static let validToneStrings = [
        "None", "67", "71.9", "74.4", "77", "79.7", "82.5", "85.4", "88.5",
        "91.5", "94.8", "97.4", "100", "103.5", "107.2", "110.9", "114.8",
        "118.8", "123", "127.3", "131.8", "136.5", "141.3", "146.2", "151.4",
        "156.7", "162.2", "167.9", "173.8", "179.9", "186.2", "192.8", "203.5",
        "210.7", "218.1", "225.7", "233.6", "241.8", "250.3"
    ]

    private static let validToneValues: [Double] = [
        67, 71.9, 74.4, 77, 79.7, 82.5, 85.4, 88.5,
        91.5, 94.8, 97.4, 100, 103.5, 107.2, 110.9, 114.8,
        118.8, 123, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4,
        156.7, 162.2, 167.9, 173.8, 179.9, 186.2, 192.8, 203.5,
        210.7, 218.1, 225.7, 233.6, 241.8, 250.3
    ]

    static func normalize(_ input: String?) -> String {
        guard let input else { return "None" }
        let tone = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tone.isEmpty else { return "None" }
        if validToneStrings.contains(tone) { return tone }
        guard let value = Double(tone), value != 0, value != 1 else { return "None" }

        let candidate = validToneValues
            .map { (tone: $0, distance: abs($0 - value)) }
            .filter { $0.distance <= 1.0 }
            .min { $0.distance < $1.distance }?
            .tone

        guard let candidate else { return "None" }
        if candidate.rounded() == candidate {
            return String(format: "%.0f", candidate)
        }
        return String(candidate)
    }

    static func toneIndex(_ input: String?) -> UInt8 {
        let normalized = normalize(input)
        guard let index = validToneStrings.firstIndex(of: normalized) else { return 0 }
        return UInt8(index)
    }
}
