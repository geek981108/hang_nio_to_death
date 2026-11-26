import Combine
import Foundation
import WatchKit
import WidgetKit

@MainActor
final class WatchDashboardViewModel: ObservableObject {
    enum PendingCommand: Identifiable, Equatable {
        case lock
        case unlockStart
        case acOn
        case acOff
        case guardOn
        case guardOff
        case find
        case stopFinding
        case createSwapOrder

        var id: String {
            switch self {
            case .lock: return "lock"
            case .unlockStart: return "unlock-start"
            case .acOn: return "ac-on"
            case .acOff: return "ac-off"
            case .guardOn: return "guard-on"
            case .guardOff: return "guard-off"
            case .find: return "find"
            case .stopFinding: return "stop-finding"
            case .createSwapOrder: return "create-swap-order"
            }
        }

        var title: String {
            switch self {
            case .lock: return "远程锁车？"
            case .unlockStart: return "解锁并启动？"
            case .acOn: return "开启空调？"
            case .acOff: return "关闭空调？"
            case .guardOn: return "开启守卫并展镜？"
            case .guardOff: return "关闭守卫模式？"
            case .find: return "开始寻车？"
            case .stopFinding: return "停止寻车？"
            case .createSwapOrder: return "发起换电？"
            }
        }

        func message(acTemperature: Double) -> String {
            switch self {
            case .lock: return "将向车辆发送一次落锁指令。"
            case .unlockStart: return "高风险操作，将解锁车辆并授予启动权限。"
            case .acOn: return "将以 \(Self.formatTemp(acTemperature)) 开启车内空调。"
            case .acOff: return "将关闭车内空调。"
            case .guardOn: return "将开启守卫模式并展开后视镜。"
            case .guardOff: return "将关闭守卫模式。"
            case .find: return "将向车辆发送鸣笛闪灯指令。"
            case .stopFinding: return "将发送停止寻车指令。"
            case .createSwapOrder: return "将为 iPhone 当前换电站创建真实订单。"
            }
        }

        private static func formatTemp(_ value: Double) -> String {
            let rounded = (value * 2).rounded() / 2
            return rounded.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(rounded))℃"
                : String(format: "%.1f℃", rounded)
        }

        var inProgressLabel: String {
            switch self {
            case .lock: return "正在锁车…"
            case .unlockStart: return "正在解锁启动…"
            case .acOn: return "正在开空调…"
            case .acOff: return "正在关空调…"
            case .guardOn: return "正在开守卫…"
            case .guardOff: return "正在关守卫…"
            case .find: return "正在寻车…"
            case .stopFinding: return "正在停止…"
            case .createSwapOrder: return "正在下单…"
            }
        }

        var isDestructive: Bool {
            self == .unlockStart || self == .createSwapOrder
        }
    }

    struct ActionFeedback: Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    @Published private(set) var vehicleName: String?
    @Published private(set) var dashboard: WatchDashboard?
    @Published private(set) var activeOrder: WatchActiveOrder?
    @Published private(set) var stationLive: WatchStationLive?
    @Published private(set) var stationName: String?
    @Published private(set) var hasStation = false
    @Published private(set) var hasControlKey = false
    @Published private(set) var isConfigured = false
    @Published private(set) var isShowingCachedData = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPerformingCommand = false
    @Published private(set) var activeCommandLabel: String?
    @Published private(set) var updatedAt: Date?
    @Published var targetACTemperature: Double = 22.0
    @Published var errorMessage: String?
    @Published var feedback: ActionFeedback?
    @Published var pendingCommand: PendingCommand?

    var clampedACTemperature: Double {
        let clamped = min(max(targetACTemperature, 16.0), 30.0)
        return (clamped * 2).rounded() / 2
    }

    var formattedACTemperature: String {
        let value = clampedACTemperature
        return value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))℃"
            : String(format: "%.1f℃", value)
    }

    func adjustACTemperature(by delta: Double) {
        let next = min(max(clampedACTemperature + delta, 16.0), 30.0)
        targetACTemperature = (next * 2).rounded() / 2
    }

    init() {
        if let configuration = try? WatchCredentialStore.shared.load() {
            isConfigured = true
            stationName = configuration.stationName
            hasStation = configuration.stationID?.isEmpty == false
            hasControlKey = !configuration.controlKey.isEmpty
        }
        if let snapshot = WatchSnapshotStore.load() {
            vehicleName = snapshot.vehicleName
            dashboard = WatchDashboard(
                isConnected: snapshot.isConnected,
                stateOfCharge: snapshot.stateOfCharge,
                remainingRange: snapshot.remainingRange,
                isCharging: snapshot.isCharging,
                isSwapping: snapshot.isSwapping,
                isRepairing: snapshot.isRepairing,
                isFotaActive: snapshot.isFotaActive,
                isSVTActive: snapshot.isSVTActive
            )
            if stationName == nil {
                stationName = snapshot.stationName
            }
            updatedAt = snapshot.updatedAt
            isShowingCachedData = true
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let configuration = try WatchCredentialStore.shared.load()
            isConfigured = true
            stationName = configuration.stationName
            hasStation = configuration.stationID?.isEmpty == false
            hasControlKey = !configuration.controlKey.isEmpty
            let client = WatchBackendClient(configuration: configuration)
            async let dashboardRequest = client.fetchDashboard()
            async let profileRequest = try? await client.fetchVehicleProfile()
            async let ordersRequest = (try? await client.fetchActiveOrders()) ?? []
            async let stationLiveRequest: WatchStationLive? = {
                guard let stationID = configuration.stationID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !stationID.isEmpty else { return nil }
                return try? await client.fetchStationLive(stationID: stationID)
            }()
            let newDashboard = try await dashboardRequest
            let profile = await profileRequest
            let orders = await ordersRequest
            let liveStation = await stationLiveRequest
            if let resolvedTitle = profile?.displayTitle {
                vehicleName = resolvedTitle
            }
            dashboard = newDashboard
            activeOrder = orders.first
            stationLive = liveStation
            if let liveName = liveStation?.stationName.trimmingCharacters(in: .whitespacesAndNewlines),
               !liveName.isEmpty {
                stationName = liveName
            }
            updatedAt = Date()
            isShowingCachedData = false
            errorMessage = nil
            cacheSnapshot(dashboard: newDashboard, activeOrder: orders.first)
        } catch {
            if let configError = error as? WatchConfigurationError,
               case .notConfigured = configError {
                isConfigured = false
            }
            errorMessage = Self.message(for: error)
        }
    }

    func confirmPendingCommand() async {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        await executeCommand(command)
    }

    func executeDirectly(_ command: PendingCommand) async {
        pendingCommand = nil
        await executeCommand(command)
    }

    private func executeCommand(_ command: PendingCommand) async {
        guard !isPerformingCommand else { return }
        isPerformingCommand = true
        activeCommandLabel = command.inProgressLabel
        feedback = nil
        defer {
            isPerformingCommand = false
            activeCommandLabel = nil
        }

        do {
            let configuration = try WatchCredentialStore.shared.load()
            let client = WatchBackendClient(configuration: configuration)
            let successMessage: String
            switch command {
            case .lock:
                try await client.performVehicleAction(.lock)
                successMessage = "已发送锁车指令"
            case .unlockStart:
                try await client.performVehicleAction(.unlockStart)
                successMessage = "已发送解锁并启动指令"
            case .acOn:
                let temperature = clampedACTemperature
                try await client.performVehicleAction(.acOn, temperature: temperature)
                successMessage = "已开启 \(formattedACTemperature) 空调"
            case .acOff:
                try await client.performVehicleAction(.acOff)
                successMessage = "已关闭空调"
            case .guardOn:
                try await client.performVehicleAction(.guardOn, expandMirrors: true)
                successMessage = "已开启守卫并展镜"
            case .guardOff:
                try await client.performVehicleAction(.guardOff)
                successMessage = "已关闭守卫模式"
            case .find:
                try await client.performVehicleAction(.find)
                successMessage = "已发送寻车指令"
            case .stopFinding:
                try await client.performVehicleAction(.findStop)
                successMessage = "已停止寻车"
            case .createSwapOrder:
                try await client.createSwapOrder()
                successMessage = "换电订单已创建"
            }
            WKInterfaceDevice.current().play(.success)
            feedback = ActionFeedback(message: successMessage, isError: false)
            await refresh()
        } catch {
            WKInterfaceDevice.current().play(.failure)
            feedback = ActionFeedback(message: Self.message(for: error), isError: true)
        }
    }

    private func cacheSnapshot(dashboard: WatchDashboard, activeOrder: WatchActiveOrder?) {
        WatchSnapshotStore.save(
            WatchSnapshot(
                vehicleName: vehicleName,
                stateOfCharge: dashboard.stateOfCharge,
                remainingRange: dashboard.remainingRange,
                isConnected: dashboard.isConnected,
                isCharging: dashboard.isCharging,
                isSwapping: dashboard.isSwapping,
                isRepairing: dashboard.isRepairing,
                isFotaActive: dashboard.isFotaActive,
                isSVTActive: dashboard.isSVTActive,
                stationName: activeOrder?.stationName ?? stationName,
                queueText: activeOrder?.queueStatusText,
                updatedAt: Date()
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "请求失败，请稍后重试。"
    }
}
