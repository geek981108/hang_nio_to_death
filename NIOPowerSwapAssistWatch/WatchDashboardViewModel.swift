import Combine
import Foundation
import WidgetKit

@MainActor
final class WatchDashboardViewModel: ObservableObject {
    enum PendingCommand: Identifiable {
        case find
        case stopFinding
        case unlockDoors
        case createSwapOrder

        var id: String {
            switch self {
            case .find: return "find"
            case .stopFinding: return "stop-finding"
            case .unlockDoors: return "unlock-doors"
            case .createSwapOrder: return "create-swap-order"
            }
        }

        var title: String {
            switch self {
            case .find: return "开始寻车？"
            case .stopFinding: return "停止寻车？"
            case .unlockDoors: return "解锁车门？"
            case .createSwapOrder: return "发起换电？"
            }
        }

        var message: String {
            switch self {
            case .find: return "将向车辆发送一次鸣笛闪灯指令。"
            case .stopFinding: return "将发送一次停止寻车指令。"
            case .unlockDoors: return "这是高风险操作，将立即解锁车辆。"
            case .createSwapOrder: return "将为 iPhone 中当前选择的换电站创建一次真实订单。"
            }
        }
    }

    @Published private(set) var dashboard: WatchDashboard?
    @Published private(set) var activeOrder: WatchActiveOrder?
    @Published private(set) var stationName: String?
    @Published private(set) var hasStation = false
    @Published private(set) var hasControlKey = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPerformingCommand = false
    @Published private(set) var updatedAt: Date?
    @Published var errorMessage: String?
    @Published var actionMessage: String?
    @Published var pendingCommand: PendingCommand?

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let configuration = try WatchCredentialStore.shared.load()
            stationName = configuration.stationName
            hasStation = configuration.stationID?.isEmpty == false
            hasControlKey = !configuration.controlKey.isEmpty
            let client = WatchBackendClient(configuration: configuration)
            async let dashboardRequest = client.fetchDashboard()
            async let ordersRequest = (try? await client.fetchActiveOrders()) ?? []
            let newDashboard = try await dashboardRequest
            let orders = await ordersRequest
            dashboard = newDashboard
            activeOrder = orders.first
            updatedAt = Date()
            errorMessage = nil
            cacheSnapshot(dashboard: newDashboard, activeOrder: orders.first)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func confirmPendingCommand() async {
        guard let command = pendingCommand, !isPerformingCommand else { return }
        pendingCommand = nil
        isPerformingCommand = true
        actionMessage = nil
        defer { isPerformingCommand = false }

        do {
            let configuration = try WatchCredentialStore.shared.load()
            let client = WatchBackendClient(configuration: configuration)
            switch command {
            case .find:
                try await client.performVehicleAction(.find)
                actionMessage = "寻车指令已发送。"
            case .stopFinding:
                try await client.performVehicleAction(.findStop)
                actionMessage = "停止寻车指令已发送。"
            case .unlockDoors:
                try await client.performVehicleAction(.unlockDoors)
                actionMessage = "车门解锁指令已发送。"
            case .createSwapOrder:
                try await client.createSwapOrder()
                actionMessage = "换电订单已创建。"
            }
            await refresh()
        } catch {
            actionMessage = Self.message(for: error)
        }
    }

    private func cacheSnapshot(dashboard: WatchDashboard, activeOrder: WatchActiveOrder?) {
        WatchSnapshotStore.save(
            WatchSnapshot(
                stateOfCharge: dashboard.stateOfCharge,
                remainingRange: dashboard.remainingRange,
                isConnected: dashboard.isConnected,
                isCharging: dashboard.isCharging,
                isSwapping: dashboard.isSwapping,
                stationName: activeOrder?.stationName ?? stationName,
                queueText: activeOrder?.queueStatusText,
                updatedAt: Date()
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "请求失败，请稍后手动重试。"
    }
}
