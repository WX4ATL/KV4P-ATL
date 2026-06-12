// SPDX-License-Identifier: GPL-3.0-or-later
import CoreLocation
import Foundation

enum APRSMessageType: String, Codable {
    case message
    case position
    case weather
    case object
    case item
    case status
    case telemetry
    case query
    case thirdParty
    case capability
    case raw
}

struct APRSMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: APRSMessageType
    var from: String
    var to: String
    var body: String
    var timestamp: Date
    var latitude: Double?
    var longitude: Double?
    var relay: String?
    var symbolTable: String?
    var symbolCode: String?
    var acknowledged = false

    var symbol: APRSSymbol? {
        guard let table = symbolTable?.first, let code = symbolCode?.first else { return nil }
        return APRSSymbol(table: table, code: code)
    }
}

struct APRSStation: Identifiable, Equatable {
    var id: String { callsign }
    var callsign: String
    var coordinate: CLLocationCoordinate2D
    var lastHeard: Date
    var comment: String
    var relay: String?
    var symbol: APRSSymbol?

    static func == (lhs: APRSStation, rhs: APRSStation) -> Bool {
        lhs.callsign == rhs.callsign &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.lastHeard == rhs.lastHeard &&
        lhs.comment == rhs.comment &&
        lhs.relay == rhs.relay &&
        lhs.symbol == rhs.symbol
    }
}

struct APRSService {
    static let defaultDigipeaters = ["WIDE1-1", "WIDE2-1"]
    static let defaultRecipient = "BLN1CQ"

    static func adjustedCoordinate(_ coordinate: CLLocationCoordinate2D, accuracySetting: String) -> CLLocationCoordinate2D {
        guard accuracySetting == "Approx" else { return coordinate }

        // APRS "Approx" intentionally degrades precision to about city-neighborhood scale.
        let scale = 100.0
        return CLLocationCoordinate2D(
            latitude: (coordinate.latitude * scale).rounded() / scale,
            longitude: (coordinate.longitude * scale).rounded() / scale
        )
    }

    static func symbol(named name: String) -> APRSSymbol {
        switch name {
        case "Person": return .person
        case "House": return .house
        case "Car": return .car
        default: return .phone
        }
    }

    func makeMessage(from source: String, to destination: String, body: String, number: Int, digipeaters: [String] = defaultDigipeaters) throws -> AX25Packet {
        let safeBody = String(body.prefix(67))
        let recipient = destination.isEmpty ? Self.defaultRecipient : destination.uppercased()
        let info = ":\(recipient.padding(toLength: 9, withPad: " ", startingAt: 0)):\(safeBody){\(String(format: "%05d", number % 100_000))"
        return try makePacket(source: source, destination: "APRS", digipeaters: digipeaters, info: info)
    }

    func makePosition(from source: String, coordinate: CLLocationCoordinate2D, comment: String, symbol: APRSSymbol = .phone, digipeaters: [String] = defaultDigipeaters) throws -> AX25Packet {
        let info = "!\(formatLatitude(coordinate.latitude))\(symbol.table)\(formatLongitude(coordinate.longitude))\(symbol.code)\(comment)"
        return try makePacket(source: source, destination: "APRS", digipeaters: digipeaters, info: info)
    }

    func parse(packet: AX25Packet) -> APRSMessage {
        let body = String(decoding: packet.information, as: UTF8.self)
        let relay = packet.digipeaters.first(where: { $0.hasBeenRepeated })?.display

        guard let dataType = body.first else {
            return APRSMessage(type: .raw, from: packet.source.display, to: packet.destination.display, body: body, timestamp: Date(), relay: relay)
        }

        if dataType == ":" {
            let toStart = body.index(after: body.startIndex)
            let toEnd = body.index(toStart, offsetBy: min(9, body.distance(from: toStart, to: body.endIndex)), limitedBy: body.endIndex) ?? body.endIndex
            let to = String(body[toStart..<toEnd]).trimmingCharacters(in: .whitespaces)
            let hasSeparator = toEnd < body.endIndex && body[toEnd] == ":"
            let messageStart = hasSeparator ? body.index(after: toEnd) : toEnd
            let text = String(body[messageStart...])
            return APRSMessage(type: .message, from: packet.source.display, to: to, body: text, timestamp: Date(), relay: relay, acknowledged: text.contains("{"))
        }

        if dataType == "!" || dataType == "=" || dataType == "/" || dataType == "@" {
            let parsed = parsePositionInfo(body)
            return APRSMessage(type: .position, from: packet.source.display, to: packet.destination.display, body: parsed.comment, timestamp: Date(), latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString)
        }

        if dataType == ";" {
            let parsed = parseObjectInfo(body)
            return APRSMessage(type: .object, from: packet.source.display, to: packet.destination.display, body: parsed.text, timestamp: Date(), latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString)
        }

        if dataType == ")" {
            let parsed = parseItemInfo(body)
            return APRSMessage(type: .item, from: packet.source.display, to: packet.destination.display, body: parsed.text, timestamp: Date(), latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString)
        }

        if dataType == ">" {
            return APRSMessage(type: .status, from: packet.source.display, to: packet.destination.display, body: String(body.dropFirst()), timestamp: Date(), relay: relay)
        }

        if dataType == "_" {
            return APRSMessage(type: .weather, from: packet.source.display, to: packet.destination.display, body: String(body.dropFirst()), timestamp: Date(), relay: relay)
        }

        if dataType == "T" && body.hasPrefix("T#") {
            return APRSMessage(type: .telemetry, from: packet.source.display, to: packet.destination.display, body: body, timestamp: Date(), relay: relay)
        }

        if dataType == "?" {
            return APRSMessage(type: .query, from: packet.source.display, to: packet.destination.display, body: String(body.dropFirst()), timestamp: Date(), relay: relay)
        }

        if dataType == "}" {
            return APRSMessage(type: .thirdParty, from: packet.source.display, to: packet.destination.display, body: String(body.dropFirst()), timestamp: Date(), relay: relay)
        }

        if dataType == "<" {
            return APRSMessage(type: .capability, from: packet.source.display, to: packet.destination.display, body: String(body.dropFirst()), timestamp: Date(), relay: relay)
        }

        return APRSMessage(type: .raw, from: packet.source.display, to: packet.destination.display, body: body, timestamp: Date(), relay: relay)
    }

    private func makePacket(source: String, destination: String, digipeaters: [String], info: String) throws -> AX25Packet {
        AX25Packet(
            destination: try AX25Address(destination),
            source: try AX25Address(source),
            digipeaters: try digipeaters.map { try AX25Address($0) },
            information: Data(info.utf8)
        )
    }

    private func formatLatitude(_ latitude: Double) -> String {
        let hemisphere = latitude >= 0 ? "N" : "S"
        let absolute = abs(latitude)
        let degrees = Int(absolute)
        let minutes = (absolute - Double(degrees)) * 60
        return String(format: "%02d%05.2f%@", degrees, minutes, hemisphere)
    }

    private func formatLongitude(_ longitude: Double) -> String {
        let hemisphere = longitude >= 0 ? "E" : "W"
        let absolute = abs(longitude)
        let degrees = Int(absolute)
        let minutes = (absolute - Double(degrees)) * 60
        return String(format: "%03d%05.2f%@", degrees, minutes, hemisphere)
    }

    private func parsePositionInfo(_ body: String) -> (latitude: Double?, longitude: Double?, comment: String, symbol: APRSSymbol?) {
        let offset = (body.first == "/" || body.first == "@") ? 8 : 1
        return parseUncompressedPosition(body, start: offset, fallback: body)
    }

    private func parseObjectInfo(_ body: String) -> (latitude: Double?, longitude: Double?, text: String, symbol: APRSSymbol?) {
        guard body.count >= 11 else { return (nil, nil, body, nil) }
        let chars = Array(body)
        let name = String(chars[1..<min(10, chars.count)]).trimmingCharacters(in: .whitespaces)
        let parsed = parseUncompressedPosition(body, start: 11, fallback: body)
        let state = chars.count > 10 && chars[10] == "_" ? "deleted" : "live"
        let text = [name, state, parsed.comment]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return (parsed.latitude, parsed.longitude, text, parsed.symbol)
    }

    private func parseItemInfo(_ body: String) -> (latitude: Double?, longitude: Double?, text: String, symbol: APRSSymbol?) {
        let chars = Array(body)
        guard chars.count > 2,
              let marker = chars.dropFirst().firstIndex(where: { $0 == "!" || $0 == "_" }) else {
            return (nil, nil, body, nil)
        }
        let name = String(chars[1..<marker]).trimmingCharacters(in: .whitespaces)
        let parsed = parseUncompressedPosition(body, start: marker + 1, fallback: body)
        let state = chars[marker] == "_" ? "deleted" : "live"
        let text = [name, state, parsed.comment]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return (parsed.latitude, parsed.longitude, text, parsed.symbol)
    }

    private func parseUncompressedPosition(_ body: String, start: Int, fallback: String) -> (latitude: Double?, longitude: Double?, comment: String, symbol: APRSSymbol?) {
        guard body.count >= start + 19 else { return (nil, nil, fallback, nil) }
        let chars = Array(body)
        let latString = String(chars[start..<start + 8])
        let symbolTable = chars[start + 8]
        let lonString = String(chars[start + 9..<start + 18])
        let symbolCode = chars[start + 18]
        let comment = body.count > start + 19 ? String(chars.dropFirst(start + 19)) : ""
        return (parseLatitude(latString), parseLongitude(lonString), comment, APRSSymbol(table: symbolTable, code: symbolCode))
    }

    private func parseLatitude(_ text: String) -> Double? {
        guard text.count == 8,
              let degrees = Double(text.prefix(2)),
              let minutes = Double(text.dropFirst(2).prefix(5)) else { return nil }
        let sign = text.last == "S" ? -1.0 : 1.0
        return sign * (degrees + minutes / 60.0)
    }

    private func parseLongitude(_ text: String) -> Double? {
        guard text.count == 9,
              let degrees = Double(text.prefix(3)),
              let minutes = Double(text.dropFirst(3).prefix(5)) else { return nil }
        let sign = text.last == "W" ? -1.0 : 1.0
        return sign * (degrees + minutes / 60.0)
    }
}

struct APRSSymbol: Equatable {
    var table: Character
    var code: Character

    var encodedPair: String {
        "\(table)\(code)"
    }

    var tableString: String {
        String(table)
    }

    var codeString: String {
        String(code)
    }

    var sfSymbolName: String {
        switch code {
        case ">": return "car.fill"
        case "[": return "figure.walk"
        case "-": return "house.fill"
        case "$": return "iphone.gen1"
        case "_": return "cloud.sun.fill"
        case "r": return "antenna.radiowaves.left.and.right"
        case "k": return "truck.box.fill"
        case "Y": return "sailboat.fill"
        case "j": return "jeep.fill"
        case "b": return "bicycle"
        case "s": return "dot.radiowaves.left.and.right"
        case "/": return "mappin.and.ellipse"
        default: return "diamond.fill"
        }
    }

    static let phone = APRSSymbol(table: "/", code: "$")
    static let person = APRSSymbol(table: "/", code: "[")
    static let house = APRSSymbol(table: "/", code: "-")
    static let car = APRSSymbol(table: "/", code: ">")
}

final class DigipeatDeduper {
    private var cache: [String: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 120) {
        self.window = window
    }

    func shouldDigipeat(_ packet: AX25Packet, now: Date = Date()) -> Bool {
        cache = cache.filter { now.timeIntervalSince($0.value) < window }
        let key = packet.source.display + "|" + packet.destination.display + "|" + packet.information.base64EncodedString()
        if cache[key] != nil { return false }
        cache[key] = now
        return true
    }
}
