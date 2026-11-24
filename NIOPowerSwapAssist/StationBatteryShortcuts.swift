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

enum GuardModeToggleOption: String, AppEnum, Sendable {
    case enable
    case disable

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "守卫模式操作")
    static var caseDisplayRepresentations: [GuardModeToggleOption: DisplayRepresentation] = [
        .enable: DisplayRepresentation(title: "开启"),
        .disable: DisplayRepresentation(title: "关闭")
    ]

    var vehicleAction: VehicleAction {
        switch self {
        case .enable: return .guardOn
        case .disable: return .guardOff
        }
    }
}

enum FindVehicleActionOption: String, AppEnum, Sendable {
    case start
    case stop

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "寻车操作")
    static var caseDisplayRepresentations: [FindVehicleActionOption: DisplayRepresentation] = [
        .start: DisplayRepresentation(title: "开始寻车"),
        .stop: DisplayRepresentation(title: "停止寻车")
    ]

    var vehicleAction: VehicleAction {
        switch self {
        case .start: return .find
        case .stop: return .findStop
        }
    }
}

enum VehicleControlShortcutExecutor {
    static func execute(
        action: VehicleAction,
        temperature: Double? = nil,
        expandMirrors: Bool = false,
        settingsStore: BackendSettingsStore = .shared,
        session: URLSession? = nil
    ) async throws -> String {
        let configuration = try settingsStore.configuration()
        let controlKey = settingsStore.controlKey()
        guard !controlKey.isEmpty else {
            throw BackendClientError.invalidControlKey
        }
        let clampedTemperature = action == .acOn
            ? temperature.map { min(max($0, 16), 30) }
            : nil
        let input = VehicleActionInput(
            action: action,
            temperature: clampedTemperature,
            expandMirrors: action == .guardOn && expandMirrors
        )
        let outcome = try await BackendClient(configuration: configuration, session: session)
            .performVehicleAction(input, controlKey: controlKey)
        return spokenResult(for: outcome, requestedTemperature: clampedTemperature)
    }

    static func spokenResult(
        for outcome: VehicleActionOutcome,
        requestedTemperature: Double? = nil
    ) -> String {
        let actionLabel: String
        if outcome.action == .acOn, let requestedTemperature {
            let formatted = requestedTemperature.rounded() == requestedTemperature
                ? "\(Int(requestedTemperature))℃"
                : String(format: "%.1f℃", requestedTemperature)
            actionLabel = "开启空调（\(formatted)）"
        } else {
            actionLabel = outcome.action.title
        }

        let base: String
        switch outcome.status {
        case "verified":
            base = "\(actionLabel)已完成。"
        case "already_desired":
            base = "车辆原本已处于\(actionLabel)状态，未重复发送指令。"
        case "accepted_unverified":
            base = "\(actionLabel)指令已发送，上游已接受，请结合车辆现场确认。"
        default:
            base = "\(actionLabel)已返回状态：\(outcome.status)。"
        }

        guard let mirrors = outcome.mirrors else { return base }
        switch mirrors {
        case "already_expanded":
            return "\(base)后视镜原本已展开。"
        case "accepted_unverified":
            return "\(base)后视镜展开指令已接受，请现场核对。"
        default:
            return "\(base)后视镜状态：\(mirrors)。"
        }
    }
}

struct SetGuardModeIntent: AppIntent {
    static var title: LocalizedStringResource = "开关守卫模式"
    static var description = IntentDescription("远程开启或关闭车辆守卫模式，无需确认。")
    static var openAppWhenRun = false

    @Parameter(title: "操作", default: .enable)
    var mode: GuardModeToggleOption

    @Parameter(title: "同时展开后视镜", default: false)
    var expandMirrors: Bool

    static var parameterSummary: some ParameterSummary {
        Switch(\.$mode) {
            Case(.enable) {
                Summary("\(\.$mode)守卫模式") {
                    \.$expandMirrors
                }
            }
            DefaultCase {
                Summary("\(\.$mode)守卫模式")
            }
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await VehicleControlShortcutExecutor.execute(
            action: mode.vehicleAction,
            expandMirrors: mode == .enable && expandMirrors
        )
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct LockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource = "远程锁车"
    static var description = IntentDescription("立即发送远程锁车指令，无需确认。")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("远程锁车")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await VehicleControlShortcutExecutor.execute(action: .lock)
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct FindVehicleIntent: AppIntent {
    static var title: LocalizedStringResource = "寻车"
    static var description = IntentDescription("远程开始或停止寻车（鸣笛闪灯），无需确认。")
    static var openAppWhenRun = false

    @Parameter(title: "操作", default: .start)
    var mode: FindVehicleActionOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await VehicleControlShortcutExecutor.execute(action: mode.vehicleAction)
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct StartVehicleACIntent: AppIntent {
    static var title: LocalizedStringResource = "开启车辆空调"
    static var description = IntentDescription("远程开启车辆空调并设置目标温度（16–30℃），无需确认。")
    static var openAppWhenRun = false

    @Parameter(
        title: "目标温度",
        default: 22,
        controlStyle: .stepper,
        inclusiveRange: (16, 30)
    )
    var temperature: Double

    static var parameterSummary: some ParameterSummary {
        Summary("开启车辆空调至 \(\.$temperature)℃")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await VehicleControlShortcutExecutor.execute(
            action: .acOn,
            temperature: temperature
        )
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct StopVehicleACIntent: AppIntent {
    static var title: LocalizedStringResource = "关闭车辆空调"
    static var description = IntentDescription("远程关闭车辆空调，无需确认。")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("关闭车辆空调")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await VehicleControlShortcutExecutor.execute(action: .acOff)
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct UnlockVehicleDoorsIntent: AppIntent {
    static var title: LocalizedStringResource = "远程解锁车门"
    static var description = IntentDescription("立即发送仅解锁车门指令（不授予启动权限），无需确认。")
    static var openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("远程解锁车门")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let spoken = try await VehicleControlShortcutExecutor.execute(action: .unlockDoors)
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
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
        AppShortcut(
            intent: SetGuardModeIntent(),
            phrases: [
                "\(.applicationName)\(\.$mode)守卫模式"
            ],
            shortTitle: "开关守卫模式",
            systemImageName: "shield.lefthalf.filled"
        )
        AppShortcut(
            intent: LockVehicleIntent(),
            phrases: [
                "\(.applicationName)锁车",
                "\(.applicationName)远程锁车",
                "\(.applicationName)锁定车辆"
            ],
            shortTitle: "远程锁车",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: FindVehicleIntent(),
            phrases: [
                "\(.applicationName)寻车",
                "\(.applicationName)\(\.$mode)"
            ],
            shortTitle: "寻车",
            systemImageName: "horn.blast.fill"
        )
        AppShortcut(
            intent: StartVehicleACIntent(),
            phrases: [
                "\(.applicationName)开空调",
                "\(.applicationName)开启空调",
                "\(.applicationName)开启车辆空调"
            ],
            shortTitle: "开启空调",
            systemImageName: "fan.fill"
        )
        AppShortcut(
            intent: StopVehicleACIntent(),
            phrases: [
                "\(.applicationName)关空调",
                "\(.applicationName)关闭空调",
                "\(.applicationName)关闭车辆空调"
            ],
            shortTitle: "关闭空调",
            systemImageName: "fan.slash"
        )
        AppShortcut(
            intent: UnlockVehicleDoorsIntent(),
            phrases: [
                "\(.applicationName)解锁",
                "\(.applicationName)解锁车门",
                "\(.applicationName)开锁"
            ],
            shortTitle: "解锁车门",
            systemImageName: "lock.open.fill"
        )
    }
}
