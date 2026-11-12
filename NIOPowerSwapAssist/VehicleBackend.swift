import Foundation

struct BackendConfiguration: Equatable, Sendable {
    let baseURL: URL
    let apiKey: String

    init(baseURLString: String, apiKey: String) throws {
        let rawURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw BackendClientError.invalidBaseURL
        }

        guard scheme == "http" || scheme == "https" else {
            throw BackendClientError.invalidBaseURL
        }
        guard trimmedKey.count >= 32, trimmedKey.count <= 512 else {
            throw BackendClientError.invalidAPIKey
        }

        self.baseURL = url
        self.apiKey = trimmedKey
    }
}

struct VehicleDashboard: Codable, Equatable, Sendable {
    let vehicleID: String
    let isConnected: Bool
    let stateCode: Int?
    let mileage: Double?
    let isSwapping: Bool
    let stateOfCharge: Double?
    let remainingRange: Double?
    let remainingActualRange: Double?
    let chargeStateCode: Int?
    let chargingCurrent: Double?
    let chargingPower: Double?
    let chargingVoltage: Double?
    let chargeLimitPercent: Double?
    let batterySampledAt: Date?
    let lockStatusCode: Int?
    let location: VehicleCoordinate?
    let locationSampledAt: Date?
    let insideTemperature: Double?
    let outsideTemperature: Double?
    let updatedAt: Date
}

struct VehicleProfile: Decodable, Equatable, Sendable {
    let vehicleID: String
    let displayName: String?
    let modelType: String?
    let color: String?
    let imageURL: String?
    let imageAvailable: Bool
    let imageSHA256: String?
    let imageFetchedAt: String?

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case displayName = "display_name"
        case modelType = "model_type"
        case color
        case imageURL = "image_url"
        case imageAvailable = "image_available"
        case imageSHA256 = "image_sha256"
        case imageFetchedAt = "image_fetched_at"
    }

    var localizedColorName: String? {
        guard let color = color?.trimmingCharacters(in: .whitespacesAndNewlines),
              !color.isEmpty else { return nil }
        switch color.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "tech_grey", "tech_gray", "star_grey", "star_gray":
            return "星灰"
        case "white", "cloud_white":
            return "云白"
        case "black", "deep_black":
            return "深空黑"
        case "blue":
            return "蓝色"
        case "red":
            return "红色"
        case "silver":
            return "银色"
        case "grey", "gray":
            return "灰色"
        default:
            return color
        }
    }

    var displayTitle: String {
        if let name = trimmed(displayName) { return name }
        if let model = trimmed(modelType) { return "NIO \(model)" }
        return "我的蔚来"
    }

    /// Bundled artwork only exists for models shipped with the app; every other
    /// model falls back to the neutral placeholder instead of a wrong car.
    var bundledArtworkAssetName: String? {
        guard let model = trimmed(modelType) else { return nil }
        return Self.bundledArtworkAssets[model.uppercased()]
    }

    private static let bundledArtworkAssets = ["ET5T": "ET5TTouringSide"]

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum VehicleImageFetchResult: Sendable {
    case unavailable
    case notModified
    case downloaded(data: Data, etag: String?)
}

struct VehiclePresentation: Sendable {
    let profile: VehicleProfile
    let image: VehicleImageFetchResult
}

struct VehicleCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
            && !(abs(latitude) < 0.01 && abs(longitude) < 0.01)
    }
}

struct NIOVehicleStatusResponse: Decodable, Sendable {
    let resultCode: String
    let serverTime: Int64?
    let data: Payload

    enum CodingKeys: String, CodingKey {
        case resultCode = "result_code"
        case serverTime = "server_time"
        case data
    }

    struct Payload: Decodable, Sendable {
        let vehicleID: String
        let connectionStatus: ConnectionStatus?
        let exteriorStatus: ExteriorStatus?
        let specialStatus: SpecialStatus?
        let positionStatus: PositionStatus?
        let socStatus: NIOWidgetInfoResponse.SOCStatus?
        let hvacStatus: HVACStatus?

        enum CodingKeys: String, CodingKey {
            case vehicleID = "vehicle_id"
            case connectionStatus = "connection_status"
            case exteriorStatus = "exterior_status"
            case specialStatus = "special_status"
            case positionStatus = "position_status"
            case socStatus = "soc_status"
            case hvacStatus = "hvac_status"
        }
    }

    struct ConnectionStatus: Decodable, Sendable {
        let connected: Bool?
    }

    struct ExteriorStatus: Decodable, Sendable {
        let mileage: Double?
        let vehicleState: Int?

        enum CodingKeys: String, CodingKey {
            case mileage
            case vehicleState = "vehicle_state"
        }
    }

    struct SpecialStatus: Decodable, Sendable {
        let swapping: Int?
    }

    struct PositionStatus: Decodable, Sendable {
        let latitude: Double?
        let longitude: Double?
        let sampleTime: Int64?

        enum CodingKeys: String, CodingKey {
            case latitude, longitude
            case sampleTime = "sample_time"
        }
    }

    struct HVACStatus: Decodable, Sendable {
        let temperature: Double?
        let outsideTemperature: Double?

        enum CodingKeys: String, CodingKey {
            case temperature
            case outsideTemperature = "outside_temperature"
        }
    }
}

struct NIOWidgetInfoResponse: Decodable, Sendable {
    let resultCode: String
    let serverTime: Int64?
    let data: Payload

    enum CodingKeys: String, CodingKey {
        case resultCode = "result_code"
        case serverTime = "server_time"
        case data
    }

    struct Payload: Decodable, Sendable {
        let status: Status
    }

    struct Status: Decodable, Sendable {
        let vehicleID: String
        let connectionStatus: NIOVehicleStatusResponse.ConnectionStatus?
        let exteriorStatus: NIOVehicleStatusResponse.ExteriorStatus?
        let specialStatus: NIOVehicleStatusResponse.SpecialStatus?
        let socStatus: SOCStatus?
        let doorStatus: DoorStatus?

        enum CodingKeys: String, CodingKey {
            case vehicleID = "vehicle_id"
            case connectionStatus = "connection_status"
            case exteriorStatus = "exterior_status"
            case specialStatus = "special_status"
            case socStatus = "soc_status"
            case doorStatus = "door_status"
        }
    }

    struct SOCStatus: Decodable, Sendable {
        let soc: Double?
        let remainingRange: Double?
        let remainingActualRange: Double?
        let chargeState: Int?
        let chargingCurrent: Double?
        let chargingPower: Double?
        let chargingVoltage: Double?
        let maxSOC: Double?
        let maxSOCEnabled: Bool?
        let sampleTime: Int64?

        enum CodingKeys: String, CodingKey {
            case soc
            case remainingRange = "remaining_range"
            case remainingActualRange = "remaining_actual_range"
            case chargeState = "charge_state"
            case chargingCurrent = "charging_current"
            case chargingPower = "charging_power"
            case chargingVoltage = "charging_voltage"
            case maxSOC = "max_soc"
            case maxSOCEnabled = "max_soc_enable_on_vehl"
            case sampleTime = "sample_time"
        }
    }

    struct DoorStatus: Decodable, Sendable {
        let vehicleLockStatus: Int?

        enum CodingKeys: String, CodingKey {
            case vehicleLockStatus = "vehicle_lock_status"
        }
    }
}

struct NIOStationSearchResult: Decodable, Sendable {
    let stations: [Station]

    struct Station: Decodable, Equatable, Sendable, Identifiable {
        let stationID: String
        let name: String
        let address: String?

        var id: String { stationID }

        enum CodingKeys: String, CodingKey {
            case stationID = "station_id"
            case name, address
        }
    }
}

struct NIOStationLiveStatus: Decodable, Sendable {
    let stationID: String
    let stationName: String
    let available75Count: Int
    let available75Batteries: [Battery]

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case stationName = "station_name"
        case available75Count = "available_75_count"
        case available75Batteries = "available_75_batteries"
    }

    struct Battery: Decodable, Equatable, Sendable {
        let batteryID: String
        let slotID: Int?
        let stateOfCharge: Double?
        let productionDate: String?

        enum CodingKeys: String, CodingKey {
            case batteryID = "battery_id"
            case slotID = "slot_id"
            case stateOfCharge = "soc_percent"
            case productionDate = "production_date"
        }
    }
}

enum BackendClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidAPIKey
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case serverFailure(code: String, message: String, status: Int)
    case upstreamFailure(String)
    case vehicleMismatch
    case decodingFailed
    case invalidControlKey
    case configurationChanged
    case vehicleControlUnauthorized
    case vehicleControlDisabled
    case vehicleControlUnsafe(String)
    case vehiclePINUnavailable
    case vehicleControlFailed(String)
    case swapOrderUnauthorized
    case swapOrderFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "后端地址无效。"
        case .invalidAPIKey: return "后端 API Key 长度无效。"
        case .invalidResponse: return "后端返回了无法识别的响应。"
        case .unauthorized: return "后端 API Key 不正确。"
        case .httpStatus(let status): return "后端请求失败（HTTP \(status)）。"
        case .serverFailure(let code, let message, let status):
            switch code {
            case "vehicle_not_configured": return "服务端尚未配置车辆信息。"
            case "station_template_not_configured": return "服务端尚未配置换电站查询模板。"
            case "station_not_configured": return "服务端尚未配置换电站轮询。"
            case "database_error": return "后端数据库暂时不可用，请稍后重试。"
            default: return "\(message)（HTTP \(status) · \(code)）"
            }
        case .upstreamFailure(let code): return "NIO 上游返回失败状态：\(code)。"
        case .vehicleMismatch: return "车辆状态接口返回了不一致的车辆标识。"
        case .decodingFailed: return "车辆状态响应格式已发生变化。"
        case .invalidControlKey: return "车控 Key 至少需要 32 个字符。"
        case .configurationChanged: return "后端配置已更改，请重新加载。"
        case .vehicleControlUnauthorized: return "后端 API Key 或车控 Key 不正确。"
        case .vehicleControlDisabled: return "服务端未启用车控。仅在 App 中保存车控 Key 不会启用服务端；请检查服务端车控配置。"
        case .vehicleControlUnsafe(let message): return "车辆当前状态不允许执行此指令：\(message)"
        case .vehiclePINUnavailable: return "服务端尚未配置可用的车辆 PIN，指令没有执行。"
        case .vehicleControlFailed(let message): return message
        case .swapOrderUnauthorized: return "车控 Key 不正确，无法创建换电订单。"
        case .swapOrderFailed(let message): return message
        }
    }
}

struct CreateSwapOrderInput: Encodable, Sendable {
    let stationID: String
    let confirmation = "CREATE SWAP ORDER"

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case confirmation
    }
}

struct CreateSwapOrderOutcome: Decodable, Equatable, Sendable {
    let stationID: String
    let latitude: Double
    let longitude: Double
    let scanRequestID: String?
    let requestID: String?
    let serverTime: Int64?
    let orderID: String
    let requestedBatteryCapLevel: UInt8
    let batteryCapLevel: UInt8?
    let targetBatteryCapLevel: UInt8?
    let powerSwapResourceModel: String?

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case latitude, longitude
        case scanRequestID = "scan_request_id"
        case requestID = "request_id"
        case serverTime = "server_time"
        case orderID = "order_id"
        case requestedBatteryCapLevel = "requested_battery_cap_level"
        case batteryCapLevel = "battery_cap_level"
        case targetBatteryCapLevel = "target_battery_cap_level"
        case powerSwapResourceModel = "ps_resource_model"
    }
}

enum VehicleAction: String, Codable, CaseIterable, Sendable {
    case unlockDoors = "unlock-doors"
    case unlockStart = "unlock-start"
    case lock
    case guardOn = "guard-on"
    case guardOff = "guard-off"
    case find
    case findStop = "find-stop"
    case acOn = "ac-on"
    case acOff = "ac-off"

    var confirmation: String {
        switch self {
        case .unlockDoors: return "UNLOCK DOORS"
        case .unlockStart: return "UNLOCK AND START"
        case .lock: return "LOCK VEHICLE"
        case .guardOn: return "ENABLE GUARD MODE"
        case .guardOff: return "DISABLE GUARD MODE"
        case .find: return "FIND VEHICLE"
        case .findStop: return "STOP FINDING"
        case .acOn: return "START AC"
        case .acOff: return "STOP AC"
        }
    }

    var title: String {
        switch self {
        case .unlockDoors: return "仅解锁车门"
        case .unlockStart: return "解锁并启动"
        case .lock: return "锁定车辆"
        case .guardOn: return "开启守卫模式"
        case .guardOff: return "关闭守卫模式"
        case .find: return "开始寻车"
        case .findStop: return "停止寻车"
        case .acOn: return "开启空调"
        case .acOff: return "关闭空调"
        }
    }

    var isHighRisk: Bool { self == .unlockDoors || self == .unlockStart }
}

struct VehicleActionInput: Encodable, Sendable {
    let action: VehicleAction
    let confirmation: String
    let temperature: Double?
    let recirculation: UInt8?
    let expandMirrors: Bool
    let mirrorConfirmation: String?

    enum CodingKeys: String, CodingKey {
        case action, confirmation, temperature, recirculation
        case expandMirrors = "expand_mirrors"
        case mirrorConfirmation = "mirror_confirmation"
    }

    init(action: VehicleAction, temperature: Double? = nil, expandMirrors: Bool = false) {
        self.action = action
        confirmation = action.confirmation
        self.temperature = action == .acOn ? temperature : nil
        recirculation = nil
        self.expandMirrors = action == .guardOn && expandMirrors
        mirrorConfirmation = self.expandMirrors ? "EXPAND MIRRORS" : nil
    }
}

struct VehicleActionOutcome: Decodable, Equatable, Sendable {
    let action: VehicleAction
    let status: String
    let verified: Bool
    let mirrors: String?
}

struct EnergyStats: Decodable, Equatable, Sendable {
    let from: Date
    let to: Date
    let swapCount: Int
    let swapElectricityFeeCNYKnown: Double
    let swapServiceFeeCNYKnown: Double
    let swapTotalFeeCNYKnown: Double
    let couponDiscountCNYKnown: Double
    let actualPaidCNYKnown: Double
    let feeBreakdownCoveredCount: Int
    let paidAmountCoveredCount: Int
    let swapEnergyKWhKnown: Double
    let swapEnergyCoveredCount: Int
    let chargingEnergyKWhEstimated: Double?
    let chargingEnergyKWhFromPower: Double
    let chargingEnergyKWhFromSOC: Double
    let chargingSegmentsFromPower: Int
    let chargingSegmentsFromSOC: Int
    let chargingSegmentsUncovered: Int
    let chargingSampleCount: Int
    let totalEnergyKWhKnown: Double
    let swapEnergySharePercentOfKnown: Double?
    let chargingEnergySharePercentOfKnown: Double?
    let energyCoverageComplete: Bool
    let currentMonthSwapCount: Int
    let currentMonthTimezone: String

    enum CodingKeys: String, CodingKey {
        case from, to
        case swapCount = "swap_count"
        case swapElectricityFeeCNYKnown = "swap_electricity_fee_cny_known"
        case swapServiceFeeCNYKnown = "swap_service_fee_cny_known"
        case swapTotalFeeCNYKnown = "swap_total_fee_cny_known"
        case couponDiscountCNYKnown = "coupon_discount_cny_known"
        case actualPaidCNYKnown = "actual_paid_cny_known"
        case feeBreakdownCoveredCount = "fee_breakdown_covered_count"
        case paidAmountCoveredCount = "paid_amount_covered_count"
        case swapEnergyKWhKnown = "swap_energy_kwh_known"
        case swapEnergyCoveredCount = "swap_energy_covered_count"
        case chargingEnergyKWhEstimated = "charging_energy_kwh_estimated"
        case chargingEnergyKWhFromPower = "charging_energy_kwh_from_power"
        case chargingEnergyKWhFromSOC = "charging_energy_kwh_from_soc"
        case chargingSegmentsFromPower = "charging_segments_from_power"
        case chargingSegmentsFromSOC = "charging_segments_from_soc"
        case chargingSegmentsUncovered = "charging_segments_uncovered"
        case chargingSampleCount = "charging_sample_count"
        case totalEnergyKWhKnown = "total_energy_kwh_known"
        case swapEnergySharePercentOfKnown = "swap_energy_share_percent_of_known"
        case chargingEnergySharePercentOfKnown = "charging_energy_share_percent_of_known"
        case energyCoverageComplete = "energy_coverage_complete"
        case currentMonthSwapCount = "current_month_swap_count"
        case currentMonthTimezone = "current_month_timezone"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ key: CodingKeys) throws -> Date {
            let raw = try values.decode(String.self, forKey: key)
            if let value = formatter.date(from: raw) { return value }
            let fallback = ISO8601DateFormatter()
            guard let value = fallback.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: values,
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return value
        }
        from = try date(.from)
        to = try date(.to)
        swapCount = try values.decode(Int.self, forKey: .swapCount)
        swapElectricityFeeCNYKnown = try values.decode(Double.self, forKey: .swapElectricityFeeCNYKnown)
        swapServiceFeeCNYKnown = try values.decode(Double.self, forKey: .swapServiceFeeCNYKnown)
        swapTotalFeeCNYKnown = try values.decode(Double.self, forKey: .swapTotalFeeCNYKnown)
        couponDiscountCNYKnown = try values.decode(Double.self, forKey: .couponDiscountCNYKnown)
        actualPaidCNYKnown = try values.decode(Double.self, forKey: .actualPaidCNYKnown)
        feeBreakdownCoveredCount = try values.decode(Int.self, forKey: .feeBreakdownCoveredCount)
        paidAmountCoveredCount = try values.decode(Int.self, forKey: .paidAmountCoveredCount)
        swapEnergyKWhKnown = try values.decode(Double.self, forKey: .swapEnergyKWhKnown)
        swapEnergyCoveredCount = try values.decode(Int.self, forKey: .swapEnergyCoveredCount)
        chargingEnergyKWhEstimated = try values.decodeIfPresent(Double.self, forKey: .chargingEnergyKWhEstimated)
        chargingEnergyKWhFromPower = try values.decode(Double.self, forKey: .chargingEnergyKWhFromPower)
        chargingEnergyKWhFromSOC = try values.decode(Double.self, forKey: .chargingEnergyKWhFromSOC)
        chargingSegmentsFromPower = try values.decode(Int.self, forKey: .chargingSegmentsFromPower)
        chargingSegmentsFromSOC = try values.decode(Int.self, forKey: .chargingSegmentsFromSOC)
        chargingSegmentsUncovered = try values.decode(Int.self, forKey: .chargingSegmentsUncovered)
        chargingSampleCount = try values.decode(Int.self, forKey: .chargingSampleCount)
        totalEnergyKWhKnown = try values.decode(Double.self, forKey: .totalEnergyKWhKnown)
        swapEnergySharePercentOfKnown = try values.decodeIfPresent(Double.self, forKey: .swapEnergySharePercentOfKnown)
        chargingEnergySharePercentOfKnown = try values.decodeIfPresent(Double.self, forKey: .chargingEnergySharePercentOfKnown)
        energyCoverageComplete = try values.decode(Bool.self, forKey: .energyCoverageComplete)
        currentMonthSwapCount = try values.decode(Int.self, forKey: .currentMonthSwapCount)
        currentMonthTimezone = try values.decode(String.self, forKey: .currentMonthTimezone)
    }
}

indirect enum JSONValue: Decodable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON value") }
    }

    var displayString: String? {
        switch self {
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "是" : "否"
        case .object, .array, .null: return nil
        }
    }
}

struct AvailableCoupon: Decodable, Equatable, Sendable {
    let fields: [String: JSONValue]

    var quantity: Int?
    var faceValueCNY: Int?

    init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    var title: String {
        firstValue(for: ["coupon_name", "couponName", "display_name", "displayName", "title", "name"])
            ?? "可用卡券"
    }

    var subtitle: String? {
        firstValue(for: ["sub_title", "subtitle", "coupon_desc", "description", "use_scope", "remark"])
    }

    var validityText: String? {
        firstValue(for: ["valid_time_desc", "validity", "expire_time_desc", "expire_desc", "expire_time", "expired_at", "end_time"])
    }

    var sourceIdentifier: String? {
        firstValue(for: ["coupon_instance_id", "coupon_id", "couponId", "id", "code"])
    }

    var identifier: String { sourceIdentifier ?? "\(title)|\(validityText ?? "")" }

    private func firstValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = recursiveValue(for: key, in: .object(fields)), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func recursiveValue(for key: String, in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            if let direct = object[key]?.displayString { return direct }
            for nested in object.values {
                if let result = recursiveValue(for: key, in: nested) { return result }
            }
        case .array(let values):
            for nested in values {
                if let result = recursiveValue(for: key, in: nested) { return result }
            }
        case .string, .number, .bool, .null:
            break
        }
        return nil
    }
}

struct AvailableCouponsPage: Decodable, Equatable, Sendable {
    let amount: Int
    let coupons: [AvailableCoupon]
    let hasMore: Bool
    let limit: Int
    let offset: Int
    let pageCouponCount: Int?
    let totalCouponCount: Int?

    private struct Group: Decodable {
        let count: Int?
        let face_value_cny: Int?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decode(Int.self, forKey: .amount)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        limit = try container.decode(Int.self, forKey: .limit)
        offset = try container.decode(Int.self, forKey: .offset)
        pageCouponCount = try container.decodeIfPresent(Int.self, forKey: .pageCouponCount)
        totalCouponCount = try container.decodeIfPresent(Int.self, forKey: .totalCouponCount)
        var items = try container.decode([AvailableCoupon].self, forKey: .coupons)
        let groups = try container.decodeIfPresent([Group].self, forKey: .couponGroups) ?? []
        for index in items.indices where index < groups.count {
            items[index].quantity = groups[index].count
            items[index].faceValueCNY = groups[index].face_value_cny
        }
        coupons = items
    }

    enum CodingKeys: String, CodingKey {
        case amount, coupons, limit, offset
        case hasMore = "has_more"
        case couponGroups = "coupon_groups"
        case pageCouponCount = "page_coupon_count"
        case totalCouponCount = "total_coupon_count"
    }
}

private struct BackendErrorEnvelope: Decodable {
    let error: String
    let message: String
}

struct BackendClient: Sendable {
    let configuration: BackendConfiguration
    let session: URLSession

    init(configuration: BackendConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session
            ?? TemporaryBackendTLS.session(allowingUntrustedHost: configuration.baseURL.host)
    }

    func fetchDashboard() async throws -> VehicleDashboard {
        async let status = fetchVehicleStatus()
        async let widget = fetchWidgetInfo()
        return try await makeDashboard(status: status, widget: widget)
    }

    func fetchVehicleProfile() async throws -> VehicleProfile {
        try await fetch(path: "api/v1/vehicle/profile")
    }

    func fetchVehiclePresentation(cachedETag: String?) async throws -> VehiclePresentation {
        let profile = try await fetchVehicleProfile()
        guard profile.imageAvailable else {
            return VehiclePresentation(profile: profile, image: .unavailable)
        }
        let request = makeVehicleImageRequest(cachedETag: cachedETag)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        if response.statusCode == 304 {
            return VehiclePresentation(profile: profile, image: .notModified)
        }
        if response.statusCode == 401 {
            throw BackendClientError.unauthorized
        }
        guard response.statusCode == 200 else {
            throw BackendClientError.httpStatus(response.statusCode)
        }
        guard response.mimeType?.hasPrefix("image/") == true, !data.isEmpty else {
            throw BackendClientError.invalidResponse
        }
        return VehiclePresentation(
            profile: profile,
            image: .downloaded(
                data: data,
                etag: response.value(forHTTPHeaderField: "ETag")
            )
        )
    }

    func makeVehicleImageRequest(cachedETag: String?) -> URLRequest {
        var request = makeRequest(path: "api/v1/vehicle/image")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let cachedETag, !cachedETag.isEmpty {
            request.setValue(cachedETag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    func fetchVehicleStatus() async throws -> NIOVehicleStatusResponse {
        try await fetch(path: "api/v1/vehicle/status")
    }

    func fetchWidgetInfo() async throws -> NIOWidgetInfoResponse {
        try await fetch(path: "api/v1/vehicle/widget-info")
    }

    func fetchVehicleHistory(limit: Int = 2000) async throws -> VehicleSnapshotPage {
        try await fetch(path: "api/v1/vehicle/history?limit=\(min(max(limit, 1), 2000))")
    }

    func fetchCurrentChargingSession() async throws -> VehicleChargingSamplePage {
        try await fetch(path: "api/v1/vehicle/charging/current")
    }

    func fetchChargingSessions(limit: Int = 50) async throws -> ChargingSessionPage {
        try await fetch(path: "api/v1/vehicle/charging/sessions?limit=\(min(max(limit, 1), 100))")
    }

    func fetchChargingSession(id: String) async throws -> VehicleChargingSamplePage {
        try await fetch(path: "api/v1/vehicle/charging/sessions/\(id)")
    }

    func fetchSwapEvents(limit: Int = 100) async throws -> SwapEventPage {
        try await fetch(path: "api/v1/swaps?limit=\(min(max(limit, 1), 200))")
    }

    func fetchActiveServiceOrders() async throws -> ActiveServiceOrderPage {
        try await fetch(path: "api/v1/orders/active")
    }

    func fetchSwapEvent(id: String) async throws -> SwapEvent {
        try await fetch(path: "api/v1/swaps/\(id)")
    }

    func fetchSwapStations(
        limit: Int = 100,
        offset: Int = 0,
        search: String? = nil
    ) async throws -> SwapStationPage {
        let normalizedLimit = min(max(limit, 1), 200)
        let normalizedOffset = max(offset, 0)
        let normalizedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedSearch = normalizedSearch
            .flatMap { $0.isEmpty ? nil : Self.percentEncodedQueryValue($0) }
            .map { "&q=\($0)" } ?? ""
        return try await fetch(
            path: "api/v1/stations?limit=\(normalizedLimit)&offset=\(normalizedOffset)\(encodedSearch)"
        )
    }

    func searchSwapStations(name: String) async throws -> [NIOStationSearchResult.Station] {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              let encodedName = Self.percentEncodedQueryValue(normalizedName) else {
            return []
        }
        let result: NIOStationSearchResult = try await fetch(
            path: "api/v1/stations/search?name=\(encodedName)"
        )
        return result.stations
    }

    func fetchSwapStation(id: String) async throws -> SwapStation {
        try await fetch(path: "api/v1/stations/\(id)")
    }

    func fetchSwapStationLive(id: String) async throws -> NIOStationLiveStatus {
        try await fetch(path: "api/v1/stations/\(id)/live")
    }

    func fetchVehicleTrips(count: Int = 20) async throws -> VehicleTripPage {
        try await fetch(path: "api/v1/vehicle/trips?count=\(min(max(count, 1), 100))")
    }

    func fetchEnergyStats(from: Date, to: Date) async throws -> EnergyStats {
        let request = try makeEnergyStatsRequest(from: from, to: to)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeEnergyStatsRequest(from: Date, to: Date) throws -> URLRequest {
        let formatter = ISO8601DateFormatter()
        let rawFrom = formatter.string(from: from)
        let rawTo = formatter.string(from: to)
        guard let encodedFrom = Self.percentEncodedQueryValue(rawFrom),
              let encodedTo = Self.percentEncodedQueryValue(rawTo) else {
            throw BackendClientError.invalidResponse
        }
        return makeRequest(path: "api/v1/energy/stats?from=\(encodedFrom)&to=\(encodedTo)")
    }

    func fetchAvailableCoupons(limit: Int = 20, offset: Int = 0) async throws -> AvailableCouponsPage {
        let request = makeAvailableCouponsRequest(limit: limit, offset: offset)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeAvailableCouponsRequest(limit: Int = 20, offset: Int = 0) -> URLRequest {
        makeRequest(
            path: "api/v1/coupons/available?limit=\(min(max(limit, 1), 100))&offset=\(max(offset, 0))"
        )
    }

    func performVehicleAction(
        _ input: VehicleActionInput,
        controlKey: String
    ) async throws -> VehicleActionOutcome {
        let request = try makeVehicleActionRequest(input: input, controlKey: controlKey)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 { throw BackendClientError.vehicleControlUnauthorized }
        guard 200..<300 ~= httpResponse.statusCode else {
            if let body = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) {
                switch body.error {
                case "vehicle_control_disabled": throw BackendClientError.vehicleControlDisabled
                case "vehicle_pin_unavailable": throw BackendClientError.vehiclePINUnavailable
                case "vehicle_state_unsafe": throw BackendClientError.vehicleControlUnsafe(body.message)
                default: throw BackendClientError.vehicleControlFailed("HTTP \(httpResponse.statusCode) · \(body.error)：\(body.message)")
                }
            }
            throw BackendClientError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(VehicleActionOutcome.self, from: data)
        } catch {
            throw BackendClientError.decodingFailed
        }
    }

    func makeVehicleActionRequest(
        input: VehicleActionInput,
        controlKey: String
    ) throws -> URLRequest {
        let trimmedKey = controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= 32, trimmedKey.count <= 512 else {
            throw BackendClientError.invalidControlKey
        }
        var request = makeRequest(path: "api/v1/vehicle/action")
        request.timeoutInterval = 90
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "X-Vehicle-Control-Key")
        request.httpBody = try JSONEncoder().encode(input)
        return request
    }

    func createSwapOrder(
        stationID: String,
        controlKey: String
    ) async throws -> CreateSwapOrderOutcome {
        let request = try makeCreateSwapOrderRequest(
            stationID: stationID,
            controlKey: controlKey
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw BackendClientError.swapOrderUnauthorized
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            if let body = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) {
                throw BackendClientError.swapOrderFailed(
                    "HTTP \(httpResponse.statusCode) · \(body.error)：\(body.message)"
                )
            }
            throw BackendClientError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(CreateSwapOrderOutcome.self, from: data)
        } catch {
            throw BackendClientError.decodingFailed
        }
    }

    func makeCreateSwapOrderRequest(
        stationID: String,
        controlKey: String
    ) throws -> URLRequest {
        let trimmedStationID = stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStationID.isEmpty else {
            throw BackendClientError.swapOrderFailed("当前换电站缺少有效 ID。")
        }
        guard (32...512).contains(trimmedKey.count) else {
            throw BackendClientError.invalidControlKey
        }
        var request = makeRequest(path: "api/v1/swap-orders")
        request.timeoutInterval = 90
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "X-Vehicle-Control-Key")
        request.httpBody = try JSONEncoder().encode(
            CreateSwapOrderInput(stationID: trimmedStationID)
        )
        return request
    }

    func makeRequest(path: String) -> URLRequest {
        let parts = path.split(separator: "?", maxSplits: 1)
        let url = parts[0].split(separator: "/").reduce(configuration.baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = parts.count == 2 ? String(parts[1]) : nil
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.url = components?.url ?? url
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch<Response: Decodable>(path: String) async throws -> Response {
        let (data, response) = try await session.data(for: makeRequest(path: path))
        return try decode(data: data, response: response)
    }

    private func decode<Response: Decodable>(data: Data, response: URLResponse) throws -> Response {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw BackendClientError.unauthorized
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            if let body = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) {
                throw BackendClientError.serverFailure(code: body.error, message: body.message, status: httpResponse.statusCode)
            }
            throw BackendClientError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BackendClientError.decodingFailed
        }
    }

    private static func percentEncodedQueryValue(_ value: String) -> String? {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    func makeDashboard(
        status: NIOVehicleStatusResponse,
        widget: NIOWidgetInfoResponse
    ) throws -> VehicleDashboard {
        guard status.resultCode == "success" else {
            throw BackendClientError.upstreamFailure(status.resultCode)
        }
        guard widget.resultCode == "success" else {
            throw BackendClientError.upstreamFailure(widget.resultCode)
        }
        guard status.data.vehicleID == widget.data.status.vehicleID else {
            throw BackendClientError.vehicleMismatch
        }

        let widgetStatus = widget.data.status
        let statusSOC = status.data.socStatus
        let position = status.data.positionStatus
        let coordinate = position.flatMap { position -> VehicleCoordinate? in
            guard let latitude = position.latitude, let longitude = position.longitude else { return nil }
            let value = VehicleCoordinate(latitude: latitude, longitude: longitude)
            return value.isValid ? value : nil
        }
        return VehicleDashboard(
            vehicleID: status.data.vehicleID,
            isConnected: status.data.connectionStatus?.connected
                ?? widgetStatus.connectionStatus?.connected
                ?? false,
            stateCode: status.data.exteriorStatus?.vehicleState
                ?? widgetStatus.exteriorStatus?.vehicleState,
            mileage: status.data.exteriorStatus?.mileage
                ?? widgetStatus.exteriorStatus?.mileage,
            isSwapping: (status.data.specialStatus?.swapping
                ?? widgetStatus.specialStatus?.swapping
                ?? 0) != 0,
            stateOfCharge: statusSOC?.soc ?? widgetStatus.socStatus?.soc,
            remainingRange: statusSOC?.remainingRange ?? widgetStatus.socStatus?.remainingRange,
            remainingActualRange: statusSOC?.remainingActualRange
                ?? widgetStatus.socStatus?.remainingActualRange,
            chargeStateCode: statusSOC?.chargeState ?? widgetStatus.socStatus?.chargeState,
            chargingCurrent: statusSOC?.chargingCurrent ?? widgetStatus.socStatus?.chargingCurrent,
            chargingPower: statusSOC?.chargingPower ?? widgetStatus.socStatus?.chargingPower,
            chargingVoltage: statusSOC?.chargingVoltage ?? widgetStatus.socStatus?.chargingVoltage,
            chargeLimitPercent: statusSOC?.maxSOCEnabled == true
                ? statusSOC?.maxSOC
                : (widgetStatus.socStatus?.maxSOCEnabled == true
                    ? widgetStatus.socStatus?.maxSOC
                    : nil),
            batterySampledAt: (statusSOC?.sampleTime ?? widgetStatus.socStatus?.sampleTime)
                .flatMap(Self.dateFromUnixTimestamp),
            lockStatusCode: widgetStatus.doorStatus?.vehicleLockStatus,
            location: coordinate,
            locationSampledAt: position?.sampleTime.flatMap(Self.dateFromUnixTimestamp),
            insideTemperature: status.data.hvacStatus?.temperature,
            outsideTemperature: status.data.hvacStatus?.outsideTemperature,
            updatedAt: Date()
        )
    }

    private static func dateFromUnixTimestamp(_ value: Int64) -> Date? {
        let seconds = abs(value) < 10_000_000_000 ? TimeInterval(value) : TimeInterval(value) / 1000
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
