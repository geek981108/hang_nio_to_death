import Combine
import Foundation
import WatchConnectivity

final class WatchConnectivityCoordinator: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityCoordinator()

    @Published private(set) var hasReceivedConfiguration = false
    @Published private(set) var lastErrorMessage: String?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if !session.receivedApplicationContext.isEmpty {
            persist(session.receivedApplicationContext)
        }
    }

    func requestConfiguration() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["request": "configuration"], replyHandler: { [weak self] reply in
            self?.persist(reply)
        }) { [weak self] error in
            DispatchQueue.main.async { self?.lastErrorMessage = error.localizedDescription }
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async { self.lastErrorMessage = error.localizedDescription }
            return
        }
        guard activationState == .activated else { return }
        if !session.receivedApplicationContext.isEmpty {
            persist(session.receivedApplicationContext)
        }
        requestConfiguration()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        persist(applicationContext)
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    private func persist(_ context: [String: Any]) {
        do {
            try WatchCredentialStore.shared.save(applicationContext: context)
            DispatchQueue.main.async {
                self.hasReceivedConfiguration = true
                self.lastErrorMessage = nil
                NotificationCenter.default.post(name: .watchConfigurationDidChange, object: nil)
            }
        } catch {
            DispatchQueue.main.async {
                self.lastErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "配置同步失败。"
            }
        }
    }
}

extension Notification.Name {
    static let watchConfigurationDidChange = Notification.Name("watchConfigurationDidChange")
}
