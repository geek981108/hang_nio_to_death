import Foundation

struct WatchDashboard: Equatable, Sendable {
    let isConnected: Bool
    let stateOfCharge: Double?
    let remainingRange: Double?
    let isCharging: Bool
    let isSwapping: Bool
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

enum WatchVehicleAction: String, Sendable {
    case unlockDoors = "unlock-doors"
    case find
    case findStop = "find-stop"

    var confirmation: String {
        switch self {
        case .unlockDoors: return "UNLOCK DOORS"
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
    var session: URLSession = .shared

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
        return WatchDashboard(
            isConnected: vehicleStatus.data.connectionStatus?.connected
                ?? fallback.connectionStatus?.connected
                ?? false,
            stateOfCharge: soc?.soc,
            remainingRange: soc?.remainingActualRange ?? soc?.remainingRange,
            isCharging: soc?.chargeState == 1,
            isSwapping: (vehicleStatus.data.specialStatus?.swapping
                ?? fallback.specialStatus?.swapping
                ?? 0) != 0
        )
    }

    func fetchActiveOrders() async throws -> [WatchActiveOrder] {
        let page: ActiveOrderPage = try await fetch(path: "api/v1/orders/active")
        return page.items
    }

    func performVehicleAction(_ action: WatchVehicleAction) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "action": action.rawValue,
            "confirmation": action.confirmation,
            "expand_mirrors": false
        ])
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
    struct SpecialStatus: Decodable { let swapping: Int? }
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
    let specialStatus: SpecialStatus?
    let socStatus: SOCStatus?

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case connectionStatus = "connection_status"
        case specialStatus = "special_status"
        case socStatus = "soc_status"
    }
}
