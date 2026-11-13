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

    var readyCount: Int { batteries.filter { $0.status == .ready }.count }
    var chargingCount: Int { batteries.filter { $0.status == .charging }.count }
    var occupiedCount: Int { batteries.filter { $0.status == .occupied }.count }

    func dismissError() {
        errorMessage = nil
    }

    var groupedBatteries: [(name: String, batteries: [BatteryModel])] {
        let groups = Dictionary(grouping: batteries, by: \.groupName)
        let priority = [
            "75 kWh": 0,
            "70 kWh": 1,
            "70/75 kWh": 2,
            "100 kWh": 3,
            "150 kWh": 4
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
