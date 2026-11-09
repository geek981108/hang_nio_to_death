import Foundation

enum WatchSharedStorage {
    static let appGroup = "group.com.shuto.happyvalley.watch"
    static let snapshotKey = "watch.vehicle.snapshot.v1"
}

struct WatchSnapshot: Codable, Equatable, Sendable {
    let stateOfCharge: Double?
    let remainingRange: Double?
    let isConnected: Bool
    let isCharging: Bool
    let isSwapping: Bool
    let stationName: String?
    let queueText: String?
    let updatedAt: Date
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
