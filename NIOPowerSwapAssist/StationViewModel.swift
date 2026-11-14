import Combine
import Foundation

@MainActor
final class StationViewModel: ObservableObject {
    @Published private(set) var batteries: [BatteryModel] = []
    @Published private(set) var feeInfo: FeeInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var currentRequestName: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var failureNotice: APIErrorNotice?
    @Published var errorMessage: String? {
        didSet {
            guard let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else { return }
            failureNotice = APIErrorNotice(message: message)
        }
    }

    private var refreshToken = UUID()
    private var activeRefreshTask: Task<SwapStationSnapshot, Error>?
    private var currentRequest: InfoRequest?
    private let fetchStation: @Sendable (InfoRequest) async throws -> SwapStationSnapshot

    init(fetchStation: @escaping @Sendable (InfoRequest) async throws -> SwapStationSnapshot = { try await $0.fetchSwapStation() }) {
        self.fetchStation = fetchStation
    }

    #if DEBUG
    private var isDesignPreview = false

    static func designPreview() -> StationViewModel {
        let model = StationViewModel()
        model.isDesignPreview = true
        model.batteries = DesignPreviewFixtures.batteries
        model.feeInfo = DesignPreviewFixtures.fees
        model.currentRequestName = "示例换电站 · 科技园区"
        model.lastUpdated = .now
        return model
    }
    #endif

    static let batteryFilterKey = "stationPreferredBatteryType"
    static let allBatteryTypes = "全部"
    static let batteryFilterOptions = [allBatteryTypes, "75 kWh", "70 kWh", "70/75 kWh", "100 kWh", "102 kWh", "150 kWh"]

    /// The battery tier the vehicle actually swaps to, chosen in settings.
    static var preferredBatteryTypeSetting: String {
        get { UserDefaults.standard.string(forKey: batteryFilterKey) ?? allBatteryTypes }
        set { UserDefaults.standard.set(newValue, forKey: batteryFilterKey) }
    }

    var preferredBatteryType: String { Self.preferredBatteryTypeSetting }

    /// Batteries of the preferred tier; every battery when the filter is "全部".
    var visibleBatteries: [BatteryModel] {
        let preferred = preferredBatteryType
        guard preferred != Self.allBatteryTypes, !preferred.isEmpty else { return batteries }
        return batteries.filter { $0.groupName == preferred }
    }

    var readyCount: Int { visibleBatteries.filter { $0.status == .ready }.count }
    var chargingCount: Int { visibleBatteries.filter { $0.status == .charging }.count }
    var occupiedCount: Int { visibleBatteries.filter { $0.status == .occupied }.count }

    /// Marks a backend station lookup as in flight; keeps the current batteries
    /// on screen when the same station is refreshed.
    func beginExternalRefresh(name: String?) {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        refreshToken = UUID()
        if currentRequestName != name {
            batteries = []
            feeInfo = nil
            lastUpdated = nil
        }
        currentRequest = nil
        currentRequestName = name
        errorMessage = nil
        isLoading = true
    }

    func failExternalRefresh(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    /// Shows a snapshot fetched through the backend (nearest station or a saved
    /// station's live data) instead of replaying a saved cURL request.
    func apply(snapshot: SwapStationSnapshot, name: String) {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        refreshToken = UUID()
        currentRequest = nil
        currentRequestName = name
        batteries = snapshot.batteries
        feeInfo = snapshot.feeInfo
        lastUpdated = .now
        errorMessage = nil
        isLoading = false
    }

    func dismissError() {
        errorMessage = nil
    }

    var groupedBatteries: [(name: String, batteries: [BatteryModel])] {
        let groups = Dictionary(grouping: visibleBatteries, by: \.groupName)
        let priority = [
            "75 kWh": 0,
            "70 kWh": 1,
            "70/75 kWh": 2,
            "100 kWh": 3,
            "102 kWh": 4,
            "150 kWh": 5
        ]
        return groups.map { (name: $0.key, batteries: $0.value) }
            .sorted {
                let lhs = priority[$0.name] ?? 99
                let rhs = priority[$1.name] ?? 99
                return lhs == rhs ? $0.name < $1.name : lhs < rhs
            }
    }

    func showNeedsConfiguration() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        refreshToken = UUID()
        currentRequest = nil
        currentRequestName = nil
        batteries = []
        feeInfo = nil
        lastUpdated = nil
        errorMessage = nil
        isLoading = false
    }

    func refresh(request: InfoRequest, name: String?) async {
        #if DEBUG
        if isDesignPreview { return }
        #endif
        if currentRequest == request, let task = activeRefreshTask {
            currentRequestName = name
            _ = try? await task.value
            return
        }

        activeRefreshTask?.cancel()
        let token = UUID()
        refreshToken = token

        if currentRequest != request {
            batteries = []
            feeInfo = nil
            lastUpdated = nil
        }
        currentRequest = request
        currentRequestName = name
        isLoading = true
        errorMessage = nil
        let fetchStation = fetchStation
        let task = Task { try await fetchStation(request) }
        activeRefreshTask = task
        defer {
            if refreshToken == token {
                activeRefreshTask = nil
                isLoading = false
            }
        }

        do {
            let snapshot = try await task.value
            guard refreshToken == token else { return }
            batteries = snapshot.batteries
            feeInfo = snapshot.feeInfo
            lastUpdated = Date()
        } catch is CancellationError {
            return
        } catch {
            guard refreshToken == token else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "刷新失败，请稍后重试。"
        }
    }
}
