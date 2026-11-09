import Foundation

/// Temporary compatibility switch for the user-configured backend only.
/// Remove this file (or set `isEnabled` to false) after the backend certificate
/// chain has been repaired. Other hosts continue to use normal system trust.
enum TemporaryBackendTLS {
    static let isEnabled = true

    static func session(allowingUntrustedHost host: String?) -> URLSession {
        guard isEnabled, let host, !host.isEmpty else { return .shared }
        let delegate = BackendTrustDelegate(allowedHost: host)
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }
}

private final class BackendTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        guard TemporaryBackendTLS.isEnabled,
              protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              protectionSpace.host.lowercased() == allowedHost,
              let trust = protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
