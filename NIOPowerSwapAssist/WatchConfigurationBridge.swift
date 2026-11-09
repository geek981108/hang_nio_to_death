import Foundation
import WatchConnectivity

struct WatchConfigurationPayload: Equatable, Sendable {
    let baseURLString: String
    let apiKey: String
    let controlKey: String
    let stationID: String?
    let stationName: String?

    fileprivate var applicationContext: [String: Any] {
        var context: [String: Any] = [
            "schema": 1,
            "base_url": baseURLString,
            "api_key": apiKey,
            "control_key": controlKey
        ]
        if let stationID { context["station_id"] = stationID }
        if let stationName { context["station_name"] = stationName }
        return context
    }
}

final class WatchConfigurationBridge: NSObject, WCSessionDelegate {
    static let shared = WatchConfigurationBridge()

    private var pendingConfiguration: WatchConfigurationPayload?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func sync(_ configuration: WatchConfigurationPayload) {
        guard WCSession.isSupported() else { return }
        pendingConfiguration = configuration
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        if session.activationState == .activated {
            try? session.updateApplicationContext(configuration.applicationContext)
        } else {
            session.activate()
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated else { return }
        let configuration = pendingConfiguration
            ?? BackendSettingsStore.shared.watchConfiguration()
        try? session.updateApplicationContext(configuration.applicationContext)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["request"] as? String == "configuration" else {
            replyHandler(["error": "unsupported_request"])
            return
        }
        replyHandler(BackendSettingsStore.shared.watchConfiguration().applicationContext)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
