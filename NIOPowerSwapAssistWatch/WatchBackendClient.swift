import Foundation

struct WatchVehicleProfile: Decodable, Equatable, Sendable {
    let vehicleID: String
    let displayName: String?
    let modelType: String?

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case displayName = "display_name"
        case modelType = "model_type"
    }

    var displayTitle: String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let model = modelType?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            return "NIO \(model)"
        }
        return "我的蔚来"
    }
}

struct WatchDashboard: Equatable, Sendable {
    let isConnected: Bool
    let stateOfCharge: Double?
    let remainingRange: Double?
    let isCharging: Bool
    let isSwapping: Bool
    let isRepairing: Bool
    let isFotaActive: Bool
    let isSVTActive: Bool
    let isDriving: Bool
    let lockStatusCode: Int?
    let insideTemperature: Double?

    init(
        isConnected: Bool,
        stateOfCharge: Double?,
        remainingRange: Double?,
        isCharging: Bool,
        isSwapping: Bool,
        isRepairing: Bool = false,
        isFotaActive: Bool = false,
        isSVTActive: Bool = false,
        isDriving: Bool = false,
        lockStatusCode: Int? = nil,
        insideTemperature: Double? = nil
    ) {
        self.isConnected = isConnected
        self.stateOfCharge = stateOfCharge
        self.remainingRange = remainingRange
        self.isCharging = isCharging
        self.isSwapping = isSwapping
        self.isRepairing = isRepairing
        self.isFotaActive = isFotaActive
        self.isSVTActive = isSVTActive
        self.isDriving = isDriving
        self.lockStatusCode = lockStatusCode
        self.insideTemperature = insideTemperature
    }
}

struct WatchActiveOrder: Decodable, Equatable, Sendable, Identifiable {
    let orderNo: String
    let stationName: String?
    let stationAddress: String?
    let orderStatusName: String?
    let queueNumber: Int?
    let vehiclesAhead: Int?
    let estimatedWaitMinutes: Int?
    let queueStatusText: String?

    var id: String { orderNo }

    enum CodingKeys: String, CodingKey {
        case orderNo = "order_no"
        case stationName = "station_name"
        case stationAddress = "station_address"
        case orderStatusName = "order_status_name"
        case queueNumber = "queue_number"
        case vehiclesAhead = "vehicles_ahead"
        case estimatedWaitMinutes = "estimated_wait_minutes"
        case queueStatusText = "queue_status_text"
    }
}

struct WatchStationLive: Decodable, Equatable, Sendable {
    struct Fee: Decodable, Equatable, Sendable {
        let fee: String
        let unit: String
        let currency: String
        let isTotal: Bool

        enum CodingKeys: String, CodingKey {
            case fee, unit, currency
            case isTotal = "is_total"
        }
    }

    struct Queue: Decodable, Equatable, Sendable {
        let vehiclesAhead: Int?
        let waitingDescription: String?
        let estimatedWaitMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case vehiclesAhead = "vehicles_ahead"
            case waitingDescription = "waiting_description"
            case estimatedWaitMinutes = "estimated_wait_minutes"
        }
    }

    let stationID: String
    let stationName: String
    let available75Count: Int
    let isScannable: Bool?
    let currentFees: [Fee]
    let queue: Queue?

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case stationName = "station_name"
        case available75Count = "available_75_count"
        case isScannable = "is_scannable"
        case currentFees = "current_fees"
        case queue
    }

    var allowsSwap: Bool {
        isScannable ?? true
    }

    var formattedPrice: String? {
        let total = currentFees.first(where: \.isTotal)
        let fallbackTotal = currentFees.compactMap { Double($0.fee) }.reduce(0, +)
        guard let representative = total ?? currentFees.first else { return nil }
        let amount = total.flatMap { Double($0.fee) } ?? fallbackTotal
        let amountText = amount.formatted(.number.precision(.fractionLength(2)))
        let normalizedUnit = representative.unit
            .replacingOccurrences(of: "元/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix: String
        if normalizedUnit.isEmpty {
            suffix = ""
        } else if normalizedUnit.hasPrefix("/") {
            suffix = normalizedUnit
        } else {
            suffix = "/\(normalizedUnit)"
        }
        return "\(representative.currency)\(amountText)\(suffix)"
    }

    var queueSummary: String? {
        if let desc = queue?.waitingDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            return desc
        }
        if let ahead = queue?.vehiclesAhead, ahead > 0 {
            if let wait = queue?.estimatedWaitMinutes, wait > 0 {
                return "排队 \(ahead) 辆 · 约 \(wait) 分"
            }
            return "排队 \(ahead) 辆"
        }
        return nil
    }
}

enum WatchVehicleAction: String, Sendable {
    case lock
    case unlockDoors = "unlock-doors"
    case unlockStart = "unlock-start"
    case acOn = "ac-on"
    case acOff = "ac-off"
    case guardOn = "guard-on"
    case guardOff = "guard-off"
    case find
    case findStop = "find-stop"

    var confirmation: String {
        switch self {
        case .lock: return "LOCK VEHICLE"
        case .unlockDoors: return "UNLOCK DOORS"
        case .unlockStart: return "UNLOCK AND START"
        case .acOn: return "START AC"
        case .acOff: return "STOP AC"
        case .guardOn: return "ENABLE GUARD MODE"
        case .guardOff: return "DISABLE GUARD MODE"
        case .find: return "FIND VEHICLE"
        case .findStop: return "STOP FINDING"
        }
    }
}

enum WatchBackendError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case server(String)
    case invalidControlKey
    case missingStation
    case upstreamUnavailable
    case vehicleMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "后端响应无法识别。"
        case .unauthorized: return "后端认证失败，请在 iPhone 中检查 Key。"
        case .httpStatus(let status): return "后端请求失败（HTTP \(status)）。"
        case .server(let message): return message
        case .invalidControlKey: return "请先在 iPhone 中配置有效的车控 Key。"
        case .missingStation: return "请先在 iPhone 中选择换电站。"
        case .upstreamUnavailable: return "车辆状态暂不可用。"
        case .vehicleMismatch: return "车辆状态来源不一致。"
        }
    }
}

struct WatchBackendClient: Sendable {
    let configuration: WatchBackendConfiguration
    let session: URLSession

    init(configuration: WatchBackendConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session
            ?? TemporaryBackendTLS.session(allowingUntrustedHost: configuration.baseURL.host)
    }

    func fetchDashboard() async throws -> WatchDashboard {
        async let status: VehicleStatusEnvelope = fetch(path: "api/v1/vehicle/status")
        async let widget: WidgetInfoEnvelope = fetch(path: "api/v1/vehicle/widget-info")
        let (vehicleStatus, widgetInfo) = try await (status, widget)
        guard vehicleStatus.resultCode == "success", widgetInfo.resultCode == "success" else {
            throw WatchBackendError.upstreamUnavailable
        }
        let fallback = widgetInfo.data.status
        guard vehicleStatus.data.vehicleID == fallback.vehicleID else {
            throw WatchBackendError.vehicleMismatch
        }
        let soc = vehicleStatus.data.socStatus ?? fallback.socStatus
        let statusSpecial = vehicleStatus.data.specialStatus
        let fallbackSpecial = fallback.specialStatus
        let isSwapping = (statusSpecial?.swapping ?? fallbackSpecial?.swapping ?? 0) != 0
        let isRepairing = (statusSpecial?.effectiveRepairing ?? fallbackSpecial?.effectiveRepairing ?? 0) != 0
        let isFotaActive = (statusSpecial?.fotaStatus ?? fallbackSpecial?.fotaStatus ?? 0) != 0
        let isSVTActive = (statusSpecial?.effectiveSVT ?? fallbackSpecial?.effectiveSVT ?? 0) != 0
        let vehicleState = vehicleStatus.data.exteriorStatus?.vehicleState
            ?? fallback.exteriorStatus?.vehicleState
        return WatchDashboard(
            isConnected: vehicleStatus.data.connectionStatus?.connected
                ?? fallback.connectionStatus?.connected
                ?? false,
            stateOfCharge: soc?.soc,
            remainingRange: soc?.remainingActualRange ?? soc?.remainingRange,
            isCharging: soc?.chargeState == 1,
            isSwapping: isSwapping,
            isRepairing: isRepairing,
            isFotaActive: isFotaActive,
            isSVTActive: isSVTActive,
            isDriving: !isSwapping && !isRepairing && !isFotaActive && vehicleState == 1,
            lockStatusCode: fallback.doorStatus?.vehicleLockStatus
                ?? vehicleStatus.data.doorStatus?.vehicleLockStatus,
            insideTemperature: vehicleStatus.data.hvacStatus?.temperature
                ?? fallback.hvacStatus?.temperature
        )
    }

    func fetchVehicleProfile() async throws -> WatchVehicleProfile {
        try await fetch(path: "api/v1/vehicle/profile")
    }

    func fetchActiveOrders() async throws -> [WatchActiveOrder] {
        let page: ActiveOrderPage = try await fetch(path: "api/v1/orders/active")
        return page.items
    }

    func fetchStationLive(stationID: String) async throws -> WatchStationLive {
        let trimmed = stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WatchBackendError.missingStation }
        return try await fetch(path: "api/v1/stations/\(trimmed)/live")
    }

    func performVehicleAction(
        _ action: WatchVehicleAction,
        temperature: Double? = nil,
        expandMirrors: Bool = false
    ) async throws {
        let shouldExpandMirrors = action == .guardOn && expandMirrors
        var payload: [String: Any] = [
            "action": action.rawValue,
            "confirmation": action.confirmation,
            "expand_mirrors": shouldExpandMirrors
        ]
        if shouldExpandMirrors {
            payload["mirror_confirmation"] = "EXPAND MIRRORS"
        }
        if let temperature {
            payload["temperature"] = temperature
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await send(
            path: "api/v1/vehicle/action",
            body: body,
            timeout: 90
        )
    }

    func createSwapOrder() async throws {
        guard let stationID = configuration.stationID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stationID.isEmpty else { throw WatchBackendError.missingStation }
        let body = try JSONSerialization.data(withJSONObject: [
            "station_id": stationID,
            "confirmation": "CREATE SWAP ORDER"
        ])
        _ = try await send(path: "api/v1/swap-orders", body: body, timeout: 90)
    }

    private func fetch<Response: Decodable>(path: String) async throws -> Response {
        let (data, response) = try await session.data(for: makeRequest(path: path))
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WatchBackendError.invalidResponse
        }
    }

    private func send(path: String, body: Data, timeout: TimeInterval) async throws -> Data {
        let controlKey = configuration.controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...512).contains(controlKey.count) else {
            throw WatchBackendError.invalidControlKey
        }
        var request = makeRequest(path: path)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(controlKey, forHTTPHeaderField: "X-Vehicle-Control-Key")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func makeRequest(path: String) -> URLRequest {
        let url = path.split(separator: "/").reduce(configuration.baseURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw WatchBackendError.invalidResponse
        }
        if response.statusCode == 401 { throw WatchBackendError.unauthorized }
        guard 200..<300 ~= response.statusCode else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw WatchBackendError.server(envelope.message)
            }
            throw WatchBackendError.httpStatus(response.statusCode)
        }
    }
}

private struct ErrorEnvelope: Decodable {
    let message: String
}

private struct ActiveOrderPage: Decodable {
    let items: [WatchActiveOrder]
}

private struct VehicleStatusEnvelope: Decodable {
    let resultCode: String
    let data: VehiclePayload

    enum CodingKeys: String, CodingKey {
        case resultCode = "result_code"
        case data
    }
}

private struct WidgetInfoEnvelope: Decodable {
    struct Payload: Decodable { let status: VehiclePayload }
    let resultCode: String
    let data: Payload

    enum CodingKeys: String, CodingKey {
        case resultCode = "result_code"
        case data
    }
}

private struct VehiclePayload: Decodable {
    struct ConnectionStatus: Decodable { let connected: Bool? }
    struct SpecialStatus: Decodable {
        let swapping: Int?
        let repaired: Int?
        let repairing: Int?
        let vehlRepaired: Int?
        let fotaStatus: Int?
        let svt: Int?
        let vehlSVT: Int?

        var effectiveRepairing: Int? {
            [repaired, repairing, vehlRepaired].compactMap { $0 }.first { $0 != 0 }
                ?? repaired ?? repairing ?? vehlRepaired
        }

        var effectiveSVT: Int? {
            [svt, vehlSVT].compactMap { $0 }.first { $0 != 0 } ?? svt ?? vehlSVT
        }

        enum CodingKeys: String, CodingKey {
            case swapping
            case repaired
            case repairing
            case vehlRepaired = "vehl_repaired"
            case fotaStatus = "fota_status"
            case svt
            case vehlSVT = "vehl_svt"
        }
    }
    struct ExteriorStatus: Decodable {
        let vehicleState: Int?
        enum CodingKeys: String, CodingKey {
            case vehicleState = "vehicle_state"
        }
    }
    struct DoorStatus: Decodable {
        let vehicleLockStatus: Int?
        enum CodingKeys: String, CodingKey {
            case vehicleLockStatus = "vehicle_lock_status"
        }
    }
    struct HVACStatus: Decodable {
        let temperature: Double?
    }
    struct SOCStatus: Decodable {
        let soc: Double?
        let remainingRange: Double?
        let remainingActualRange: Double?
        let chargeState: Int?

        enum CodingKeys: String, CodingKey {
            case soc
            case remainingRange = "remaining_range"
            case remainingActualRange = "remaining_actual_range"
            case chargeState = "charge_state"
        }
    }

    let vehicleID: String
    let connectionStatus: ConnectionStatus?
    let exteriorStatus: ExteriorStatus?
    let doorStatus: DoorStatus?
    let hvacStatus: HVACStatus?
    let specialStatus: SpecialStatus?
    let socStatus: SOCStatus?

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case connectionStatus = "connection_status"
        case exteriorStatus = "exterior_status"
        case doorStatus = "door_status"
        case hvacStatus = "hvac_status"
        case specialStatus = "special_status"
        case socStatus = "soc_status"
    }
}
