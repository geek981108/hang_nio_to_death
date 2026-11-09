import CryptoSwift
import Foundation

struct InfoRequest: Codable, Equatable, Sendable {
    var url: URL?
    var headers: [String: String]?

    func replacingStationID(_ stationID: String) throws -> InfoRequest {
        guard let url else { throw SwapStationError.missingConfiguration }
        return InfoRequest(
            url: try NIOSwapRequestSigner.replacingStationID(in: url, with: stationID),
            headers: headers
        )
    }

    func fetchSwapStation() async throws -> SwapStationSnapshot {
        do {
            return try await fetchSwapStationOnce()
        } catch let error as SwapStationError {
            guard case .invalidPayload(_) = error else { throw error }
            // A 200 response may briefly contain incomplete station data while
            // the upstream refreshes. Retry this read-only GET once, never the
            // authorization, HTTP, or decryption failures.
            try await Task.sleep(for: .seconds(1))
            return try await fetchSwapStationOnce()
        }
    }

    private func fetchSwapStationOnce() async throws -> SwapStationSnapshot {
        guard let url else { throw SwapStationError.missingConfiguration }
        guard url.scheme?.lowercased() == "https" else { throw SwapStationError.insecureURL }

        let requestHeaders = headers ?? [:]
        let requestURL = try NIOSwapRequestSigner.signedURLIfSupported(
            url,
            headers: requestHeaders
        )

        var request = URLRequest(url: requestURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SwapStationError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw SwapStationError.httpStatus(httpResponse.statusCode)
        }

        let envelope: EncryptedEnvelope
        do {
            envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: data)
        } catch {
            throw SwapStationError.invalidEnvelope
        }

        let decrypted = try decrypt(ciphertextBase64: envelope.data)
        return try SwapStationPayloadParser.parse(decrypted)
    }

    private func decrypt(ciphertextBase64: String) throws -> Data {
        // These are protocol constants used by the upstream response format, not user credentials.
        let keyHex = "6b6331245b34315f6670717865673730"
        let ivHex = "6733514e647469357143456f4656436a"
        guard let key = keyHex.byteArray,
              let iv = ivHex.byteArray,
              let encryptedData = Data(base64Encoded: ciphertextBase64) else {
            throw SwapStationError.invalidCiphertext
        }

        do {
            let aes = try AES(key: key, blockMode: CBC(iv: iv), padding: .pkcs7)
            return Data(try aes.decrypt(encryptedData.bytes))
        } catch {
            throw SwapStationError.decryptionFailed
        }
    }
}

enum NIOSwapRequestSigner {
    private static let supportedHost = "app.nio.com"
    private static let supportedPathPrefix = "/nio/app/bff/map/resources/v1/swap/"
    private static let signingSalt = "2bc9b00fdcf8f7ded6d77afdd7077e79"

    static func stationID(from url: URL?) -> String? {
        guard let url,
              url.host?.lowercased() == supportedHost,
              url.path.hasPrefix(supportedPathPrefix) else { return nil }
        let suffix = url.path.dropFirst(supportedPathPrefix.count)
        guard let stationID = suffix.split(separator: "/").first.map(String.init),
              isValidStationID(stationID) else { return nil }
        return stationID
    }

    static func replacingStationID(in url: URL, with stationID: String) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == supportedHost,
              url.path.hasPrefix(supportedPathPrefix),
              isValidStationID(stationID),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NIOSigningError.invalidStationID
        }
        components.path = supportedPathPrefix + stationID
        guard let result = components.url else { throw NIOSigningError.invalidURL }
        return result
    }

    private static func isValidStationID(_ value: String) -> Bool {
        value.hasPrefix("PS-NIO-")
            && value.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    /// Refreshes `timestamp` and `sign` for the verified NIO BFF swap endpoint.
    /// Other endpoints are returned unchanged so an unverified rule is never applied accidentally.
    static func signedURLIfSupported(
        _ url: URL,
        headers: [String: String],
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) throws -> URL {
        guard url.host?.lowercased() == supportedHost,
              url.path.hasPrefix(supportedPathPrefix) else {
            return url
        }

        guard url.scheme?.lowercased() == "https" else {
            throw NIOSigningError.invalidURL
        }
        guard let authorization = headers.first(where: {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
        })?.value else {
            throw NIOSigningError.missingAuthorization
        }

        let parts = authorization.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame,
              !parts[1].isEmpty else {
            throw NIOSigningError.invalidAuthorization
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NIOSigningError.invalidURL
        }

        var unsignedItems = (components.queryItems ?? []).filter {
            $0.name.caseInsensitiveCompare("sign") != .orderedSame &&
            $0.name.caseInsensitiveCompare("timestamp") != .orderedSame
        }
        unsignedItems.append(URLQueryItem(name: "timestamp", value: String(timestamp)))

        guard unsignedItems.allSatisfy({ item in
            !item.name.contains("&") && !item.name.contains("=") &&
            !(item.value ?? "").contains("&")
        }) else {
            throw NIOSigningError.invalidQuery
        }

        let canonicalQuery = unsignedItems.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.name == rhs.element.name { return lhs.offset < rhs.offset }
                return lhs.element.name < rhs.element.name
            }
            .map { "\($0.element.name)=\($0.element.value ?? "")" }
            .joined(separator: "&")

        let normalizedAuthorization = "Bearer \(parts[1])"
        let signText = "GET\(url.path)?\(canonicalQuery)\(signingSalt)\(normalizedAuthorization)"
        let sign = signText.md5()

        components.queryItems = unsignedItems + [URLQueryItem(name: "sign", value: sign)]
        guard let signedURL = components.url else { throw NIOSigningError.invalidURL }
        return signedURL
    }
}

enum NIOSigningError: LocalizedError, Equatable {
    case missingAuthorization
    case invalidAuthorization
    case invalidURL
    case invalidQuery
    case invalidStationID

    var errorDescription: String? {
        switch self {
        case .missingAuthorization: return "该换电站请求缺少 Authorization，无法自动更新签名。"
        case .invalidAuthorization: return "Authorization 不是有效的 Bearer Token。"
        case .invalidURL: return "换电站请求地址无法用于自动签名。"
        case .invalidQuery: return "换电站请求参数包含无法签名的字符。"
        case .invalidStationID: return "后端返回的换电站 ID 无法用于当前请求模板。"
        }
    }
}

enum SwapStationError: LocalizedError, Equatable {
    case missingConfiguration
    case insecureURL
    case invalidResponse
    case httpStatus(Int)
    case invalidEnvelope
    case invalidCiphertext
    case decryptionFailed
    case invalidPayload(field: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "请先添加并选择一个换电站请求。"
        case .insecureURL: return "仅支持安全的 HTTPS 请求。"
        case .invalidResponse: return "服务器返回了无法识别的响应。"
        case .httpStatus(let status): return "服务器请求失败（HTTP \(status)）。"
        case .invalidEnvelope: return "接口响应格式已发生变化。"
        case .invalidCiphertext: return "接口返回的数据不完整。"
        case .decryptionFailed: return "换电站数据解密失败。"
        case .invalidPayload(let field): return "换电站数据格式无法解析（字段：\(field)）。"
        }
    }
}

struct CurlCommandParser {
    enum ParseError: LocalizedError, Equatable {
        case missingCurl
        case missingURL
        case insecureURL

        var errorDescription: String? {
            switch self {
            case .missingCurl: return "内容不是有效的 cURL 命令。"
            case .missingURL: return "未找到请求 URL。"
            case .insecureURL: return "仅支持 HTTPS 地址。"
            }
        }
    }

    static func parse(_ command: String) throws -> InfoRequest {
        let normalized = command.replacingOccurrences(of: "\\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix("curl ") else { throw ParseError.missingCurl }

        let urlPattern = #"https?://[^\s'\"]+"#
        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range, in: normalized),
              let url = URL(string: String(normalized[range])) else {
            throw ParseError.missingURL
        }
        guard url.scheme?.lowercased() == "https" else { throw ParseError.insecureURL }

        let headerPattern = #"(?:-H|--header)\s+(?:'([^']*)'|\"([^\"]*)\"|([^\s]+))"#
        var headers: [String: String] = [:]
        if let headerRegex = try? NSRegularExpression(pattern: headerPattern, options: .caseInsensitive) {
            for match in headerRegex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
                let value = (1...3).compactMap { index -> String? in
                    guard match.range(at: index).location != NSNotFound,
                          let range = Range(match.range(at: index), in: normalized) else { return nil }
                    return String(normalized[range])
                }.first
                guard let value, let separator = value.firstIndex(of: ":") else { continue }
                let name = value[..<separator].trimmingCharacters(in: .whitespaces)
                let headerValue = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                headers[name] = headerValue
            }
        }

        return InfoRequest(url: url, headers: headers)
    }
}

enum SwapStationPayloadParser {
    static func parse(_ data: Data) throws -> SwapStationSnapshot {
        let payload: SwapStationPayload
        do {
            payload = try JSONDecoder().decode(SwapStationPayload.self, from: data)
        } catch let error as DecodingError {
            throw SwapStationError.invalidPayload(field: safeFieldName(from: error))
        } catch {
            throw SwapStationError.invalidPayload(field: "根节点")
        }

        let groupedBatteries = payload.battery.batteryCapLevelSortList?.flatMap(\.batteryList) ?? []
        let rawBatteries = groupedBatteries.isEmpty
            ? (payload.battery.batteryList ?? [])
            : groupedBatteries

        let batteries = rawBatteries.map { raw -> BatteryModel in
            let batteryID = raw.batteryID ?? ""
            let description = raw.lowerCaseDescription?
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "") ?? ""
            let type: String
            if description.contains("75") {
                type = batteryID.hasPrefix("P007") ? "70 kWh" : "75 kWh"
            } else {
                type = description
            }

            return BatteryModel(
                id: batteryID.isEmpty ? "slot-\(raw.slotID.value)" : batteryID,
                chargingProgress: min(max(raw.progress.value, 0), 100),
                batteryType: type,
                chargingRemainingMinutes: raw.chargingTimeDescription.value > 0 ? raw.chargingTimeDescription.value : nil,
                isOccupied: raw.batteryOccupied.value,
                manufactureDate: manufactureDate(from: batteryID),
                slotID: raw.slotID.value
            )
        }

        let fees = payload.feeInfo?.currentFee.map {
            FeeItem(type: $0.type, name: $0.name.value, fee: $0.fee.value, unit: $0.unit.value, currency: $0.currency.value)
        } ?? []
        let periods = payload.feeInfo?.detail.compactMap { period -> FeePeriod? in
            let items = period.fee.map {
                FeeItem(type: $0.type, name: $0.name.value, fee: $0.fee.value, unit: $0.unit.value, currency: $0.currency.value)
            }
            guard !period.timePeriod.value.isEmpty, !items.isEmpty else { return nil }
            return FeePeriod(timePeriod: period.timePeriod.value, fees: items)
        } ?? []
        let notices = payload.feeInfo?.specialDescriptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        return SwapStationSnapshot(
            batteries: batteries.sorted { $0.slotID < $1.slotID },
            feeInfo: fees.isEmpty && periods.isEmpty ? nil : FeeInfo(currentFees: fees, periods: periods, notices: notices)
        )
    }

    private static func manufactureDate(from batteryID: String) -> String? {
        guard batteryID.count >= 15 else { return nil }
        let start = batteryID.index(batteryID.startIndex, offsetBy: 10)
        let end = batteryID.index(start, offsetBy: 5)
        let raw = String(batteryID[start..<end])
        guard raw.count == 5 else { return nil }
        return "20\(raw.suffix(2))-\(raw.prefix(3))"
    }

    private static func safeFieldName(from error: DecodingError) -> String {
        let path: [CodingKey]
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            path = context.codingPath
        @unknown default: return "根节点"
        }
        // Coding keys are part of our schema, not decrypted response values.
        let field = path.map(\.stringValue).joined(separator: ".")
        return field.isEmpty ? "根节点" : field
    }
}

private struct EncryptedEnvelope: Decodable {
    let data: String
}

private struct SwapStationPayload: Decodable {
    let battery: BatteryPayload
    let feeInfo: FeePayload?

    enum CodingKeys: String, CodingKey {
        case battery
        case feeInfo = "fee_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decode(BatteryPayload.self, forKey: .battery)
        // Fee metadata is supplemental. A malformed or temporarily absent fee
        // section must not discard otherwise valid live battery inventory.
        feeInfo = try? container.decode(FeePayload.self, forKey: .feeInfo)
    }
}

private struct BatteryPayload: Decodable {
    let batteryCapLevelSortList: [BatteryGroup]?
    let batteryList: [BatteryDTO]?

    enum CodingKeys: String, CodingKey {
        case batteryCapLevelSortList = "battery_cap_level_sort_list"
        case batteryList = "battery_list"
    }
}

private struct BatteryGroup: Decodable {
    let batteryList: [BatteryDTO]

    enum CodingKeys: String, CodingKey { case batteryList = "battery_list" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batteryList = (try? container.decode([BatteryDTO].self, forKey: .batteryList)) ?? []
    }
}

private struct BatteryDTO: Decodable {
    let batteryID: String?
    let progress: FlexibleDouble
    let lowerCaseDescription: String?
    let chargingTimeDescription: FlexibleInt
    let batteryOccupied: FlexibleBool
    let slotID: FlexibleInt

    enum CodingKeys: String, CodingKey {
        case batteryID = "battery_id"
        case progress
        case lowerCaseDescription = "lower_case_desc"
        case chargingTimeDescription = "charging_time_desc"
        case batteryOccupied = "battery_occupied"
        case slotID = "slot_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batteryID = try? container.decode(String.self, forKey: .batteryID)
        progress = (try? container.decode(FlexibleDouble.self, forKey: .progress)) ?? .zero
        lowerCaseDescription = try? container.decode(String.self, forKey: .lowerCaseDescription)
        chargingTimeDescription = (try? container.decode(FlexibleInt.self, forKey: .chargingTimeDescription)) ?? .zero
        batteryOccupied = (try? container.decode(FlexibleBool.self, forKey: .batteryOccupied)) ?? .falseValue
        slotID = (try? container.decode(FlexibleInt.self, forKey: .slotID)) ?? .zero
    }
}

private struct FeePayload: Decodable {
    let currentFee: [FeeDTO]
    let detail: [FeePeriodDTO]
    let specialDescriptions: [String]

    enum CodingKeys: String, CodingKey {
        case currentFee = "current_fee"
        case detail
        case specialDescriptions = "fee_special_desc_array"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentFee = (try? container.decode([FeeDTO].self, forKey: .currentFee)) ?? []
        detail = (try? container.decode([FeePeriodDTO].self, forKey: .detail)) ?? []
        specialDescriptions = (try? container.decode([String].self, forKey: .specialDescriptions)) ?? []
    }
}

private struct FeePeriodDTO: Decodable {
    let timePeriod: FlexibleString
    let fee: [FeeDTO]

    enum CodingKeys: String, CodingKey {
        case timePeriod = "time_period"
        case fee
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timePeriod = (try? container.decode(FlexibleString.self, forKey: .timePeriod)) ?? .empty
        fee = (try? container.decode([FeeDTO].self, forKey: .fee)) ?? []
    }
}

private struct FeeDTO: Decodable {
    let type: String?
    let name: FlexibleString
    let fee: FlexibleString
    let unit: FlexibleString
    let currency: FlexibleString

    enum CodingKeys: String, CodingKey { case type, name, fee, unit, currency }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        name = (try? container.decode(FlexibleString.self, forKey: .name)) ?? .empty
        fee = (try? container.decode(FlexibleString.self, forKey: .fee)) ?? .empty
        unit = (try? container.decode(FlexibleString.self, forKey: .unit)) ?? .empty
        currency = (try? container.decode(FlexibleString.self, forKey: .currency)) ?? .empty
    }
}

private struct FlexibleDouble: Decodable {
    static let zero = FlexibleDouble(value: 0)
    let value: Double

    init(value: Double) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self.value = value; return }
        if let value = try? container.decode(String.self), let number = Double(value) { self.value = number; return }
        self.value = 0
    }
}

private struct FlexibleInt: Decodable {
    static let zero = FlexibleInt(value: 0)
    let value: Int

    init(value: Int) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self.value = value; return }
        if let value = try? container.decode(Double.self) { self.value = Int(value); return }
        if let value = try? container.decode(String.self) {
            self.value = Int(value.filter { $0.isNumber || $0 == "-" }) ?? 0
            return
        }
        self.value = 0
    }
}

private struct FlexibleBool: Decodable {
    static let falseValue = FlexibleBool(value: false)
    let value: Bool

    init(value: Bool) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self.value = value; return }
        if let value = try? container.decode(Int.self) { self.value = value != 0; return }
        if let value = try? container.decode(String.self) { self.value = ["true", "1", "yes"].contains(value.lowercased()); return }
        self.value = false
    }
}

private struct FlexibleString: Decodable {
    static let empty = FlexibleString(value: "")
    let value: String

    init(value: String) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value; return }
        if let value = try? container.decode(Double.self) { self.value = String(value); return }
        if let value = try? container.decode(Int.self) { self.value = String(value); return }
        self.value = ""
    }
}

extension String {
    fileprivate var byteArray: [UInt8]? {
        guard count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var cursor = startIndex
        while cursor < endIndex {
            let next = index(cursor, offsetBy: 2)
            guard let byte = UInt8(self[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        return bytes
    }
}
