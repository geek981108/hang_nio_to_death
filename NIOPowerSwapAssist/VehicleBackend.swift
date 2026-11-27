import Foundation

extension Error {
    /// Swift cancellation can surface either as `CancellationError` or as the
    /// URL loading system's cancelled error, depending on where it is observed.
    var isTaskCancellation: Bool {
        if self is CancellationError { return true }
        let error = self as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}

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
    enum SpecialStatusKind: String, Codable, Equatable, Hashable, Sendable {
        case svt
        case repairing
        case fota
        case swapping
    }

    let vehicleID: String
    let isConnected: Bool
    let stateCode: Int?
    let mileage: Double?
    let isSwapping: Bool
    let isRepairing: Bool
    let fotaStatusCode: Int?
    let isSVTActive: Bool
    let repairSampledAt: Date?
    let fotaPreparingSampledAt: Date?
    let fotaPreparingCountdownSeconds: Int64?
    let svtSampledAt: Date?
    let rawSpecialStatusFields: [String: String]?
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

    init(
        vehicleID: String,
        isConnected: Bool,
        stateCode: Int?,
        mileage: Double?,
        isSwapping: Bool,
        isRepairing: Bool = false,
        fotaStatusCode: Int? = nil,
        isSVTActive: Bool = false,
        repairSampledAt: Date? = nil,
        fotaPreparingSampledAt: Date? = nil,
        fotaPreparingCountdownSeconds: Int64? = nil,
        svtSampledAt: Date? = nil,
        rawSpecialStatusFields: [String: String]? = nil,
        stateOfCharge: Double?,
        remainingRange: Double?,
        remainingActualRange: Double?,
        chargeStateCode: Int?,
        chargingCurrent: Double?,
        chargingPower: Double?,
        chargingVoltage: Double?,
        chargeLimitPercent: Double?,
        batterySampledAt: Date?,
        lockStatusCode: Int?,
        location: VehicleCoordinate?,
        locationSampledAt: Date?,
        insideTemperature: Double?,
        outsideTemperature: Double?,
        updatedAt: Date
    ) {
        self.vehicleID = vehicleID
        self.isConnected = isConnected
        self.stateCode = stateCode
        self.mileage = mileage
        self.isSwapping = isSwapping
        self.isRepairing = isRepairing
        self.fotaStatusCode = fotaStatusCode
        self.isSVTActive = isSVTActive
        self.repairSampledAt = repairSampledAt
        self.fotaPreparingSampledAt = fotaPreparingSampledAt
        self.fotaPreparingCountdownSeconds = fotaPreparingCountdownSeconds
        self.svtSampledAt = svtSampledAt
        self.rawSpecialStatusFields = rawSpecialStatusFields
        self.stateOfCharge = stateOfCharge
        self.remainingRange = remainingRange
        self.remainingActualRange = remainingActualRange
        self.chargeStateCode = chargeStateCode
        self.chargingCurrent = chargingCurrent
        self.chargingPower = chargingPower
        self.chargingVoltage = chargingVoltage
        self.chargeLimitPercent = chargeLimitPercent
        self.batterySampledAt = batterySampledAt
        self.lockStatusCode = lockStatusCode
        self.location = location
        self.locationSampledAt = locationSampledAt
        self.insideTemperature = insideTemperature
        self.outsideTemperature = outsideTemperature
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vehicleID = try container.decode(String.self, forKey: .vehicleID)
        isConnected = try container.decode(Bool.self, forKey: .isConnected)
        stateCode = try container.decodeIfPresent(Int.self, forKey: .stateCode)
        mileage = try container.decodeIfPresent(Double.self, forKey: .mileage)
        isSwapping = try container.decodeIfPresent(Bool.self, forKey: .isSwapping) ?? false
        isRepairing = try container.decodeIfPresent(Bool.self, forKey: .isRepairing) ?? false
        fotaStatusCode = try container.decodeIfPresent(Int.self, forKey: .fotaStatusCode)
        isSVTActive = try container.decodeIfPresent(Bool.self, forKey: .isSVTActive) ?? false
        repairSampledAt = try container.decodeIfPresent(Date.self, forKey: .repairSampledAt)
        fotaPreparingSampledAt = try container.decodeIfPresent(Date.self, forKey: .fotaPreparingSampledAt)
        fotaPreparingCountdownSeconds = try container.decodeIfPresent(Int64.self, forKey: .fotaPreparingCountdownSeconds)
        svtSampledAt = try container.decodeIfPresent(Date.self, forKey: .svtSampledAt)
        rawSpecialStatusFields = try container.decodeIfPresent([String: String].self, forKey: .rawSpecialStatusFields)
        stateOfCharge = try container.decodeIfPresent(Double.self, forKey: .stateOfCharge)
        remainingRange = try container.decodeIfPresent(Double.self, forKey: .remainingRange)
        remainingActualRange = try container.decodeIfPresent(Double.self, forKey: .remainingActualRange)
        chargeStateCode = try container.decodeIfPresent(Int.self, forKey: .chargeStateCode)
        chargingCurrent = try container.decodeIfPresent(Double.self, forKey: .chargingCurrent)
        chargingPower = try container.decodeIfPresent(Double.self, forKey: .chargingPower)
        chargingVoltage = try container.decodeIfPresent(Double.self, forKey: .chargingVoltage)
        chargeLimitPercent = try container.decodeIfPresent(Double.self, forKey: .chargeLimitPercent)
        batterySampledAt = try container.decodeIfPresent(Date.self, forKey: .batterySampledAt)
        lockStatusCode = try container.decodeIfPresent(Int.self, forKey: .lockStatusCode)
        location = try container.decodeIfPresent(VehicleCoordinate.self, forKey: .location)
        locationSampledAt = try container.decodeIfPresent(Date.self, forKey: .locationSampledAt)
        insideTemperature = try container.decodeIfPresent(Double.self, forKey: .insideTemperature)
        outsideTemperature = try container.decodeIfPresent(Double.self, forKey: .outsideTemperature)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    var isFotaActive: Bool {
        (fotaStatusCode ?? 0) != 0
    }

    /// Ordered by safety/intervention priority: SVT > Repairing > FOTA > Swapping.
    var activeSpecialStatuses: [SpecialStatusKind] {
        var list: [SpecialStatusKind] = []
        if isSVTActive { list.append(.svt) }
        if isRepairing { list.append(.repairing) }
        if isFotaActive { list.append(.fota) }
        if isSwapping { list.append(.swapping) }
        return list
    }

    var primarySpecialStatus: SpecialStatusKind? {
        activeSpecialStatuses.first
    }

    var hasActiveSpecialStatus: Bool {
        !activeSpecialStatuses.isEmpty
    }

    /// Vehicle is actively driving when stateCode == 1 and not in swap/repair/FOTA special modes.
    var isDriving: Bool {
        !isSwapping && !isRepairing && !isFotaActive && stateCode == 1
    }
}

struct VehicleProfile: Codable, Equatable, Sendable {
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
    case failed
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
        let repairing: Int?
        let fotaStatus: Int?
        let svt: Int?
        let repairSampleTime: Int64?
        let preparingSampleTime: Int64?
        let preparingCountdownSeconds: Int64?
        let svtSampleTime: Int64?
        let rawFields: [String: String]

        private struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
            init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
        }

        enum CodingKeys: String, CodingKey {
            case swapping
            case repaired
            case repairing
            case vehlRepaired = "vehl_repaired"
            case fotaStatus = "fota_status"
            case fota
            case svt
            case vehlSVT = "vehl_svt"
            case repairSampleTime = "repair_sample_time"
            case preparingSampleTime = "preparing_sample_time"
            case preparingCountdownSeconds = "preparing_countdown_seconds"
            case svtSampleTime = "svt_sample_time"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            swapping = Self.decodeFlagInt(container, forKey: .swapping)
            repairing = Self.decodeFirstFlagInt(container, keys: [.repaired, .repairing, .vehlRepaired])
            fotaStatus = Self.decodeFirstFlagInt(container, keys: [.fotaStatus, .fota])
            svt = Self.decodeFirstFlagInt(container, keys: [.svt, .vehlSVT])
            repairSampleTime = Self.decodeInt64(container, forKey: .repairSampleTime)
            preparingSampleTime = Self.decodeInt64(container, forKey: .preparingSampleTime)
            preparingCountdownSeconds = Self.decodeInt64(container, forKey: .preparingCountdownSeconds)
            svtSampleTime = Self.decodeInt64(container, forKey: .svtSampleTime)

            var captured: [String: String] = [:]
            if let dynamic = try? decoder.container(keyedBy: DynamicKey.self) {
                for key in dynamic.allKeys {
                    if let intVal = try? dynamic.decode(Int64.self, forKey: key) {
                        captured[key.stringValue] = String(intVal)
                    } else if let boolVal = try? dynamic.decode(Bool.self, forKey: key) {
                        captured[key.stringValue] = boolVal ? "true" : "false"
                    } else if let strVal = try? dynamic.decode(String.self, forKey: key), !strVal.isEmpty {
                        captured[key.stringValue] = strVal
                    } else if let dblVal = try? dynamic.decode(Double.self, forKey: key) {
                        captured[key.stringValue] = String(dblVal)
                    }
                }
            }
            rawFields = captured
        }

        private static func decodeFirstFlagInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Int? {
            var fallbackZero: Int?
            for key in keys {
                guard let value = decodeFlagInt(container, forKey: key) else { continue }
                if value != 0 { return value }
                fallbackZero = value
            }
            return fallbackZero
        }

        private static func decodeFlagInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intVal
            }
            if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: key) {
                return boolVal ? 1 : 0
            }
            if let strVal = try? container.decodeIfPresent(String.self, forKey: key) {
                let trimmed = strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let parsed = Int(trimmed) { return parsed }
                if trimmed == "true" || trimmed == "yes" { return 1 }
                if trimmed == "false" || trimmed == "no" { return 0 }
            }
            return nil
        }

        private static func decodeInt64(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int64? {
            if let intVal = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return intVal
            }
            if let strVal = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int64(strVal.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
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
        let latitude: Double?
        let longitude: Double?

        var id: String { stationID }

        var hasValidCoordinates: Bool {
            guard let latitude, let longitude else { return false }
            return latitude.isFinite && longitude.isFinite
                && (-90.0...90.0).contains(latitude)
                && (-180.0...180.0).contains(longitude)
                && (latitude != 0 || longitude != 0)
        }

        enum CodingKeys: String, CodingKey {
            case stationID = "station_id"
            case name, address, latitude, longitude
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
        let batteryID: String?
        let slotID: Int?
        let batteryCapSeries: Int?
        let stateOfCharge: Double?
        let productionDate: String?

        enum CodingKeys: String, CodingKey {
            case batteryID = "battery_id"
            case slotID = "slot_id"
            case batteryCapSeries = "battery_cap_series"
            case stateOfCharge = "soc_percent"
            case productionDate = "production_date"
        }
    }
}

/// Live station data fetched through the backend: `GET /api/v1/stations/nearest`
/// (station closest to the vehicle, with distance) or `/api/v1/stations/{id}/live`
/// (a chosen station, no distance). The backend signs these requests with its
/// own NIO session, so no captured app token is involved.
struct NearestStationLive: Decodable, Sendable {
    let stationID: String
    let stationName: String
    let straightLineDistanceKm: Double?
    let currentFees: [FeeEntry]
    let feePeriods: [FeePeriodEntry]
    let feeNotices: [String]
    let batteryReadiness: [BatteryReadinessEntry]
    let isScannable: Bool?
    let statusTags: [StatusTag]?
    let notification: String?

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case stationName = "station_name"
        case straightLineDistanceKm = "straight_line_distance_km"
        case currentFees = "current_fees"
        case feePeriods = "fee_periods"
        case feeNotices = "fee_notices"
        case batteryReadiness = "battery_readiness"
        case isScannable = "is_scannable"
        case statusTags = "status_tags"
        case notification
    }

    struct StatusTag: Decodable, Sendable {
        let text: String
        let type: String?
    }

    struct FeeEntry: Decodable, Sendable {
        let feeType: String?
        let name: String?
        let fee: String?
        let unit: String?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case feeType = "fee_type"
            case name, fee, unit, currency
        }

        var item: FeeItem {
            FeeItem(type: feeType, name: name ?? "", fee: fee ?? "", unit: unit ?? "", currency: currency ?? "¥")
        }
    }

    struct FeePeriodEntry: Decodable, Sendable {
        let timePeriod: String
        let fees: [FeeEntry]

        enum CodingKeys: String, CodingKey {
            case timePeriod = "time_period"
            case fees
        }
    }

    struct BatteryReadinessEntry: Decodable, Sendable {
        let slotID: Int?
        let batteryCapSeries: Int?
        let capacityKwh: Double?
        let progressPercent: Double?
        let batteryOccupied: Bool?
        let batteryID: String?
        let productionDate: String?
        let chargingRemainingMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case slotID = "slot_id"
            case batteryCapSeries = "battery_cap_series"
            case capacityKwh = "capacity_kwh"
            case progressPercent = "progress_percent"
            case batteryOccupied = "battery_occupied"
            case batteryID = "battery_id"
            case productionDate = "production_date"
            case chargingRemainingMinutes = "charging_remaining_minutes"
        }
    }

    var displayName: String {
        guard let distance = straightLineDistanceKm else { return stationName }
        return "\(stationName) · 距车 \(String(format: "%.1f", distance)) km"
    }

    /// Same presentation model as a station fetched through a saved request.
    func stationSnapshot() -> SwapStationSnapshot {
        let batteries = batteryReadiness.enumerated().map { index, entry -> BatteryModel in
            let type: String
            switch entry.capacityKwh {
            case 70: type = "70 kWh"
            case 75: type = "75 kWh"
            case 100: type = "100 kWh"
            case 102: type = "102 kWh"
            case 150: type = "150 kWh"
            default: type = "其他电池"
            }
            let slot = entry.slotID ?? 0
            let trimmedID = entry.batteryID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedID = (trimmedID?.isEmpty == false ? trimmedID : nil) ?? "slot-\(slot)-\(index)"
            return BatteryModel(
                id: resolvedID,
                chargingProgress: min(max(entry.progressPercent ?? 0, 0), 100),
                batteryType: type,
                chargingRemainingMinutes: (entry.chargingRemainingMinutes ?? 0) > 0
                    ? entry.chargingRemainingMinutes
                    : nil,
                isOccupied: entry.batteryOccupied ?? false,
                manufactureDate: entry.productionDate,
                slotID: slot
            )
        }
        .sorted { $0.slotID < $1.slotID }
        let fees = currentFees.map(\.item)
        let periods = feePeriods.map { FeePeriod(timePeriod: $0.timePeriod, fees: $0.fees.map(\.item)) }
        let feeInfo = fees.isEmpty && periods.isEmpty && feeNotices.isEmpty
            ? nil
            : FeeInfo(currentFees: fees, periods: periods, notices: feeNotices)
        let unavailableText = statusTags?.first {
            $0.type?.localizedCaseInsensitiveCompare("negative") == .orderedSame
        }?.text
        return SwapStationSnapshot(
            batteries: batteries,
            feeInfo: feeInfo,
            serviceState: StationServiceState(
                isScannable: isScannable,
                statusText: unavailableText,
                notification: notification
            )
        )
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
    case invalidLoginInput(String)

    var isVehicleNotConfigured: Bool {
        if case .serverFailure(let code, _, _) = self, code == "vehicle_not_configured" {
            return true
        }
        return false
    }

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
            case "login_not_configured": return "服务端尚未启用短信登录（需配置 API_KEY 与 NIO_DEVICE_ID）。"
            case "nio_login_rejected": return "蔚来登录被拒绝：\(message)"
            case "nio_login_upstream_error": return "蔚来登录上游请求失败，请稍后重试。"
            case "station_template_not_configured": return "服务端尚未配置换电站查询模板。"
            case "station_not_configured": return "服务端尚未配置换电站轮询。"
            case "database_error": return "后端数据库暂时不可用，请稍后重试。"
            case "trip_track_not_found": return "该行程暂未同步 GPS 轨迹。"
            case "invalid_journey_id": return "行程编号无效。"
            case "check_in_already_attempted": return "今日已完成签到。"
            case "rewards_disabled": return "服务端尚未启用积分与签到服务。"
            case "station_coordinates_unavailable": return "该换电站缺少坐标信息，无法估算直线能耗。"
            case "send_route_result_unknown": return "发送超时或连接中断，无法确认车机是否已收到路线，请先在车机确认后再决定是否重试。"
            case "vehicle_position_unavailable": return "暂未获取到车辆当前位置，无法自动规划加电路线。"
            case "route_plan_failed": return "加电路线规划失败：\(message)"
            case "confirmation_expired": return "确认弹窗已过期或已使用，请重新发送路线。"
            case "vehicle_changed": return "当前绑定车辆已变更，请重新发起发送。"
            case "invalid_btn_action": return "所选弹窗操作无效，请重新发送。"
            case "invalid_send_route_input": return "路线或目的地信息不完整，请检查后重试。"
            case "send_route_rejected": return "蔚来云端拒绝了发送路线请求：\(message)"
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
        case .invalidLoginInput(let message): return message
        }
    }
}

struct BackendServiceStatus: Decodable, Equatable, Sendable {
    let stationConfigured: Bool
    let vehicleConfigured: Bool
    let serviceOrderConfigured: Bool
    let stationTemplateConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case stationConfigured = "station_configured"
        case vehicleConfigured = "vehicle_configured"
        case serviceOrderConfigured = "service_order_configured"
        case stationTemplateConfigured = "station_template_configured"
    }
}

struct NIOLoginSMSRequest: Encodable, Sendable {
    let mobile: String
}

struct NIOLoginSMSChallenge: Decodable, Equatable, Sendable {
    let challengeID: String
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case expiresInSeconds = "expires_in_seconds"
    }
}

struct NIOLoginSubmitRequest: Encodable, Sendable {
    let challengeID: String
    let verificationCode: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case verificationCode = "verification_code"
    }
}

struct NIOLoginOutcome: Decodable, Equatable, Sendable {
    struct Metadata: Decodable, Equatable, Sendable {
        let tokenType: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    let resultCode: String
    let backendConfigSaved: Bool?
    let vehicleClientReloaded: Bool?
    let data: Metadata?

    enum CodingKeys: String, CodingKey {
        case resultCode = "result_code"
        case backendConfigSaved = "backend_config_saved"
        case vehicleClientReloaded = "vehicle_client_reloaded"
        case data
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

struct DailyCheckInOutcome: Decodable, Equatable, Sendable {
    let checkedIn: Bool
    let tip: String
    let credit: Int
    let serverTime: Int64
    let checkinTime: Int64
    let continuousDays: Int
    let creditAmount: Int

    enum CodingKeys: String, CodingKey {
        case checkedIn = "checked_in"
        case tip, credit
        case serverTime = "server_time"
        case checkinTime = "checkin_time"
        case continuousDays = "continuous_days"
        case creditAmount = "credit_amount"
    }
}

struct NearbyStationsRequestPayload: Encodable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct NearbyStation: Decodable, Equatable, Identifiable, Sendable {
    let stationID: String
    let name: String?
    let latitude: Double
    let longitude: Double
    let straightLineDistanceKm: Double

    var id: String { stationID }

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? stationID
    }

    var coordinate: VehicleCoordinate {
        VehicleCoordinate(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case name, latitude, longitude
        case straightLineDistanceKm = "straight_line_distance_km"
    }
}

struct NearbyStationResult: Decodable, Equatable, Sendable {
    let source: String
    let fetchedAt: String
    let viewportZoomLevel: Int
    let viewportScreenRatio: Double
    let coverage: String
    let stations: [NearbyStation]

    enum CodingKeys: String, CodingKey {
        case source, coverage, stations
        case fetchedAt = "fetched_at"
        case viewportZoomLevel = "viewport_zoom_level"
        case viewportScreenRatio = "viewport_screen_ratio"
    }
}

struct StraightLineEnergyRequestPayload: Encodable, Sendable {
    let latitude: Double
    let longitude: Double
    let stationLatitude: Double?
    let stationLongitude: Double?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case stationLatitude = "station_latitude"
        case stationLongitude = "station_longitude"
    }
}

struct StraightLineEnergyEstimate: Decodable, Equatable, Sendable {
    struct EnergyCache: Decodable, Equatable, Sendable {
        struct Summary: Decodable, Equatable, Sendable {
            let actualDistanceKm: Double?
            let consumptionKWhPer100Km: Double?
            let coverageComplete: Bool?

            enum CodingKeys: String, CodingKey {
                case actualDistanceKm = "actual_distance_km"
                case consumptionKWhPer100Km = "consumption_kwh_per_100km"
                case coverageComplete = "coverage_complete"
            }
        }

        let status: String
        let stale: Bool
        let summary: Summary?
    }

    let stationID: String
    let stationCoordinatesSource: String
    let straightLineDistanceKm: Double
    let energyCache: EnergyCache
    let estimatedEnergyForStraightLineKWh: Double?
    let distanceKind: String
    let roadDistanceKm: Double?
    let roadTravelTimeMinutes: Double?
    let trafficAndTollsIncluded: Bool

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case stationCoordinatesSource = "station_coordinates_source"
        case straightLineDistanceKm = "straight_line_distance_km"
        case energyCache = "energy_cache"
        case estimatedEnergyForStraightLineKWh = "estimated_energy_for_straight_line_kwh"
        case distanceKind = "distance_kind"
        case roadDistanceKm = "road_distance_km"
        case roadTravelTimeMinutes = "road_travel_time_minutes"
        case trafficAndTollsIncluded = "traffic_and_tolls_included"
    }
}

enum RouteNodeType: String, Codable, Equatable, Sendable {
    case orig
    case dest
    case waypoint
    case resource
    case candidate
    case waypointCandidate = "waypoint_candidate"
    case origCandidate = "orig_candidate"
    case destCandidate = "dest_candidate"
}

struct SendRoutePoiInput: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
    let resourceID: String?
    let cloneLatitude: Double?
    let cloneLongitude: Double?
    let nextPointDistance: Int?
    let stationType: RouteNodeType?

    var id: String {
        "\(resourceID ?? name):\(latitude):\(longitude)"
    }

    init(
        name: String,
        address: String? = nil,
        latitude: Double,
        longitude: Double,
        resourceID: String? = nil,
        cloneLatitude: Double? = nil,
        cloneLongitude: Double? = nil,
        nextPointDistance: Int? = nil,
        stationType: RouteNodeType? = nil
    ) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.resourceID = resourceID
        self.cloneLatitude = cloneLatitude
        self.cloneLongitude = cloneLongitude
        self.nextPointDistance = nextPointDistance
        self.stationType = stationType
    }

    enum CodingKeys: String, CodingKey {
        case name, address, latitude, longitude
        case resourceID = "resource_id"
        case cloneLatitude = "clone_latitude"
        case cloneLongitude = "clone_longitude"
        case nextPointDistance = "next_point_distance"
        case stationType = "station_type"
    }
}

struct SendRouteDriverInput: Codable, Equatable, Sendable {
    let routeDriverDuration: Int?
    let chargeTimes: Int?
    let routeDistance: Int?

    enum CodingKeys: String, CodingKey {
        case routeDriverDuration = "route_driver_duration"
        case chargeTimes = "charge_times"
        case routeDistance = "route_distance"
    }
}

struct PlanRouteInput: Encodable, Equatable, Sendable {
    let poiList: [SendRoutePoiInput]
    let includeChargeStops: Bool?

    init(poiList: [SendRoutePoiInput], includeChargeStops: Bool? = nil) {
        self.poiList = poiList
        self.includeChargeStops = includeChargeStops
    }

    enum CodingKeys: String, CodingKey {
        case poiList = "poi_list"
        case includeChargeStops = "include_charge_stops"
    }
}

struct PlannedRouteStation: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    let address: String?
    let resourceID: String?
    let resourceType: String?
    let stationType: RouteNodeType
    let durationDesc: String?
    let distanceDesc: String?
    let remainSOC: Int?

    var id: String {
        "\(resourceID ?? name):\(stationType.rawValue)"
    }

    enum CodingKeys: String, CodingKey {
        case name, address
        case resourceID = "resource_id"
        case resourceType = "resource_type"
        case stationType = "station_type"
        case durationDesc = "duration_desc"
        case distanceDesc = "distance_desc"
        case remainSOC = "remain_soc"
    }
}

struct PlannedRouteStep: Decodable, Equatable, Identifiable, Sendable {
    let title: String
    let subtitle: String?
    let distanceDesc: String?
    let remainSOC: Int?
    let resourceID: String?
    let resourceType: String?
    let isPoi: Bool
    let isPowerSwapClone: Bool
    let tags: [String]
    let riskMsg: String?

    var id: String {
        "\(resourceID ?? title):\(distanceDesc ?? ""):\(isPoi)"
    }

    var isEnergyStop: Bool {
        !isPoi || resourceID != nil || resourceType == "PowerSwap" || resourceType == "ChargeStation" || resourceType == "FakePowerSwap"
    }

    enum CodingKeys: String, CodingKey {
        case title, subtitle, tags
        case distanceDesc = "distance_desc"
        case remainSOC = "remain_soc"
        case resourceID = "resource_id"
        case resourceType = "resource_type"
        case isPoi = "is_poi"
        case isPowerSwapClone = "is_power_swap_clone"
        case riskMsg = "risk_msg"
    }
}

struct PlannedRouteOption: Decodable, Equatable, Identifiable, Sendable {
    let routeID: String?
    let tagDesc: String?
    let driveDistanceDesc: String?
    let driveDurationDesc: String?
    let planDurationDesc: String?
    let chargeDesc: String?
    let chargeDuration: Int?
    let chargeDurationDesc: String?
    let tollChargeDesc: String?
    let hasRisk: Bool?
    let driver: SendRouteDriverInput?
    let poiList: [SendRoutePoiInput]
    let chargeStations: [PlannedRouteStation]
    let steps: [PlannedRouteStep]

    var id: String {
        routeID ?? "\(tagDesc ?? "plan"):\(driveDistanceDesc ?? ""):\(poiList.count)"
    }

    enum CodingKeys: String, CodingKey {
        case routeID = "route_id"
        case tagDesc = "tag_desc"
        case driveDistanceDesc = "drive_distance_desc"
        case driveDurationDesc = "drive_duration_desc"
        case planDurationDesc = "plan_duration_desc"
        case chargeDesc = "charge_desc"
        case chargeDuration = "charge_duration"
        case chargeDurationDesc = "charge_duration_desc"
        case tollChargeDesc = "toll_charge_desc"
        case hasRisk = "has_risk"
        case driver
        case poiList = "poi_list"
        case chargeStations = "charge_stations"
        case steps
    }

    init(
        routeID: String?,
        tagDesc: String?,
        driveDistanceDesc: String?,
        driveDurationDesc: String?,
        planDurationDesc: String?,
        chargeDesc: String?,
        chargeDuration: Int? = nil,
        chargeDurationDesc: String? = nil,
        tollChargeDesc: String?,
        hasRisk: Bool?,
        driver: SendRouteDriverInput?,
        poiList: [SendRoutePoiInput],
        chargeStations: [PlannedRouteStation],
        steps: [PlannedRouteStep] = []
    ) {
        self.routeID = routeID
        self.tagDesc = tagDesc
        self.driveDistanceDesc = driveDistanceDesc
        self.driveDurationDesc = driveDurationDesc
        self.planDurationDesc = planDurationDesc
        self.chargeDesc = chargeDesc
        self.chargeDuration = chargeDuration
        self.chargeDurationDesc = chargeDurationDesc
        self.tollChargeDesc = tollChargeDesc
        self.hasRisk = hasRisk
        self.driver = driver
        self.poiList = poiList
        self.chargeStations = chargeStations
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routeID = try container.decodeIfPresent(String.self, forKey: .routeID)
        tagDesc = try container.decodeIfPresent(String.self, forKey: .tagDesc)
        driveDistanceDesc = try container.decodeIfPresent(String.self, forKey: .driveDistanceDesc)
        driveDurationDesc = try container.decodeIfPresent(String.self, forKey: .driveDurationDesc)
        planDurationDesc = try container.decodeIfPresent(String.self, forKey: .planDurationDesc)
        chargeDesc = try container.decodeIfPresent(String.self, forKey: .chargeDesc)
        chargeDuration = try container.decodeIfPresent(Int.self, forKey: .chargeDuration)
        chargeDurationDesc = try container.decodeIfPresent(String.self, forKey: .chargeDurationDesc)
        tollChargeDesc = try container.decodeIfPresent(String.self, forKey: .tollChargeDesc)
        hasRisk = try container.decodeIfPresent(Bool.self, forKey: .hasRisk)
        driver = try container.decodeIfPresent(SendRouteDriverInput.self, forKey: .driver)
        poiList = try container.decodeIfPresent([SendRoutePoiInput].self, forKey: .poiList) ?? []
        chargeStations = try container.decodeIfPresent([PlannedRouteStation].self, forKey: .chargeStations) ?? []
        steps = try container.decodeIfPresent([PlannedRouteStep].self, forKey: .steps) ?? []
    }
}

struct PlanRouteOutcome: Decodable, Equatable, Sendable {
    let requestID: String?
    let serverTime: Int64?
    let toastMsg: String?
    let plans: [PlannedRouteOption]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case serverTime = "server_time"
        case toastMsg = "toast_msg"
        case plans
    }
}

struct PlannedRouteSummary: Decodable, Equatable, Sendable {
    let routeID: String?
    let tagDesc: String?
    let driveDistanceDesc: String?
    let planDurationDesc: String?
    let chargeDesc: String?
    let chargeDurationDesc: String?
    let chargeTimes: Int?
    let chargeStationNames: [String]
    let poiCount: Int

    enum CodingKeys: String, CodingKey {
        case routeID = "route_id"
        case tagDesc = "tag_desc"
        case driveDistanceDesc = "drive_distance_desc"
        case planDurationDesc = "plan_duration_desc"
        case chargeDesc = "charge_desc"
        case chargeDurationDesc = "charge_duration_desc"
        case chargeTimes = "charge_times"
        case chargeStationNames = "charge_station_names"
        case poiCount = "poi_count"
    }
}

struct SendRouteInput: Encodable, Equatable, Sendable {
    let poiList: [SendRoutePoiInput]
    let driver: SendRouteDriverInput?
    let routeID: String?
    let autoPlan: Bool?
    let includeChargeStops: Bool?

    init(
        poiList: [SendRoutePoiInput],
        driver: SendRouteDriverInput? = nil,
        routeID: String? = nil,
        autoPlan: Bool? = nil,
        includeChargeStops: Bool? = nil
    ) {
        self.poiList = poiList
        self.driver = driver
        self.routeID = routeID
        self.autoPlan = autoPlan
        self.includeChargeStops = includeChargeStops
    }

    enum CodingKeys: String, CodingKey {
        case poiList = "poi_list"
        case driver
        case routeID = "route_id"
        case autoPlan = "auto_plan"
        case includeChargeStops = "include_charge_stops"
    }
}

struct ConfirmSendRouteInput: Encodable, Equatable, Sendable {
    let confirmationToken: String
    let btnAction: Int

    enum CodingKeys: String, CodingKey {
        case confirmationToken = "confirmation_token"
        case btnAction = "btn_action"
    }
}

struct SendRouteSwitchStatus: Decodable, Equatable, Sendable {
    let exposeSendVehicleButton: Bool?
    let enabled: Bool
    let requestID: String?
    let serverTime: Int64?

    enum CodingKeys: String, CodingKey {
        case exposeSendVehicleButton = "expose_send_vehicle_button"
        case enabled
        case requestID = "request_id"
        case serverTime = "server_time"
    }
}

struct SendRoutePopup: Decodable, Equatable, Sendable {
    let content: String?
    let leftBtnText: String?
    let leftBtnAction: Int?
    let rightBtnText: String?
    let rightBtnAction: Int?

    enum CodingKeys: String, CodingKey {
        case content
        case leftBtnText = "left_btn_text"
        case leftBtnAction = "left_btn_action"
        case rightBtnText = "right_btn_text"
        case rightBtnAction = "right_btn_action"
    }
}

struct SendRouteOutcome: Decodable, Equatable, Sendable {
    let status: String
    let resultCode: String
    let requestID: String?
    let serverTime: Int64?
    let toastMsg: String?
    let popupMessage: SendRoutePopup?
    let confirmationToken: String?
    let confirmationExpiresInSeconds: Int?
    let plannedRoute: PlannedRouteSummary?

    var requiresConfirmation: Bool {
        popupMessage != nil
    }

    enum CodingKeys: String, CodingKey {
        case status
        case resultCode = "result_code"
        case requestID = "request_id"
        case serverTime = "server_time"
        case toastMsg = "toast_msg"
        case popupMessage = "popup_message"
        case confirmationToken = "confirmation_token"
        case confirmationExpiresInSeconds = "confirmation_expires_in_seconds"
        case plannedRoute = "planned_route"
    }
}

enum LiveActivityTokenKind: String, Codable, Equatable, Sendable {
    case pushToStart = "push_to_start"
    case activityUpdate = "activity_update"
}

enum LiveActivityAPNsEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

struct LiveActivityTokenRegistration: Encodable, Equatable, Sendable {
    let deviceID: String
    let tokenKind: LiveActivityTokenKind
    let pushToken: String
    let activityID: String?
    let sessionKey: String?
    let activityMode: String?
    let bundleID: String?
    let apnsEnvironment: LiveActivityAPNsEnvironment

    init(
        deviceID: String,
        tokenKind: LiveActivityTokenKind,
        pushToken: String,
        activityID: String? = nil,
        sessionKey: String? = nil,
        activityMode: String? = nil,
        bundleID: String? = nil,
        apnsEnvironment: LiveActivityAPNsEnvironment
    ) {
        self.deviceID = deviceID
        self.tokenKind = tokenKind
        self.pushToken = pushToken
        self.activityID = activityID
        self.sessionKey = sessionKey
        self.activityMode = activityMode
        self.bundleID = bundleID
        self.apnsEnvironment = apnsEnvironment
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case tokenKind = "token_kind"
        case pushToken = "push_token"
        case activityID = "activity_id"
        case sessionKey = "session_key"
        case activityMode = "activity_mode"
        case bundleID = "bundle_id"
        case apnsEnvironment = "apns_environment"
    }
}

struct LiveActivityTokenDeleteInput: Encodable, Equatable, Sendable {
    let deviceID: String
    let tokenKind: LiveActivityTokenKind?
    let activityID: String?

    init(
        deviceID: String,
        tokenKind: LiveActivityTokenKind? = nil,
        activityID: String? = nil
    ) {
        self.deviceID = deviceID
        self.tokenKind = tokenKind
        self.activityID = activityID
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case tokenKind = "token_kind"
        case activityID = "activity_id"
    }
}

struct LiveActivityTokenResponse: Decodable, Equatable, Sendable {
    let registered: Bool
    let apnsConfigured: Bool
    let tokenKind: LiveActivityTokenKind
    let apnsEnvironment: LiveActivityAPNsEnvironment

    enum CodingKeys: String, CodingKey {
        case registered
        case apnsConfigured = "apns_configured"
        case tokenKind = "token_kind"
        case apnsEnvironment = "apns_environment"
    }
}

struct LiveActivityTokenDeleteResponse: Decodable, Equatable, Sendable {
    let deleted: Int64
}

enum LiveActivitySimulationMode: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case charging
    case swapQueue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .charging: return "模拟充电"
        case .swapQueue: return "模拟换电排队"
        }
    }
}

struct LiveActivitySimulationRequest: Encodable, Equatable, Sendable {
    let mode: LiveActivitySimulationMode
    let intervalSeconds: Int
    let steps: Int
    let deviceID: String?

    init(
        mode: LiveActivitySimulationMode = .charging,
        intervalSeconds: Int = 5,
        steps: Int = 6,
        deviceID: String? = nil
    ) {
        self.mode = mode
        self.intervalSeconds = intervalSeconds
        self.steps = steps
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case intervalSeconds = "interval_seconds"
        case steps
        case deviceID = "device_id"
    }
}

struct LiveActivitySimulationStopInput: Encodable, Equatable, Sendable {
    let deviceID: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
    }
}

struct LiveActivitySimulationSnapshot: Decodable, Equatable, Sendable {
    let running: Bool
    let simulationID: String?
    let mode: LiveActivitySimulationMode?
    let sessionKey: String?
    let currentStep: Int
    let totalSteps: Int
    let intervalSeconds: Int
    let startedAt: String?
    let lastEvent: String?
    let lastDeliveredCount: Int
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case running
        case simulationID = "simulation_id"
        case mode
        case sessionKey = "session_key"
        case currentStep = "current_step"
        case totalSteps = "total_steps"
        case intervalSeconds = "interval_seconds"
        case startedAt = "started_at"
        case lastEvent = "last_event"
        case lastDeliveredCount = "last_delivered_count"
        case lastError = "last_error"
    }
}

struct LiveActivitySimulationOutcome: Decodable, Equatable, Sendable {
    let started: Bool
    let simulationID: String
    let mode: LiveActivitySimulationMode
    let sessionKey: String
    let intervalSeconds: Int
    let totalSteps: Int
    let startTokensTargeted: Int
    let startDelivered: Int
    let updateTokensTargeted: Int
    let updateDelivered: Int

    enum CodingKeys: String, CodingKey {
        case started
        case simulationID = "simulation_id"
        case mode
        case sessionKey = "session_key"
        case intervalSeconds = "interval_seconds"
        case totalSteps = "total_steps"
        case startTokensTargeted = "start_tokens_targeted"
        case startDelivered = "start_delivered"
        case updateTokensTargeted = "update_tokens_targeted"
        case updateDelivered = "update_delivered"
    }
}

struct LiveActivitySimulationStopOutcome: Decodable, Equatable, Sendable {
    let stopped: Bool
    let endedTokens: Int
    let endDelivered: Int

    enum CodingKeys: String, CodingKey {
        case stopped
        case endedTokens = "ended_tokens"
        case endDelivered = "end_delivered"
    }
}

struct LiveActivityPushStatus: Decodable, Equatable, Sendable {
    let apnsConfigured: Bool
    let bundleID: String?
    let defaultEnvironment: LiveActivityAPNsEnvironment?
    let pushToStartTokenCount: Int
    let activityUpdateTokenCount: Int
    let activeSessionKey: String?
    let activeMode: LiveActivitySimulationMode?
    let lastPushAt: String?
    let simulation: LiveActivitySimulationSnapshot?

    enum CodingKeys: String, CodingKey {
        case apnsConfigured = "apns_configured"
        case bundleID = "bundle_id"
        case defaultEnvironment = "default_environment"
        case pushToStartTokenCount = "push_to_start_token_count"
        case activityUpdateTokenCount = "activity_update_token_count"
        case activeSessionKey = "active_session_key"
        case activeMode = "active_mode"
        case lastPushAt = "last_push_at"
        case simulation
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

    func fetchServiceStatus() async throws -> BackendServiceStatus {
        try await fetch(path: "api/v1/status")
    }

    func fetchLiveActivityPushStatus() async throws -> LiveActivityPushStatus {
        try await fetch(path: "api/v1/live-activities/status")
    }

    func makeRegisterLiveActivityTokenRequest(
        _ input: LiveActivityTokenRegistration
    ) throws -> URLRequest {
        var request = makeRequest(path: "api/v1/live-activities/tokens")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(input)
        return request
    }

    func registerLiveActivityToken(
        _ input: LiveActivityTokenRegistration
    ) async throws -> LiveActivityTokenResponse {
        let request = try makeRegisterLiveActivityTokenRequest(input)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeDeleteLiveActivityTokenRequest(
        _ input: LiveActivityTokenDeleteInput
    ) throws -> URLRequest {
        var request = makeRequest(path: "api/v1/live-activities/tokens")
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(input)
        return request
    }

    func deleteLiveActivityToken(
        _ input: LiveActivityTokenDeleteInput
    ) async throws -> LiveActivityTokenDeleteResponse {
        let request = try makeDeleteLiveActivityTokenRequest(input)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeStartLiveActivitySimulationRequest(
        _ input: LiveActivitySimulationRequest
    ) throws -> URLRequest {
        var request = makeRequest(path: "api/v1/live-activities/simulation")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(input)
        return request
    }

    func startLiveActivitySimulation(
        _ input: LiveActivitySimulationRequest
    ) async throws -> LiveActivitySimulationOutcome {
        let request = try makeStartLiveActivitySimulationRequest(input)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeStopLiveActivitySimulationRequest(
        deviceID: String? = nil
    ) throws -> URLRequest {
        var request = makeRequest(path: "api/v1/live-activities/simulation")
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LiveActivitySimulationStopInput(deviceID: deviceID)
        )
        return request
    }

    func stopLiveActivitySimulation(
        deviceID: String? = nil
    ) async throws -> LiveActivitySimulationStopOutcome {
        let request = try makeStopLiveActivitySimulationRequest(deviceID: deviceID)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeSendNIOLoginSMSRequest(mobile: String) throws -> URLRequest {
        let trimmed = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidMainlandMobile(trimmed) else {
            throw BackendClientError.invalidLoginInput("请输入有效的 11 位中国大陆手机号。")
        }
        var request = makeRequest(path: "api/v1/auth/sms")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(NIOLoginSMSRequest(mobile: trimmed))
        return request
    }

    func sendNIOLoginSMS(mobile: String) async throws -> NIOLoginSMSChallenge {
        let request = try makeSendNIOLoginSMSRequest(mobile: mobile)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeSubmitNIOLoginRequest(
        challengeID: String,
        verificationCode: String
    ) throws -> URLRequest {
        let trimmedChallenge = challengeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChallenge.isEmpty else {
            throw BackendClientError.invalidLoginInput("请先获取短信验证码。")
        }
        guard trimmedCode.count == 6, trimmedCode.allSatisfy(\.isASCII), trimmedCode.allSatisfy(\.isNumber) else {
            throw BackendClientError.invalidLoginInput("请输入 6 位数字短信验证码。")
        }
        var request = makeRequest(path: "api/v1/auth/login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            NIOLoginSubmitRequest(
                challengeID: trimmedChallenge,
                verificationCode: trimmedCode
            )
        )
        return request
    }

    func submitNIOLogin(
        challengeID: String,
        verificationCode: String
    ) async throws -> NIOLoginOutcome {
        let request = try makeSubmitNIOLoginRequest(
            challengeID: challengeID,
            verificationCode: verificationCode
        )
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private static func isValidMainlandMobile(_ mobile: String) -> Bool {
        let bytes = Array(mobile.utf8)
        guard bytes.count == 11,
              bytes[0] == UInt8(ascii: "1"),
              (UInt8(ascii: "3")...UInt8(ascii: "9")).contains(bytes[1]) else {
            return false
        }
        return bytes.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    func fetchVehicleProfile() async throws -> VehicleProfile {
        try await fetch(path: "api/v1/vehicle/profile")
    }

    func fetchVehiclePresentation(
        cachedETag: String?,
        cachedVehicleID: String?
    ) async throws -> VehiclePresentation {
        let profile = try await fetchVehicleProfile()
        guard profile.imageAvailable else {
            return VehiclePresentation(profile: profile, image: .unavailable)
        }
        let matchingETag = cachedVehicleID == profile.vehicleID ? cachedETag : nil
        do {
            let request = makeVehicleImageRequest(cachedETag: matchingETag)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw BackendClientError.invalidResponse
            }
            if response.statusCode == 304 {
                return VehiclePresentation(profile: profile, image: .notModified)
            }
            guard response.statusCode == 200,
                  response.mimeType?.hasPrefix("image/") == true,
                  !data.isEmpty else {
                throw BackendClientError.httpStatus(response.statusCode)
            }
            return VehiclePresentation(
                profile: profile,
                image: .downloaded(
                    data: data,
                    etag: response.value(forHTTPHeaderField: "ETag")
                )
            )
        } catch {
            if Task.isCancelled || error.isTaskCancellation {
                throw CancellationError()
            }
            return VehiclePresentation(profile: profile, image: .failed)
        }
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

    func fetchNearestStationLive() async throws -> NearestStationLive {
        try await fetch(path: "api/v1/stations/nearest")
    }

    /// Full live data of one station, queried by the backend.
    func fetchStationLiveDetails(id: String) async throws -> NearestStationLive {
        try await fetch(path: "api/v1/stations/\(id)/live")
    }

    func fetchVehicleTrips(count: Int = 20) async throws -> VehicleTripPage {
        try await fetch(path: "api/v1/vehicle/trips?count=\(min(max(count, 1), 100))")
    }

    func makeVehicleTripTrackRequest(journeyID: String) throws -> URLRequest {
        let trimmed = journeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || byte == UInt8(ascii: "_")
                      || byte == UInt8(ascii: "-")
              }) else {
            throw BackendClientError.serverFailure(
                code: "invalid_journey_id",
                message: "invalid journey_id",
                status: 400
            )
        }
        return makeRequest(path: "api/v1/vehicle/trips/\(trimmed)/track")
    }

    func fetchVehicleTripTrack(journeyID: String) async throws -> VehicleTripTrack {
        let request = try makeVehicleTripTrackRequest(journeyID: journeyID)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    /// Single explicit daily check-in POST. Never auto-retried.
    func makeDailyCheckInRequest() -> URLRequest {
        var request = makeRequest(path: "api/v1/check-in")
        request.httpMethod = "POST"
        return request
    }

    func performDailyCheckIn() async throws -> DailyCheckInOutcome {
        let request = makeDailyCheckInRequest()
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeNearbyStationsRequest(latitude: Double, longitude: Double) throws -> URLRequest {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            throw BackendClientError.serverFailure(
                code: "invalid_request",
                message: "valid latitude and longitude are required",
                status: 400
            )
        }
        var request = makeRequest(path: "api/v1/stations/nearby")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            NearbyStationsRequestPayload(latitude: latitude, longitude: longitude)
        )
        return request
    }

    func fetchNearbyStations(latitude: Double, longitude: Double) async throws -> NearbyStationResult {
        let request = try makeNearbyStationsRequest(latitude: latitude, longitude: longitude)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func makeStraightLineEnergyRequest(
        stationID: String,
        latitude: Double,
        longitude: Double,
        stationLatitude: Double? = nil,
        stationLongitude: Double? = nil
    ) throws -> URLRequest {
        let trimmedStationID = stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedStationID.hasPrefix("PS-NIO-"),
              trimmedStationID.count > "PS-NIO-".count,
              trimmedStationID.count <= 128,
              latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            throw BackendClientError.serverFailure(
                code: "invalid_request",
                message: "valid station id, latitude and longitude are required",
                status: 400
            )
        }
        var request = makeRequest(path: "api/v1/stations/\(trimmedStationID)/straight-line-energy")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            StraightLineEnergyRequestPayload(
                latitude: latitude,
                longitude: longitude,
                stationLatitude: stationLatitude,
                stationLongitude: stationLongitude
            )
        )
        return request
    }

    func fetchStraightLineEnergy(
        stationID: String,
        latitude: Double,
        longitude: Double,
        stationLatitude: Double? = nil,
        stationLongitude: Double? = nil
    ) async throws -> StraightLineEnergyEstimate {
        let request = try makeStraightLineEnergyRequest(
            stationID: stationID,
            latitude: latitude,
            longitude: longitude,
            stationLatitude: stationLatitude,
            stationLongitude: stationLongitude
        )
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func fetchSendRouteSwitch() async throws -> SendRouteSwitchStatus {
        try await fetch(path: "api/v1/vehicle/route/switch")
    }

    /// Read-only route planning via NIO `energymap-multi`.
    func makePlanRouteRequest(
        _ poiList: [SendRoutePoiInput],
        includeChargeStops: Bool = true
    ) throws -> URLRequest {
        try validateRoutePOIs(poiList)
        var request = makeRequest(path: "api/v1/vehicle/route/plan")
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PlanRouteInput(poiList: poiList, includeChargeStops: includeChargeStops)
        )
        return request
    }

    func planRouteToVehicle(
        _ poiList: [SendRoutePoiInput],
        includeChargeStops: Bool = true
    ) async throws -> PlanRouteOutcome {
        let request = try makePlanRouteRequest(poiList, includeChargeStops: includeChargeStops)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    /// Single explicit POST to send a route/destination to the bound vehicle.
    /// Never auto-retried; timeout surfaces `send_route_result_unknown`.
    func makeSendRouteRequest(_ input: SendRouteInput) throws -> URLRequest {
        try validateRoutePOIs(input.poiList)
        var request = makeRequest(path: "api/v1/vehicle/route/send")
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(input)
        return request
    }

    private func validateRoutePOIs(_ poiList: [SendRoutePoiInput]) throws {
        guard !poiList.isEmpty, poiList.count <= 20 else {
            throw BackendClientError.serverFailure(
                code: "invalid_send_route_input",
                message: "poi_list must contain 1 to 20 points",
                status: 400
            )
        }
        for poi in poiList {
            let trimmedName = poi.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  poi.latitude.isFinite, poi.longitude.isFinite,
                  (-90.0...90.0).contains(poi.latitude),
                  (-180.0...180.0).contains(poi.longitude) else {
                throw BackendClientError.serverFailure(
                    code: "invalid_send_route_input",
                    message: "each poi requires a valid name and coordinates",
                    status: 400
                )
            }
        }
    }

    func sendRouteToVehicle(_ input: SendRouteInput) async throws -> SendRouteOutcome {
        let request = try makeSendRouteRequest(input)
        return try await executeSendRouteRequest(request)
    }

    func makeConfirmSendRouteRequest(token: String, btnAction: Int) throws -> URLRequest {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            throw BackendClientError.serverFailure(
                code: "confirmation_expired",
                message: "confirmation token is missing or invalid",
                status: 410
            )
        }
        var request = makeRequest(path: "api/v1/vehicle/route/send/confirm")
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ConfirmSendRouteInput(confirmationToken: trimmed, btnAction: btnAction)
        )
        return request
    }

    func confirmSendRouteToVehicle(token: String, btnAction: Int) async throws -> SendRouteOutcome {
        let request = try makeConfirmSendRouteRequest(token: token, btnAction: btnAction)
        return try await executeSendRouteRequest(request)
    }

    private func executeSendRouteRequest(_ request: URLRequest) async throws -> SendRouteOutcome {
        do {
            let (data, response) = try await session.data(for: request)
            return try decode(data: data, response: response)
        } catch let error as URLError
            where error.code == .timedOut || error.code == .networkConnectionLost {
            throw BackendClientError.serverFailure(
                code: "send_route_result_unknown",
                message: error.localizedDescription,
                status: 504
            )
        }
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
        let statusSpecial = status.data.specialStatus
        let widgetSpecial = widgetStatus.specialStatus
        let fotaStatusCode = statusSpecial?.fotaStatus ?? widgetSpecial?.fotaStatus
        let mergedSpecialFields: [String: String]? = {
            var merged = widgetSpecial?.rawFields ?? [:]
            for (k, v) in statusSpecial?.rawFields ?? [:] {
                merged[k] = v
            }
            return merged.isEmpty ? nil : merged
        }()
        return VehicleDashboard(
            vehicleID: status.data.vehicleID,
            isConnected: status.data.connectionStatus?.connected
                ?? widgetStatus.connectionStatus?.connected
                ?? false,
            stateCode: status.data.exteriorStatus?.vehicleState
                ?? widgetStatus.exteriorStatus?.vehicleState,
            mileage: status.data.exteriorStatus?.mileage
                ?? widgetStatus.exteriorStatus?.mileage,
            isSwapping: (statusSpecial?.swapping ?? widgetSpecial?.swapping ?? 0) != 0,
            isRepairing: (statusSpecial?.repairing ?? widgetSpecial?.repairing ?? 0) != 0,
            fotaStatusCode: fotaStatusCode,
            isSVTActive: (statusSpecial?.svt ?? widgetSpecial?.svt ?? 0) != 0,
            repairSampledAt: (statusSpecial?.repairSampleTime ?? widgetSpecial?.repairSampleTime)
                .flatMap(Self.positiveDateFromUnixTimestamp),
            fotaPreparingSampledAt: (statusSpecial?.preparingSampleTime ?? widgetSpecial?.preparingSampleTime)
                .flatMap(Self.positiveDateFromUnixTimestamp),
            fotaPreparingCountdownSeconds: (statusSpecial?.preparingCountdownSeconds
                ?? widgetSpecial?.preparingCountdownSeconds)
                .flatMap { $0 > 0 ? $0 : nil },
            svtSampledAt: (statusSpecial?.svtSampleTime ?? widgetSpecial?.svtSampleTime)
                .flatMap(Self.positiveDateFromUnixTimestamp),
            rawSpecialStatusFields: mergedSpecialFields,
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

    private static func positiveDateFromUnixTimestamp(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return dateFromUnixTimestamp(value)
    }

    private static func dateFromUnixTimestamp(_ value: Int64) -> Date? {
        let seconds = abs(value) < 10_000_000_000 ? TimeInterval(value) : TimeInterval(value) / 1000
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
