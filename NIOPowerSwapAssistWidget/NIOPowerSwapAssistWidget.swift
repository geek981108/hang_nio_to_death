import Foundation
import Security
import SwiftUI
import WidgetKit

private enum SharedBackendStorage {
  static let keychainService = "com.shuto.happyvalley.vehicle-backend"
  static let baseURLAccount = "vehicle-backend-base-url"
  static let apiKeyAccount = "vehicle-backend-api-key"
  static let stationIDAccount = "widget-station-id"
  static let stationNameAccount = "widget-station-name"
  static let keychainAccessGroup = "A8686RABF4.com.shuto.happyvalley.shared"
}

private struct WidgetBackendConfiguration: Sendable {
  let baseURL: URL
  let apiKey: String
  let station: WidgetStationSelection?

  static func load() throws -> Self {
    guard let rawURL = try readKeychainString(account: SharedBackendStorage.baseURLAccount),
      let components = URLComponents(string: rawURL),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let baseURL = components.url
    else {
      throw WidgetBackendError.notConfigured
    }

    guard let apiKey = try readKeychainString(account: SharedBackendStorage.apiKeyAccount),
      (32...512).contains(apiKey.count)
    else {
      throw WidgetBackendError.notConfigured
    }
    let stationID = try readKeychainString(account: SharedBackendStorage.stationIDAccount)
    let stationName = try readKeychainString(account: SharedBackendStorage.stationNameAccount)
    let station = stationID.map { stationID in
      let displayName = stationName.flatMap { $0.isEmpty ? nil : $0 } ?? stationID
      return WidgetStationSelection(id: stationID, name: displayName)
    }
    return Self(baseURL: baseURL, apiKey: apiKey, station: station)
  }

  private static func readKeychainString(account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SharedBackendStorage.keychainService,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: SharedBackendStorage.keychainAccessGroup,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw WidgetBackendError.credentialsUnavailable
    }
    return value
  }
}

private struct WidgetStationSelection: Sendable {
  let id: String
  let name: String
}

private enum WidgetBackendError: LocalizedError {
  case notConfigured
  case credentialsUnavailable
  case invalidResponse
  case unauthorized
  case httpStatus(Int)
  case upstreamFailure
  case vehicleMismatch

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "请先在 App 中配置后端"
    case .credentialsUnavailable: return "无法读取共享凭证"
    case .invalidResponse: return "后端响应无法识别"
    case .unauthorized: return "后端认证失败"
    case .httpStatus(let status): return "后端错误 HTTP \(status)"
    case .upstreamFailure: return "车辆数据暂不可用"
    case .vehicleMismatch: return "车辆数据不一致"
    }
  }
}

private struct NIOVehicleStatusResponse: Decodable, Sendable {
  let resultCode: String
  let data: Payload

  enum CodingKeys: String, CodingKey {
    case resultCode = "result_code"
    case data
  }

  struct Payload: Decodable, Sendable {
    let vehicleID: String
    let connectionStatus: ConnectionStatus?
    let exteriorStatus: ExteriorStatus?
    let specialStatus: SpecialStatus?
    let socStatus: SOCStatus?
    let hvacStatus: HVACStatus?

    enum CodingKeys: String, CodingKey {
      case vehicleID = "vehicle_id"
      case connectionStatus = "connection_status"
      case exteriorStatus = "exterior_status"
      case specialStatus = "special_status"
      case socStatus = "soc_status"
      case hvacStatus = "hvac_status"
    }
  }

  struct ConnectionStatus: Decodable, Sendable { let connected: Bool? }

  struct ExteriorStatus: Decodable, Sendable {
    let vehicleState: Int?

    enum CodingKeys: String, CodingKey {
      case vehicleState = "vehicle_state"
    }
  }

  struct SpecialStatus: Decodable, Sendable {
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

  struct SOCStatus: Decodable, Sendable {
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

  struct HVACStatus: Decodable, Sendable {
    let outsideTemperature: Double?

    enum CodingKeys: String, CodingKey {
      case outsideTemperature = "outside_temperature"
    }
  }
}

private struct NIOWidgetInfoResponse: Decodable, Sendable {
  let resultCode: String
  let data: Payload

  enum CodingKeys: String, CodingKey {
    case resultCode = "result_code"
    case data
  }

  struct Payload: Decodable, Sendable { let status: Status }

  struct Status: Decodable, Sendable {
    struct DoorStatus: Decodable, Sendable {
      let vehicleLockStatus: Int?

      enum CodingKeys: String, CodingKey {
        case vehicleLockStatus = "vehicle_lock_status"
      }
    }

    let vehicleID: String
    let connectionStatus: NIOVehicleStatusResponse.ConnectionStatus?
    let exteriorStatus: NIOVehicleStatusResponse.ExteriorStatus?
    let specialStatus: NIOVehicleStatusResponse.SpecialStatus?
    let socStatus: NIOVehicleStatusResponse.SOCStatus?
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
}

private struct WidgetBackendClient: Sendable {
  let configuration: WidgetBackendConfiguration
  let session: URLSession

  init(configuration: WidgetBackendConfiguration, session: URLSession? = nil) {
    self.configuration = configuration
    self.session = session
      ?? TemporaryBackendTLS.session(allowingUntrustedHost: configuration.baseURL.host)
  }

  func fetchSnapshot() async throws -> WidgetVehicleSnapshot {
    async let status: NIOVehicleStatusResponse = fetch(path: "api/v1/vehicle/status")
    async let widget: NIOWidgetInfoResponse = fetch(path: "api/v1/vehicle/widget-info")
    async let station = fetchStation()
    let (vehicleStatus, widgetInfo, stationStatus) = try await (status, widget, station)

    guard vehicleStatus.resultCode == "success", widgetInfo.resultCode == "success" else {
      throw WidgetBackendError.upstreamFailure
    }
    let widgetStatus = widgetInfo.data.status
    guard vehicleStatus.data.vehicleID == widgetStatus.vehicleID else {
      throw WidgetBackendError.vehicleMismatch
    }

    let statusSOC = vehicleStatus.data.socStatus
    let widgetSOC = widgetStatus.socStatus
    if let lockStatus = widgetStatus.doorStatus?.vehicleLockStatus,
      ControlCenterLockStateCache.save(lockStatus == 1)
    {
      ControlCenter.shared.reloadControls(ofKind: NIOControlLockWidget.kind)
    }
    let statusSpecial = vehicleStatus.data.specialStatus
    let widgetSpecial = widgetStatus.specialStatus
    return WidgetVehicleSnapshot(
      isConnected: vehicleStatus.data.connectionStatus?.connected
        ?? widgetStatus.connectionStatus?.connected
        ?? false,
      stateCode: vehicleStatus.data.exteriorStatus?.vehicleState
        ?? widgetStatus.exteriorStatus?.vehicleState,
      isSwapping: (statusSpecial?.swapping ?? widgetSpecial?.swapping ?? 0) != 0,
      isRepairing: (statusSpecial?.effectiveRepairing ?? widgetSpecial?.effectiveRepairing ?? 0) != 0,
      isFotaActive: (statusSpecial?.fotaStatus ?? widgetSpecial?.fotaStatus ?? 0) != 0,
      isSVTActive: (statusSpecial?.effectiveSVT ?? widgetSpecial?.effectiveSVT ?? 0) != 0,
      stateOfCharge: statusSOC?.soc ?? widgetSOC?.soc,
      remainingRange: statusSOC?.remainingRange ?? widgetSOC?.remainingRange,
      remainingActualRange: statusSOC?.remainingActualRange
        ?? widgetSOC?.remainingActualRange,
      chargeStateCode: statusSOC?.chargeState ?? widgetSOC?.chargeState,
      outsideTemperature: vehicleStatus.data.hvacStatus?.outsideTemperature,
      updatedAt: Date(),
      station: stationStatus.map(makeStationSnapshot),
      hasStationSelection: configuration.station != nil
    )
  }

  private func fetchStation() async -> WidgetStationLivePayload? {
    guard let selection = configuration.station else { return nil }
    return try? await fetch(path: "api/v1/stations/\(selection.id)/live")
  }

  private func makeStationSnapshot(_ status: WidgetStationLivePayload) -> WidgetStationSnapshot {
    status.makeSnapshot(selectedName: configuration.station?.name)
  }

  private func fetch<Response: Decodable>(path: String) async throws -> Response {
    let url = path.split(separator: "/").reduce(configuration.baseURL) { partialURL, component in
      partialURL.appendingPathComponent(String(component))
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WidgetBackendError.invalidResponse
    }
    if httpResponse.statusCode == 401 { throw WidgetBackendError.unauthorized }
    guard 200..<300 ~= httpResponse.statusCode else {
      throw WidgetBackendError.httpStatus(httpResponse.statusCode)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw WidgetBackendError.invalidResponse
    }
  }
}

private struct VehicleWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> VehicleWidgetEntry {
    VehicleWidgetEntry(date: Date(), state: .loaded(Self.sampleSnapshot))
  }

  func getSnapshot(in context: Context, completion: @escaping (VehicleWidgetEntry) -> Void) {
    guard !context.isPreview else {
      completion(placeholder(in: context))
      return
    }
    Task { completion(await loadEntry()) }
  }

  func getTimeline(
    in context: Context, completion: @escaping (Timeline<VehicleWidgetEntry>) -> Void
  ) {
    Task {
      let entry = await loadEntry()
      let interval: TimeInterval
      switch entry.state {
      case .loaded(let snapshot): interval = snapshot.preferredRefreshInterval
      case .unconfigured: interval = 60 * 60
      case .failed: interval = 5 * 60
      }
      completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(interval))))
    }
  }

  private func loadEntry() async -> VehicleWidgetEntry {
    do {
      let configuration = try WidgetBackendConfiguration.load()
      let snapshot = try await WidgetBackendClient(configuration: configuration).fetchSnapshot()
      return VehicleWidgetEntry(date: Date(), state: .loaded(snapshot))
    } catch WidgetBackendError.notConfigured {
      return VehicleWidgetEntry(date: Date(), state: .unconfigured)
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "刷新失败"
      return VehicleWidgetEntry(date: Date(), state: .failed(message))
    }
  }

  static let sampleSnapshot = WidgetVehicleSnapshot(
    isConnected: true,
    stateCode: 2,
    isSwapping: false,
    stateOfCharge: 82,
    remainingRange: 438,
    remainingActualRange: 396,
    chargeStateCode: 0,
    outsideTemperature: 22.5,
    updatedAt: Date(),
    station: WidgetStationSnapshot(
      name: "天津红星美凯龙滨海店",
      price: "¥1.47/度",
      available75Count: 5,
      batteries: [
        WidgetStationBattery(
          id: "sample-4", slotID: 4, stateOfCharge: 100, productionDate: "2025-03-30"),
        WidgetStationBattery(
          id: "sample-5", slotID: 5, stateOfCharge: 100, productionDate: "2025-09-27"),
        WidgetStationBattery(
          id: "sample-6", slotID: 6, stateOfCharge: 100, productionDate: "2024-10-01"),
      ]
    ),
    hasStationSelection: true
  )
}

private struct NIOVehicleWidget: Widget {
  let kind = "NIOVehicleWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: VehicleWidgetProvider()) { entry in
      VehicleWidgetView(entry: entry)
    }
    .configurationDisplayName("NIO 车辆状态")
    .description("车辆状态、当前换电站费率与 75 kWh 可用电池，支持主屏幕与锁屏显示。")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .accessoryCircular,
      .accessoryRectangular,
      .accessoryInline,
    ])
  }
}

@main
struct NIOPowerSwapAssistWidgetBundle: WidgetBundle {
  var body: some Widget {
    NIOVehicleWidget()
    NIOVehicleLiveActivityWidget()
    NIOControlLockWidget()
    NIOControlACOnWidget()
    NIOControlGuardOnWidget()
    NIOControlFindWidget()
  }
}

#Preview("车辆 · 小号", as: .systemSmall) {
  NIOVehicleWidget()
} timeline: {
  VehicleWidgetEntry(date: .now, state: .loaded(VehicleWidgetProvider.sampleSnapshot))
  VehicleWidgetEntry(date: .now, state: .unconfigured)
}

#Preview("车辆与换电站 · 中号", as: .systemMedium) {
  NIOVehicleWidget()
} timeline: {
  VehicleWidgetEntry(date: .now, state: .loaded(VehicleWidgetProvider.sampleSnapshot))
  VehicleWidgetEntry(date: .now, state: .failed("网络暂时不可用"))
}

#Preview("锁屏 · 圆形", as: .accessoryCircular) {
  NIOVehicleWidget()
} timeline: {
  VehicleWidgetEntry(date: .now, state: .loaded(VehicleWidgetProvider.sampleSnapshot))
}

#Preview("锁屏 · 矩形", as: .accessoryRectangular) {
  NIOVehicleWidget()
} timeline: {
  VehicleWidgetEntry(date: .now, state: .loaded(VehicleWidgetProvider.sampleSnapshot))
}

#Preview("锁屏 · 单行", as: .accessoryInline) {
  NIOVehicleWidget()
} timeline: {
  VehicleWidgetEntry(date: .now, state: .loaded(VehicleWidgetProvider.sampleSnapshot))
}
