import Foundation

/// Temporary compatibility switch for the user-configured backend only.
/// Set `isEnabled` to false (or remove this file) after the backend certificate
/// chain has been repaired. Other hosts continue to use normal system trust.
/// The challenge handling itself lives in `BackendAuthentication`, which also
/// presents the optional TLS client certificate.
enum TemporaryBackendTLS {
    static let isEnabled = true

    static func session(allowingUntrustedHost host: String?) -> URLSession {
        BackendURLSession.session(for: host)
    }
}
