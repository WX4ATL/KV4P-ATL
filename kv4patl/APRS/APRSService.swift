// SPDX-License-Identifier: GPL-3.0-or-later
import CoreLocation
import Foundation

enum APRSMessageType: String, Codable {
    case message
    case position
    case micE
    case weather
    case object
    case item
    case status
    case telemetry
    case query
    case thirdParty
    case capability
    case userDefined
    case gps
    case directionFinding
    case invalid
    case raw
}

struct APRSDataPoint: Codable, Equatable {
    var label: String
    var value: String
    var systemImage: String
    var tint: String
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
    var dataPoints: [APRSDataPoint] = []

    var symbol: APRSSymbol? {
        guard let table = symbolTable?.first, let code = symbolCode?.first else { return nil }
        return APRSSymbol(table: table, code: code)
    }

    init(
        id: UUID = UUID(),
        type: APRSMessageType,
        from: String,
        to: String,
        body: String,
        timestamp: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        relay: String? = nil,
        symbolTable: String? = nil,
        symbolCode: String? = nil,
        acknowledged: Bool = false,
        dataPoints: [APRSDataPoint] = []
    ) {
        self.id = id
        self.type = type
        self.from = from
        self.to = to
        self.body = body
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.relay = relay
        self.symbolTable = symbolTable
        self.symbolCode = symbolCode
        self.acknowledged = acknowledged
        self.dataPoints = dataPoints
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case from
        case to
        case body
        case timestamp
        case latitude
        case longitude
        case relay
        case symbolTable
        case symbolCode
        case acknowledged
        case dataPoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decode(APRSMessageType.self, forKey: .type)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        body = try container.decode(String.self, forKey: .body)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        relay = try container.decodeIfPresent(String.self, forKey: .relay)
        symbolTable = try container.decodeIfPresent(String.self, forKey: .symbolTable)
        symbolCode = try container.decodeIfPresent(String.self, forKey: .symbolCode)
        acknowledged = try container.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
        dataPoints = try container.decodeIfPresent([APRSDataPoint].self, forKey: .dataPoints) ?? []
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
        return parseInfo(
            body,
            source: packet.source.display,
            destination: packet.destination.display,
            destinationAddress: packet.destination,
            relay: relay,
            timestamp: Date(),
            depth: 0
        )
    }

    private func parseInfo(
        _ body: String,
        source: String,
        destination: String,
        destinationAddress: AX25Address?,
        relay: String?,
        timestamp: Date,
        depth: Int
    ) -> APRSMessage {

        guard let dataType = body.first else {
            return APRSMessage(type: .raw, from: source, to: destination, body: body, timestamp: timestamp, relay: relay)
        }

        if dataType == ":" {
            let parsed = parseMessageInfo(body)
            return APRSMessage(type: .message, from: source, to: parsed.to, body: parsed.text, timestamp: timestamp, relay: relay, acknowledged: parsed.acknowledged)
        }

        if dataType == "!" || dataType == "=" || dataType == "/" || dataType == "@" {
            let parsed = parsePositionInfo(body)
            let type: APRSMessageType = parsed.symbol?.code == "_" ? .weather : .position
            return APRSMessage(type: type, from: source, to: destination, body: parsed.comment, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString, dataPoints: parsed.dataPoints)
        }

        if dataType == ";" {
            let parsed = parseObjectInfo(body)
            return APRSMessage(type: .object, from: source, to: destination, body: parsed.text, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString, dataPoints: parsed.dataPoints)
        }

        if dataType == ")" {
            let parsed = parseItemInfo(body)
            return APRSMessage(type: .item, from: source, to: destination, body: parsed.text, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString, dataPoints: parsed.dataPoints)
        }

        if dataType == ">" {
            return APRSMessage(type: .status, from: source, to: destination, body: parseStatusInfo(body), timestamp: timestamp, relay: relay)
        }

        if dataType == "_" {
            let parsed = parseWeatherReport(String(body.dropFirst()))
            return APRSMessage(type: .weather, from: source, to: destination, body: parsed.body, timestamp: timestamp, relay: relay, dataPoints: parsed.dataPoints)
        }

        if dataType == "#" || dataType == "*" {
            return APRSMessage(type: .weather, from: source, to: destination, body: "raw weather - \(String(body.dropFirst()))", timestamp: timestamp, relay: relay)
        }

        if dataType == "T" && body.hasPrefix("T#") {
            let parsed = parseTelemetryInfo(body)
            return APRSMessage(type: .telemetry, from: source, to: destination, body: parsed.body, timestamp: timestamp, relay: relay, dataPoints: parsed.dataPoints)
        }

        if dataType == "?" {
            return APRSMessage(type: .query, from: source, to: destination, body: String(body.dropFirst()), timestamp: timestamp, relay: relay)
        }

        if dataType == "}" {
            let parsed = parseThirdPartyInfo(body, relay: relay, timestamp: timestamp, depth: depth)
            return APRSMessage(type: .thirdParty, from: source, to: destination, body: parsed.body, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString, dataPoints: parsed.dataPoints)
        }

        if dataType == "<" {
            return APRSMessage(type: .capability, from: source, to: destination, body: String(body.dropFirst()), timestamp: timestamp, relay: relay)
        }

        if dataType == "{" {
            return APRSMessage(type: .userDefined, from: source, to: destination, body: parseUserDefinedInfo(body), timestamp: timestamp, relay: relay)
        }

        if dataType == "$" {
            let parsed = parseNMEAInfo(body)
            return APRSMessage(type: .gps, from: source, to: destination, body: parsed.body, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, dataPoints: parsed.dataPoints)
        }

        if dataType == "%" {
            return APRSMessage(type: .directionFinding, from: source, to: destination, body: String(body.dropFirst()), timestamp: timestamp, relay: relay)
        }

        if dataType == "[" {
            let parsed = parseMaidenheadInfo(body)
            return APRSMessage(type: .position, from: source, to: destination, body: parsed.body, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay)
        }

        if dataType == "," {
            return APRSMessage(type: .invalid, from: source, to: destination, body: "invalid/test data - \(String(body.dropFirst()))", timestamp: timestamp, relay: relay)
        }

        if isMicEDataType(dataType), let destinationAddress {
            let parsed = parseMicEInfo(body, destination: destinationAddress)
            return APRSMessage(type: .micE, from: source, to: destination, body: parsed.body, timestamp: timestamp, latitude: parsed.latitude, longitude: parsed.longitude, relay: relay, symbolTable: parsed.symbol?.tableString, symbolCode: parsed.symbol?.codeString, dataPoints: parsed.dataPoints)
        }

        return APRSMessage(type: .raw, from: source, to: destination, body: body, timestamp: timestamp, relay: relay)
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

    private func parseMessageInfo(_ body: String) -> (to: String, text: String, acknowledged: Bool) {
        let toStart = body.index(after: body.startIndex)
        let toEnd = body.index(toStart, offsetBy: min(9, body.distance(from: toStart, to: body.endIndex)), limitedBy: body.endIndex) ?? body.endIndex
        let to = String(body[toStart..<toEnd]).trimmingCharacters(in: .whitespaces)
        let hasSeparator = toEnd < body.endIndex && body[toEnd] == ":"
        let messageStart = hasSeparator ? body.index(after: toEnd) : toEnd
        let text = String(body[messageStart...])

        if to.hasPrefix("BLN") {
            return (to, "bulletin \(to) - \(text)", text.contains("{"))
        }
        if text.hasPrefix("ack") || text.hasPrefix("rej") {
            return (to, "message \(text)", true)
        }
        return (to, text, text.contains("{"))
    }

    private func parsePositionInfo(_ body: String) -> ParsedPosition {
        let offset = (body.first == "/" || body.first == "@") ? 8 : 1
        return parsePositionBody(body, start: offset, fallback: body)
    }

    private func parseObjectInfo(_ body: String) -> (latitude: Double?, longitude: Double?, text: String, symbol: APRSSymbol?, dataPoints: [APRSDataPoint]) {
        let chars = Array(body)
        guard chars.count >= 11 else { return (nil, nil, body, nil, []) }
        let name = String(chars[1..<min(10, chars.count)]).trimmingCharacters(in: .whitespaces)
        let state = chars.count > 10 && chars[10] == "_" ? "deleted" : "live"
        let hasTimestamp = chars.count >= 18 && isAPRSTimestamp(chars, start: 11)
        let parsed = parsePositionBody(body, start: hasTimestamp ? 18 : 11, fallback: body)
        let points = [dataPoint("State", state, "power", "green")] + parsed.dataPoints
        let text = [name, state, parsed.comment]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return (parsed.latitude, parsed.longitude, text, parsed.symbol, points)
    }

    private func parseItemInfo(_ body: String) -> (latitude: Double?, longitude: Double?, text: String, symbol: APRSSymbol?, dataPoints: [APRSDataPoint]) {
        let chars = Array(body)
        guard chars.count > 2,
              let marker = chars.dropFirst().firstIndex(where: { $0 == "!" || $0 == "_" }) else {
            return (nil, nil, body, nil, [])
        }
        let name = String(chars[1..<marker]).trimmingCharacters(in: .whitespaces)
        let parsed = parsePositionBody(body, start: marker + 1, fallback: body)
        let state = chars[marker] == "_" ? "deleted" : "live"
        let points = [dataPoint("State", state, "power", "green")] + parsed.dataPoints
        let text = [name, state, parsed.comment]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return (parsed.latitude, parsed.longitude, text, parsed.symbol, points)
    }

    private func parsePositionBody(_ body: String, start: Int, fallback: String) -> ParsedPosition {
        if let uncompressed = parseUncompressedPosition(body, start: start) {
            return uncompressed
        }
        if let compressed = parseCompressedPosition(body, start: start) {
            return compressed
        }
        return ParsedPosition(latitude: nil, longitude: nil, comment: fallback, symbol: nil)
    }

    private func parseUncompressedPosition(_ body: String, start: Int) -> ParsedPosition? {
        let chars = Array(body)
        guard chars.count >= start + 19 else { return nil }
        let latString = String(chars[start..<start + 8])
        let lonString = String(chars[start + 9..<start + 18])
        guard let latitude = parseLatitude(latString),
              let longitude = parseLongitude(lonString) else { return nil }
        let symbolTable = chars[start + 8]
        let symbolCode = chars[start + 18]
        let rawComment = chars.count > start + 19 ? String(chars.dropFirst(start + 19)) : ""
        let payload = summarizePositionComment(rawComment, symbolCode: symbolCode)
        return ParsedPosition(latitude: latitude, longitude: longitude, comment: payload.body, symbol: APRSSymbol(table: symbolTable, code: symbolCode), dataPoints: payload.dataPoints)
    }

    private func parseCompressedPosition(_ body: String, start: Int) -> ParsedPosition? {
        let chars = Array(body)
        guard chars.count >= start + 13 else { return nil }
        let symbolTable = chars[start]
        let latChars = Array(chars[start + 1..<start + 5])
        let lonChars = Array(chars[start + 5..<start + 9])
        let symbolCode = chars[start + 9]
        guard let latValue = base91(latChars),
              let lonValue = base91(lonChars) else { return nil }

        let latitude = 90.0 - Double(latValue) / 380_926.0
        let longitude = -180.0 + Double(lonValue) / 190_463.0
        var dataPoints: [APRSDataPoint] = []
        if let courseValue = base91(chars[start + 10]),
           let speedValue = base91(chars[start + 11]),
           courseValue >= 0,
           courseValue < 90 {
            let course = courseValue * 4
            let speed = max(0, Int(pow(1.08, Double(speedValue)).rounded()) - 1)
            dataPoints.append(contentsOf: courseSpeedDataPoints(course: course, knots: speed, isWeather: symbolCode == "_"))
        }

        let rawComment = chars.count > start + 13 ? String(chars.dropFirst(start + 13)) : ""
        let payload = summarizePositionComment(rawComment, symbolCode: symbolCode)
        return ParsedPosition(latitude: latitude, longitude: longitude, comment: payload.body, symbol: APRSSymbol(table: symbolTable, code: symbolCode), dataPoints: dataPoints + payload.dataPoints)
    }

    private func summarizePositionComment(_ rawComment: String, symbolCode: Character) -> ParsedPayload {
        var comment = rawComment.trimmingCharacters(in: .whitespacesAndNewlines)
        var dataPoints: [APRSDataPoint] = []

        if comment.count >= 7 {
            let prefix = String(comment.prefix(7))
            let parts = prefix.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2,
               parts[0].count == 3,
               parts[1].count == 3,
               let course = Int(parts[0]),
               let speed = Int(parts[1]) {
                dataPoints.append(contentsOf: courseSpeedDataPoints(course: course, knots: speed, isWeather: symbolCode == "_"))
                comment.removeFirst(7)
            }
        }

        if comment.hasPrefix("PHG"), comment.count >= 7 {
            dataPoints.append(dataPoint("PHG", String(comment.prefix(7)), "antenna.radiowaves.left.and.right", "purple"))
            comment.removeFirst(7)
        }

        if comment.hasPrefix("RNG"), comment.count >= 7 {
            let value = String(comment.dropFirst(3).prefix(4))
            if let range = Int(value) {
                dataPoints.append(dataPoint("Range", "\(range) mi", "scope", "purple"))
                comment.removeFirst(7)
            }
        }

        if let altitude = extractAltitude(from: &comment) {
            dataPoints.append(dataPoint("Altitude", "\(altitude) ft", "mountain.2", "orange"))
        }

        if symbolCode == "_" {
            let weather = parseWeatherReport(comment)
            if !weather.dataPoints.isEmpty {
                comment = weather.body
                dataPoints.append(contentsOf: weather.dataPoints)
            }
        }

        return ParsedPayload(
            body: comment.trimmingCharacters(in: CharacterSet(charactersIn: " /,\t\r\n")),
            dataPoints: dataPoints
        )
    }

    private func extractAltitude(from comment: inout String) -> Int? {
        guard let range = comment.range(of: #"/A=-?[0-9]{6}"#, options: .regularExpression) else { return nil }
        let token = String(comment[range])
        comment.removeSubrange(range)
        return Int(token.replacingOccurrences(of: "/A=", with: ""))
    }

    private func parseStatusInfo(_ body: String) -> String {
        let text = String(body.dropFirst())
        let chars = Array(text)
        if chars.count >= 7, isAPRSTimestamp(chars, start: 0) {
            return String(chars.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func parseWeatherReport(_ text: String) -> ParsedPayload {
        let chars = Array(text)
        var dataPoints: [APRSDataPoint] = []
        let widths: [Character: Int] = ["c": 3, "s": 3, "g": 3, "t": 3, "r": 3, "p": 3, "P": 3, "h": 2, "b": 5, "L": 3, "l": 3, "X": 3]
        var index = 0
        var lastParsedEnd = 0

        while index < chars.count {
            let key = chars[index]
            guard let width = widths[key], index + width < chars.count else {
                index += 1
                continue
            }
            let value = String(chars[(index + 1)...(index + width)])
            guard value.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else {
                index += 1
                continue
            }
            switch key {
            case "c":
                dataPoints.append(windDirectionDataPoint(degrees: Int(value) ?? 0))
            case "s":
                dataPoints.append(windSpeedDataPoint(knots: Int(value) ?? 0))
            case "g":
                dataPoints.append(dataPoint("Gust", "\(mph(fromKnots: Int(value) ?? 0)) mph", "wind.snow", "blue"))
            case "t":
                dataPoints.append(dataPoint("Temp", "\(Int(value) ?? 0)°F", "thermometer.medium", "orange"))
            case "r":
                dataPoints.append(dataPoint("Rain 1h", "\(hundredths(value)) in", "cloud.rain", "teal"))
            case "p":
                dataPoints.append(dataPoint("Rain 24h", "\(hundredths(value)) in", "cloud.heavyrain", "teal"))
            case "P":
                dataPoints.append(dataPoint("Rain today", "\(hundredths(value)) in", "drop", "teal"))
            case "h":
                dataPoints.append(dataPoint("Humidity", "\(value == "00" ? "100" : value)%", "humidity", "cyan"))
            case "b":
                if let pressure = Double(value) {
                    dataPoints.append(dataPoint("Pressure", String(format: "%.1f mb", pressure / 10.0), "barometer", "purple"))
                }
            case "L", "l":
                dataPoints.append(dataPoint("Light", value, "sun.max", "yellow"))
            case "X":
                dataPoints.append(dataPoint("Radiation", value, "waveform.path.ecg", "red"))
            default:
                break
            }
            lastParsedEnd = index + width + 1
            index += width + 1
        }

        let body = dataPoints.isEmpty ? text : weatherComment(in: chars, after: lastParsedEnd)
        return ParsedPayload(body: body, dataPoints: dataPoints)
    }

    private func parseTelemetryInfo(_ body: String) -> ParsedPayload {
        let payload = String(body.dropFirst(2))
        let parts = payload.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return ParsedPayload(body: body) }
        let sequence = parts[0]
        let analog = parts.dropFirst().prefix(5).filter { !$0.isEmpty }
        let digital = parts.count > 6 ? parts[6] : ""
        let comment = parts.count > 7 ? parts.dropFirst(7).joined(separator: ",") : ""
        var dataPoints = [dataPoint("Sequence", sequence, "number", "blue")]
        if !analog.isEmpty {
            dataPoints.append(dataPoint("Channels", analog.joined(separator: "/"), "waveform.path.ecg", "purple"))
        }
        if !digital.isEmpty {
            dataPoints.append(dataPoint("Bits", digital, "switch.2", "purple"))
        }
        return ParsedPayload(body: comment.isEmpty ? "Telemetry report" : comment, dataPoints: dataPoints)
    }

    private func parseThirdPartyInfo(_ body: String, relay: String?, timestamp: Date, depth: Int) -> ParsedPosition {
        let inner = String(body.dropFirst())
        guard depth < 2,
              let headerEnd = inner.firstIndex(of: ":"),
              let sourceEnd = inner.firstIndex(of: ">"),
              sourceEnd < headerEnd else {
            return ParsedPosition(latitude: nil, longitude: nil, comment: inner, symbol: nil)
        }

        let source = String(inner[..<sourceEnd])
        let path = String(inner[inner.index(after: sourceEnd)..<headerEnd])
        let parts = path.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let destination = parts.first ?? ""
        let info = String(inner[inner.index(after: headerEnd)...])
        let parsed = parseInfo(info, source: source, destination: destination, destinationAddress: nil, relay: relay, timestamp: timestamp, depth: depth + 1)
        let prefix = "\(source)>\(destination)"
        let body = parsed.body.isEmpty ? "\(prefix): \(parsed.type.rawValue)" : "\(prefix): \(parsed.body)"
        return ParsedPosition(latitude: parsed.latitude, longitude: parsed.longitude, comment: body, symbol: parsed.symbol, dataPoints: parsed.dataPoints)
    }

    private func parseUserDefinedInfo(_ body: String) -> String {
        let payload = String(body.dropFirst())
        guard let userID = payload.first else { return "" }
        let rest = String(payload.dropFirst())
        return "user \(userID) - \(rest)"
    }

    private func parseNMEAInfo(_ body: String) -> (latitude: Double?, longitude: Double?, body: String, dataPoints: [APRSDataPoint]) {
        let fields = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let sentence = fields.first else { return (nil, nil, body, []) }

        if sentence.hasSuffix("GGA"), fields.count > 9,
           let latitude = parseNMEACoordinate(fields[2], hemisphere: fields[3], degreeDigits: 2),
           let longitude = parseNMEACoordinate(fields[4], hemisphere: fields[5], degreeDigits: 3) {
            var dataPoints: [APRSDataPoint] = []
            if !fields[7].isEmpty {
                dataPoints.append(dataPoint("Satellites", fields[7], "dot.radiowaves.left.and.right", "blue"))
            }
            if !fields[9].isEmpty {
                dataPoints.append(dataPoint("Altitude", "\(fields[9]) m", "mountain.2", "orange"))
            }
            return (latitude, longitude, "GPS fix", dataPoints)
        }

        if sentence.hasSuffix("RMC"), fields.count > 8,
           let latitude = parseNMEACoordinate(fields[3], hemisphere: fields[4], degreeDigits: 2),
           let longitude = parseNMEACoordinate(fields[5], hemisphere: fields[6], degreeDigits: 3) {
            var dataPoints: [APRSDataPoint] = []
            if let knots = Double(fields[7]) {
                dataPoints.append(dataPoint("Speed", "\(Int((knots * 1.15078).rounded())) mph", "speedometer", "green"))
            }
            if !fields[8].isEmpty {
                dataPoints.append(dataPoint("Course", "\(fields[8])°", "location.north.line", "blue"))
            }
            return (latitude, longitude, "GPS fix", dataPoints)
        }

        return (nil, nil, "raw GPS - \(body)", [])
    }

    private func parseMaidenheadInfo(_ body: String) -> (latitude: Double?, longitude: Double?, body: String) {
        let payload = String(body.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        let grid = String(payload.prefix(6)).uppercased()
        guard grid.count >= 4,
              let coordinate = maidenheadCenter(grid) else {
            return (nil, nil, payload)
        }
        let suffix = payload.count > grid.count ? " - \(String(payload.dropFirst(grid.count)).trimmingCharacters(in: .whitespaces))" : ""
        return (coordinate.latitude, coordinate.longitude, "Maidenhead \(grid)\(suffix)")
    }

    private func parseMicEInfo(_ body: String, destination: AX25Address) -> ParsedPosition {
        let info = Array(body)
        guard info.count >= 9,
              let latitude = parseMicELatitude(destination.callsign),
              let longitude = parseMicELongitude(info, destination: destination.callsign) else {
            return ParsedPosition(latitude: nil, longitude: nil, comment: "Mic-E \(String(body.dropFirst()))", symbol: nil)
        }

        let speedCourse = parseMicESpeedCourse(info)
        var dataPoints = [dataPoint("Format", "Mic-E", "dot.radiowaves.left.and.right", "purple")]
        if let speedCourse {
            dataPoints.append(dataPoint("Course", "\(speedCourse.course)°", "location.north.line", "blue"))
            dataPoints.append(speedDataPoint(knots: speedCourse.speed))
        }
        let symbol = APRSSymbol(table: info[8], code: info[7])
        let comment = info.count > 9 ? String(info.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return ParsedPosition(latitude: latitude, longitude: longitude, comment: comment, symbol: symbol, dataPoints: dataPoints)
    }

    private func parseLatitude(_ text: String) -> Double? {
        guard text.count == 8 else { return nil }
        let chars = Array(text)
        guard chars[7] == "N" || chars[7] == "S" else { return nil }
        let normalized = text.replacingOccurrences(of: " ", with: "0")
        guard let degrees = Double(normalized.prefix(2)),
              let minutes = Double(normalized.dropFirst(2).prefix(5)) else { return nil }
        let sign = chars[7] == "S" ? -1.0 : 1.0
        return sign * (degrees + minutes / 60.0)
    }

    private func parseLongitude(_ text: String) -> Double? {
        guard text.count == 9 else { return nil }
        let chars = Array(text)
        guard chars[8] == "E" || chars[8] == "W" else { return nil }
        let normalized = text.replacingOccurrences(of: " ", with: "0")
        guard let degrees = Double(normalized.prefix(3)),
              let minutes = Double(normalized.dropFirst(3).prefix(5)) else { return nil }
        let sign = chars[8] == "W" ? -1.0 : 1.0
        return sign * (degrees + minutes / 60.0)
    }

    private func parseNMEACoordinate(_ value: String, hemisphere: String, degreeDigits: Int) -> Double? {
        guard value.count > degreeDigits,
              let degrees = Double(value.prefix(degreeDigits)),
              let minutes = Double(value.dropFirst(degreeDigits)) else { return nil }
        let sign = (hemisphere == "S" || hemisphere == "W") ? -1.0 : 1.0
        return sign * (degrees + minutes / 60.0)
    }

    private func maidenheadCenter(_ grid: String) -> CLLocationCoordinate2D? {
        let chars = Array(grid.uppercased())
        guard chars.count >= 4,
              let fieldLon = letterIndex(chars[0], in: "ABCDEFGHIJKLMNOPQR"),
              let fieldLat = letterIndex(chars[1], in: "ABCDEFGHIJKLMNOPQR"),
              let squareLon = chars[2].wholeNumberValue,
              let squareLat = chars[3].wholeNumberValue else { return nil }

        var longitude = Double(fieldLon) * 20.0 - 180.0 + Double(squareLon) * 2.0
        var latitude = Double(fieldLat) * 10.0 - 90.0 + Double(squareLat)
        var cellWidth = 2.0
        var cellHeight = 1.0

        if chars.count >= 6,
           let subLon = letterIndex(chars[4], in: "ABCDEFGHIJKLMNOPQRSTUVWX"),
           let subLat = letterIndex(chars[5], in: "ABCDEFGHIJKLMNOPQRSTUVWX") {
            cellWidth = 5.0 / 60.0
            cellHeight = 2.5 / 60.0
            longitude += Double(subLon) * cellWidth
            latitude += Double(subLat) * cellHeight
        }

        return CLLocationCoordinate2D(latitude: latitude + cellHeight / 2.0, longitude: longitude + cellWidth / 2.0)
    }

    private func parseMicELatitude(_ destination: String) -> Double? {
        let chars = Array(destination.padding(toLength: 6, withPad: "0", startingAt: 0))
        guard chars.count >= 6,
              let d0 = micEDigit(chars[0]),
              let d1 = micEDigit(chars[1]),
              let m0 = micEDigit(chars[2]),
              let m1 = micEDigit(chars[3]),
              let h0 = micEDigit(chars[4]),
              let h1 = micEDigit(chars[5]) else { return nil }

        let degrees = Double(d0 * 10 + d1)
        let minutes = Double(m0 * 10 + m1) + Double(h0 * 10 + h1) / 100.0
        let sign = micEFlagIsHigh(chars[3]) ? 1.0 : -1.0
        return sign * (degrees + minutes / 60.0)
    }

    private func parseMicELongitude(_ info: [Character], destination: String) -> Double? {
        let chars = Array(destination.padding(toLength: 6, withPad: "0", startingAt: 0))
        guard info.count > 3,
              chars.count >= 6,
              var degrees = micEByte(info[1]),
              var minutes = micEByte(info[2]),
              var hundredths = micEByte(info[3]) else { return nil }

        if micEFlagIsHigh(chars[4]) {
            degrees += 100
        }
        if degrees >= 180 {
            degrees -= 80
        }
        if minutes >= 60 {
            minutes -= 60
        }
        if hundredths >= 60 {
            hundredths -= 60
        }
        guard (0...179).contains(degrees),
              (0...59).contains(minutes),
              (0...99).contains(hundredths) else { return nil }

        let longitude = Double(degrees) + (Double(minutes) + Double(hundredths) / 100.0) / 60.0
        return micEFlagIsHigh(chars[5]) ? -longitude : longitude
    }

    private func parseMicESpeedCourse(_ info: [Character]) -> (speed: Int, course: Int)? {
        guard info.count > 6,
              let sp = micEByte(info[4]),
              let dc = micEByte(info[5]),
              let se = micEByte(info[6]) else { return nil }
        var speed = sp * 10 + dc / 10
        var course = (dc % 10) * 100 + se
        if speed >= 800 {
            speed -= 800
        }
        if course >= 400 {
            course -= 400
        }
        return (speed, course)
    }

    private func micEDigit(_ char: Character) -> Int? {
        guard let value = ascii(char) else { return nil }
        switch value {
        case 48...57:
            return Int(value - 48)
        case 65...74:
            return Int(value - 65)
        case 80...89:
            return Int(value - 80)
        default:
            return nil
        }
    }

    private func micEFlagIsHigh(_ char: Character) -> Bool {
        guard let value = ascii(char) else { return false }
        return (65...90).contains(value)
    }

    private func micEByte(_ char: Character) -> Int? {
        guard let value = ascii(char) else { return nil }
        return Int(value) - 28
    }

    private func isMicEDataType(_ char: Character) -> Bool {
        if char == "`" || char == "'" { return true }
        guard let value = ascii(char) else { return false }
        return value == 0x1C || value == 0x1D
    }

    private func isAPRSTimestamp(_ chars: [Character], start: Int) -> Bool {
        guard chars.count >= start + 7 else { return false }
        let numeric = chars[start..<(start + 6)].allSatisfy { $0.isNumber }
        let suffix = chars[start + 6]
        return numeric && (suffix == "z" || suffix == "/" || suffix == "h")
    }

    private func base91(_ chars: [Character]) -> Int? {
        var value = 0
        for char in chars {
            guard let digit = base91(char) else { return nil }
            value = value * 91 + digit
        }
        return value
    }

    private func base91(_ char: Character) -> Int? {
        guard let value = ascii(char),
              (33...123).contains(value) else { return nil }
        return Int(value - 33)
    }

    private func letterIndex(_ char: Character, in alphabet: String) -> Int? {
        Array(alphabet).firstIndex(of: char)
    }

    private func hundredths(_ value: String) -> String {
        guard let integer = Int(value) else { return value }
        return String(format: "%.2f", Double(integer) / 100.0)
    }

    private func courseSpeedDataPoints(course: Int, knots: Int, isWeather: Bool) -> [APRSDataPoint] {
        if isWeather {
            return [
                windDirectionDataPoint(degrees: course),
                windSpeedDataPoint(knots: knots)
            ]
        }
        return [
            dataPoint("Course", "\(course)°", "location.north.line", "blue"),
            speedDataPoint(knots: knots)
        ]
    }

    private func speedDataPoint(knots: Int) -> APRSDataPoint {
        dataPoint("Speed", "\(mph(fromKnots: knots)) mph", "speedometer", "green")
    }

    private func windDirectionDataPoint(degrees: Int) -> APRSDataPoint {
        dataPoint("Wind dir", "\(degrees)°", "safari", "blue")
    }

    private func windSpeedDataPoint(knots: Int) -> APRSDataPoint {
        dataPoint("Wind speed", "\(mph(fromKnots: knots)) mph", "wind", "blue")
    }

    private func weatherComment(in chars: [Character], after index: Int) -> String {
        guard index < chars.count else { return "" }
        return String(chars.dropFirst(index)).trimmingCharacters(in: CharacterSet(charactersIn: " /,\t\r\n"))
    }

    private func mph(fromKnots knots: Int) -> Int {
        Int((Double(knots) * 1.15078).rounded())
    }

    private func dataPoint(_ label: String, _ value: String, _ systemImage: String, _ tint: String) -> APRSDataPoint {
        APRSDataPoint(label: label, value: value, systemImage: systemImage, tint: tint)
    }

    private func ascii(_ char: Character) -> UInt8? {
        guard char.unicodeScalars.count == 1,
              let value = char.unicodeScalars.first?.value,
              value <= UInt8.max else { return nil }
        return UInt8(value)
    }
}

private struct ParsedPosition {
    var latitude: Double?
    var longitude: Double?
    var comment: String
    var symbol: APRSSymbol?
    var dataPoints: [APRSDataPoint] = []

    var body: String {
        comment
    }
}

private struct ParsedPayload {
    var body: String
    var dataPoints: [APRSDataPoint] = []
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
