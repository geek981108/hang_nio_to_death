import Foundation

enum WatchSharedStorage {
    static let appGroup = "group.com.shuto.happyvalley.watch"
    static let snapshotKey = "watch.vehicle.snapshot.v1"
}

struct WatchSnapshot: Codable, Equatable, Sendable {
    let vehicleName: String?
    let stateOfCharge: Double?
    let remainingRange: Double?
    let isConnected: Bool
    let isCharging: Bool
    let isSwapping: Bool
    let isRepairing: Bool
    let isFotaActive: Bool
    let isSVTActive: Bool
    let stationName: String?
    let queueText: String?
    let updatedAt: Date

    init(
        vehicleName: String? = nil,
        stateOfCharge: Double?,
        remainingRange: Double?,
        isConnected: Bool,
        isCharging: Bool,
        isSwapping: Bool,
        isRepairing: Bool = false,
        isFotaActive: Bool = false,
        isSVTActive: Bool = false,
        stationName: String?,
        queueText: String?,
        updatedAt: Date
    ) {
        self.vehicleName = vehicleName
        self.stateOfCharge = stateOfCharge
        self.remainingRange = remainingRange
        self.isConnected = isConnected
        self.isCharging = isCharging
        self.isSwapping = isSwapping
        self.isRepairing = isRepairing
        self.isFotaActive = isFotaActive
        self.isSVTActive = isSVTActive
        self.stationName = stationName
        self.queueText = queueText
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vehicleName = try container.decodeIfPresent(String.self, forKey: .vehicleName)
        stateOfCharge = try container.decodeIfPresent(Double.self, forKey: .stateOfCharge)
        remainingRange = try container.decodeIfPresent(Double.self, forKey: .remainingRange)
        isConnected = try container.decode(Bool.self, forKey: .isConnected)
        isCharging = try container.decode(Bool.self, forKey: .isCharging)
        isSwapping = try container.decodeIfPresent(Bool.self, forKey: .isSwapping) ?? false
        isRepairing = try container.decodeIfPresent(Bool.self, forKey: .isRepairing) ?? false
        isFotaActive = try container.decodeIfPresent(Bool.self, forKey: .isFotaActive) ?? false
        isSVTActive = try container.decodeIfPresent(Bool.self, forKey: .isSVTActive) ?? false
        stationName = try container.decodeIfPresent(String.self, forKey: .stationName)
        queueText = try container.decodeIfPresent(String.self, forKey: .queueText)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

enum WatchSnapshotStore {
    static func load() -> WatchSnapshot? {
        guard let defaults = UserDefaults(suiteName: WatchSharedStorage.appGroup),
              let data = defaults.data(forKey: WatchSharedStorage.snapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    static func save(_ snapshot: WatchSnapshot) {
        guard let defaults = UserDefaults(suiteName: WatchSharedStorage.appGroup),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: WatchSharedStorage.snapshotKey)
    }
}
