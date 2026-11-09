import AppIntents
import Foundation

struct SwapStationEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "换电站")
    static var defaultQuery = SwapStationEntityQuery()

    let id: String

    @Property(title: "名称")
    var name: String

    @Property(title: "地址")
    var address: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: address.map { "\($0)" }
        )
    }

    init(id: String, name: String, address: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
    }
}

struct SwapStationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SwapStationEntity] {
        let client = try Self.client()
        return await withTaskGroup(of: SwapStationEntity?.self) { group in
            for identifier in identifiers {
                group.addTask {
                    guard let station = try? await client.fetchSwapStation(id: identifier) else {
                        return nil
                    }
                    return SwapStationEntity(
                        id: station.stationID,
                        name: station.stationName,
                        address: station.stationAddress
                    )
                }
            }
            var values: [SwapStationEntity] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return identifiers.compactMap { id in values.first(where: { $0.id == id }) }
        }
    }

    func entities(matching string: String) async throws -> [SwapStationEntity] {
        let stations = try await Self.client().searchSwapStations(name: string)
        return stations.map {
            SwapStationEntity(id: $0.stationID, name: $0.name, address: $0.address)
        }
    }

    func suggestedEntities() async throws -> [SwapStationEntity] {
        let page = try await Self.client().fetchSwapStations(limit: 20)
        return page.items.map {
            SwapStationEntity(id: $0.stationID, name: $0.stationName, address: $0.stationAddress)
        }
    }

    func defaultResult() async -> SwapStationEntity? {
        let selection = BackendSettingsStore.shared.watchConfiguration()
        guard let id = selection.stationID, let name = selection.stationName else { return nil }
        return SwapStationEntity(id: id, name: name)
    }

    private static func client() throws -> BackendClient {
        BackendClient(configuration: try BackendSettingsStore.shared.configuration())
    }
}

struct QueryStationBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "查询换电站电池"
    static var description = IntentDescription(
        "查询指定换电站可用的 75 kWh 电池数量和生产日期。可用标准为未占用且电量不低于 92%。"
    )
    static var openAppWhenRun = false

    @Parameter(title: "换电站", requestValueDialog: "要查询哪个换电站？")
    var station: SwapStationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("查询 \(\.$station) 的 75 kWh 电池")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let configuration = try BackendSettingsStore.shared.configuration()
        let status = try await BackendClient(configuration: configuration)
            .fetchSwapStationLive(id: station.id)
        let spoken = Self.spokenResult(for: status, requestedName: station.name)
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }

    static func spokenResult(
        for status: NIOStationLiveStatus,
        requestedName: String
    ) -> String {
        let name = status.stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? requestedName
            : status.stationName
        guard status.available75Count > 0 else {
            return "\(name)目前没有可用的75千瓦时电池。可用标准是未占用，并且电量不低于百分之92。"
        }

        let knownDates = status.available75Batteries.compactMap(\.productionDate).map(spokenDate)
        let unknownDateCount = max(status.available75Count - knownDates.count, 0)
        var result = "\(name)目前有\(status.available75Count)块可用的75千瓦时电池。"
        if !knownDates.isEmpty {
            result += "生产日期分别是\(knownDates.joined(separator: "、"))。"
        }
        if unknownDateCount > 0 {
            result += "另有\(unknownDateCount)块电池暂时没有生产日期。"
        }
        return result
    }

    private static func spokenDate(_ rawValue: String) -> String {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return rawValue }
        return "\(parts[0])年\(month)月\(day)日"
    }
}

struct NIOPowerSwapAssistShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QueryStationBatteryIntent(),
            phrases: [
                "用 \(.applicationName) 查询 \(\.$station) 的电池信息",
                "用 \(.applicationName) 查询 \(\.$station) 有几块75度电池",
                "在 \(.applicationName) 查询 \(\.$station) 换电站"
            ],
            shortTitle: "查询换电站电池",
            systemImageName: "battery.75percent"
        )
    }
}
