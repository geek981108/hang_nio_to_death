import Foundation
import Security

/// Optional TLS client certificate (mTLS) for the configured backend.
///
/// When the backend sits behind an edge that requires a client certificate
/// (for example Cloudflare API Shield mTLS), requests without one are rejected
/// before they reach the server. The user imports a `.p12` in the backend
/// settings; it is kept in the shared Keychain and presented only to the
/// configured backend host.
final class BackendClientCertificate: @unchecked Sendable {
    static let shared = BackendClientCertificate()

    private let lock = NSLock()
    private var loaded = false
    private var cached: (identity: SecIdentity, certificates: [SecCertificate])?
    private let settingsStore: BackendSettingsStore

    init(settingsStore: BackendSettingsStore = .shared) {
        self.settingsStore = settingsStore
    }

    /// Credential to answer a client-certificate challenge, or nil when no
    /// usable certificate is installed.
    func credential() -> URLCredential? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let identity = settingsStore.loadClientIdentity() {
                var certificate: SecCertificate?
                SecIdentityCopyCertificate(identity, &certificate)
                cached = (identity, certificate.map { [$0] } ?? [])
            }
        }
        guard let cached else { return nil }
        // Pass the chain explicitly; otherwise CFNetwork resolves the identity
        // back from the Keychain and can end up with an empty private key.
        return URLCredential(
            identity: cached.identity,
            certificates: cached.certificates,
            persistence: .forSession
        )
    }

    /// Drops the cached identity and every pooled TLS session, so the next
    /// request performs a fresh handshake with the current certificate.
    func invalidate() {
        lock.lock()
        loaded = false
        cached = nil
        lock.unlock()
        BackendURLSession.reset()
    }
}

/// Answers TLS challenges for the configured backend host only.
enum BackendAuthentication {
    static func response(
        for challenge: URLAuthenticationChallenge,
        allowedHost: String?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard let allowedHost, space.host.lowercased() == allowedHost.lowercased() else {
            return (.performDefaultHandling, nil)
        }
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = BackendClientCertificate.shared.credential() {
                return (.useCredential, credential)
            }
            return (.performDefaultHandling, nil)
        case NSURLAuthenticationMethodServerTrust:
            if TemporaryBackendTLS.isEnabled, let trust = space.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}

/// One delegate-backed session per backend host, reused across clients.
enum BackendURLSession {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]

    static func session(for host: String?) -> URLSession {
        guard let host = host?.lowercased(), !host.isEmpty else { return .shared }
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[host] { return session }
        let session = URLSession(
            configuration: .default,
            delegate: BackendSessionDelegate(allowedHost: host),
            delegateQueue: nil
        )
        sessions[host] = session
        return session
    }

    static func reset() {
        lock.lock()
        let old = sessions
        sessions = [:]
        lock.unlock()
        old.values.forEach { $0.finishTasksAndInvalidate() }
    }
}

private final class BackendSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = BackendAuthentication.response(
            for: challenge,
            allowedHost: allowedHost
        )
        completionHandler(disposition, credential)
    }
}

extension BackendSettingsStore {
    /// Object identifiers of PKCS#12 encryptions that `SecPKCS12Import` cannot
    /// read on iOS (it fails or crashes): RC2 and PBES2/AES.
    private static let unsupportedP12OIDs: [[UInt8]] = [
        [0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x06], // pbeWithSHA1And40BitRC2-CBC
        [0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x01], // pbeWithSHA1And128BitRC2-CBC
        [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D], // PBES2
    ]

    static func p12UsesUnsupportedEncryption(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return unsupportedP12OIDs.contains { oid in
            guard oid.count <= bytes.count else { return false }
            return (0...(bytes.count - oid.count)).contains { index in
                bytes[index..<(index + oid.count)].elementsEqual(oid)
            }
        }
    }
}

enum ClientCertificateError: LocalizedError {
    case unsupportedEncryption
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedEncryption:
            return "此 p12 的加密格式 iOS 无法读取（RC2 / AES）。请用 3DES 重新导出：openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA256"
        case .unreadable:
            return "无法读取证书：密码错误，或文件里没有可用的证书与私钥。"
        }
    }
}
