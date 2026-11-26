import Foundation
import SwiftUI

@MainActor
final class TVGarageViewModel: ObservableObject {
    enum StationSourceMode: Equatable {
        case selected(id: String, name: String)
        case nearest
    }

    struct ActionFeedback: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    @Published private(set) var isConfigured = false
    @Published private(set) var hasControlKey = false
    @Published private(set) var settings: TVStoredSettings?

    @Published private(set) var dashboard: VehicleDashboard?
    @Published private(set) var vehicleProfile: VehicleProfile?
    @Published private(set) var vehicleImageData: Data?
    @Published private(set) var activeServiceOrders: [ActiveServiceOrder] = []
    @Published private(set) var stationLive: NearestStationLive?
    @Published private(set) var nearbyStations: [NearbyStation] = []
    @Published private(set) var stationSourceMode: StationSourceMode = .nearest

    @Published private(set) var chargingSamples: [ChargingSample] = []
    @Published private(set) var currentChargingEnergyKWh: Double?
    @Published private(set) var chargingSessions: [ChargingSession] = []
    @Published private(set) var selectedChargingSessionID: String?
    @Published private(set) var selectedSessionSamples: [ChargingSample] = []
    @Published private(set) var isLoadingChargingSession = false

    @Published private(set) var energyStats: EnergyStats?
    @Published private(set) var trips: [VehicleTrip] = []
    @Published private(set) var selectedTripID: String?
    @Published private(set) var selectedTripTrack: VehicleTripTrack?
    @Published private(set) var isLoadingTripTrack = false

    @Published private(set) var routePresets: [TVPairingRoutePreset] = []
    @Published private(set) var isSendingRoute = false
    @Published var pendingRoutePopup: SendRoutePopup?
    @Published private(set) var pendingRouteConfirmationToken: String?

    @Published private(set) var isLoading = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var errorMessage: String?
    @Published var feedback: ActionFeedback?
    @Published var targetACTemperature: Double = 22.0

    @Published private(set) var eventStreamStatus: BackendEventStreamStatus = .idle
    @Published private(set) var lastEventName: String?
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var lastEventID: String?

    private let store: TVCredentialStore
    private var vehicleImageETag: String?
    private var vehicleImageVehicleID: String?
    private var monitorTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var revision = UUID()

    init(store: TVCredentialStore = .shared) {
        self.store = store
        reloadStoredSettings()
    }

    var vehicleTitle: String {
        vehicleProfile?.displayTitle ?? "我的蔚来"
    }

    var vehicleColorLabel: String? {
        vehicleProfile?.localizedColorName
    }

    var clampedACTemperature: Double {
        min(max((targetACTemperature * 2).rounded() / 2, 16.0), 30.0)
    }

    var stationSnapshot: SwapStationSnapshot? {
        stationLive?.stationSnapshot()
    }

    func reloadStoredSettings() {
        settings = store.loadSettings()
        isConfigured = (try? store.configuration()) != nil
        hasControlKey = settings?.hasControlKey ?? false
        routePresets = store.loadRoutePresets()
        if let id = settings?.stationID, let name = settings?.stationName {
            stationSourceMode = .selected(id: id, name: name)
        } else {
            stationSourceMode = .nearest
        }
    }

    func saveManualConfiguration(
        baseURLString: String,
        apiKey: String,
        controlKey: String,
        stationID: String?,
        stationName: String?
    ) throws {
        try store.save(
            baseURLString: baseURLString,
            apiKey: apiKey,
            controlKey: controlKey,
            stationID: stationID,
            stationName: stationName
        )
        resetForConfigurationChange()
    }

    func applyPairingPayload(_ payload: TVPairingPayload) throws {
        try store.applyPairingPayload(payload)
        resetForConfigurationChange()
        showFeedback("已从 iPhone 同步配置", isError: false)
    }

    func clearConfiguration() {
        stopMonitoring()
        store.clearAll()
        revision = UUID()
        settings = nil
        isConfigured = false
        hasControlKey = false
        dashboard = nil
        vehicleProfile = nil
        vehicleImageData = nil
        vehicleImageETag = nil
        vehicleImageVehicleID = nil
        activeServiceOrders = []
        stationLive = nil
        nearbyStations = []
        chargingSamples = []
        chargingSessions = []
        selectedSessionSamples = []
        energyStats = nil
        trips = []
        selectedTripTrack = nil
        routePresets = []
        errorMessage = nil
        eventStreamStatus = .idle
    }

    func startMonitoring() {
        guard isConfigured else { return }
        stopMonitoring()
        let currentRevision = revision

        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            while !Task.isCancelled && self.revision == currentRevision {
                let interval: TimeInterval = (self.dashboard?.chargeStateCode == 1
                    || self.dashboard?.hasActiveSpecialStatus == true
                    || !self.activeServiceOrders.isEmpty) ? 20 : 60
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, self.revision == currentRevision else { break }
                await self.refreshLiveOnly()
            }
        }

        sseTask = Task { [weak self] in
            await self?.runEventStreamLoop(for: currentRevision)
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        sseTask?.cancel()
        sseTask = nil
        if eventStreamStatus != .idle {
            eventStreamStatus = .stopped
        }
    }

    func refreshAll() async {
        guard let configuration = try? store.configuration() else {
            isConfigured = false
            return
        }
        let currentRevision = revision
        let client = BackendClient(configuration: configuration)
        isLoading = true
        defer { isLoading = false }

        async let dashboardTask = capture { try await client.fetchDashboard() }
        async let presentationTask = capture {
            try await client.fetchVehiclePresentation(
                cachedETag: self.vehicleImageETag,
                cachedVehicleID: self.vehicleImageVehicleID
            )
        }
        async let ordersTask = capture { try await client.fetchActiveServiceOrders() }
        async let stationTask = capture { try await self.fetchConfiguredStation(client: client) }
        async let currentChargingTask = capture { try await client.fetchCurrentChargingSession() }
        async let sessionsTask = capture { try await client.fetchChargingSessions(limit: 16) }
        async let tripsTask = capture { try await client.fetchVehicleTrips(count: 20) }
        async let energyTask = capture {
            let to = Date()
            let from = Calendar.current.date(byAdding: .day, value: -30, to: to) ?? to.addingTimeInterval(-30 * 86_400)
            return try await client.fetchEnergyStats(from: from, to: to)
        }

        let (dashRes, presRes, ordersRes, stationRes, curChargeRes, sessionsRes, tripsRes, energyRes) = await (
            dashboardTask, presentationTask, ordersTask, stationTask,
            currentChargingTask, sessionsTask, tripsTask, energyTask
        )
        guard revision == currentRevision, !Task.isCancelled else { return }

        switch dashRes {
        case .success(let newDashboard):
            dashboard = newDashboard
            errorMessage = nil
            lastRefreshAt = Date()
            if let loc = newDashboard.location, loc.isValid, nearbyStations.isEmpty {
                Task { [weak self] in
                    await self?.loadNearbyStations(client: client, location: loc, revision: currentRevision)
                }
            }
        case .failure(let msg):
            errorMessage = msg
        }

        if case .success(let presentation) = presRes {
            applyPresentation(presentation)
        }
        if case .success(let page) = ordersRes {
            activeServiceOrders = page.items
        }
        if case .success(let live) = stationRes {
            stationLive = live
        }
        if case .success(let currentPage) = curChargeRes {
            chargingSamples = currentPage.items
            currentChargingEnergyKWh = currentPage.energyKWh
        }
        if case .success(let sessionPage) = sessionsRes {
            chargingSessions = sessionPage.items
            if selectedChargingSessionID == nil, let first = sessionPage.items.first {
                await selectChargingSession(first.id)
            }
        }
        if case .success(let tripPage) = tripsRes {
            trips = tripPage.items
            if selectedTripID == nil, let first = tripPage.items.first {
                await selectTrip(first.id)
            }
        }
        if case .success(let stats) = energyRes {
            energyStats = stats
        }
    }

    func refreshLiveOnly() async {
        guard let configuration = try? store.configuration() else { return }
        let currentRevision = revision
        let client = BackendClient(configuration: configuration)

        async let dashRes = capture { try await client.fetchDashboard() }
        async let ordersRes = capture { try await client.fetchActiveServiceOrders() }
        async let stationRes = capture { try await self.fetchConfiguredStation(client: client) }
        async let chargeRes = capture { try await client.fetchCurrentChargingSession() }

        let (dash, orders, station, charge) = await (dashRes, ordersRes, stationRes, chargeRes)
        guard revision == currentRevision, !Task.isCancelled else { return }

        if case .success(let newDashboard) = dash {
            dashboard = newDashboard
            errorMessage = nil
            lastRefreshAt = Date()
        }
        if case .success(let page) = orders {
            activeServiceOrders = page.items
        }
        if case .success(let live) = station {
            stationLive = live
        }
        if case .success(let currentPage) = charge {
            chargingSamples = currentPage.items
            currentChargingEnergyKWh = currentPage.energyKWh
        }
    }

    func switchStationSource(_ mode: StationSourceMode) async {
        stationSourceMode = mode
        switch mode {
        case .selected(let id, let name):
            store.saveSelectedStation(id: id, name: name)
        case .nearest:
            store.saveSelectedStation(id: nil, name: nil)
        }
        settings = store.loadSettings()
        guard let configuration = try? store.configuration() else { return }
        let client = BackendClient(configuration: configuration)
        if case .success(let live) = await capture({ try await self.fetchConfiguredStation(client: client) }) {
            stationLive = live
        }
    }

    func selectChargingSession(_ sessionID: String) async {
        selectedChargingSessionID = sessionID
        guard let configuration = try? store.configuration() else { return }
        let currentRevision = revision
        isLoadingChargingSession = true
        defer { isLoadingChargingSession = false }
        let client = BackendClient(configuration: configuration)
        if case .success(let page) = await capture({ try await client.fetchChargingSession(id: sessionID) }) {
            guard revision == currentRevision, selectedChargingSessionID == sessionID else { return }
            selectedSessionSamples = page.items
        }
    }

    func selectTrip(_ journeyID: String) async {
        selectedTripID = journeyID
        selectedTripTrack = nil
        guard let configuration = try? store.configuration() else { return }
        let currentRevision = revision
        isLoadingTripTrack = true
        defer { isLoadingTripTrack = false }
        let client = BackendClient(configuration: configuration)
        if case .success(let track) = await capture({ try await client.fetchVehicleTripTrack(journeyID: journeyID) }) {
            guard revision == currentRevision, selectedTripID == journeyID else { return }
            selectedTripTrack = track
        }
    }

    /// Couch-safe remote action execution. Never auto-retried; `unlockStart` is intentionally excluded on TV.
    func performSafeVehicleAction(_ action: VehicleAction) async {
        guard action != .unlockStart else { return }
        guard !isPerformingAction else { return }
        guard let configuration = try? store.configuration(),
              let controlKey = settings?.controlKey,
              (32...512).contains(controlKey.count) else {
            showFeedback("请先配置车控 Key 后再执行远程控制。", isError: true)
            return
        }

        isPerformingAction = true
        defer { isPerformingAction = false }
        let client = BackendClient(configuration: configuration)
        let input = VehicleActionInput(
            action: action,
            temperature: action == .acOn ? clampedACTemperature : nil,
            expandMirrors: action == .guardOn
        )
        do {
            let outcome = try await client.performVehicleAction(input, controlKey: controlKey)
            let summary = Self.describeActionOutcome(outcome, targetTemp: clampedACTemperature)
            showFeedback(summary, isError: false)
            try? await Task.sleep(for: .seconds(1))
            await refreshLiveOnly()
        } catch {
            showFeedback(Self.describe(error), isError: true)
        }
    }

    private static func describeActionOutcome(_ outcome: VehicleActionOutcome, targetTemp: Double) -> String {
        let name: String
        switch outcome.action {
        case .acOn:
            name = String(format: "空调已开启（%.1f°C）", targetTemp)
        case .acOff:
            name = "空调已关闭"
        case .lock:
            name = "车门已上锁"
        case .unlockDoors:
            name = "车门已解锁"
        case .guardOn:
            name = "守卫模式已开启"
        case .guardOff:
            name = "守卫模式已关闭"
        case .find:
            name = "闪灯鸣笛已触发"
        case .findStop:
            name = "已停止寻车"
        case .unlockStart:
            name = "指令已执行"
        }
        return outcome.verified ? "\(name) · 已回传确认" : "\(name) · 已下发"
    }

    func sendFavoriteRoute(_ preset: TVPairingRoutePreset) async {
        guard !isSendingRoute else { return }
        guard let configuration = try? store.configuration() else { return }
        let pois = preset.buildRequestPOIs()
        guard !pois.isEmpty else { return }

        isSendingRoute = true
        defer { isSendingRoute = false }
        let client = BackendClient(configuration: configuration)
        do {
            let payload: SendRouteInput
            if let tag = preset.preferredPlanTag?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let planOutcome = try? await client.planRouteToVehicle(
                   pois,
                   includeChargeStops: preset.enableEnergyPlanning
               ),
               !planOutcome.plans.isEmpty {
                let chosen = planOutcome.plans.first { $0.tagDesc?.trimmingCharacters(in: .whitespacesAndNewlines) == tag }
                    ?? planOutcome.plans[0]
                payload = SendRouteInput(
                    poiList: chosen.poiList,
                    driver: chosen.driver,
                    routeID: chosen.routeID,
                    includeChargeStops: preset.enableEnergyPlanning
                )
            } else {
                payload = SendRouteInput(
                    poiList: pois,
                    includeChargeStops: preset.enableEnergyPlanning
                )
            }
            let outcome = try await client.sendRouteToVehicle(payload)
            handleSendRouteOutcome(outcome, presetName: preset.name)
        } catch {
            showFeedback(Self.describe(error), isError: true)
        }
    }

    func confirmPendingRoute(btnAction: Int) async {
        guard let token = pendingRouteConfirmationToken, !isSendingRoute else { return }
        pendingRoutePopup = nil
        pendingRouteConfirmationToken = nil
        guard let configuration = try? store.configuration() else { return }

        isSendingRoute = true
        defer { isSendingRoute = false }
        let client = BackendClient(configuration: configuration)
        do {
            let outcome = try await client.confirmSendRouteToVehicle(token: token, btnAction: btnAction)
            handleSendRouteOutcome(outcome, presetName: nil)
        } catch {
            showFeedback(Self.describe(error), isError: true)
        }
    }

    func dismissPendingRoutePopup() {
        pendingRoutePopup = nil
        pendingRouteConfirmationToken = nil
    }

    private func handleSendRouteOutcome(_ outcome: SendRouteOutcome, presetName: String?) {
        if let popup = outcome.popupMessage {
            pendingRoutePopup = popup
            pendingRouteConfirmationToken = outcome.confirmationToken
            return
        }
        let toast = outcome.toastMsg?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let toast, !toast.isEmpty {
            showFeedback(toast, isError: false)
        } else if let presetName {
            showFeedback("已将「\(presetName)」发送到车机", isError: false)
        } else {
            showFeedback("路线已发送到车机", isError: false)
        }
    }

    private func resetForConfigurationChange() {
        revision = UUID()
        vehicleImageData = nil
        vehicleImageETag = nil
        vehicleImageVehicleID = nil
        nearbyStations = []
        selectedChargingSessionID = nil
        selectedTripID = nil
        reloadStoredSettings()
        startMonitoring()
    }

    private func fetchConfiguredStation(client: BackendClient) async throws -> NearestStationLive {
        switch stationSourceMode {
        case .selected(let id, _):
            return try await client.fetchStationLiveDetails(id: id)
        case .nearest:
            return try await client.fetchNearestStationLive()
        }
    }

    private func loadNearbyStations(
        client: BackendClient,
        location: VehicleCoordinate,
        revision targetRevision: UUID
    ) async {
        if case .success(let result) = await capture({
            try await client.fetchNearbyStations(latitude: location.latitude, longitude: location.longitude)
        }) {
            guard revision == targetRevision else { return }
            nearbyStations = Array(result.stations.prefix(8))
        }
    }

    private func applyPresentation(_ presentation: VehiclePresentation) {
        vehicleProfile = presentation.profile
        switch presentation.image {
        case .downloaded(let data, let etag):
            vehicleImageData = data
            vehicleImageETag = etag
            vehicleImageVehicleID = presentation.profile.vehicleID
        case .notModified:
            vehicleImageVehicleID = presentation.profile.vehicleID
        case .unavailable:
            vehicleImageData = nil
            vehicleImageETag = nil
            vehicleImageVehicleID = presentation.profile.vehicleID
        case .failed:
            break
        }
    }

    private func runEventStreamLoop(for currentRevision: UUID) async {
        guard let configuration = try? store.configuration() else { return }
        let client = BackendEventStreamClient(configuration: configuration)
        var attempt = 0
        var cursor: String? = lastEventID

        while !Task.isCancelled && revision == currentRevision {
            eventStreamStatus = attempt == 0 ? .connecting : .reconnecting
            var serverRetryMs: Int?
            do {
                let stream = client.events(lastEventID: cursor)
                eventStreamStatus = .connected
                for try await event in stream {
                    guard !Task.isCancelled, revision == currentRevision else { return }
                    attempt = 0
                    if let id = event.id, !id.isEmpty {
                        cursor = id
                        lastEventID = id
                    }
                    if let retry = event.retryMilliseconds {
                        serverRetryMs = retry
                    }
                    lastEventName = event.name
                    lastEventAt = Date()
                    await refreshLiveOnly()
                }
            } catch let error as BackendEventStreamError {
                if case .unauthorized = error {
                    eventStreamStatus = .authenticationFailed
                    return
                }
            } catch {
                if Task.isCancelled || error.isTaskCancellation { return }
            }

            guard !Task.isCancelled, revision == currentRevision else { return }
            eventStreamStatus = .reconnecting
            let delay = BackendEventReconnectPolicy.delay(
                attempt: attempt,
                serverRetryMilliseconds: serverRetryMs,
                jitter: Double.random(in: 0.85...1.15)
            )
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func showFeedback(_ message: String, isError: Bool) {
        feedback = ActionFeedback(message: message, isError: isError)
    }

    private enum CaptureResult<T> {
        case success(T)
        case failure(String)
    }

    private func capture<T>(_ work: () async throws -> T) async -> CaptureResult<T> {
        do {
            return .success(try await work())
        } catch {
            return .failure(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
