import Foundation
import Security
import WidgetKit

final class BackendSettingsStore {
    static let shared = BackendSettingsStore()

    private static let sharedKeychainService = "com.shuto.happyvalley.vehicle-backend"
    private static let sharedKeychainAccessGroup = "A8686RABF4.com.shuto.happyvalley.shared"

    private let defaults: UserDefaults
    private let keychainService: String
    private let keychainAccessGroup: String?
    private let legacyKeychainService: String
    private let permitsLegacyMigration: Bool
    private let baseURLKey = "vehicleBackendBaseURL"
    private let baseURLAccount = "vehicle-backend-base-url"
    private let apiKeyAccount = "vehicle-backend-api-key"
    private let controlKeyAccount = "vehicle-control-api-key"
    private let stationIDAccount = "widget-station-id"
    private let stationNameAccount = "widget-station-name"
    private let clientCertificateAccount = "client-certificate-p12"
    private let clientCertificatePasswordAccount = "client-certificate-password"
    private let clientCertificateVersionAccount = "client-certificate-version"
    /// Bumped when the stored format changes; older entries are discarded
    /// instead of being parsed.
    private let clientCertificateVersion = "4"

    init(
        defaults: UserDefaults = .standard,
        keychainService: String? = nil,
        keychainAccessGroup: String? = BackendSettingsStore.sharedKeychainAccessGroup
    ) {
        self.defaults = defaults
        permitsLegacyMigration = keychainService == nil
        legacyKeychainService = "\(Bundle.main.bundleIdentifier ?? "NIOPowerSwapAssist").vehicle-backend"
        self.keychainService = keychainService ?? Self.sharedKeychainService
        self.keychainAccessGroup = keychainService == nil ? keychainAccessGroup : nil
        if permitsLegacyMigration { migrateLegacyConfigurationIfNeeded() }
    }

    var baseURLString: String {
        if let data = try? readKeychainData(
            service: keychainService,
            account: baseURLAccount,
            accessGroup: keychainAccessGroup
        ), let value = String(data: data, encoding: .utf8) {
            return value
        }
        return defaults.string(forKey: baseURLKey) ?? "http://127.0.0.1:8080"
    }

    func apiKey() -> String {
        if let data = try? readKeychainData(
            service: keychainService,
            account: apiKeyAccount,
            accessGroup: keychainAccessGroup
        ) {
            return String(data: data, encoding: .utf8) ?? ""
        }

        guard permitsLegacyMigration,
              let legacyData = try? readKeychainData(
            service: legacyKeychainService,
            account: apiKeyAccount,
            accessGroup: nil
        ) else { return "" }
        try? writeKeychainData(
            legacyData,
            service: keychainService,
            account: apiKeyAccount,
            accessGroup: keychainAccessGroup
        )
        let data = legacyData
        return String(data: data, encoding: .utf8) ?? ""
    }

    func controlKey() -> String {
        guard let data = try? readKeychainData(
            service: keychainService,
            account: controlKeyAccount,
            accessGroup: keychainAccessGroup
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func configuration() throws -> BackendConfiguration {
        try BackendConfiguration(baseURLString: baseURLString, apiKey: apiKey())
    }

    func save(baseURLString: String, apiKey: String, controlKey: String) throws {
        let configuration = try BackendConfiguration(
            baseURLString: baseURLString,
            apiKey: apiKey
        )
        let normalizedControlKey = controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedControlKey.isEmpty,
           !(32...512).contains(normalizedControlKey.count) {
            throw BackendClientError.invalidControlKey
        }
        try writeKeychainData(
            Data(configuration.baseURL.absoluteString.utf8),
            service: keychainService,
            account: baseURLAccount,
            accessGroup: keychainAccessGroup
        )
        try writeKeychainData(
            Data(configuration.apiKey.utf8),
            service: keychainService,
            account: apiKeyAccount,
            accessGroup: keychainAccessGroup
        )
        if normalizedControlKey.isEmpty {
            deleteKeychainData(
                service: keychainService,
                account: controlKeyAccount,
                accessGroup: keychainAccessGroup
            )
        } else {
            try writeKeychainData(
                Data(normalizedControlKey.utf8),
                service: keychainService,
                account: controlKeyAccount,
                accessGroup: keychainAccessGroup
            )
        }
        defaults.set(configuration.baseURL.absoluteString, forKey: baseURLKey)
        WidgetCenter.shared.reloadAllTimelines()
        syncWatchConfiguration()
    }

    func saveWidgetStation(id: String, name: String) throws {
        try writeKeychainData(
            Data(id.utf8),
            service: keychainService,
            account: stationIDAccount,
            accessGroup: keychainAccessGroup
        )
        try writeKeychainData(
            Data(name.utf8),
            service: keychainService,
            account: stationNameAccount,
            accessGroup: keychainAccessGroup
        )
        WidgetCenter.shared.reloadAllTimelines()
        syncWatchConfiguration()
    }

    func clearWidgetStation() {
        for account in [stationIDAccount, stationNameAccount] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account
            ]
            if let keychainAccessGroup {
                query[kSecAttrAccessGroup as String] = keychainAccessGroup
            }
            SecItemDelete(query as CFDictionary)
        }
        WidgetCenter.shared.reloadAllTimelines()
        syncWatchConfiguration()
    }

    // MARK: - TLS client certificate (mTLS)

    var hasClientCertificate: Bool {
        (try? readKeychainData(
            service: keychainService,
            account: clientCertificateAccount,
            accessGroup: keychainAccessGroup
        )) != nil
    }

    /// Validates and stores a PKCS#12 client certificate with its password.
    func saveClientCertificate(p12Data: Data, password: String) throws {
        guard !Self.p12UsesUnsupportedEncryption(p12Data) else {
            throw ClientCertificateError.unsupportedEncryption
        }
        guard Self.importIdentity(p12Data: p12Data, password: password) != nil else {
            throw ClientCertificateError.unreadable
        }
        removePersistedIdentities()
        try writeKeychainData(
            p12Data,
            service: keychainService,
            account: clientCertificateAccount,
            accessGroup: keychainAccessGroup
        )
        try writeKeychainData(
            Data(password.utf8),
            service: keychainService,
            account: clientCertificatePasswordAccount,
            accessGroup: keychainAccessGroup
        )
        try writeKeychainData(
            Data(clientCertificateVersion.utf8),
            service: keychainService,
            account: clientCertificateVersionAccount,
            accessGroup: keychainAccessGroup
        )
    }

    func clearClientCertificate() {
        for account in [
            clientCertificateAccount,
            clientCertificatePasswordAccount,
            clientCertificateVersionAccount,
        ] {
            try? deleteKeychainData(
                service: keychainService,
                account: account,
                accessGroup: keychainAccessGroup
            )
        }
        removePersistedIdentities()
    }

    /// Identity backed by the Keychain, ready to answer a TLS challenge.
    func loadClientIdentity() -> SecIdentity? {
        let storedVersion = (try? readKeychainData(
            service: keychainService,
            account: clientCertificateVersionAccount,
            accessGroup: keychainAccessGroup
        )).flatMap { String(data: $0, encoding: .utf8) }
        guard storedVersion == clientCertificateVersion else {
            if storedVersion != nil { clearClientCertificate() }
            return nil
        }
        guard let p12 = try? readKeychainData(
            service: keychainService,
            account: clientCertificateAccount,
            accessGroup: keychainAccessGroup
        ) else { return nil }
        guard !Self.p12UsesUnsupportedEncryption(p12) else {
            clearClientCertificate()
            return nil
        }
        guard let passwordData = try? readKeychainData(
            service: keychainService,
            account: clientCertificatePasswordAccount,
            accessGroup: keychainAccessGroup
        ), let password = String(data: passwordData, encoding: .utf8),
              let identity = Self.importIdentity(p12Data: p12, password: password) else {
            return nil
        }
        return persistedIdentity(for: identity)
    }

    /// In-memory identity from a PKCS#12 blob, accepted only when its private
    /// key is usable (an empty key makes the TLS stack crash later).
    private static func importIdentity(p12Data: Data, password: String) -> SecIdentity? {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(p12Data as CFData, options, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String],
              CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else {
            return nil
        }
        let identity = raw as! SecIdentity
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecKeyCopyExternalRepresentation(key, nil) != nil else {
            return nil
        }
        return identity
    }

    /// CFNetwork resolves the presented identity against the Keychain; an
    /// identity that only lives in memory reaches the handshake without its
    /// private key. Store the certificate and key, then read the pair back.
    private func persistedIdentity(for identity: SecIdentity) -> SecIdentity? {
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
              let key else { return nil }
        let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: Self.clientIdentityLabel,
            kSecAttrAccessible as String: accessible,
        ] as CFDictionary, nil)
        SecItemAdd([
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrLabel as String: Self.clientIdentityLabel,
            kSecAttrAccessible as String: accessible,
        ] as CFDictionary, nil)
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: Self.clientIdentityLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let item,
              CFGetTypeID(item) == SecIdentityGetTypeID() else {
            // Older installs stored the pair without a label.
            var unlabeled: CFTypeRef?
            guard SecItemCopyMatching([
                kSecClass as String: kSecClassIdentity,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &unlabeled) == errSecSuccess, let unlabeled,
                  CFGetTypeID(unlabeled) == SecIdentityGetTypeID() else { return nil }
            return (unlabeled as! SecIdentity)
        }
        return (item as! SecIdentity)
    }

    private func removePersistedIdentities() {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            SecItemDelete([
                kSecClass as String: itemClass,
                kSecAttrLabel as String: Self.clientIdentityLabel,
            ] as CFDictionary)
        }
    }

    private static let clientIdentityLabel = "backend-client-certificate"

    func watchConfiguration() -> WatchConfigurationPayload {
        WatchConfigurationPayload(
            baseURLString: baseURLString,
            apiKey: apiKey(),
            controlKey: controlKey(),
            stationID: readString(account: stationIDAccount),
            stationName: readString(account: stationNameAccount)
        )
    }

    private func syncWatchConfiguration() {
        WatchConfigurationBridge.shared.sync(watchConfiguration())
    }

    private func readString(account: String) -> String? {
        guard let data = try? readKeychainData(
            service: keychainService,
            account: account,
            accessGroup: keychainAccessGroup
        ), let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func migrateLegacyConfigurationIfNeeded() {
        guard keychainAccessGroup != nil else { return }

        if (try? readKeychainData(
            service: keychainService,
            account: baseURLAccount,
            accessGroup: keychainAccessGroup
        )) == nil,
           let legacyURL = defaults.string(forKey: baseURLKey) {
            try? writeKeychainData(
                Data(legacyURL.utf8),
                service: keychainService,
                account: baseURLAccount,
                accessGroup: keychainAccessGroup
            )
        }

        guard (try? readKeychainData(
            service: keychainService,
            account: apiKeyAccount,
            accessGroup: keychainAccessGroup
        )) == nil,
              let legacyData = try? readKeychainData(
                service: legacyKeychainService,
                account: apiKeyAccount,
                accessGroup: nil
              ) else { return }
        try? writeKeychainData(
            legacyData,
            service: keychainService,
            account: apiKeyAccount,
            accessGroup: keychainAccessGroup
        )
    }

    private func readKeychainData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data
    }

    private func writeKeychainData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private func deleteKeychainData(
        service: String,
        account: String,
        accessGroup: String?
    ) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        SecItemDelete(query as CFDictionary)
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "无法安全保存后端 API Key（Keychain \(status)）。"
    }
}
