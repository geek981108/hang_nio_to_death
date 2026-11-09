import Foundation
import Security

struct WatchBackendConfiguration: Equatable, Sendable {
    let baseURL: URL
    let apiKey: String
    let controlKey: String
    let stationID: String?
    let stationName: String?
}

enum WatchConfigurationError: LocalizedError {
    case notConfigured
    case invalidConfiguration
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在 iPhone App 中配置后端。"
        case .invalidConfiguration: return "iPhone 发送的后端配置无效。"
        case .keychain: return "无法安全保存后端配置。"
        }
    }
}

final class WatchCredentialStore: @unchecked Sendable {
    static let shared = WatchCredentialStore()

    private let service = "com.shuto.happyvalley.watchapp.backend"
    private let accounts = ["base_url", "api_key", "control_key", "station_id", "station_name"]

    func save(applicationContext: [String: Any]) throws {
        guard (applicationContext["schema"] as? Int) == 1,
              let rawURL = applicationContext["base_url"] as? String,
              let apiKey = applicationContext["api_key"] as? String,
              let controlKey = applicationContext["control_key"] as? String,
              let url = Self.validatedURL(rawURL),
              (32...512).contains(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count),
              controlKey.isEmpty || (32...512).contains(controlKey.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
            throw WatchConfigurationError.invalidConfiguration
        }

        let values: [String: String?] = [
            "base_url": url.absoluteString,
            "api_key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "control_key": controlKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "station_id": applicationContext["station_id"] as? String,
            "station_name": applicationContext["station_name"] as? String
        ]
        for account in accounts {
            if let value = values[account] ?? nil, !value.isEmpty {
                try write(value, account: account)
            } else {
                delete(account: account)
            }
        }
    }

    func load() throws -> WatchBackendConfiguration {
        guard let rawURL = try read(account: "base_url"),
              let url = Self.validatedURL(rawURL),
              let apiKey = try read(account: "api_key"),
              (32...512).contains(apiKey.count) else {
            throw WatchConfigurationError.notConfigured
        }
        return WatchBackendConfiguration(
            baseURL: url,
            apiKey: apiKey,
            controlKey: (try read(account: "control_key")) ?? "",
            stationID: try read(account: "station_id"),
            stationName: try read(account: "station_name")
        )
    }

    private static func validatedURL(_ rawValue: String) -> URL? {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        return components.url
    }

    private func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WatchConfigurationError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw WatchConfigurationError.keychain(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw WatchConfigurationError.keychain(status) }
    }

    private func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
