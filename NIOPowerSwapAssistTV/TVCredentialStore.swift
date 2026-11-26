import Foundation
import Security

struct TVStoredSettings: Equatable, Sendable {
    let baseURLString: String
    let apiKey: String
    let controlKey: String
    let stationID: String?
    let stationName: String?

    var hasControlKey: Bool {
        (32...512).contains(controlKey.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }
}

final class TVCredentialStore {
    static let shared = TVCredentialStore()

    private let service: String
    private let defaults: UserDefaults

    private let baseURLAccount = "tv.backend.base_url"
    private let apiKeyAccount = "tv.backend.api_key"
    private let controlKeyAccount = "tv.backend.control_key"
    private let stationIDKey = "tv.station.id.v1"
    private let stationNameKey = "tv.station.name.v1"
    private let routePresetsKey = "tv.route.presets.v1"
    private let ambientModeKey = "tv.ambient.prefer_dimmed.v1"

    init(
        service: String = "com.shuto.happyvalley.tv.credentials",
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
    }

    func loadSettings() -> TVStoredSettings? {
        guard let baseURL = readKeychainString(account: baseURLAccount),
              let apiKey = readKeychainString(account: apiKeyAccount),
              !baseURL.isEmpty,
              !apiKey.isEmpty else {
            return nil
        }
        let controlKey = readKeychainString(account: controlKeyAccount) ?? ""
        let stationID = defaults.string(forKey: stationIDKey)?.nilIfBlank
        let stationName = defaults.string(forKey: stationNameKey)?.nilIfBlank
        return TVStoredSettings(
            baseURLString: baseURL,
            apiKey: apiKey,
            controlKey: controlKey,
            stationID: stationID,
            stationName: stationName
        )
    }

    func configuration() throws -> BackendConfiguration {
        guard let settings = loadSettings() else {
            throw BackendClientError.invalidBaseURL
        }
        return try BackendConfiguration(
            baseURLString: settings.baseURLString,
            apiKey: settings.apiKey
        )
    }

    func save(
        baseURLString: String,
        apiKey: String,
        controlKey: String,
        stationID: String? = nil,
        stationName: String? = nil,
        routePresets: [TVPairingRoutePreset]? = nil
    ) throws {
        let validated = try BackendConfiguration(baseURLString: baseURLString, apiKey: apiKey)
        let normalizedControl = controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedControl.isEmpty, !(32...512).contains(normalizedControl.count) {
            throw BackendClientError.invalidControlKey
        }

        try writeKeychainString(validated.baseURL.absoluteString, account: baseURLAccount)
        try writeKeychainString(validated.apiKey, account: apiKeyAccount)
        if normalizedControl.isEmpty {
            deleteKeychainItem(account: controlKeyAccount)
        } else {
            try writeKeychainString(normalizedControl, account: controlKeyAccount)
        }

        if let stationID = stationID?.nilIfBlank {
            defaults.set(stationID, forKey: stationIDKey)
        }
        if let stationName = stationName?.nilIfBlank {
            defaults.set(stationName, forKey: stationNameKey)
        }
        if let routePresets {
            saveRoutePresets(routePresets)
        }
    }

    func applyPairingPayload(_ payload: TVPairingPayload) throws {
        try save(
            baseURLString: payload.baseURLString,
            apiKey: payload.apiKey,
            controlKey: payload.controlKey ?? "",
            stationID: payload.stationID,
            stationName: payload.stationName,
            routePresets: payload.routePresets
        )
    }

    func saveSelectedStation(id: String?, name: String?) {
        if let id = id?.nilIfBlank {
            defaults.set(id, forKey: stationIDKey)
        } else {
            defaults.removeObject(forKey: stationIDKey)
        }
        if let name = name?.nilIfBlank {
            defaults.set(name, forKey: stationNameKey)
        } else {
            defaults.removeObject(forKey: stationNameKey)
        }
    }

    func loadRoutePresets() -> [TVPairingRoutePreset] {
        guard let data = defaults.data(forKey: routePresetsKey),
              let decoded = try? JSONDecoder().decode([TVPairingRoutePreset].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveRoutePresets(_ presets: [TVPairingRoutePreset]) {
        let trimmed = Array(presets.prefix(12))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: routePresetsKey)
        }
    }

    var prefersDimmedAmbientHUD: Bool {
        get { defaults.bool(forKey: ambientModeKey) }
        set { defaults.set(newValue, forKey: ambientModeKey) }
    }

    func clearAll() {
        for account in [baseURLAccount, apiKeyAccount, controlKeyAccount] {
            deleteKeychainItem(account: account)
        }
        defaults.removeObject(forKey: stationIDKey)
        defaults.removeObject(forKey: stationNameKey)
        defaults.removeObject(forKey: routePresetsKey)
    }

    private func readKeychainString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychainString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BackendClientError.invalidResponse
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BackendClientError.invalidResponse
        }
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
