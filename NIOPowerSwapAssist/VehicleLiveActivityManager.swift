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

    private var manuallyDismissedSessionKey: String?
    private var lastPushedSessionKey: String?
    private var lastPushedState: NIOVehicleLiveActivityAttributes.ContentState?
    #if DEBUG
    private var isSimulationActive = false
    #endif

    var hasActiveActivity: Bool {
        !Activity<NIOVehicleLiveActivityAttributes>.activities.isEmpty
    }

    /// Synchronizes the system Live Activity with the latest vehicle/order state.
    /// Returns whether a Live Activity is active after synchronization.
    func synchronize(plan: VehicleLiveActivityPlan?, forceStart: Bool = false) async -> Bool {
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
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return false
        }

        if forceStart {
            manuallyDismissedSessionKey = nil
        }

        if manuallyDismissedSessionKey == plan.sessionKey {
            return !activities.isEmpty
        }

        if let existing = activities.first(where: { $0.attributes.sessionKey == plan.sessionKey }) {
            // End any stale activities from previous sessions.
            for stale in activities where stale.id != existing.id {
                await stale.end(nil, dismissalPolicy: .immediate)
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
        for stale in activities {
            await stale.end(nil, dismissalPolicy: .immediate)
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
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            lastPushedSessionKey = plan.sessionKey
            lastPushedState = plan.state
            return true
        } catch {
            return false
        }
    }

    func dismissCurrent(sessionKey: String?) async {
        #if DEBUG
        isSimulationActive = false
        #endif
        manuallyDismissedSessionKey = sessionKey
        lastPushedSessionKey = nil
        lastPushedState = nil
        for activity in Activity<NIOVehicleLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
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
