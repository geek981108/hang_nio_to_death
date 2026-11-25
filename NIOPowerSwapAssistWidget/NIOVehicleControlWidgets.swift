import AppIntents
import Foundation
import Security
import SwiftUI
import WidgetKit

enum ControlCenterVehicleAction: String, Sendable, CaseIterable {
  case lock
  case unlockStart = "unlock-start"
  case acOn = "ac-on"
  case guardOn = "guard-on"
  case find

  static func forLockToggle(targetLocked: Bool) -> Self {
    targetLocked ? .lock : .unlockStart
  }

  var confirmation: String {
    switch self {
    case .lock: return "LOCK VEHICLE"
    case .unlockStart: return "UNLOCK AND START"
    case .acOn: return "START AC"
    case .guardOn: return "ENABLE GUARD MODE"
    case .find: return "FIND VEHICLE"
    }
  }

  var title: String {
    switch self {
    case .lock: return "锁车"
    case .unlockStart: return "解锁并启动"
    case .acOn: return "开空调"
    case .guardOn: return "开守卫"
    case .find: return "寻车"
    }
  }

  var systemImage: String {
    switch self {
    case .lock: return "lock.fill"
    case .unlockStart: return "lock.open.fill"
    case .acOn: return "fan.fill"
    case .guardOn: return "shield.lefthalf.filled"
    case .find: return "horn.blast.fill"
    }
  }

  var defaultTemperature: Double? {
    self == .acOn ? 22.0 : nil
  }

  var expandsMirrors: Bool {
    self == .guardOn
  }

  func makeRequest(
    baseURL: URL,
    apiKey: String,
    controlKey: String
  ) throws -> URLRequest {
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedControlKey = controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (32...512).contains(trimmedAPIKey.count) else {
      throw ControlCenterActionError.notConfigured
    }
    guard (32...512).contains(trimmedControlKey.count) else {
      throw ControlCenterActionError.controlKeyUnavailable
    }
    let url = ["api", "v1", "vehicle", "action"].reduce(baseURL) { partial, component in
      partial.appendingPathComponent(component)
    }
    var payload: [String: Any] = [
      "action": rawValue,
      "confirmation": confirmation,
      "expand_mirrors": expandsMirrors,
    ]
    if let temperature = defaultTemperature {
      payload["temperature"] = temperature
    }
    if expandsMirrors {
      payload["mirror_confirmation"] = "EXPAND MIRRORS"
    }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
    request.setValue(trimmedControlKey, forHTTPHeaderField: "X-Vehicle-Control-Key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    return request
  }
}

enum ControlCenterActionError: LocalizedError, Equatable {
  case notConfigured
  case controlKeyUnavailable
  case invalidResponse
  case unauthorized
  case server(String)
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "请先在 App 中配置车辆后端。"
    case .controlKeyUnavailable: return "请先在 App 后端设置中保存有效的车控 Key。"
    case .invalidResponse: return "后端响应无法识别。"
    case .unauthorized: return "后端或车控 Key 认证失败。"
    case .server(let message): return message
    case .httpStatus(let code): return "车控请求失败（HTTP \(code)）。"
    }
  }
}

private enum ControlCenterKeychainStorage {
  static let service = "com.shuto.happyvalley.vehicle-backend"
  static let accessGroup = "A8686RABF4.com.shuto.happyvalley.shared"
  static let baseURLAccount = "vehicle-backend-base-url"
  static let apiKeyAccount = "vehicle-backend-api-key"
  static let controlKeyAccount = "vehicle-control-api-key"
  static let lockStateAccount = "vehicle-last-known-lock-state"

  struct Credentials: Sendable {
    let baseURL: URL
    let apiKey: String
    let controlKey: String
  }

  static func loadReadCredentials() throws -> (baseURL: URL, apiKey: String) {
    guard let rawURL = readString(account: baseURLAccount),
      let components = URLComponents(string: rawURL),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let baseURL = components.url,
      let apiKey = readString(account: apiKeyAccount),
      (32...512).contains(apiKey.count)
    else {
      throw ControlCenterActionError.notConfigured
    }
    return (baseURL, apiKey)
  }

  static func load() throws -> Credentials {
    let (baseURL, apiKey) = try loadReadCredentials()
    guard let controlKey = readString(account: controlKeyAccount),
      (32...512).contains(controlKey.count)
    else {
      throw ControlCenterActionError.controlKeyUnavailable
    }
    return Credentials(baseURL: baseURL, apiKey: apiKey, controlKey: controlKey)
  }

  static func readString(
    account: String,
    service: String = service,
    accessGroup: String? = accessGroup
  ) -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func writeString(
    _ value: String,
    account: String,
    service: String = service,
    accessGroup: String? = accessGroup
  ) {
    let data = Data(value.utf8)
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    let attributes: [String: Any] = [kSecValueData as String: data]
    if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
      return
    }
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(addQuery as CFDictionary, nil)
  }
}

enum ControlCenterLockStateCache {
  static func load(
    service: String = ControlCenterKeychainStorage.service,
    accessGroup: String? = ControlCenterKeychainStorage.accessGroup
  ) -> Bool? {
    guard let raw = ControlCenterKeychainStorage.readString(
      account: ControlCenterKeychainStorage.lockStateAccount,
      service: service,
      accessGroup: accessGroup
    ) else { return nil }
    if raw == "1" { return true }
    if raw == "0" { return false }
    return nil
  }

  /// Persists the latest known lock state in the shared Keychain group.
  /// Returns `true` when the stored value changed.
  @discardableResult
  static func save(
    _ isLocked: Bool,
    service: String = ControlCenterKeychainStorage.service,
    accessGroup: String? = ControlCenterKeychainStorage.accessGroup
  ) -> Bool {
    if load(service: service, accessGroup: accessGroup) == isLocked {
      return false
    }
    ControlCenterKeychainStorage.writeString(
      isLocked ? "1" : "0",
      account: ControlCenterKeychainStorage.lockStateAccount,
      service: service,
      accessGroup: accessGroup
    )
    return true
  }
}

enum ControlCenterVehicleExecutor {
  private struct ErrorEnvelope: Decodable {
    let message: String
  }

  private struct WidgetLockInfoResponse: Decodable {
    struct Payload: Decodable {
      struct Status: Decodable {
        struct DoorStatus: Decodable {
          let vehicleLockStatus: Int?

          enum CodingKeys: String, CodingKey {
            case vehicleLockStatus = "vehicle_lock_status"
          }
        }

        let doorStatus: DoorStatus?

        enum CodingKeys: String, CodingKey {
          case doorStatus = "door_status"
        }
      }

      let status: Status
    }

    let resultCode: String
    let data: Payload

    enum CodingKeys: String, CodingKey {
      case resultCode = "result_code"
      case data
    }
  }

  static func fetchIsLocked(session: URLSession? = nil) async throws -> Bool {
    let (baseURL, apiKey) = try ControlCenterKeychainStorage.loadReadCredentials()
    let url = ["api", "v1", "vehicle", "widget-info"].reduce(baseURL) { partial, component in
      partial.appendingPathComponent(component)
    }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let activeSession = session
      ?? TemporaryBackendTLS.session(allowingUntrustedHost: baseURL.host)
    do {
      let (data, response) = try await activeSession.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        200..<300 ~= httpResponse.statusCode
      else {
        throw ControlCenterActionError.invalidResponse
      }
      let decoded = try JSONDecoder().decode(WidgetLockInfoResponse.self, from: data)
      guard decoded.resultCode == "success",
        let lockStatus = decoded.data.status.doorStatus?.vehicleLockStatus
      else {
        throw ControlCenterActionError.invalidResponse
      }
      let isLocked = lockStatus == 1
      ControlCenterLockStateCache.save(isLocked)
      return isLocked
    } catch {
      if let cached = ControlCenterLockStateCache.load() {
        return cached
      }
      throw error
    }
  }

  /// Sends a single explicit vehicle control POST without retrying.
  static func perform(
    _ action: ControlCenterVehicleAction,
    session: URLSession? = nil
  ) async throws {
    let credentials = try ControlCenterKeychainStorage.load()
    let request = try action.makeRequest(
      baseURL: credentials.baseURL,
      apiKey: credentials.apiKey,
      controlKey: credentials.controlKey
    )
    let activeSession = session
      ?? TemporaryBackendTLS.session(allowingUntrustedHost: credentials.baseURL.host)
    let (data, response) = try await activeSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ControlCenterActionError.invalidResponse
    }
    if httpResponse.statusCode == 401 {
      throw ControlCenterActionError.unauthorized
    }
    guard 200..<300 ~= httpResponse.statusCode else {
      if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
        throw ControlCenterActionError.server(envelope.message)
      }
      throw ControlCenterActionError.httpStatus(httpResponse.statusCode)
    }
    WidgetCenter.shared.reloadTimelines(ofKind: NIOWidgetKind.vehicle)
    if action == .lock || action == .unlockStart {
      ControlCenterLockStateCache.save(action == .lock)
      ControlCenter.shared.reloadControls(ofKind: NIOControlLockWidget.kind)
    }
  }
}

struct NIOToggleVehicleLockIntent: SetValueIntent {
  static var title: LocalizedStringResource = "控制中心：切换车辆门锁"
  static var description = IntentDescription("已锁车时直接解锁并启动，未锁车时远程锁车。")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  @Parameter(title: "锁定车辆")
  var value: Bool

  func perform() async throws -> some IntentResult {
    try await ControlCenterVehicleExecutor.perform(
      ControlCenterVehicleAction.forLockToggle(targetLocked: value)
    )
    return .result()
  }
}

struct NIOVehicleLockStatusProvider: ControlValueProvider {
  var previewValue: Bool { true }

  func currentValue() async throws -> Bool {
    try await ControlCenterVehicleExecutor.fetchIsLocked()
  }
}

struct NIOControlACOnIntent: AppIntent {
  static var title: LocalizedStringResource = "控制中心：开启空调"
  static var description = IntentDescription("从控制中心直接以 22℃ 开启车内空调。")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  func perform() async throws -> some IntentResult {
    try await ControlCenterVehicleExecutor.perform(.acOn)
    return .result()
  }
}

struct NIOControlGuardOnIntent: AppIntent {
  static var title: LocalizedStringResource = "控制中心：开启守卫模式"
  static var description = IntentDescription("从控制中心直接开启守卫模式并展开后视镜。")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  func perform() async throws -> some IntentResult {
    try await ControlCenterVehicleExecutor.perform(.guardOn)
    return .result()
  }
}

struct NIOControlFindIntent: AppIntent {
  static var title: LocalizedStringResource = "控制中心：寻车"
  static var description = IntentDescription("从控制中心直接发送鸣笛闪灯寻车指令。")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  func perform() async throws -> some IntentResult {
    try await ControlCenterVehicleExecutor.perform(.find)
    return .result()
  }
}

struct NIOControlLockWidget: ControlWidget {
  static let kind = "com.shuto.happyvalley.control.lock"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind, provider: NIOVehicleLockStatusProvider()) { isLocked in
      ControlWidgetToggle(
        "车辆门锁",
        isOn: isLocked,
        action: NIOToggleVehicleLockIntent()
      ) { isOn in
        Label(
          isOn ? "已锁车" : "未锁车",
          systemImage: isOn ? "lock.fill" : "lock.open.fill"
        )
      }
      .tint(isLocked ? .green : .orange)
    }
    .displayName("NIO 锁车 / 解锁")
    .description("同键切换门锁：已锁车时轻点解锁并启动，未锁车时轻点远程锁车。")
  }
}

struct NIOControlACOnWidget: ControlWidget {
  static let kind = "com.shuto.happyvalley.control.ac-on"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: NIOControlACOnIntent()) {
        Label("开空调 22℃", systemImage: "fan.fill")
      }
    }
    .displayName("NIO 开空调")
    .description("在控制中心一键开启 22℃ 座舱空调。")
  }
}

struct NIOControlGuardOnWidget: ControlWidget {
  static let kind = "com.shuto.happyvalley.control.guard-on"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: NIOControlGuardOnIntent()) {
        Label("开守卫", systemImage: "shield.lefthalf.filled")
      }
    }
    .displayName("NIO 开守卫")
    .description("在控制中心一键开启守卫模式并展开后视镜。")
  }
}

struct NIOControlFindWidget: ControlWidget {
  static let kind = "com.shuto.happyvalley.control.find"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: NIOControlFindIntent()) {
        Label("寻车", systemImage: "horn.blast.fill")
      }
    }
    .displayName("NIO 寻车")
    .description("在控制中心一键触发鸣笛闪灯寻车。")
  }
}
