import Foundation

enum TVPairingConstants {
    static let bonjourType = "_niopowerswap-tv._tcp"
    static let bonjourDomain = "local."
    static let scheme = "niopowerswapassist"
    static let urlHost = "tv-pair"
    static let maxBodyBytes = 65_536
    static let maxFailedAttempts = 5
    static let sessionTTLSeconds: TimeInterval = 300
}

struct TVPairingRoutePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let customOrigin: SendRoutePoiInput?
    let waypoints: [SendRoutePoiInput]
    let destination: SendRoutePoiInput
    let enableEnergyPlanning: Bool
    let preferredPlanTag: String?

    init(
        id: UUID = UUID(),
        name: String,
        customOrigin: SendRoutePoiInput? = nil,
        waypoints: [SendRoutePoiInput] = [],
        destination: SendRoutePoiInput,
        enableEnergyPlanning: Bool = true,
        preferredPlanTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.customOrigin = customOrigin
        self.waypoints = Array(waypoints.prefix(10))
        self.destination = destination
        self.enableEnergyPlanning = enableEnergyPlanning
        self.preferredPlanTag = preferredPlanTag
    }

    var summarySubtitle: String {
        if waypoints.isEmpty {
            return "终点：\(destination.name)"
        }
        return "经 \(waypoints.count) 点 → \(destination.name)"
    }

    func buildRequestPOIs() -> [SendRoutePoiInput] {
        var result: [SendRoutePoiInput] = []
        if let customOrigin {
            result.append(Self.withStationType(customOrigin, .orig))
        }
        result.append(contentsOf: waypoints.map { Self.withStationType($0, .waypoint) })
        result.append(Self.withStationType(destination, .dest))
        return result
    }

    private static func withStationType(
        _ poi: SendRoutePoiInput,
        _ type: RouteNodeType
    ) -> SendRoutePoiInput {
        SendRoutePoiInput(
            name: poi.name,
            address: poi.address,
            latitude: poi.latitude,
            longitude: poi.longitude,
            resourceID: poi.resourceID,
            cloneLatitude: poi.cloneLatitude,
            cloneLongitude: poi.cloneLongitude,
            nextPointDistance: poi.nextPointDistance,
            stationType: type
        )
    }
}

struct TVPairingPayload: Codable, Equatable, Sendable {
    let schema: Int
    let baseURLString: String
    let apiKey: String
    let controlKey: String?
    let stationID: String?
    let stationName: String?
    let routePresets: [TVPairingRoutePreset]?

    init(
        schema: Int = 1,
        baseURLString: String,
        apiKey: String,
        controlKey: String? = nil,
        stationID: String? = nil,
        stationName: String? = nil,
        routePresets: [TVPairingRoutePreset]? = nil
    ) {
        self.schema = schema
        self.baseURLString = baseURLString
        self.apiKey = apiKey
        self.controlKey = controlKey
        self.stationID = stationID
        self.stationName = stationName
        self.routePresets = routePresets
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case baseURLString = "base_url"
        case apiKey = "api_key"
        case controlKey = "control_key"
        case stationID = "station_id"
        case stationName = "station_name"
        case routePresets = "route_presets"
    }
}

struct TVPairingEnvelope: Codable, Equatable, Sendable {
    let code: String
    let payload: TVPairingPayload
}

struct TVPairingEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16
    let code: String
    let tvName: String?

    init?(host: String, port: UInt16, code: String, tvName: String? = nil) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              port > 0,
              Self.isValidPairingCode(trimmedCode) else {
            return nil
        }
        self.host = trimmedHost
        self.port = port
        self.code = trimmedCode
        self.tvName = tvName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(pairingURL url: URL) {
        guard url.scheme?.lowercased() == TVPairingConstants.scheme,
              url.host?.lowercased() == TVPairingConstants.urlHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            }
        )
        guard let host = query["host"],
              let rawPort = query["port"],
              let port = UInt16(rawPort),
              let code = query["code"] else {
            return nil
        }
        self.init(host: host, port: port, code: code, tvName: query["name"])
    }

    var pairingURL: URL? {
        var components = URLComponents()
        components.scheme = TVPairingConstants.scheme
        components.host = TVPairingConstants.urlHost
        var items = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code)
        ]
        if let tvName, !tvName.isEmpty {
            items.append(URLQueryItem(name: "name", value: tvName))
        }
        components.queryItems = items
        return components.url
    }

    static func normalizePairingCode(_ code: String) -> String {
        String(code.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.prefix(6))
    }

    static func isValidPairingCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 6 && bytes.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }
}

enum TVPairingWireError: Error, Equatable {
    case incomplete
    case invalidRequest
    case bodyTooLarge
    case unsupportedMethod
    case notFound
}

enum TVPairingWire {
    struct ParsedHTTPRequest: Equatable, Sendable {
        let method: String
        let path: String
        let body: Data
    }

    /// Constant-time comparison for 6-digit pairing codes.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= (x ^ y)
        }
        return diff == 0
    }

    static func parseHTTPRequest(from buffer: Data) -> Result<ParsedHTTPRequest, TVPairingWireError> {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            if buffer.count > 16_384 {
                return .failure(.bodyTooLarge)
            }
            return .failure(.incomplete)
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .failure(.invalidRequest)
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(.invalidRequest)
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .failure(.invalidRequest)
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        guard method == "POST" else {
            return .failure(.unsupportedMethod)
        }
        guard path == "/pair" else {
            return .failure(.notFound)
        }

        var contentLength: Int?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length = contentLength, length >= 0 else {
            return .failure(.invalidRequest)
        }
        guard length <= TVPairingConstants.maxBodyBytes else {
            return .failure(.bodyTooLarge)
        }

        let bodyStart = headerRange.upperBound
        let available = buffer.count - bodyStart
        guard available >= length else {
            return .failure(.incomplete)
        }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .success(ParsedHTTPRequest(method: method, path: path, body: body))
    }

    static func makeHTTPResponse(statusCode: Int, statusText: String, jsonBody: String) -> Data {
        let bodyData = Data(jsonBody.utf8)
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        return response
    }

    static func makePairURLRequest(host: String, port: UInt16, envelope: TVPairingEnvelope) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/pair"
        guard let url = components.url else {
            throw TVPairingWireError.invalidRequest
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(envelope)
        return request
    }
}
