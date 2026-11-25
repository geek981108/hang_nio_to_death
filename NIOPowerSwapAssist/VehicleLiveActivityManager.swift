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

    var hasActiveActivity: Bool {
        !Activity<NIOVehicleLiveActivityAttributes>.activities.isEmpty
    }

    /// Synchronizes the system Live Activity with the latest vehicle/order state.
    /// Returns whether a Live Activity is active after synchronization.
    func synchronize(plan: VehicleLiveActivityPlan?, forceStart: Bool = false) async -> Bool {
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
        manuallyDismissedSessionKey = sessionKey
        lastPushedSessionKey = nil
        lastPushedState = nil
        for activity in Activity<NIOVehicleLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
