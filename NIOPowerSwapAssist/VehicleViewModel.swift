import Combine
import Foundation
import UIKit
import UserNotifications
import WidgetKit

struct SwapQueueNotificationPlan: Equatable {
    let title: String
    let body: String
    let delay: TimeInterval
    let isImmediate: Bool
}

enum SwapQueueNotificationPlanner {
    static let leadMinutes = 5

    static func plan(for order: ActiveServiceOrder) -> SwapQueueNotificationPlan? {
        guard let vehiclesAhead = order.vehiclesAhead else { return nil }
        let queueNumber = order.queueNumber.map { "，换电号 \(String(format: "%02d", $0))" } ?? ""
        if vehiclesAhead <= 1 {
            return SwapQueueNotificationPlan(
                title: vehiclesAhead == 0 ? "已经到你换电" : "下一辆快到你了",
                body: "\(order.stationName ?? "换电站")\(queueNumber)，请做好进站准备。",
                delay: 1,
                isImmediate: true
            )
        }
        guard let estimated = order.estimatedWaitMinutes else { return nil }
        let delayMinutes = max(1, estimated - leadMinutes)
        return SwapQueueNotificationPlan(
            title: "换电即将排到你",
            body: "\(order.stationName ?? "换电站")前方还有 \(vehiclesAhead) 辆\(queueNumber)。",
            delay: TimeInterval(delayMinutes * 60),
            isImmediate: false
        )
    }
}

private final class SwapQueueNotificationManager {
    static let shared = SwapQueueNotificationManager()
    private let enabledKey = "swapQueueNotificationsEnabled"
    private let notifiedPrefix = "swapQueueLastNotifiedState."
    private let scheduledPrefix = "swapQueueLastScheduledState."
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    var isEnabled: Bool { defaults.bool(forKey: enabledKey) }

    func setEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                defaults.set(granted, forKey: enabledKey)
                return granted
            } catch {
                defaults.set(false, forKey: enabledKey)
                return false
            }
        }
        defaults.set(false, forKey: enabledKey)
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("swap-queue-") }
        )
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(notifiedPrefix) || key.hasPrefix(scheduledPrefix) {
            defaults.removeObject(forKey: key)
        }
        return false
    }

    func synchronize(orders: [ActiveServiceOrder]) async {
        guard isEnabled else { return }
        let activeOrderIDs = Set(orders.map(\.orderNo))
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { identifier in
            guard identifier.hasPrefix("swap-queue-") else { return false }
            return !activeOrderIDs.contains { identifier.contains($0) }
        }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        for order in orders {
            guard let plan = SwapQueueNotificationPlanner.plan(for: order) else { continue }
            let identifier = "swap-queue-\(order.orderNo)"
            let state = "\(order.vehiclesAhead ?? -1)|\(order.estimatedWaitMinutes ?? -1)"
            let stateKey = (plan.isImmediate ? notifiedPrefix : scheduledPrefix) + order.orderNo
            guard defaults.string(forKey: stateKey) != state else { continue }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.userInfo = ["order_no": order.orderNo]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, plan.delay),
                repeats: false
            )
            do {
                try await center.add(
                    UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                )
                defaults.set(state, forKey: stateKey)
            } catch {}
        }
    }
}

private enum VehicleRequestResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
    case cancelled
}

private enum VehicleRefreshResult: Sendable {
    case dashboard(VehicleRequestResult<VehicleDashboard>)
    case presentation(VehicleRequestResult<VehiclePresentation>)
    case history(VehicleRequestResult<VehicleHistoryRefresh>)
    case trips(VehicleRequestResult<VehicleTripPage>)
    case chargingSessions(VehicleRequestResult<ChargingSessionPage>)
    case swapEvents(VehicleRequestResult<SwapEventPage>)
    case activeServiceOrders(VehicleRequestResult<ActiveServiceOrderPage>)
}

struct VehicleImageCacheEntry: Codable, Equatable {
    let schemaVersion: Int
    let baseURLString: String
    let vehicleID: String
    let etag: String?
    let data: Data
}

protocol VehicleImageCaching: AnyObject {
    func load(matching baseURL: URL) -> VehicleImageCacheEntry?
    func save(data: Data, etag: String?, vehicleID: String, baseURL: URL)
    func clear()
}

final class FileVehicleImageCache: VehicleImageCaching {
    static let shared = FileVehicleImageCache()

    private let fileURL: URL
    private let encoder: PropertyListEncoder
    private let decoder = PropertyListDecoder()

    init(fileURL: URL? = nil) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? root
            .appendingPathComponent("NIOPowerSwapAssist", isDirectory: true)
            .appendingPathComponent("vehicle-image-cache.plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        self.encoder = encoder
    }

    func load(matching baseURL: URL) -> VehicleImageCacheEntry? {
        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? decoder.decode(VehicleImageCacheEntry.self, from: data),
              entry.schemaVersion == 1,
              entry.baseURLString == baseURL.absoluteString else { return nil }
        return entry
    }

    func save(data: Data, etag: String?, vehicleID: String, baseURL: URL) {
        let entry = VehicleImageCacheEntry(
            schemaVersion: 1,
            baseURLString: baseURL.absoluteString,
            vehicleID: vehicleID,
            etag: etag,
            data: data
        )
        guard let encoded = try? encoder.encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: fileURL, options: .atomic)
        } catch {}
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private func captureVehicleRequest<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> VehicleRequestResult<Value> {
    do {
        return .success(try await operation())
    } catch is CancellationError {
        return .cancelled
    } catch let error as URLError where error.code == .cancelled {
        return .cancelled
    } catch {
        return .failure(
            (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        )
    }
}

private struct VehicleHistoryRefresh: Sendable {
    let history: [VehicleSnapshot]
    let paths: [DailyVehiclePath]
}

enum VehicleAutoRefreshPolicy {
    static let archiveInterval: TimeInterval = 10 * 60

    static func liveInterval(
        hasActiveOrders: Bool,
        isCharging: Bool,
        isSwapping: Bool
    ) -> TimeInterval {
        hasActiveOrders || isCharging || isSwapping ? 15 : 60
    }
}

struct VehicleDashboardCacheEntry: Codable, Equatable {
    let schemaVersion: Int
    let baseURLString: String
    let savedAt: Date
    let dashboard: VehicleDashboard
}

protocol VehicleDashboardCaching: AnyObject {
    func load(matching baseURL: URL) -> VehicleDashboardCacheEntry?
    func save(_ dashboard: VehicleDashboard, baseURL: URL, at date: Date)
    func clear()
}

final class UserDefaultsVehicleDashboardCache: VehicleDashboardCaching {
    static let shared = UserDefaultsVehicleDashboardCache()

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "cachedVehicleDashboard.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load(matching baseURL: URL) -> VehicleDashboardCacheEntry? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let entry = try? decoder.decode(VehicleDashboardCacheEntry.self, from: data) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        guard entry.schemaVersion == 1,
              entry.baseURLString == baseURL.absoluteString else { return nil }
        return entry
    }

    func save(_ dashboard: VehicleDashboard, baseURL: URL, at date: Date) {
        let entry = VehicleDashboardCacheEntry(
            schemaVersion: 1,
            baseURLString: baseURL.absoluteString,
            savedAt: date,
            dashboard: dashboard
        )
        guard let data = try? encoder.encode(entry) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

extension VehicleDashboard {
    func hasSameDisplayedState(as other: VehicleDashboard) -> Bool {
        vehicleID == other.vehicleID
            && isConnected == other.isConnected
            && stateCode == other.stateCode
            && mileage == other.mileage
            && isSwapping == other.isSwapping
            && stateOfCharge == other.stateOfCharge
            && remainingRange == other.remainingRange
            && remainingActualRange == other.remainingActualRange
            && chargeStateCode == other.chargeStateCode
            && chargingCurrent == other.chargingCurrent
            && chargingPower == other.chargingPower
            && chargingVoltage == other.chargingVoltage
            && chargeLimitPercent == other.chargeLimitPercent
            && batterySampledAt == other.batterySampledAt
            && lockStatusCode == other.lockStatusCode
            && location == other.location
            && locationSampledAt == other.locationSampledAt
            && insideTemperature == other.insideTemperature
            && outsideTemperature == other.outsideTemperature
    }
}

extension ActiveServiceOrder {
    func hasSameDisplayedState(as other: ActiveServiceOrder) -> Bool {
        orderNo == other.orderNo
            && orderType == other.orderType
            && orderStatus == other.orderStatus
            && orderStatusName == other.orderStatusName
            && orderCreatedAt == other.orderCreatedAt
            && stationKey == other.stationKey
            && stationName == other.stationName
            && stationAddress == other.stationAddress
            && baselineCapturedAt == other.baselineCapturedAt
            && queueNumber == other.queueNumber
            && targetBatteryCapLevel == other.targetBatteryCapLevel
            && vehiclesAhead == other.vehiclesAhead
            && estimatedWaitMinutes == other.estimatedWaitMinutes
            && estimatedWaitSource == other.estimatedWaitSource
            && queueStatusText == other.queueStatusText
    }
}

@MainActor
final class VehicleViewModel: ObservableObject {
    @Published private(set) var dashboard: VehicleDashboard?
    @Published private(set) var vehicleProfile: VehicleProfile?
    @Published private(set) var vehicleImageData: Data?
    @Published private(set) var history: [VehicleSnapshot] = []
    @Published private(set) var dailyPaths: [DailyVehiclePath] = []
    @Published private(set) var chargingSamples: [ChargingSample] = []
    @Published private(set) var currentChargingEnergyKWh: Double?
    @Published private(set) var chargingSessions: [ChargingSession] = []
    @Published private(set) var swapEvents: [SwapEvent] = []
    @Published private(set) var activeServiceOrders: [ActiveServiceOrder] = []
    @Published private(set) var trips: [VehicleTrip] = []
    @Published private(set) var energyStats: EnergyStats?
    @Published private(set) var availableCoupons: [AvailableCoupon] = []
    @Published private(set) var availableCouponCount = 0
    @Published private(set) var totalCouponQuantity: Int?
    @Published private(set) var couponsHaveMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEnergyStats = false
    @Published private(set) var isLoadingCoupons = false
    @Published private(set) var isPerformingVehicleAction = false
    @Published private(set) var isCreatingSwapOrder = false
    @Published private(set) var lastVehicleActionOutcome: VehicleActionOutcome?
    @Published private(set) var lastSwapOrderOutcome: CreateSwapOrderOutcome?
    @Published private(set) var queueNotificationsEnabled = false
    @Published private(set) var isConfigured = false
    @Published private(set) var isVehicleControlConfigured = false
    @Published private(set) var isShowingCachedDashboard = false
    @Published private(set) var lastDashboardRefreshAt: Date?
    @Published private(set) var failureNotice: APIErrorNotice?
    @Published private(set) var monitorConfigurationRevision = UUID()
    @Published private(set) var eventStreamStatus: BackendEventStreamStatus = .idle
    @Published private(set) var lastEventStreamEventName: String?
    @Published private(set) var lastEventStreamEventID: String?
    @Published private(set) var lastEventStreamEventAt: Date?
    @Published private(set) var lastEventStreamError: String?
    @Published private(set) var eventStreamReconnectAttempt = 0
    @Published private(set) var lastLiveDataRefreshAt: Date?
    @Published var errorMessage: String? { didSet { publishFailure(errorMessage) } }
    @Published var historyErrorMessage: String? { didSet { publishFailure(historyErrorMessage) } }
    @Published var tripsErrorMessage: String? { didSet { publishFailure(tripsErrorMessage) } }
    @Published var chargingErrorMessage: String? { didSet { publishFailure(chargingErrorMessage) } }
    @Published var chargingSessionsErrorMessage: String? { didSet { publishFailure(chargingSessionsErrorMessage) } }
    @Published var swapEventsErrorMessage: String? { didSet { publishFailure(swapEventsErrorMessage) } }
    @Published var activeServiceOrdersErrorMessage: String? { didSet { publishFailure(activeServiceOrdersErrorMessage) } }
    @Published var swapOrderErrorMessage: String? { didSet { publishFailure(swapOrderErrorMessage) } }
    @Published var energyStatsErrorMessage: String? { didSet { publishFailure(energyStatsErrorMessage) } }
    @Published var couponsErrorMessage: String? { didSet { publishFailure(couponsErrorMessage) } }

    private let settingsStore: BackendSettingsStore
    private let injectedSession: URLSession?
    private let dashboardCache: VehicleDashboardCaching?
    private let vehicleImageCache: VehicleImageCaching?
    private var vehicleImageETag: String?
    private var settingsRevision = UUID()
    private var refreshToken = UUID()
    private var activeRefreshTask: Task<Void, Never>?
    private var lastArchiveRefreshAt: Date?
    private var activeBaseURL: URL?
    private var hasPreparedInitialDisplay = false
    private var nextCouponOffset = 0
    private var pendingEventRefreshTask: Task<Void, Never>?
    private var pendingEventRefreshScope: EventRefreshScope = []
    private var chargingEnergyHydrationIDs: Set<String> = []

    private func publishFailure(_ message: String?) {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return }
        failureNotice = APIErrorNotice(message: message)
    }

    #if DEBUG
    private var isDesignPreview = false

    static func designPreview() -> VehicleViewModel {
        let settings = BackendSettingsStore(
            defaults: UserDefaults(suiteName: "nio-design-preview")!,
            keychainService: "nio-design-preview-isolated"
        )
        let model = VehicleViewModel(settingsStore: settings)
        model.isDesignPreview = true
        model.isConfigured = true
        model.isVehicleControlConfigured = true
        model.dashboard = DesignPreviewFixtures.dashboard
        model.history = DesignPreviewFixtures.history
        model.dailyPaths = VehiclePathBuilder.buildDailyPaths(from: model.history)
        model.trips = DesignPreviewFixtures.trips
        model.chargingSamples = DesignPreviewFixtures.samples
        model.chargingSessions = DesignPreviewFixtures.sessions
        model.swapEvents = DesignPreviewFixtures.swaps
        return model
    }
    #endif

    init(
        settingsStore: BackendSettingsStore = .shared,
        session: URLSession? = nil,
        dashboardCache: VehicleDashboardCaching? = nil,
        vehicleImageCache: VehicleImageCaching? = nil
    ) {
        self.settingsStore = settingsStore
        self.injectedSession = session
        self.dashboardCache = dashboardCache
            ?? (settingsStore === BackendSettingsStore.shared
                ? UserDefaultsVehicleDashboardCache.shared
                : nil)
        self.vehicleImageCache = vehicleImageCache
            ?? (settingsStore === BackendSettingsStore.shared
                ? FileVehicleImageCache.shared
                : nil)
        queueNotificationsEnabled = SwapQueueNotificationManager.shared.isEnabled
    }

    /// Runs after SwiftUI installs the root view. Keychain access stays out of
    /// StateObject initialization, while a saved dashboard can still appear
    /// before the first network response.
    func prepareForInitialDisplay() {
        guard !hasPreparedInitialDisplay else { return }
        hasPreparedInitialDisplay = true
        guard let configuration = try? settingsStore.configuration() else {
            isConfigured = false
            isVehicleControlConfigured = false
            return
        }
        activeBaseURL = configuration.baseURL
        isConfigured = true
        isVehicleControlConfigured = !settingsStore.controlKey().isEmpty
        if let entry = dashboardCache?.load(matching: configuration.baseURL) {
            dashboard = entry.dashboard
            lastDashboardRefreshAt = entry.savedAt
            isShowingCachedDashboard = true
        }
        if let entry = vehicleImageCache?.load(matching: configuration.baseURL),
           UIImage(data: entry.data) != nil {
            vehicleImageData = entry.data
            vehicleImageETag = entry.etag
        }
    }

    var baseURLString: String { settingsStore.baseURLString }
    var savedAPIKey: String { settingsStore.apiKey() }
    var savedControlKey: String { settingsStore.controlKey() }
    var vehicleTitle: String { vehicleProfile?.displayTitle ?? "我的蔚来" }
    var vehicleColorLabel: String? { vehicleProfile?.localizedColorName }
    var debugBaseURLString: String {
        (try? settingsStore.configuration().baseURL.absoluteString) ?? "未配置"
    }
    var debugLatestAPIError: String? {
        [
            errorMessage,
            activeServiceOrdersErrorMessage,
            historyErrorMessage,
            tripsErrorMessage,
            chargingErrorMessage,
            chargingSessionsErrorMessage,
            swapEventsErrorMessage,
            energyStatsErrorMessage,
            couponsErrorMessage
        ].compactMap { $0 }.first
    }
    func saveSettings(baseURLString: String, apiKey: String, controlKey: String) throws {
        #if DEBUG
        if isDesignPreview { throw BackendClientError.vehicleControlFailed("设计预览不保存连接设置。") }
        #endif
        let previous = try? settingsStore.configuration()
        try settingsStore.save(
            baseURLString: baseURLString,
            apiKey: apiKey,
            controlKey: controlKey
        )
        if previous != (try? settingsStore.configuration()) {
            settingsRevision = UUID()
            monitorConfigurationRevision = UUID()
            pendingEventRefreshTask?.cancel()
            pendingEventRefreshTask = nil
            pendingEventRefreshScope = []
            chargingEnergyHydrationIDs.removeAll()
            eventStreamStatus = .idle
            lastEventStreamEventName = nil
            lastEventStreamEventID = nil
            lastEventStreamEventAt = nil
            lastEventStreamError = nil
            eventStreamReconnectAttempt = 0
            refreshToken = UUID()
            activeRefreshTask?.cancel()
            activeRefreshTask = nil
            lastArchiveRefreshAt = nil
            isLoading = false
            dashboardCache?.clear()
            vehicleImageCache?.clear()
            activeBaseURL = try? settingsStore.configuration().baseURL
            dashboard = nil
            vehicleProfile = nil
            vehicleImageData = nil
            vehicleImageETag = nil
            isShowingCachedDashboard = false
            lastDashboardRefreshAt = nil
            history = []
            dailyPaths = []
            chargingSamples = []
            chargingSessions = []
            swapEvents = []
            activeServiceOrders = []
            trips = []
            energyStats = nil
            availableCoupons = []
            availableCouponCount = 0
            totalCouponQuantity = nil
            couponsHaveMore = false
            nextCouponOffset = 0
            lastVehicleActionOutcome = nil
            lastSwapOrderOutcome = nil
            historyErrorMessage = nil
            tripsErrorMessage = nil
            chargingErrorMessage = nil
            chargingSessionsErrorMessage = nil
            swapEventsErrorMessage = nil
            activeServiceOrdersErrorMessage = nil
            swapOrderErrorMessage = nil
            energyStatsErrorMessage = nil
            couponsErrorMessage = nil
        }
        isConfigured = true
        isVehicleControlConfigured = !settingsStore.controlKey().isEmpty
        errorMessage = nil
    }

    private func client(for configuration: BackendConfiguration) -> BackendClient {
        BackendClient(configuration: configuration, session: injectedSession)
    }

    func performVehicleAction(
        _ action: VehicleAction,
        temperature: Double? = nil,
        expandMirrors: Bool = false
    ) async throws -> VehicleActionOutcome {
        #if DEBUG
        if isDesignPreview { throw BackendClientError.vehicleControlFailed("设计预览不会发送车辆指令。") }
        #endif
        guard !isPerformingVehicleAction else {
            throw BackendClientError.vehicleControlFailed("已有一条车控指令正在执行，请稍候。")
        }
        let configuration = try settingsStore.configuration()
        let revision = settingsRevision
        let controlKey = settingsStore.controlKey()
        guard !controlKey.isEmpty else { throw BackendClientError.invalidControlKey }

        isPerformingVehicleAction = true
        defer { isPerformingVehicleAction = false }
        let outcome = try await client(for: configuration).performVehicleAction(
            VehicleActionInput(action: action, temperature: temperature, expandMirrors: expandMirrors),
            controlKey: controlKey
        )
        guard revision == settingsRevision else {
            throw BackendClientError.vehicleControlFailed("车控请求期间连接配置发生了变化。指令可能已执行，请核对车辆状态；App 没有重发指令。")
        }
        lastVehicleActionOutcome = outcome

        // A command is never retried. One read-only refresh is used to pick up
        // subsequently reported state after the backend has returned.
        if !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await refreshDashboardOnly() }
        }
        return outcome
    }

    func createSwapOrder(stationID: String) async throws -> CreateSwapOrderOutcome {
        #if DEBUG
        if isDesignPreview {
            throw BackendClientError.swapOrderFailed("设计预览不会创建真实换电订单。")
        }
        #endif
        guard !isCreatingSwapOrder else {
            throw BackendClientError.swapOrderFailed("换电订单正在创建，请勿重复提交。")
        }
        let configuration = try settingsStore.configuration()
        let revision = settingsRevision
        let controlKey = settingsStore.controlKey()
        guard !controlKey.isEmpty else { throw BackendClientError.invalidControlKey }

        isCreatingSwapOrder = true
        swapOrderErrorMessage = nil
        defer { isCreatingSwapOrder = false }
        do {
            let outcome = try await client(for: configuration).createSwapOrder(
                stationID: stationID,
                controlKey: controlKey
            )
            guard revision == settingsRevision else {
                throw BackendClientError.swapOrderFailed(
                    "下单期间连接配置发生变化。订单可能已经创建，App 不会重发；请先检查活动订单。"
                )
            }
            lastSwapOrderOutcome = outcome
            if !Task.isCancelled { await refresh() }
            return outcome
        } catch {
            swapOrderErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            throw error
        }
    }

    private func refreshDashboardOnly() async {
        prepareForInitialDisplay()
        guard let configuration = try? settingsStore.configuration() else { return }
        activeBaseURL = configuration.baseURL
        let revision = settingsRevision
        let client = client(for: configuration)
        let result = await captureVehicleRequest { try await client.fetchDashboard() }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch result {
        case .success(let dashboard): updateDashboardIfNeeded(dashboard)
        case .failure(let message): errorMessage = message
        case .cancelled: break
        }
    }

    func refresh() async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        prepareForInitialDisplay()
        if let task = activeRefreshTask {
            await task.value
            return
        }

        let token = UUID()
        refreshToken = token
        guard let configuration = try? settingsStore.configuration() else {
            isConfigured = false
            isLoading = false
            return
        }
        activeBaseURL = configuration.baseURL

        isConfigured = true
        isLoading = true
        errorMessage = nil
        historyErrorMessage = nil
        tripsErrorMessage = nil
        chargingSessionsErrorMessage = nil
        swapEventsErrorMessage = nil
        activeServiceOrdersErrorMessage = nil
        defer {
            if refreshToken == token {
                activeRefreshTask = nil
                isLoading = false
            }
        }

        let client = client(for: configuration)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll(using: client, token: token)
        }
        activeRefreshTask = task
        await task.value
        if refreshToken == token, !Task.isCancelled {
            lastArchiveRefreshAt = Date()
        }
    }

    private func refreshAll(using client: BackendClient, token: UUID) async {
        let cachedVehicleImageETag = vehicleImageETag
        await withTaskGroup(of: VehicleRefreshResult.self) { group in
            group.addTask {
                .dashboard(await captureVehicleRequest { try await client.fetchDashboard() })
            }
            group.addTask {
                .presentation(
                    await captureVehicleRequest {
                        try await client.fetchVehiclePresentation(
                            cachedETag: cachedVehicleImageETag
                        )
                    }
                )
            }
            group.addTask {
                .history(await captureVehicleRequest {
                    let page = try await client.fetchVehicleHistory()
                    return VehicleHistoryRefresh(
                        history: page.items,
                        paths: VehiclePathBuilder.buildDailyPaths(from: page.items)
                    )
                })
            }
            group.addTask {
                .trips(await captureVehicleRequest { try await client.fetchVehicleTrips() })
            }
            group.addTask {
                .chargingSessions(
                    await captureVehicleRequest { try await client.fetchChargingSessions() }
                )
            }
            group.addTask {
                .swapEvents(await captureVehicleRequest { try await client.fetchSwapEvents() })
            }
            group.addTask {
                .activeServiceOrders(
                    await captureVehicleRequest { try await client.fetchActiveServiceOrders() }
                )
            }

            for await result in group {
                guard refreshToken == token, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                apply(result)
            }
        }
    }

    private func apply(_ result: VehicleRefreshResult) {
        switch result {
        case .dashboard(.success(let dashboard)):
            updateDashboardIfNeeded(dashboard)
        case .dashboard(.failure(let message)):
            errorMessage = message
        case .presentation(.success(let presentation)):
            updateVehiclePresentation(presentation)
        case .presentation(.failure):
            // Vehicle identity/artwork is optional. Keep the last valid local
            // image and do not turn a cosmetic refresh failure into a page error.
            break
        case .history(.success(let result)):
            if history != result.history { history = result.history }
            if dailyPaths != result.paths { dailyPaths = result.paths }
        case .history(.failure(let message)):
            historyErrorMessage = message
        case .trips(.success(let page)):
            if trips != page.items { trips = page.items }
        case .trips(.failure(let message)):
            tripsErrorMessage = message
        case .chargingSessions(.success(let page)):
            updateChargingSessions(page.items)
        case .chargingSessions(.failure(let message)):
            chargingSessionsErrorMessage = message
        case .swapEvents(.success(let page)):
            if swapEvents != page.items { swapEvents = page.items }
        case .swapEvents(.failure(let message)):
            swapEventsErrorMessage = message
        case .activeServiceOrders(.success(let page)):
            updateActiveServiceOrdersIfNeeded(page.items)
        case .activeServiceOrders(.failure(let message)):
            activeServiceOrdersErrorMessage = message
        case .dashboard(.cancelled),
             .presentation(.cancelled),
             .history(.cancelled),
             .trips(.cancelled),
             .chargingSessions(.cancelled),
             .swapEvents(.cancelled),
             .activeServiceOrders(.cancelled):
            break
        }
    }

    private func updateVehiclePresentation(_ presentation: VehiclePresentation) {
        if vehicleProfile != presentation.profile {
            vehicleProfile = presentation.profile
        }
        switch presentation.image {
        case .unavailable:
            vehicleImageData = nil
            vehicleImageETag = nil
            vehicleImageCache?.clear()
        case .notModified:
            break
        case .downloaded(let data, let responseETag):
            guard UIImage(data: data) != nil else { return }
            let etag = responseETag
                ?? presentation.profile.imageSHA256.map { "\"\($0)\"" }
            vehicleImageData = data
            vehicleImageETag = etag
            if let activeBaseURL {
                vehicleImageCache?.save(
                    data: data,
                    etag: etag,
                    vehicleID: presentation.profile.vehicleID,
                    baseURL: activeBaseURL
                )
            }
        }
    }

    private func updateDashboardIfNeeded(_ newDashboard: VehicleDashboard) {
        isShowingCachedDashboard = false
        lastDashboardRefreshAt = newDashboard.updatedAt
        if let activeBaseURL {
            dashboardCache?.save(
                newDashboard,
                baseURL: activeBaseURL,
                at: newDashboard.updatedAt
            )
        }
        guard dashboard?.hasSameDisplayedState(as: newDashboard) != true else {
            if errorMessage != nil { errorMessage = nil }
            return
        }
        dashboard = newDashboard
        errorMessage = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func updateActiveServiceOrdersIfNeeded(_ newOrders: [ActiveServiceOrder]) {
        let unchanged = activeServiceOrders.count == newOrders.count
            && zip(activeServiceOrders, newOrders).allSatisfy {
                $0.hasSameDisplayedState(as: $1)
            }
        if activeServiceOrdersErrorMessage != nil { activeServiceOrdersErrorMessage = nil }
        guard !unchanged else { return }
        activeServiceOrders = newOrders
        synchronizeQueueNotifications()
    }

    private func updateChargingSessions(_ sessions: [ChargingSession]) {
        let sorted = sessions.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            if $0.endedAt != $1.endedAt { return $0.endedAt > $1.endedAt }
            return $0.id > $1.id
        }
        if chargingSessions != sorted { chargingSessions = sorted }
    }

    func setQueueNotificationsEnabled(_ enabled: Bool) async {
        queueNotificationsEnabled = await SwapQueueNotificationManager.shared.setEnabled(enabled)
        if queueNotificationsEnabled {
            synchronizeQueueNotifications()
        }
    }

    func monitorForegroundRefresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.monitorBackendEvents()
            }
            group.addTask { [weak self] in
                await self?.monitorPollingFallback()
            }
            await group.waitForAll()
        }
        pendingEventRefreshTask?.cancel()
        pendingEventRefreshTask = nil
        pendingEventRefreshScope = []
        if eventStreamStatus != .authenticationFailed {
            eventStreamStatus = .stopped
        }
    }

    private func monitorPollingFallback() async {
        while !Task.isCancelled {
            let seconds = VehicleAutoRefreshPolicy.liveInterval(
                hasActiveOrders: !activeServiceOrders.isEmpty,
                isCharging: dashboard?.chargeStateCode == 1,
                isSwapping: dashboard?.isSwapping == true
            )
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refreshLiveData()
            if Date().timeIntervalSince(lastArchiveRefreshAt ?? .distantPast)
                >= VehicleAutoRefreshPolicy.archiveInterval {
                await refreshArchiveData()
                lastArchiveRefreshAt = Date()
            }
        }
    }

    private struct EventRefreshScope: OptionSet {
        let rawValue: Int

        static let dashboard = EventRefreshScope(rawValue: 1 << 0)
        static let activeOrders = EventRefreshScope(rawValue: 1 << 1)
        static let allLiveData: EventRefreshScope = [.dashboard, .activeOrders]
    }

    private func monitorBackendEvents() async {
        guard let configuration = try? settingsStore.configuration() else { return }
        let expectedRevision = settingsRevision
        let streamClient = BackendEventStreamClient(
            configuration: configuration,
            session: injectedSession
        )
        var lastEventID: String?
        var lastNumericEventID: Int64?
        var retryMilliseconds: Int?
        var reconnectAttempt = 0
        eventStreamStatus = .connecting
        lastEventStreamError = nil

        while !Task.isCancelled, expectedRevision == settingsRevision {
            let connectionStartedAt = Date()
            do {
                for try await event in streamClient.events(lastEventID: lastEventID) {
                    guard !Task.isCancelled, expectedRevision == settingsRevision else { return }
                    eventStreamStatus = .connected
                    lastEventStreamError = nil
                    if let retry = event.retryMilliseconds { retryMilliseconds = retry }

                    if let eventID = event.id, !eventID.isEmpty {
                        if eventID == lastEventID { continue }
                        if let numericID = Int64(eventID), let previous = lastNumericEventID {
                            if numericID <= previous { continue }
                            if numericID > previous + 1 {
                                scheduleEventRefresh(.allLiveData)
                            }
                        }
                        lastEventID = eventID
                        lastNumericEventID = Int64(eventID)
                    }
                    lastEventStreamEventName = event.name
                    lastEventStreamEventID = event.id ?? lastEventID
                    lastEventStreamEventAt = Date()

                    switch event.name {
                    case "ready", "resync":
                        scheduleEventRefresh(.allLiveData)
                    case "vehicle_changed":
                        scheduleEventRefresh(.dashboard)
                    case "active_orders_changed":
                        scheduleEventRefresh(.activeOrders)
                    default:
                        break
                    }
                }
            } catch let error as BackendEventStreamError {
                if case .unauthorized = error {
                    eventStreamStatus = .authenticationFailed
                    lastEventStreamError = error.localizedDescription
                    return
                }
                eventStreamStatus = .reconnecting
                lastEventStreamError = error.localizedDescription
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                eventStreamStatus = .reconnecting
                lastEventStreamError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }

            if Date().timeIntervalSince(connectionStartedAt) >= 15 {
                reconnectAttempt = 0
            }
            let delay = BackendEventReconnectPolicy.delay(
                attempt: reconnectAttempt,
                serverRetryMilliseconds: retryMilliseconds,
                jitter: Double.random(in: 0.8...1.2)
            )
            reconnectAttempt = min(reconnectAttempt + 1, 10)
            eventStreamReconnectAttempt = reconnectAttempt
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            eventStreamStatus = .connecting
        }
    }

    private func scheduleEventRefresh(_ scope: EventRefreshScope) {
        pendingEventRefreshScope.formUnion(scope)
        pendingEventRefreshTask?.cancel()
        pendingEventRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let scope = self.pendingEventRefreshScope
            self.pendingEventRefreshScope = []
            self.pendingEventRefreshTask = nil
            if scope == .allLiveData {
                await self.refreshLiveData()
            } else if scope.contains(.dashboard) {
                await self.refreshDashboardOnly()
            } else if scope.contains(.activeOrders) {
                await self.refreshActiveServiceOrdersOnly()
            }
        }
    }

    func refreshLiveData() async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        prepareForInitialDisplay()
        if let task = activeRefreshTask {
            await task.value
            return
        }
        guard let configuration = try? settingsStore.configuration() else { return }
        activeBaseURL = configuration.baseURL
        let revision = settingsRevision
        let client = client(for: configuration)
        async let dashboardRequest = captureVehicleRequest { try await client.fetchDashboard() }
        async let ordersRequest = captureVehicleRequest {
            try await client.fetchActiveServiceOrders()
        }
        let (dashboardResult, ordersResult) = await (dashboardRequest, ordersRequest)
        guard revision == settingsRevision, !Task.isCancelled else { return }
        lastLiveDataRefreshAt = Date()
        apply(.dashboard(dashboardResult))
        apply(.activeServiceOrders(ordersResult))
    }

    private func refreshArchiveData() async {
        if let task = activeRefreshTask {
            await task.value
            return
        }
        guard let configuration = try? settingsStore.configuration() else { return }
        let revision = settingsRevision
        let client = client(for: configuration)
        await withTaskGroup(of: VehicleRefreshResult.self) { group in
            group.addTask {
                .history(await captureVehicleRequest {
                    let page = try await client.fetchVehicleHistory()
                    return VehicleHistoryRefresh(
                        history: page.items,
                        paths: VehiclePathBuilder.buildDailyPaths(from: page.items)
                    )
                })
            }
            group.addTask {
                .trips(await captureVehicleRequest { try await client.fetchVehicleTrips() })
            }
            group.addTask {
                .chargingSessions(
                    await captureVehicleRequest { try await client.fetchChargingSessions() }
                )
            }
            group.addTask {
                .swapEvents(await captureVehicleRequest { try await client.fetchSwapEvents() })
            }
            for await result in group {
                guard revision == settingsRevision, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                apply(result)
            }
        }
    }

    func refreshActiveServiceOrdersOnly() async {
        guard let configuration = try? settingsStore.configuration() else { return }
        let revision = settingsRevision
        let result = await captureVehicleRequest {
            try await self.client(for: configuration).fetchActiveServiceOrders()
        }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch result {
        case .success(let page):
            updateActiveServiceOrdersIfNeeded(page.items)
        case .failure(let message):
            activeServiceOrdersErrorMessage = message
        case .cancelled:
            break
        }
    }

    private func synchronizeQueueNotifications() {
        let orders = activeServiceOrders
        Task { await SwapQueueNotificationManager.shared.synchronize(orders: orders) }
    }

    func refreshChargingData() async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        guard let configuration = try? settingsStore.configuration() else { return }
        let revision = settingsRevision
        let client = client(for: configuration)
        chargingErrorMessage = nil

        let chargingResult = await captureVehicleRequest {
            try await client.fetchCurrentChargingSession()
        }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch chargingResult {
        case .success(let page):
            if chargingSamples != page.items { chargingSamples = page.items }
            currentChargingEnergyKWh = page.energyKWh
        case .failure(let message): chargingErrorMessage = message
        case .cancelled: break
        }
    }

    func refreshChargingSessions() async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        guard let configuration = try? settingsStore.configuration() else { return }
        let revision = settingsRevision
        chargingSessionsErrorMessage = nil
        let client = client(for: configuration)
        let result = await captureVehicleRequest { try await client.fetchChargingSessions() }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch result {
        case .success(let page):
            updateChargingSessions(page.items)
        case .failure(let message): chargingSessionsErrorMessage = message
        case .cancelled: break
        }
    }

    func fetchChargingSessionDetail(id: String) async throws -> VehicleChargingSamplePage {
        #if DEBUG
        if isDesignPreview {
            return VehicleChargingSamplePage(items: chargingSamples)
        }
        #endif
        guard let configuration = try? settingsStore.configuration() else {
            throw BackendClientError.invalidBaseURL
        }
        let revision = settingsRevision
        let page = try await client(for: configuration)
            .fetchChargingSession(id: id)
        guard revision == settingsRevision else { throw BackendClientError.configurationChanged }
        try Task.checkCancellation()
        return page
    }

    func hydrateChargingSessionEnergyIfNeeded(id: String) async {
        guard let session = chargingSessions.first(where: { $0.id == id }),
              session.energyKWh == nil,
              let configuration = try? settingsStore.configuration(),
              chargingEnergyHydrationIDs.insert(id).inserted else { return }
        defer { chargingEnergyHydrationIDs.remove(id) }
        let revision = settingsRevision
        guard let page = try? await client(for: configuration).fetchChargingSession(id: id),
              let energyKWh = page.energyKWh,
              energyKWh.isFinite,
              energyKWh >= 0,
              revision == settingsRevision,
              !Task.isCancelled,
              let index = chargingSessions.firstIndex(where: { $0.id == id }) else { return }
        chargingSessions[index] = chargingSessions[index].replacingEnergyKWh(energyKWh)
    }

    func fetchChargingSessionSamples(id: String) async throws -> [ChargingSample] {
        try await fetchChargingSessionDetail(id: id).items
    }

    func refreshSwapEvents() async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        guard let configuration = try? settingsStore.configuration() else { return }
        let revision = settingsRevision
        swapEventsErrorMessage = nil
        activeServiceOrdersErrorMessage = nil
        let client = client(for: configuration)
        async let swapEventsRequest = captureVehicleRequest { try await client.fetchSwapEvents() }
        async let activeOrdersRequest = captureVehicleRequest {
            try await client.fetchActiveServiceOrders()
        }
        let (swapEventsResult, activeOrdersResult) = await (swapEventsRequest, activeOrdersRequest)
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch swapEventsResult {
        case .success(let page):
            if swapEvents != page.items { swapEvents = page.items }
        case .failure(let message): swapEventsErrorMessage = message
        case .cancelled: break
        }
        switch activeOrdersResult {
        case .success(let page): updateActiveServiceOrdersIfNeeded(page.items)
        case .failure(let message): activeServiceOrdersErrorMessage = message
        case .cancelled: break
        }
    }

    func fetchSwapEvent(id: String) async throws -> SwapEvent {
        #if DEBUG
        if isDesignPreview, let event = swapEvents.first(where: { $0.id == id }) { return event }
        if isDesignPreview { throw BackendClientError.httpStatus(404) }
        #endif
        guard let configuration = try? settingsStore.configuration() else {
            throw BackendClientError.invalidBaseURL
        }
        let revision = settingsRevision
        let event = try await client(for: configuration).fetchSwapEvent(id: id)
        guard revision == settingsRevision else { throw BackendClientError.configurationChanged }
        try Task.checkCancellation()
        return event
    }

    func fetchSwapStations(search: String? = nil) async throws -> [SwapStation] {
        #if DEBUG
        if isDesignPreview { return [] }
        #endif
        guard let configuration = try? settingsStore.configuration() else {
            throw BackendClientError.invalidBaseURL
        }
        let revision = settingsRevision
        let page = try await client(for: configuration)
            .fetchSwapStations(limit: 200, search: search)
        guard revision == settingsRevision else { throw BackendClientError.configurationChanged }
        try Task.checkCancellation()
        return page.items
    }

    func refreshEnergyStats(from: Date, to: Date) async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        guard to > from, !isLoadingEnergyStats else { return }
        guard let configuration = try? settingsStore.configuration() else {
            energyStatsErrorMessage = "请先配置后端地址与 API Key。"
            return
        }
        let revision = settingsRevision
        isLoadingEnergyStats = true
        energyStatsErrorMessage = nil
        defer { isLoadingEnergyStats = false }
        let result = await captureVehicleRequest {
            try await self.client(for: configuration).fetchEnergyStats(from: from, to: to)
        }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch result {
        case .success(let stats):
            energyStats = stats
        case .failure(let message):
            energyStatsErrorMessage = message
        case .cancelled:
            break
        }
    }

    func refreshAvailableCoupons(reset: Bool = true) async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        guard !isLoadingCoupons else { return }
        guard reset || couponsHaveMore else { return }
        guard let configuration = try? settingsStore.configuration() else {
            couponsErrorMessage = "请先配置后端地址与 API Key。"
            return
        }
        let revision = settingsRevision
        let offset = reset ? 0 : nextCouponOffset
        isLoadingCoupons = true
        couponsErrorMessage = nil
        defer { isLoadingCoupons = false }
        let result = await captureVehicleRequest {
            try await self.client(for: configuration).fetchAvailableCoupons(
                limit: 20,
                offset: offset
            )
        }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        switch result {
        case .success(let page):
            if reset {
                availableCoupons = page.coupons
            } else {
                let existing = Set(availableCoupons.compactMap(\.sourceIdentifier))
                availableCoupons.append(contentsOf: page.coupons.filter {
                    guard let identifier = $0.sourceIdentifier else { return true }
                    return !existing.contains(identifier)
                })
            }
            availableCouponCount = page.amount
            totalCouponQuantity = page.totalCouponCount
            couponsHaveMore = page.hasMore
            nextCouponOffset = page.offset + page.coupons.count
        case .failure(let message):
            couponsErrorMessage = message
        case .cancelled:
            break
        }
    }
}
struct APIErrorNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}

