import ActivityKit
import Foundation

struct VehicleLiveActivityPlan: Equatable, Sendable {
    let sessionKey: String
    let vehicleName: String
    let state: NIOVehicleLiveActivityAttributes.ContentState
}

enum VehicleLiveActivityPlanner {
    static func plan(
        dashboard: VehicleDashboard?,
        activeOrders: [ActiveServiceOrder],
        currentChargingEnergyKWh: Double?,
        vehicleName: String,
        now: Date = Date()
    ) -> VehicleLiveActivityPlan? {
        if let order = activeOrders.first {
            let title = nonEmpty(order.stationName) ?? "蔚来换电站"
            let subtitle = nonEmpty(order.queueStatusText)
                ?? nonEmpty(order.orderStatusName)
                ?? "换电排队中"
            return VehicleLiveActivityPlan(
                sessionKey: "swap:\(order.orderNo)",
                vehicleName: vehicleName,
                state: NIOVehicleLiveActivityAttributes.ContentState(
                    mode: .swapQueue,
                    title: title,
                    subtitle: subtitle,
                    updatedAt: now,
                    orderNo: order.orderNo,
                    queueNumber: order.queueNumber,
                    vehiclesAhead: order.vehiclesAhead,
                    estimatedWaitMinutes: order.estimatedWaitMinutes,
                    stateOfCharge: dashboard?.stateOfCharge,
                    chargeLimitPercent: nil,
                    chargingPowerKW: nil,
                    remainingRangeKm: dashboard?.remainingActualRange ?? dashboard?.remainingRange,
                    chargedEnergyKWh: nil
                )
            )
        }

        if let dashboard, dashboard.isSwapping {
            return VehicleLiveActivityPlan(
                sessionKey: "swap-active:\(dashboard.vehicleID)",
                vehicleName: vehicleName,
                state: NIOVehicleLiveActivityAttributes.ContentState(
                    mode: .swapQueue,
                    title: "正在换电",
                    subtitle: "换电站正在为车辆更换电池",
                    updatedAt: now,
                    orderNo: nil,
                    queueNumber: nil,
                    vehiclesAhead: 0,
                    estimatedWaitMinutes: nil,
                    stateOfCharge: dashboard.stateOfCharge,
                    chargeLimitPercent: nil,
                    chargingPowerKW: nil,
                    remainingRangeKm: dashboard.remainingActualRange ?? dashboard.remainingRange,
                    chargedEnergyKWh: nil
                )
            )
        }

        if let dashboard, dashboard.chargeStateCode == 1 {
            let powerKW: Double? = dashboard.chargingPower.flatMap { watts in
                guard watts.isFinite, watts > 0 else { return nil }
                return (watts / 1_000.0 * 10.0).rounded() / 10.0
            }
            let subtitle: String
            if let limit = dashboard.chargeLimitPercent, limit.isFinite {
                subtitle = "充电中 · 上限 \(Int(limit.rounded()))%"
            } else {
                subtitle = "车辆充电中"
            }
            return VehicleLiveActivityPlan(
                sessionKey: "charging:\(dashboard.vehicleID)",
                vehicleName: vehicleName,
                state: NIOVehicleLiveActivityAttributes.ContentState(
                    mode: .charging,
                    title: "正在充电",
                    subtitle: subtitle,
                    updatedAt: now,
                    orderNo: nil,
                    queueNumber: nil,
                    vehiclesAhead: nil,
                    estimatedWaitMinutes: nil,
                    stateOfCharge: dashboard.stateOfCharge,
                    chargeLimitPercent: dashboard.chargeLimitPercent,
                    chargingPowerKW: powerKW,
                    remainingRangeKm: dashboard.remainingActualRange ?? dashboard.remainingRange,
                    chargedEnergyKWh: currentChargingEnergyKWh
                )
            )
        }

        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

@MainActor
final class VehicleLiveActivityManager {
    static let shared = VehicleLiveActivityManager()

    private static let deviceIDDefaultsKey = "live_activity_device_id.v1"

    private struct CachedActivityToken {
        let token: String
        let sessionKey: String
        let mode: String
    }

    private var manuallyDismissedSessionKey: String?
    private var lastPushedSessionKey: String?
    private var lastPushedState: NIOVehicleLiveActivityAttributes.ContentState?

    private var isObservingPushTokens = false
    private var pushToStartTask: Task<Void, Never>?
    private var activityUpdatesTask: Task<Void, Never>?
    private var activityTokenTasks: [String: Task<Void, Never>] = [:]
    private var activityStateTasks: [String: Task<Void, Never>] = [:]
    private var cachedPushToStartToken: String?
    private var cachedActivityTokens: [String: CachedActivityToken] = [:]
    private var lastUploadedSignature: [String: String] = [:]
    private(set) var lastTokenUploadedAt: Date?
    private(set) var lastTokenUploadError: String?

    #if DEBUG
    private var isSimulationActive = false
    #endif

    var hasActiveActivity: Bool {
        !Activity<NIOVehicleLiveActivityAttributes>.activities.isEmpty
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var hasPushToStartToken: Bool {
        cachedPushToStartToken != nil
    }

    var activeActivityCount: Int {
        Activity<NIOVehicleLiveActivityAttributes>.activities.count
    }

    var activeActivityPushTokenCount: Int {
        cachedActivityTokens.count
    }

    var activeActivitySessionKeys: [String] {
        Activity<NIOVehicleLiveActivityAttributes>.activities.map(\.attributes.sessionKey)
    }

    var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.deviceIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: Self.deviceIDDefaultsKey)
        return generated
    }

    nonisolated static var currentAPNsEnvironment: LiveActivityAPNsEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    nonisolated static func hexEncodedPushToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts observing iOS 17.2+ Push-to-Start tokens, remotely/locally created Live Activities,
    /// per-activity update tokens, and activity lifecycle ends so the Rust backend can remotely
    /// start, continuously update, and end Live Activities over APNs.
    func startPushTokenObservation() {
        guard !isObservingPushTokens else { return }
        isObservingPushTokens = true

        if #available(iOS 17.2, *) {
            pushToStartTask = Task { [weak self] in
                for await tokenData in Activity<NIOVehicleLiveActivityAttributes>.pushToStartTokenUpdates {
                    guard !Task.isCancelled, let self else { break }
                    let hex = Self.hexEncodedPushToken(tokenData)
                    self.cachedPushToStartToken = hex
                    await self.uploadPushToStartToken(hex, force: false)
                }
            }
        }

        for activity in Activity<NIOVehicleLiveActivityAttributes>.activities {
            observe(activity: activity)
        }

        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<NIOVehicleLiveActivityAttributes>.activityUpdates {
                guard !Task.isCancelled, let self else { break }
                self.observe(activity: activity)
            }
        }
    }

    /// Re-uploads any cached Push-to-Start and active Live Activity update tokens to the currently
    /// configured backend (for example after saving backend settings or returning to the foreground).
    func syncRegisteredTokensIfNeeded(force: Bool = false) async {
        startPushTokenObservation()
        if let startToken = cachedPushToStartToken {
            await uploadPushToStartToken(startToken, force: force)
        }
        for activity in Activity<NIOVehicleLiveActivityAttributes>.activities {
            observe(activity: activity)
            if let existing = activity.pushToken {
                let hex = Self.hexEncodedPushToken(existing)
                let mode = activity.content.state.mode.rawValue
                cachedActivityTokens[activity.id] = CachedActivityToken(
                    token: hex,
                    sessionKey: activity.attributes.sessionKey,
                    mode: mode
                )
            }
            if let cached = cachedActivityTokens[activity.id] {
                await uploadActivityUpdateToken(
                    activityID: activity.id,
                    token: cached.token,
                    sessionKey: cached.sessionKey,
                    mode: cached.mode,
                    force: force
                )
            }
        }
    }

    private func observe(activity: Activity<NIOVehicleLiveActivityAttributes>) {
        let activityID = activity.id
        let sessionKey = activity.attributes.sessionKey

        if let initialToken = activity.pushToken {
            let hex = Self.hexEncodedPushToken(initialToken)
            let mode = activity.content.state.mode.rawValue
            cachedActivityTokens[activityID] = CachedActivityToken(
                token: hex,
                sessionKey: sessionKey,
                mode: mode
            )
            Task { [weak self] in
                await self?.uploadActivityUpdateToken(
                    activityID: activityID,
                    token: hex,
                    sessionKey: sessionKey,
                    mode: mode,
                    force: false
                )
            }
        }

        if activityTokenTasks[activityID] == nil {
            activityTokenTasks[activityID] = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    guard !Task.isCancelled, let self else { break }
                    let hex = Self.hexEncodedPushToken(tokenData)
                    let mode = activity.content.state.mode.rawValue
                    self.cachedActivityTokens[activityID] = CachedActivityToken(
                        token: hex,
                        sessionKey: sessionKey,
                        mode: mode
                    )
                    await self.uploadActivityUpdateToken(
                        activityID: activityID,
                        token: hex,
                        sessionKey: sessionKey,
                        mode: mode,
                        force: false
                    )
                }
            }
        }

        if activityStateTasks[activityID] == nil {
            activityStateTasks[activityID] = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled, let self else { break }
                    if state == .ended || state == .dismissed {
                        self.cleanupObservedActivity(activityID: activityID)
                        await self.unregisterActivityUpdateToken(activityID: activityID)
                        break
                    }
                }
            }
        }
    }

    private func cleanupObservedActivity(activityID: String) {
        activityTokenTasks.removeValue(forKey: activityID)?.cancel()
        activityStateTasks.removeValue(forKey: activityID)?.cancel()
        cachedActivityTokens.removeValue(forKey: activityID)
        lastUploadedSignature.removeValue(forKey: "activity:\(activityID)")
    }

    private func uploadPushToStartToken(_ token: String, force: Bool) async {
        guard !token.isEmpty,
              let config = try? BackendSettingsStore.shared.configuration() else {
            return
        }
        let signature = "\(config.baseURL.absoluteString)|\(config.apiKey.hashValue)|\(token)"
        if !force, lastUploadedSignature["start"] == signature {
            return
        }
        let client = BackendClient(configuration: config)
        let registration = LiveActivityTokenRegistration(
            deviceID: deviceID,
            tokenKind: .pushToStart,
            pushToken: token,
            bundleID: Bundle.main.bundleIdentifier,
            apnsEnvironment: Self.currentAPNsEnvironment
        )
        do {
            _ = try await client.registerLiveActivityToken(registration)
            lastUploadedSignature["start"] = signature
            lastTokenUploadedAt = Date()
            lastTokenUploadError = nil
        } catch {
            lastTokenUploadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func uploadActivityUpdateToken(
        activityID: String,
        token: String,
        sessionKey: String,
        mode: String,
        force: Bool
    ) async {
        guard !token.isEmpty,
              let config = try? BackendSettingsStore.shared.configuration() else {
            return
        }
        let cacheKey = "activity:\(activityID)"
        let signature = "\(config.baseURL.absoluteString)|\(config.apiKey.hashValue)|\(token)|\(sessionKey)|\(mode)"
        if !force, lastUploadedSignature[cacheKey] == signature {
            return
        }
        let client = BackendClient(configuration: config)
        let registration = LiveActivityTokenRegistration(
            deviceID: deviceID,
            tokenKind: .activityUpdate,
            pushToken: token,
            activityID: activityID,
            sessionKey: sessionKey,
            activityMode: mode,
            bundleID: Bundle.main.bundleIdentifier,
            apnsEnvironment: Self.currentAPNsEnvironment
        )
        do {
            _ = try await client.registerLiveActivityToken(registration)
            lastUploadedSignature[cacheKey] = signature
            lastTokenUploadedAt = Date()
            lastTokenUploadError = nil
        } catch {
            lastTokenUploadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unregisterActivityUpdateToken(activityID: String) async {
        guard let config = try? BackendSettingsStore.shared.configuration() else {
            return
        }
        let client = BackendClient(configuration: config)
        let input = LiveActivityTokenDeleteInput(
            deviceID: deviceID,
            tokenKind: .activityUpdate,
            activityID: activityID
        )
        _ = try? await client.deleteLiveActivityToken(input)
    }

    /// Synchronizes the system Live Activity with the latest vehicle/order state.
    /// Returns whether a Live Activity is active after synchronization.
    func synchronize(plan: VehicleLiveActivityPlan?, forceStart: Bool = false) async -> Bool {
        startPushTokenObservation()
        #if DEBUG
        if isSimulationActive {
            return hasActiveActivity
        }
        #endif
        return await applyPlan(plan, forceStart: forceStart)
    }

    private func applyPlan(_ plan: VehicleLiveActivityPlan?, forceStart: Bool) async -> Bool {
        let activities = Activity<NIOVehicleLiveActivityAttributes>.activities

        guard let plan else {
            manuallyDismissedSessionKey = nil
            lastPushedSessionKey = nil
            lastPushedState = nil
            // Keep backend-driven simulation activities (`sim:*`) alive so foreground refreshes
            // do not prematurely terminate an active APNs push simulation.
            for activity in activities where !activity.attributes.sessionKey.hasPrefix("sim:") {
                await endActivityAndUnregister(activity)
            }
            return !Activity<NIOVehicleLiveActivityAttributes>.activities.isEmpty
        }

        if forceStart {
            manuallyDismissedSessionKey = nil
        }

        if manuallyDismissedSessionKey == plan.sessionKey {
            return !activities.isEmpty
        }

        if let existing = activities.first(where: { $0.attributes.sessionKey == plan.sessionKey }) {
            observe(activity: existing)
            // End any stale activities from previous sessions.
            for stale in activities where stale.id != existing.id && !stale.attributes.sessionKey.hasPrefix("sim:") {
                await endActivityAndUnregister(stale)
            }
            if lastPushedSessionKey == plan.sessionKey,
               let lastPushedState,
               lastPushedState.hasSameDisplayedContent(as: plan.state) {
                return true
            }
            let content = ActivityContent(
                state: plan.state,
                staleDate: Date().addingTimeInterval(20 * 60)
            )
            await existing.update(content)
            lastPushedSessionKey = plan.sessionKey
            lastPushedState = plan.state
            return true
        }

        // Session changed: end older activities before starting the new one.
        for stale in activities where !stale.attributes.sessionKey.hasPrefix("sim:") || plan.sessionKey.hasPrefix("sim:") {
            await endActivityAndUnregister(stale)
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return false
        }

        let attributes = NIOVehicleLiveActivityAttributes(
            sessionKey: plan.sessionKey,
            vehicleName: plan.vehicleName
        )
        let content = ActivityContent(
            state: plan.state,
            staleDate: Date().addingTimeInterval(20 * 60)
        )
        let created: Activity<NIOVehicleLiveActivityAttributes>
        do {
            // Request an APNs push token so the Rust backend can keep updating this activity
            // even after the app moves to the background. Fall back to local-only when push
            // tokens are unavailable (e.g. Simulator or unsigned builds).
            created = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
        } catch {
            do {
                created = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                return false
            }
        }
        observe(activity: created)
        lastPushedSessionKey = plan.sessionKey
        lastPushedState = plan.state
        return true
    }

    private func endActivityAndUnregister(_ activity: Activity<NIOVehicleLiveActivityAttributes>) async {
        let activityID = activity.id
        cleanupObservedActivity(activityID: activityID)
        await activity.end(nil, dismissalPolicy: .immediate)
        await unregisterActivityUpdateToken(activityID: activityID)
    }

    func dismissCurrent(sessionKey: String?) async {
        #if DEBUG
        isSimulationActive = false
        #endif
        manuallyDismissedSessionKey = sessionKey
        lastPushedSessionKey = nil
        lastPushedState = nil
        for activity in Activity<NIOVehicleLiveActivityAttributes>.activities {
            await endActivityAndUnregister(activity)
        }
    }

    #if DEBUG
    enum DebugSimulationPreset: String {
        case swap
        case swapReady = "swap-ready"
        case charging
        case end

        init?(rawValueInsensitive: String) {
            switch rawValueInsensitive.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "swap", "swap-queue", "swap_queue", "queue":
                self = .swap
            case "swap-ready", "swap_ready", "ready", "swapping":
                self = .swapReady
            case "charging", "charge":
                self = .charging
            case "end", "stop", "off", "clear":
                self = .end
            default:
                return nil
            }
        }
    }

    static func debugSimulationPresetFromLaunchArgs() -> DebugSimulationPreset? {
        let prefix = "--live-activity-demo="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return DebugSimulationPreset(rawValueInsensitive: String(arg.dropFirst(prefix.count)))
    }

    @discardableResult
    func handleDebugURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "niopowerswapassist",
              url.host?.lowercased() == "debug",
              url.path.lowercased() == "/live-activity" else {
            return false
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            }
        )
        guard let rawMode = query["mode"],
              let preset = DebugSimulationPreset(rawValueInsensitive: rawMode) else {
            return false
        }
        Task {
            await applyDebugSimulation(preset, query: query)
        }
        return true
    }

    func applyDebugSimulation(
        _ preset: DebugSimulationPreset,
        query: [String: String] = [:]
    ) async {
        if preset == .end {
            isSimulationActive = false
            await dismissCurrent(sessionKey: nil)
            return
        }
        isSimulationActive = true
        let now = Date()
        let plan: VehicleLiveActivityPlan
        switch preset {
        case .swap:
            let ahead = Int(query["ahead"] ?? "") ?? 2
            let wait = Int(query["wait"] ?? "") ?? 9
            let queueNo = Int(query["queue"] ?? "") ?? 4
            let soc = Double(query["soc"] ?? "") ?? 24
            plan = VehicleLiveActivityPlan(
                sessionKey: "debug-live-activity:swap",
                vehicleName: "我的 ET5T",
                state: NIOVehicleLiveActivityAttributes.ContentState(
                    mode: .swapQueue,
                    title: query["station"] ?? "天津滨海万达换电站",
                    subtitle: ahead == 0 ? "已到你换电 · 请准备进站" : "换电排队中 · 前方 \(ahead) 辆",
                    updatedAt: now,
                    orderNo: "DEBUG-SWAP-001",
                    queueNumber: queueNo,
                    vehiclesAhead: ahead,
                    estimatedWaitMinutes: wait,
                    stateOfCharge: soc,
                    chargeLimitPercent: nil,
                    chargingPowerKW: nil,
                    remainingRangeKm: 108,
                    chargedEnergyKWh: nil
                )
            )
        case .swapReady:
            let queueNo = Int(query["queue"] ?? "") ?? 4
            plan = VehicleLiveActivityPlan(
                sessionKey: "debug-live-activity:swap",
                vehicleName: "我的 ET5T",
                state: NIOVehicleLiveActivityAttributes.ContentState(
                    mode: .swapQueue,
                    title: query["station"] ?? "天津滨海万达换电站",
                    subtitle: "换电站已就绪 · 请驶入换电车位",
                    updatedAt: now,
                    orderNo: "DEBUG-SWAP-001",
                    queueNumber: queueNo,
                    vehiclesAhead: 0,
                    estimatedWaitMinutes: 0,
                    stateOfCharge: 24,
                    chargeLimitPercent: nil,
                    chargingPowerKW: nil,
                    remainingRangeKm: 108,
                    chargedEnergyKWh: nil
                )
            )
        case .charging:
            let soc = Double(query["soc"] ?? "") ?? 68
            let limit = Double(query["limit"] ?? "") ?? 90
            let power = Double(query["power"] ?? "") ?? 76.5
            let energy = Double(query["energy"] ?? "") ?? 18.4
            let range = Double(query["range"] ?? "") ?? 312
            plan = VehicleLiveActivityPlan(
                sessionKey: "debug-live-activity:charging",
                vehicleName: "我的 ET5T",
                state: NIOVehicleLiveActivityAttributes.ContentState(
                    mode: .charging,
                    title: "正在充电",
                    subtitle: "充电中 · 上限 \(Int(limit.rounded()))%",
                    updatedAt: now,
                    orderNo: nil,
                    queueNumber: nil,
                    vehiclesAhead: nil,
                    estimatedWaitMinutes: nil,
                    stateOfCharge: soc,
                    chargeLimitPercent: limit,
                    chargingPowerKW: power,
                    remainingRangeKm: range,
                    chargedEnergyKWh: energy
                )
            )
        case .end:
            return
        }
        _ = await applyPlan(plan, forceStart: true)
    }
    #endif
}
