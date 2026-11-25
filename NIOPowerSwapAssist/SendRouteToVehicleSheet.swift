import Combine
import MapKit
import SwiftUI

/// Explicit route composition model separating optional custom origin,
/// ordered waypoints, and destination so adding/reordering waypoints never
/// overwrites the destination or assigns the wrong `RouteNodeType`.
struct RouteDraft: Equatable, Sendable {
    static let maxWaypoints = 10

    var customOrigin: SendRoutePoiInput?
    var waypoints: [SendRoutePoiInput]
    var destination: SendRoutePoiInput?

    init(
        customOrigin: SendRoutePoiInput? = nil,
        waypoints: [SendRoutePoiInput] = [],
        destination: SendRoutePoiInput? = nil
    ) {
        self.customOrigin = customOrigin
        self.waypoints = Array(waypoints.prefix(Self.maxWaypoints))
        self.destination = destination
    }

    var canAddWaypoint: Bool {
        waypoints.count < Self.maxWaypoints
    }

    var canPlanOrSend: Bool {
        destination != nil
    }

    var suggestedPresetName: String {
        guard let destination else { return "常用路线" }
        if waypoints.isEmpty {
            return destination.name
        }
        return "\(waypoints[0].name) → \(destination.name)"
    }

    mutating func setCustomOrigin(_ poi: SendRoutePoiInput) {
        customOrigin = poi.withStationType(.orig)
    }

    mutating func resetOriginToVehicle() {
        customOrigin = nil
    }

    mutating func setDestination(_ poi: SendRoutePoiInput) {
        destination = poi.withStationType(.dest)
    }

    mutating func clearDestination() {
        destination = nil
    }

    @discardableResult
    mutating func addWaypoint(_ poi: SendRoutePoiInput) -> Bool {
        guard canAddWaypoint else { return false }
        let normalized = poi.withStationType(.waypoint)
        guard !waypoints.contains(where: { $0.id == normalized.id }) else { return false }
        waypoints.append(normalized)
        return true
    }

    mutating func replaceWaypoint(at index: Int, with poi: SendRoutePoiInput) {
        guard waypoints.indices.contains(index) else { return }
        waypoints[index] = poi.withStationType(.waypoint)
    }

    mutating func removeWaypoint(at index: Int) {
        guard waypoints.indices.contains(index) else { return }
        waypoints.remove(at: index)
    }

    mutating func moveWaypointUp(at index: Int) {
        guard index > 0, waypoints.indices.contains(index) else { return }
        waypoints.swapAt(index, index - 1)
    }

    mutating func moveWaypointDown(at index: Int) {
        guard index + 1 < waypoints.count, waypoints.indices.contains(index) else { return }
        waypoints.swapAt(index, index + 1)
    }

    mutating func swapWaypointWithDestination(at index: Int) {
        guard waypoints.indices.contains(index), let currentDestination = destination else { return }
        let promoted = waypoints[index]
        waypoints[index] = currentDestination.withStationType(.waypoint)
        destination = promoted.withStationType(.dest)
    }

    /// Produces the ordered POI payload expected by `/api/v1/vehicle/route/plan`
    /// and `/api/v1/vehicle/route/send`: `[orig?, waypoint..., dest]`.
    func buildRequestPOIs() -> [SendRoutePoiInput] {
        guard let destination else { return [] }
        var result: [SendRoutePoiInput] = []
        if let customOrigin {
            result.append(customOrigin.withStationType(.orig))
        }
        result.append(contentsOf: waypoints.map { $0.withStationType(.waypoint) })
        result.append(destination.withStationType(.dest))
        return result
    }
}

/// Persisted favorite route preset with waypoints and planning preferences.
struct SavedRoutePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var customOrigin: SendRoutePoiInput?
    var waypoints: [SendRoutePoiInput]
    var destination: SendRoutePoiInput
    var enableEnergyPlanning: Bool
    var preferredPlanTag: String?
    let createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        customOrigin: SendRoutePoiInput? = nil,
        waypoints: [SendRoutePoiInput] = [],
        destination: SendRoutePoiInput,
        enableEnergyPlanning: Bool = true,
        preferredPlanTag: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.customOrigin = customOrigin
        self.waypoints = Array(waypoints.prefix(RouteDraft.maxWaypoints))
        self.destination = destination
        self.enableEnergyPlanning = enableEnergyPlanning
        self.preferredPlanTag = preferredPlanTag
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    var draft: RouteDraft {
        RouteDraft(
            customOrigin: customOrigin,
            waypoints: waypoints,
            destination: destination
        )
    }

    var summarySubtitle: String {
        if waypoints.isEmpty {
            return "终点：\(destination.name)"
        }
        return "经 \(waypoints.count) 点 → \(destination.name)"
    }
}

/// Local persistence for favorite routes and the user's energy-planning preference.
struct SavedRouteStore {
    static let maxPresets = 12
    private static let presetsKey = "nio.send_route.saved_presets.v1"
    private static let energyPlanningPrefKey = "nio.send_route.enable_energy_planning.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var defaultEnableEnergyPlanning: Bool {
        get {
            if defaults.object(forKey: Self.energyPlanningPrefKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.energyPlanningPrefKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.energyPlanningPrefKey)
        }
    }

    func loadPresets() -> [SavedRoutePreset] {
        guard let data = defaults.data(forKey: Self.presetsKey),
              let decoded = try? JSONDecoder().decode([SavedRoutePreset].self, from: data) else {
            return []
        }
        return sorted(decoded)
    }

    @discardableResult
    func savePreset(_ preset: SavedRoutePreset) -> [SavedRoutePreset] {
        var list = loadPresets()
        if let existingIndex = list.firstIndex(where: { $0.id == preset.id }) {
            list[existingIndex] = preset
        } else {
            list.insert(preset, at: 0)
        }
        return persist(list)
    }

    @discardableResult
    func markUsed(id: UUID, at date: Date = Date()) -> [SavedRoutePreset] {
        var list = loadPresets()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return list }
        list[index].lastUsedAt = date
        return persist(list)
    }

    @discardableResult
    func rename(id: UUID, name: String) -> [SavedRoutePreset] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return loadPresets() }
        var list = loadPresets()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return list }
        list[index].name = trimmed
        return persist(list)
    }

    @discardableResult
    func delete(id: UUID) -> [SavedRoutePreset] {
        var list = loadPresets()
        list.removeAll { $0.id == id }
        return persist(list)
    }

    private func persist(_ list: [SavedRoutePreset]) -> [SavedRoutePreset] {
        let trimmed = Array(sorted(list).prefix(Self.maxPresets))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: Self.presetsKey)
        }
        return trimmed
    }

    private func sorted(_ list: [SavedRoutePreset]) -> [SavedRoutePreset] {
        list.sorted { lhs, rhs in
            let leftDate = lhs.lastUsedAt ?? lhs.createdAt
            let rightDate = rhs.lastUsedAt ?? rhs.createdAt
            return leftDate > rightDate
        }
    }
}

private extension SendRoutePoiInput {
    func withStationType(_ type: RouteNodeType) -> SendRoutePoiInput {
        SendRoutePoiInput(
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            resourceID: resourceID,
            cloneLatitude: cloneLatitude,
            cloneLongitude: cloneLongitude,
            nextPointDistance: nextPointDistance,
            stationType: type
        )
    }

    var isEnergyResource: Bool {
        if let resourceID, !resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let stationType {
            return stationType == .candidate
                || stationType == .waypointCandidate
                || stationType == .origCandidate
                || stationType == .destCandidate
                || stationType == .resource
        }
        return false
    }
}

struct SendRouteToVehicleSheet: View {
    private enum SendFeedback: Equatable {
        case completed(toast: String, requestID: String?, plannedRoute: PlannedRouteSummary?)
        case resultUnknown(String)
        case failed(String)
    }

    private enum PickerTarget: Identifiable, Equatable {
        case setOrigin
        case setDestination
        case addWaypoint
        case editWaypoint(Int)

        var id: String {
            switch self {
            case .setOrigin: return "origin"
            case .setDestination: return "destination"
            case .addWaypoint: return "add-waypoint"
            case .editWaypoint(let index): return "edit-waypoint-\(index)"
            }
        }

        var title: String {
            switch self {
            case .setOrigin: return "选择起点"
            case .setDestination: return "选择目的地"
            case .addWaypoint: return "添加途经点"
            case .editWaypoint(let index): return "更换途经点 \(index + 1)"
            }
        }

        var searchPlaceholder: String {
            switch self {
            case .setOrigin: return "搜索起点位置或蔚来换电站"
            case .setDestination: return "搜索目的地、商圈或蔚来换电站"
            case .addWaypoint, .editWaypoint: return "搜索途经地点、服务区或蔚来换电站"
            }
        }
    }

    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VehicleViewModel

    private let routeStore = SavedRouteStore()

    @State private var draft: RouteDraft
    @State private var enableEnergyPlanning: Bool
    @State private var preferredPlanTag: String?

    @State private var savedPresets: [SavedRoutePreset]
    @State private var showingSavePresetPrompt = false
    @State private var savePresetName = ""
    @State private var renamingPreset: SavedRoutePreset?
    @State private var renamePresetText = ""
    @State private var quickSendingPresetID: UUID?

    @State private var switchStatus: SendRouteSwitchStatus?
    @State private var isLoadingSwitch = false
    @State private var switchError: String?

    @State private var plannedOutcome: PlanRouteOutcome?
    @State private var selectedPlanIndex = 0
    @State private var isPlanningRoute = false
    @State private var planError: String?
    @State private var planErrorCode: String?
    @State private var planTask: Task<Void, Never>?

    @State private var nearbyStations: [NearbyStation] = []
    @State private var isLoadingNearbyStations = false

    @State private var pickerTarget: PickerTarget?

    @State private var isSending = false
    @State private var feedback: SendFeedback?
    @State private var activePopup: SendRoutePopup?
    @State private var confirmationToken: String?

    init(
        isPresented: Binding<Bool>,
        viewModel: VehicleViewModel,
        initialDestination: SendRoutePoiInput? = nil
    ) {
        let store = SavedRouteStore()
        self._isPresented = isPresented
        self.viewModel = viewModel
        self._draft = State(
            initialValue: RouteDraft(destination: initialDestination?.withStationType(.dest))
        )
        self._enableEnergyPlanning = State(initialValue: store.defaultEnableEnergyPlanning)
        self._savedPresets = State(initialValue: store.loadPresets())
    }

    private var selectedPlan: PlannedRouteOption? {
        guard let plans = plannedOutcome?.plans, !plans.isEmpty else { return nil }
        let safeIndex = min(max(0, selectedPlanIndex), plans.count - 1)
        return plans[safeIndex]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        vehicleStatusStrip
                        if !savedPresets.isEmpty {
                            savedPresetsCard
                        }
                        routeComposerCard
                        if draft.canPlanOrSend {
                            plannedRouteCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomActionBar
            }
            .navigationTitle("发送到车机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
            }
            .task {
                async let switchLoad: Void = loadSwitchStatus()
                async let nearbyLoad: Void = loadNearbyStationsIfNeeded()
                _ = await (switchLoad, nearbyLoad)
                if draft.canPlanOrSend && plannedOutcome == nil {
                    scheduleRoutePlanPreview()
                }
            }
            .onDisappear {
                planTask?.cancel()
            }
            .sheet(item: $pickerTarget) { target in
                RouteLocationPickerSheet(
                    title: target.title,
                    placeholder: target.searchPlaceholder,
                    viewModel: viewModel,
                    searchAnchor: viewModel.dashboard?.location,
                    nearbyStations: nearbyStations,
                    isLoadingNearbyStations: isLoadingNearbyStations,
                    onSelect: { selectedPOI in
                        applySelection(selectedPOI, for: target)
                    }
                )
            }
            .alert("保存为常用路线", isPresented: $showingSavePresetPrompt) {
                TextField("路线名称（如：回家、去公司）", text: $savePresetName)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    saveCurrentRoutePreset()
                }
            } message: {
                Text("将连同途经点、换电站与当前「\(enableEnergyPlanning ? "开启" : "关闭")补能规划」偏好一并保存，支持一键发车机。")
            }
            .alert(
                "重命名常用路线",
                isPresented: Binding(
                    get: { renamingPreset != nil },
                    set: { if !$0 { renamingPreset = nil } }
                ),
                presenting: renamingPreset
            ) { preset in
                TextField("路线名称", text: $renamePresetText)
                Button("取消", role: .cancel) { renamingPreset = nil }
                Button("确定") {
                    savedPresets = routeStore.rename(id: preset.id, name: renamePresetText)
                    renamingPreset = nil
                }
            } message: { _ in
                Text("修改后不会影响已保存的途经点与补能偏好。")
            }
            .alert(
                "车机发送确认",
                isPresented: Binding(
                    get: { activePopup != nil },
                    set: { shown in
                        if !shown {
                            activePopup = nil
                            confirmationToken = nil
                        }
                    }
                ),
                presenting: activePopup
            ) { popup in
                popupActionButtons(for: popup)
            } message: { popup in
                Text(nonEmpty(popup.content) ?? "请确认是否继续发送到车机。")
            }
        }
    }

    // MARK: - Top Compact Vehicle & Switch Bar

    private var vehicleStatusStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "car.side.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.blue)
                .frame(width: 32, height: 32)
                .background(AppPalette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.vehicleTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                switchStatusLabel
            }

            Spacer(minLength: 4)

            if !isLoadingSwitch {
                Button {
                    Task { await loadSwitchStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(AppPalette.canvas, in: Circle())
                }
                .accessibilityLabel("重新检查开关")
            }
        }
        .nioCard(cornerRadius: 18, padding: 12)
    }

    @ViewBuilder
    private var switchStatusLabel: some View {
        if isLoadingSwitch {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在检查车机接收开关…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let switchStatus {
            HStack(spacing: 4) {
                Circle()
                    .fill(switchStatus.enabled ? AppPalette.green : .orange)
                    .frame(width: 6, height: 6)
                Text(
                    switchStatus.enabled
                        ? "车机路线接收已开启"
                        : (switchStatus.exposeSendVehicleButton == false
                           ? "服务端开关未开放"
                           : "服务端开关状态未知")
                )
                .font(.caption2)
                .foregroundStyle(switchStatus.enabled ? AppPalette.green : .orange)
            }
        } else if let switchError {
            Text("开关检查失败：\(switchError)")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else {
            Text("绑定当前车辆发送路线")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Favorite / Saved Routes Quick Bar

    private var savedPresetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("常用路线", systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("点卡片载入 · 点纸飞机一键发车机")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(savedPresets) { preset in
                        savedPresetTile(preset)
                    }
                }
            }
        }
        .nioCard(cornerRadius: 20, padding: 14)
    }

    private func savedPresetTile(_ preset: SavedRoutePreset) -> some View {
        let isQuickSendingThis = quickSendingPresetID == preset.id
        return HStack(spacing: 10) {
            Button {
                applySavedPreset(preset)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(preset.summarySubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(preset.enableEnergyPlanning ? "含补能规划" : "不自动补能")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(preset.enableEnergyPlanning ? AppPalette.green : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (preset.enableEnergyPlanning ? AppPalette.green : Color.secondary).opacity(0.12),
                                in: Capsule()
                            )
                        if let tag = nonEmpty(preset.preferredPlanTag), preset.enableEnergyPlanning {
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppPalette.blue)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(minWidth: 120, maxWidth: 165, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                Task { await quickSendPreset(preset) }
            } label: {
                Group {
                    if isQuickSendingThis {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
                .background(AppPalette.blue, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSending || !viewModel.isConfigured)
            .opacity((isSending || !viewModel.isConfigured) ? 0.5 : 1)
            .accessibilityLabel("一键发送常用路线 \(preset.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button {
                applySavedPreset(preset)
            } label: {
                Label("载入编辑", systemImage: "pencil")
            }
            Button {
                Task { await quickSendPreset(preset) }
            } label: {
                Label("一键发送到车机", systemImage: "paperplane.fill")
            }
            Button {
                renamePresetText = preset.name
                renamingPreset = preset
            } label: {
                Label("重命名", systemImage: "textformat")
            }
            Button(role: .destructive) {
                savedPresets = routeStore.delete(id: preset.id)
            } label: {
                Label("删除常用路线", systemImage: "trash")
            }
        }
    }

    // MARK: - Route Composer Card (Origin -> Waypoints -> Destination + Energy Toggle)

    private var routeComposerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("行程编排", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if draft.canPlanOrSend {
                    Button {
                        savePresetName = draft.suggestedPresetName
                        showingSavePresetPrompt = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "star.badge.plus")
                                .font(.caption2.weight(.semibold))
                            Text("存为常用")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AppPalette.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppPalette.blue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)

            // Origin Row
            routeTimelineRow(
                leadingIcon: {
                    Circle()
                        .fill(AppPalette.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(AppPalette.green.opacity(0.25), lineWidth: 4))
                },
                showTopLine: false,
                showBottomLine: true
            ) {
                HStack(spacing: 8) {
                    Button {
                        pickerTarget = .setOrigin
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("起点")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppPalette.green)
                                Text(draft.customOrigin?.name ?? "车辆当前位置")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Text(originSubtitle)
                                .font(.caption2)
                                .foregroundStyle(originNeedsAttention ? .orange : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if draft.customOrigin != nil {
                        Button("用车位") {
                            draft.resetOriginToVehicle()
                            onRouteDraftChanged()
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(AppPalette.blue.opacity(0.12), in: Capsule())
                    } else {
                        Button("自定义") {
                            pickerTarget = .setOrigin
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(AppPalette.canvas, in: Capsule())
                    }
                }
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 32)

            // Ordered Waypoint Rows
            ForEach(Array(draft.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                let isSwapWaypoint = waypoint.resourceID != nil
                routeTimelineRow(
                    leadingIcon: {
                        if isSwapWaypoint {
                            Image(systemName: "battery.100.bolt")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(AppPalette.green, in: Circle())
                        } else {
                            Text(draft.waypoints.count == 1 ? "经" : "\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Color.orange, in: Circle())
                        }
                    },
                    showTopLine: true,
                    showBottomLine: true
                ) {
                    HStack(spacing: 8) {
                        Button {
                            pickerTarget = .editWaypoint(index)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(waypoint.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if isSwapWaypoint {
                                        swapWaypointBadge
                                    }
                                }
                                if isSwapWaypoint {
                                    Text(
                                        enableEnergyPlanning
                                            ? "已标记为途经换电补能点"
                                            : (nonEmpty(waypoint.address) ?? "换电站途经点")
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(enableEnergyPlanning ? AppPalette.green : .secondary)
                                    .lineLimit(1)
                                } else if let address = nonEmpty(waypoint.address), address != waypoint.name {
                                    Text(address)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 4) {
                            if draft.waypoints.count > 1 {
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        draft.moveWaypointUp(at: index)
                                    }
                                    onRouteDraftChanged()
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 24, height: 24)
                                        .background(AppPalette.canvas, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                .opacity(index == 0 ? 0.3 : 1)
                                .accessibilityLabel("上移途经点")

                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        draft.moveWaypointDown(at: index)
                                    }
                                    onRouteDraftChanged()
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 24, height: 24)
                                        .background(AppPalette.canvas, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(index == draft.waypoints.count - 1)
                                .opacity(index == draft.waypoints.count - 1 ? 0.3 : 1)
                                .accessibilityLabel("下移途经点")
                            }

                            if draft.destination != nil {
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        draft.swapWaypointWithDestination(at: index)
                                    }
                                    onRouteDraftChanged()
                                } label: {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AppPalette.blue)
                                        .frame(width: 24, height: 24)
                                        .background(AppPalette.blue.opacity(0.1), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("与终点互换")
                            }

                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    draft.removeWaypoint(at: index)
                                }
                                onRouteDraftChanged()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除途经点 \(waypoint.name)")
                        }
                    }
                    .padding(.vertical, 10)
                }

                Divider().padding(.leading, 32)
            }

            // Add Waypoint Row
            if draft.canAddWaypoint {
                routeTimelineRow(
                    leadingIcon: {
                        Image(systemName: "plus.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.orange)
                    },
                    showTopLine: true,
                    showBottomLine: true
                ) {
                    Button {
                        pickerTarget = .addWaypoint
                    } label: {
                        HStack(spacing: 6) {
                            Text("添加途经点")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.orange)
                            Spacer()
                            Text(
                                draft.waypoints.isEmpty
                                    ? "可搜蔚来换电站（自动计为补能）"
                                    : "已添加 \(draft.waypoints.count)/\(RouteDraft.maxWaypoints)"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.leading, 32)
            }

            // Destination Row
            routeTimelineRow(
                leadingIcon: {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(AppPalette.blue, in: Circle())
                },
                showTopLine: true,
                showBottomLine: false
            ) {
                if let destination = draft.destination {
                    HStack(spacing: 8) {
                        Button {
                            pickerTarget = .setDestination
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("终点")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AppPalette.blue)
                                    Text(destination.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if destination.resourceID != nil {
                                        swapStationBadge
                                    }
                                }
                                if let address = nonEmpty(destination.address), address != destination.name {
                                    Text(address)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(String(format: "%.4f, %.4f", destination.latitude, destination.longitude))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button("更换") {
                            pickerTarget = .setDestination
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(AppPalette.blue.opacity(0.12), in: Capsule())

                        Button {
                            draft.clearDestination()
                            onRouteDraftChanged()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除目的地")
                    }
                    .padding(.vertical, 10)
                } else {
                    Button {
                        pickerTarget = .setDestination
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(AppPalette.blue)
                            Text("搜索并选择目的地或换电站…")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppPalette.blue)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().padding(.vertical, 8)

            // Energy Route Planning Toggle (persisted preference)
            HStack(spacing: 10) {
                Image(systemName: enableEnergyPlanning ? "bolt.car.fill" : "car.fill")
                    .font(.subheadline)
                    .foregroundStyle(enableEnergyPlanning ? AppPalette.green : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("开启加电补能规划")
                        .font(.subheadline.weight(.medium))
                    Text(
                        enableEnergyPlanning
                            ? "自动规划沿途换电/充电站与单站补能用时"
                            : "关闭后仍自动获取官方 route_id，仅不插入沿途自动补能站"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                Spacer(minLength: 6)
                Toggle("开启加电补能规划", isOn: $enableEnergyPlanning)
                    .labelsHidden()
                    .tint(AppPalette.green)
                    .onChange(of: enableEnergyPlanning) { _, enabled in
                        routeStore.defaultEnableEnergyPlanning = enabled
                        onEnergyPlanningToggled(enabled)
                    }
            }
            .padding(.top, 2)
        }
        .nioCard(cornerRadius: 22, padding: 14)
    }

    private func routeTimelineRow<Icon: View, Content: View>(
        @ViewBuilder leadingIcon: () -> Icon,
        showTopLine: Bool,
        showBottomLine: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(showTopLine ? Color.secondary.opacity(0.25) : Color.clear)
                        .frame(width: 2)
                    Rectangle()
                        .fill(showBottomLine ? Color.secondary.opacity(0.25) : Color.clear)
                        .frame(width: 2)
                }
                leadingIcon()
            }
            .frame(width: 22)

            content()
        }
    }

    private var swapStationBadge: some View {
        Text("换电站")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppPalette.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppPalette.green.opacity(0.14), in: Capsule())
    }

    private var swapWaypointBadge: some View {
        Text("换电补能")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppPalette.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppPalette.green.opacity(0.14), in: Capsule())
    }

    private var originNeedsAttention: Bool {
        draft.customOrigin == nil && viewModel.dashboard?.location?.isValid != true
    }

    private var originSubtitle: String {
        if let custom = draft.customOrigin {
            return nonEmpty(custom.address)
                ?? String(format: "%.4f, %.4f", custom.latitude, custom.longitude)
        }
        if viewModel.dashboard?.location?.isValid == true {
            return enableEnergyPlanning
                ? "后端将自动获取车辆实时定位并规划加电路线"
                : "后端将自动获取车辆实时定位并生成官方路线（不自动补能）"
        }
        return "暂无车辆定位样本，可点击右侧「自定义」指定起点"
    }

    // MARK: - NIO Energy Map Route Preview Card (with Per-Stop Durations)

    private var plannedRouteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    enableEnergyPlanning ? "加电路线预览" : "路线预览（已关闭自动补能）",
                    systemImage: enableEnergyPlanning ? "bolt.car.fill" : "map.fill"
                )
                .font(.headline)
                Spacer()
                Button {
                    scheduleRoutePlanPreview()
                } label: {
                    HStack(spacing: 4) {
                        if isPlanningRoute {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                        }
                        Text(isPlanningRoute ? "规划中…" : "重新规划")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppPalette.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppPalette.blue.opacity(0.12), in: Capsule())
                }
                .disabled(isPlanningRoute || !draft.canPlanOrSend || !viewModel.isConfigured)
            }

            if isPlanningRoute {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        enableEnergyPlanning
                            ? "正在调用蔚来加电地图规划沿途换电/充电站与单站用时…"
                            : "正在获取蔚来官方路线与 route_id（不插入自动补能站）…"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14))
            } else if let planError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("路线规划未成功", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(planError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if planErrorCode == "vehicle_position_unavailable" && draft.customOrigin == nil {
                        Button {
                            pickerTarget = .setOrigin
                        } label: {
                            Label("手动指定起点", systemImage: "mappin.and.ellipse")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(AppPalette.blue, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14))
            } else if let plans = plannedOutcome?.plans, !plans.isEmpty {
                if plans.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                                let isSelected = index == selectedPlanIndex
                                Button {
                                    selectedPlanIndex = index
                                    preferredPlanTag = nonEmpty(plan.tagDesc)
                                    clearConfirmationOnly()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(nonEmpty(plan.tagDesc) ?? "方案 \(index + 1)")
                                            .font(.caption.weight(.semibold))
                                        Text(
                                            [
                                                nonEmpty(plan.driveDistanceDesc),
                                                nonEmpty(plan.planDurationDesc),
                                                nonEmpty(plan.chargeDurationDesc)
                                            ]
                                            .compactMap { $0 }
                                            .joined(separator: " · ")
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .background(
                                        isSelected ? AppPalette.blue : AppPalette.canvas,
                                        in: RoundedRectangle(cornerRadius: 12)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let plan = selectedPlan {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            if let tag = nonEmpty(plan.tagDesc) {
                                Text(tag)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppPalette.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(AppPalette.blue.opacity(0.12), in: Capsule())
                            }
                            if let distance = nonEmpty(plan.driveDistanceDesc) {
                                Text(distance)
                                    .font(.subheadline.weight(.semibold))
                            }
                            if let duration = nonEmpty(plan.planDurationDesc) ?? nonEmpty(plan.driveDurationDesc) {
                                Text("· \(duration)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }

                        let metaItems = [
                            nonEmpty(plan.chargeDesc),
                            nonEmpty(plan.chargeDurationDesc),
                            nonEmpty(plan.tollChargeDesc)
                        ].compactMap { $0 }
                        if !metaItems.isEmpty {
                            Text(metaItems.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !enableEnergyPlanning {
                            Label(
                                plan.chargeStations.isEmpty
                                    ? "已关闭自动补能 · 不插入沿途补能站，保留官方 route_id"
                                    : "已关闭自动补能 · 仅保留你手动添加的 \(plan.chargeStations.count) 座补能站",
                                systemImage: "bolt.slash.fill"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        if plan.hasRisk == true {
                            Label("沿途存在续航提醒，请留意推荐补能站点", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        // Prefer rich `card_steps` (includes per-stop charging/swap duration & SOC).
                        if !plan.steps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(enableEnergyPlanning ? "全程补能与节点详情" : "将发送至车机的路线节点")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                                    plannedStepRow(
                                        step,
                                        isFirst: index == 0,
                                        isLast: index == plan.steps.count - 1
                                    )
                                }
                            }
                            .padding(.top, 2)
                        } else if !plan.poiList.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(enableEnergyPlanning ? "车机将接收的完整节点（含沿途补能）" : "车机将接收的路线节点")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(plan.poiList.enumerated()), id: \.offset) { _, node in
                                    plannedNodeFallbackRow(node, stations: plan.chargeStations)
                                }
                            }
                            .padding(.top, 2)
                        }

                        if let routeID = nonEmpty(plan.routeID) {
                            Text("官方 route_id：\(routeID) · 共 \(plan.poiList.count) 个车机节点")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .nioCard(cornerRadius: 22, padding: 16)
    }

    private func plannedStepRow(_ step: PlannedRouteStep, isFirst: Bool, isLast: Bool) -> some View {
        let isSwap = step.resourceType == "PowerSwap"
            || step.resourceType == "FakePowerSwap"
            || step.isPowerSwapClone
            || (step.resourceID?.hasPrefix("PS-") == true)
        let isCharge = step.resourceType == "ChargeStation"
        let (iconName, tint, badge): (String, Color, String) = {
            if step.isEnergyStop {
                if isCharge {
                    return ("bolt.fill", AppPalette.blue, "充电")
                }
                return ("battery.100.bolt", AppPalette.green, isSwap ? "换电" : "补能")
            }
            if isFirst { return ("circle.fill", AppPalette.green, "起点") }
            if isLast { return ("flag.fill", AppPalette.blue, "终点") }
            return ("mappin.circle.fill", .orange, "途经")
        }()

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(tint.opacity(0.12), in: Capsule())
                    Text(step.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let distance = nonEmpty(step.distanceDesc) {
                        Text(distance)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                if let subtitle = nonEmpty(step.subtitle) {
                    Text(subtitle)
                        .font(.caption2.weight(step.isEnergyStop ? .medium : .regular))
                        .foregroundStyle(step.isEnergyStop ? tint : .secondary)
                }

                let showSOCChip: Bool = {
                    guard let soc = step.remainSOC else { return false }
                    if let subtitle = step.subtitle, subtitle.contains("\(soc)%") {
                        return false
                    }
                    return true
                }()

                if showSOCChip || !step.tags.isEmpty {
                    HStack(spacing: 6) {
                        if showSOCChip, let soc = step.remainSOC {
                            Text("剩余 \(soc)%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                        ForEach(step.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(tint.opacity(0.1), in: Capsule())
                        }
                    }
                }

                if let risk = nonEmpty(step.riskMsg) {
                    Text(risk)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func plannedNodeFallbackRow(
        _ node: SendRoutePoiInput,
        stations: [PlannedRouteStation]
    ) -> some View {
        let matchedStation = stations.first {
            (node.resourceID != nil && $0.resourceID == node.resourceID) || $0.name == node.name
        }
        let isEnergy = node.isEnergyResource || matchedStation != nil
        let isCharge = matchedStation?.resourceType == "ChargeStation"
        let (iconName, tint, badge): (String, Color, String) = {
            if isEnergy {
                return isCharge
                    ? ("bolt.fill", AppPalette.blue, "充电")
                    : ("battery.100.bolt", AppPalette.green, "换电")
            }
            switch node.stationType {
            case .orig: return ("circle.fill", AppPalette.green, "起点")
            case .dest: return ("flag.fill", AppPalette.blue, "终点")
            case .waypoint: return ("mappin.circle.fill", .orange, "途经")
            default: return ("mappin", .secondary, "节点")
            }
        }()

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(tint.opacity(0.12), in: Capsule())
                    Text(node.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let distance = nonEmpty(matchedStation?.distanceDesc) {
                        Text(distance)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let duration = nonEmpty(matchedStation?.durationDesc) {
                    Text(duration)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(tint)
                }
            }
        }
    }

    // MARK: - Pinned Bottom Action Bar & Feedback

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            if let feedback {
                feedbackBanner(feedback)
            }

            HStack {
                Text(bottomSummaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Button {
                Task { await sendNow() }
            } label: {
                HStack(spacing: 8) {
                    if isSending || isPlanningRoute {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(sendButtonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(AppPalette.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.98))
            .disabled(!draft.canPlanOrSend || isSending || isPlanningRoute || !viewModel.isConfigured)
            .opacity((!draft.canPlanOrSend || isSending || isPlanningRoute || !viewModel.isConfigured) ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var sendButtonTitle: String {
        if isSending { return "正在发送到车机…" }
        if isPlanningRoute { return enableEnergyPlanning ? "正在规划加电路线…" : "正在生成官方路线…" }
        if !enableEnergyPlanning { return "发送到车机（不自动补能）" }
        if selectedPlan != nil { return "发送规划路线到车机" }
        return "自动规划并发送到车机"
    }

    private var bottomSummaryLine: String {
        if !draft.canPlanOrSend {
            return "请先选择目的地，可按需添加途经点或点上方常用路线一键发送"
        }
        if isPlanningRoute {
            return enableEnergyPlanning
                ? "正在获取蔚来官方路线、沿途换电站与各站补能用时…"
                : "正在获取蔚来官方路线与 route_id（不插入自动补能站）…"
        }
        if let plan = selectedPlan {
            let parts = [
                enableEnergyPlanning ? nonEmpty(plan.tagDesc) : "不自动补能",
                nonEmpty(plan.driveDistanceDesc),
                nonEmpty(plan.planDurationDesc) ?? nonEmpty(plan.driveDurationDesc),
                enableEnergyPlanning
                    ? (nonEmpty(plan.chargeDurationDesc) ?? (plan.chargeStations.isEmpty ? nil : "含 \(plan.chargeStations.count) 座补能站"))
                    : nil
            ].compactMap { $0 }
            if !parts.isEmpty {
                return "将发送：\(parts.joined(separator: " · "))"
            }
        }
        if !enableEnergyPlanning {
            let wpDesc = draft.waypoints.isEmpty ? "" : "（含 \(draft.waypoints.count) 个途经点）"
            return "已关闭自动补能：发送时自动生成官方 route_id 至 \(draft.destination?.name ?? "目的地")\(wpDesc)"
        }
        if !draft.waypoints.isEmpty {
            return "含 \(draft.waypoints.count) 个途经点 · 发送时后端自动获取官方加电路线"
        }
        return "发送时后端将自动获取官方 route_id 与沿途补能方案"
    }

    @ViewBuilder
    private func feedbackBanner(_ feedback: SendFeedback) -> some View {
        switch feedback {
        case .completed(let toast, let requestID, let plannedRoute):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.green)
                    Spacer()
                    Button {
                        self.feedback = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let plannedRoute {
                    let meta = [
                        nonEmpty(plannedRoute.driveDistanceDesc),
                        nonEmpty(plannedRoute.planDurationDesc),
                        nonEmpty(plannedRoute.chargeDurationDesc) ?? nonEmpty(plannedRoute.chargeDesc)
                    ].compactMap { $0 }
                    if !meta.isEmpty {
                        Text("已规划：\(meta.joined(separator: " · "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !plannedRoute.chargeStationNames.isEmpty {
                        Text("沿途补能：\(plannedRoute.chargeStationNames.joined(separator: " → "))")
                            .font(.caption)
                            .foregroundStyle(AppPalette.green)
                            .lineLimit(2)
                    }
                }
                Text("蔚来云端已受理，请在车机导航界面确认接收结果。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let routeID = nonEmpty(plannedRoute?.routeID) {
                    Text("路线 ID：\(routeID)" + (requestID.map { " · 请求 \($0)" } ?? ""))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppPalette.green.opacity(0.32), lineWidth: 1)
            }

        case .resultUnknown(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("发送结果未知", systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button { self.feedback = nil } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("发送未完成", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.red)
                    Spacer()
                    Button { self.feedback = nil } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppPalette.red.opacity(0.28), lineWidth: 1)
            }
        }
    }

    // MARK: - Actions, Saved Presets & Networking

    private func saveCurrentRoutePreset() {
        guard let destination = draft.destination else { return }
        let trimmed = savePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? draft.suggestedPresetName : trimmed
        let preset = SavedRoutePreset(
            name: name,
            customOrigin: draft.customOrigin,
            waypoints: draft.waypoints,
            destination: destination,
            enableEnergyPlanning: enableEnergyPlanning,
            preferredPlanTag: nonEmpty(selectedPlan?.tagDesc) ?? preferredPlanTag,
            lastUsedAt: Date()
        )
        savedPresets = routeStore.savePreset(preset)
    }

    private func applySavedPreset(_ preset: SavedRoutePreset) {
        draft = preset.draft
        preferredPlanTag = preset.preferredPlanTag
        enableEnergyPlanning = preset.enableEnergyPlanning
        routeStore.defaultEnableEnergyPlanning = preset.enableEnergyPlanning
        savedPresets = routeStore.markUsed(id: preset.id)
        onRouteDraftChanged()
    }

    private func quickSendPreset(_ preset: SavedRoutePreset) async {
        guard !isSending, viewModel.isConfigured else { return }
        // Sync UI composer to the preset so user clearly sees what was sent
        // and any server confirmation popup matches the displayed route.
        draft = preset.draft
        preferredPlanTag = preset.preferredPlanTag
        enableEnergyPlanning = preset.enableEnergyPlanning
        routeStore.defaultEnableEnergyPlanning = preset.enableEnergyPlanning
        savedPresets = routeStore.markUsed(id: preset.id)
        planTask?.cancel()
        plannedOutcome = nil
        planError = nil
        planErrorCode = nil
        feedback = nil
        clearConfirmationOnly()

        isSending = true
        quickSendingPresetID = preset.id
        defer {
            isSending = false
            quickSendingPresetID = nil
        }

        let pois = preset.draft.buildRequestPOIs()
        guard !pois.isEmpty else { return }

        do {
            let payload: SendRouteInput
            if let tag = nonEmpty(preset.preferredPlanTag),
               let planResult = try? await viewModel.planRouteToVehicle(
                   pois,
                   includeChargeStops: preset.enableEnergyPlanning
               ),
               !planResult.plans.isEmpty {
                plannedOutcome = planResult
                let idx = planResult.plans.firstIndex {
                    nonEmpty($0.tagDesc) == tag
                } ?? 0
                selectedPlanIndex = idx
                let chosen = planResult.plans[idx]
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
            let outcome = try await viewModel.sendRouteToVehicle(payload)
            applyOutcome(outcome)
        } catch {
            applyError(error)
        }
    }

    private func onEnergyPlanningToggled(_ enabled: Bool) {
        feedback = nil
        clearConfirmationOnly()
        planTask?.cancel()
        plannedOutcome = nil
        selectedPlanIndex = 0
        planError = nil
        planErrorCode = nil
        if draft.canPlanOrSend {
            scheduleRoutePlanPreview()
        } else {
            isPlanningRoute = false
        }
    }

    @ViewBuilder
    private func popupActionButtons(for popup: SendRoutePopup) -> some View {
        let leftTitle = nonEmpty(popup.leftBtnText)
        let rightTitle = nonEmpty(popup.rightBtnText)
        if let leftTitle {
            Button(leftTitle) {
                handlePopupChoice(action: popup.leftBtnAction)
            }
        }
        if let rightTitle {
            Button(rightTitle) {
                handlePopupChoice(action: popup.rightBtnAction)
            }
        }
        if leftTitle == nil && rightTitle == nil {
            Button("知道了", role: .cancel) {
                clearConfirmationOnly()
            }
        }
    }

    private func handlePopupChoice(action: Int?) {
        let token = confirmationToken
        clearConfirmationOnly()
        guard let action, let token else { return }
        Task { await confirmPopup(token: token, btnAction: action) }
    }

    private func clearConfirmationOnly() {
        activePopup = nil
        confirmationToken = nil
    }

    private func applySelection(_ poi: SendRoutePoiInput, for target: PickerTarget) {
        switch target {
        case .setOrigin:
            draft.setCustomOrigin(poi)
        case .setDestination:
            draft.setDestination(poi)
        case .addWaypoint:
            _ = draft.addWaypoint(poi)
        case .editWaypoint(let index):
            draft.replaceWaypoint(at: index, with: poi)
        }
        onRouteDraftChanged()
    }

    private func onRouteDraftChanged() {
        feedback = nil
        clearConfirmationOnly()
        planTask?.cancel()
        plannedOutcome = nil
        selectedPlanIndex = 0
        planError = nil
        planErrorCode = nil
        if draft.canPlanOrSend {
            scheduleRoutePlanPreview()
        }
    }

    private func scheduleRoutePlanPreview() {
        planTask?.cancel()
        let pois = draft.buildRequestPOIs()
        guard !pois.isEmpty, viewModel.isConfigured else { return }
        let includeChargeStops = enableEnergyPlanning
        planTask = Task {
            await performRoutePlanPreview(pois: pois, includeChargeStops: includeChargeStops)
        }
    }

    private func performRoutePlanPreview(
        pois: [SendRoutePoiInput],
        includeChargeStops: Bool
    ) async {
        isPlanningRoute = true
        planError = nil
        planErrorCode = nil
        defer { isPlanningRoute = false }
        do {
            let outcome = try await viewModel.planRouteToVehicle(
                pois,
                includeChargeStops: includeChargeStops
            )
            guard !Task.isCancelled else { return }
            plannedOutcome = outcome
            if let preferred = nonEmpty(preferredPlanTag),
               let matchedIndex = outcome.plans.firstIndex(where: { nonEmpty($0.tagDesc) == preferred }) {
                selectedPlanIndex = matchedIndex
            } else {
                selectedPlanIndex = 0
            }
        } catch {
            guard !Task.isCancelled, !error.isTaskCancellation else { return }
            if case let BackendClientError.serverFailure(code, _, _) = error {
                planErrorCode = code
            }
            planError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadSwitchStatus() async {
        guard !isLoadingSwitch, viewModel.isConfigured else { return }
        isLoadingSwitch = true
        switchError = nil
        defer { isLoadingSwitch = false }
        do {
            switchStatus = try await viewModel.fetchSendRouteSwitch()
        } catch {
            if !error.isTaskCancellation {
                switchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadNearbyStationsIfNeeded() async {
        guard nearbyStations.isEmpty,
              !isLoadingNearbyStations,
              viewModel.isConfigured,
              let location = viewModel.dashboard?.location,
              location.isValid else { return }
        isLoadingNearbyStations = true
        defer { isLoadingNearbyStations = false }
        if let result = try? await viewModel.fetchNearbyStations(
            latitude: location.latitude,
            longitude: location.longitude
        ) {
            nearbyStations = Array(result.stations.prefix(8))
        }
    }

    private func sendNow() async {
        guard draft.canPlanOrSend, !isSending, !isPlanningRoute else { return }
        isSending = true
        feedback = nil
        clearConfirmationOnly()
        defer { isSending = false }
        do {
            let payload: SendRouteInput
            if let plan = selectedPlan {
                payload = SendRouteInput(
                    poiList: plan.poiList,
                    driver: plan.driver,
                    routeID: plan.routeID,
                    includeChargeStops: enableEnergyPlanning
                )
            } else {
                payload = SendRouteInput(
                    poiList: draft.buildRequestPOIs(),
                    includeChargeStops: enableEnergyPlanning
                )
            }
            let outcome = try await viewModel.sendRouteToVehicle(payload)
            applyOutcome(outcome)
        } catch {
            applyError(error)
        }
    }

    private func confirmPopup(token: String, btnAction: Int) async {
        guard !isSending else { return }
        isSending = true
        feedback = nil
        defer { isSending = false }
        do {
            let outcome = try await viewModel.confirmSendRouteToVehicle(
                token: token,
                btnAction: btnAction
            )
            applyOutcome(outcome)
        } catch {
            applyError(error)
        }
    }

    private func applyOutcome(_ outcome: SendRouteOutcome) {
        if let popup = outcome.popupMessage {
            activePopup = popup
            confirmationToken = outcome.confirmationToken
            return
        }
        let message = nonEmpty(outcome.toastMsg) ?? "已提交发送请求"
        let summary = outcome.plannedRoute ?? selectedPlan.map { plan in
            PlannedRouteSummary(
                routeID: plan.routeID,
                tagDesc: plan.tagDesc,
                driveDistanceDesc: plan.driveDistanceDesc,
                planDurationDesc: plan.planDurationDesc ?? plan.driveDurationDesc,
                chargeDesc: plan.chargeDesc,
                chargeDurationDesc: plan.chargeDurationDesc,
                chargeTimes: plan.driver?.chargeTimes,
                chargeStationNames: plan.chargeStations.map(\.name),
                poiCount: plan.poiList.count
            )
        }
        feedback = .completed(toast: message, requestID: outcome.requestID, plannedRoute: summary)
    }

    private func applyError(_ error: Error) {
        if case let BackendClientError.serverFailure(code, _, _) = error,
           code == "send_route_result_unknown" {
            feedback = .resultUnknown(
                (error as? LocalizedError)?.errorDescription ?? "发送超时，结果未知。"
            )
            return
        }
        feedback = .failed(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Live Autocomplete + NIO Swap Station Dual Location Picker Sheet

@MainActor
private final class RouteSearchCompleterModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var completions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateRegion(around location: VehicleCoordinate?) {
        guard let location, location.isValid else { return }
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
        )
    }

    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completer.cancel()
            completions = []
        } else {
            completer.queryFragment = trimmed
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.completions = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.completions = []
        }
    }
}

private struct RouteLocationPickerSheet: View {
    let title: String
    let placeholder: String
    @ObservedObject var viewModel: VehicleViewModel
    let searchAnchor: VehicleCoordinate?
    let nearbyStations: [NearbyStation]
    let isLoadingNearbyStations: Bool
    let onSelect: (SendRoutePoiInput) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completerModel = RouteSearchCompleterModel()
    @FocusState private var isSearchFocused: Bool

    @State private var query = ""
    @State private var directResults: [MKMapItem] = []
    @State private var matchedSwapStations: [NIOStationSearchResult.Station] = []
    @State private var isSearching = false
    @State private var isSearchingStations = false
    @State private var searchError: String?
    @State private var stationSearchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField(placeholder, text: $query)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .submitLabel(.search)
                            .onSubmit { Task { await performDirectSearch() } }
                            .onChange(of: query) { _, newValue in
                                searchError = nil
                                directResults = []
                                completerModel.updateQuery(newValue)
                                scheduleSwapStationSearch(for: newValue)
                            }
                        if !query.isEmpty {
                            Button {
                                query = ""
                                directResults = []
                                matchedSwapStations = []
                                searchError = nil
                                stationSearchTask?.cancel()
                                completerModel.updateQuery("")
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 12))

                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("搜索") {
                            Task { await performDirectSearch() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.blue)
                        .disabled(isSearching)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                List {
                    if isSearching || isSearchingStations {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在搜索地点与蔚来换电站…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let searchError {
                        Text(searchError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // NIO Official Swap Station matches (with resource_id -> PowerSwap energy stop)
                    if !matchedSwapStations.isEmpty {
                        Section("蔚来换电站（按换电补能规划）") {
                            ForEach(matchedSwapStations.prefix(8)) { station in
                                Button {
                                    if let lat = station.latitude, let lon = station.longitude, station.hasValidCoordinates {
                                        let poi = SendRoutePoiInput(
                                            name: station.name,
                                            address: station.address ?? station.name,
                                            latitude: lat,
                                            longitude: lon,
                                            resourceID: station.stationID
                                        )
                                        onSelect(poi)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "battery.100.bolt")
                                            .foregroundStyle(AppPalette.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(station.name)
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text("补能站")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(AppPalette.green)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(AppPalette.green.opacity(0.14), in: Capsule())
                                            }
                                            if let address = station.address, !address.isEmpty {
                                                Text(address)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(AppPalette.green)
                                    }
                                }
                                .disabled(!station.hasValidCoordinates)
                            }
                        }
                    }

                    if !directResults.isEmpty {
                        Section("地图地点") {
                            ForEach(Array(directResults.prefix(12).enumerated()), id: \.offset) { _, item in
                                Button {
                                    selectMapItem(item)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundStyle(AppPalette.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name ?? "未知地点")
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            if let subtitle = item.placemark.title, !subtitle.isEmpty {
                                                Text(subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else if !completerModel.completions.isEmpty {
                        Section("地图联想建议") {
                            ForEach(Array(completerModel.completions.prefix(10).enumerated()), id: \.offset) { _, completion in
                                Button {
                                    Task { await resolveCompletion(completion) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(completion.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            if !completion.subtitle.isEmpty {
                                                Text(completion.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section("附近蔚来换电站（按换电补能规划）") {
                            if isLoadingNearbyStations {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在获取附近换电站…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if nearbyStations.isEmpty {
                                Text("输入地点或换电站关键词开始搜索，支持同时匹配蔚来官方换电站与地图地点。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(nearbyStations) { station in
                                    Button {
                                        let poi = SendRoutePoiInput(
                                            name: station.displayName,
                                            address: station.displayName,
                                            latitude: station.latitude,
                                            longitude: station.longitude,
                                            resourceID: station.stationID
                                        )
                                        onSelect(poi)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "battery.100.bolt")
                                                .foregroundStyle(AppPalette.green)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(station.displayName)
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(String(format: "直线距离 %.1f km · 换电补能站", station.straightLineDistanceKm))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundStyle(AppPalette.green)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                completerModel.updateRegion(around: searchAnchor)
                isSearchFocused = true
            }
            .onDisappear {
                stationSearchTask?.cancel()
            }
        }
    }

    private func scheduleSwapStationSearch(for rawQuery: String) {
        stationSearchTask?.cancel()
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, viewModel.isConfigured else {
            matchedSwapStations = []
            isSearchingStations = false
            return
        }
        stationSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await searchSwapStations(trimmed)
        }
    }

    private func searchSwapStations(_ trimmed: String) async {
        guard viewModel.isConfigured else { return }
        isSearchingStations = true
        defer { isSearchingStations = false }
        if let results = try? await viewModel.searchSwapStations(name: trimmed), !Task.isCancelled {
            matchedSwapStations = results.filter(\.hasValidCoordinates)
        }
    }

    private func performDirectSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        searchError = nil
        stationSearchTask?.cancel()
        defer { isSearching = false }

        async let stationTask: Void = searchSwapStations(trimmed)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let searchAnchor, searchAnchor.isValid {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: searchAnchor.latitude, longitude: searchAnchor.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            _ = await stationTask
            directResults = response.mapItems
            if response.mapItems.isEmpty && matchedSwapStations.isEmpty {
                searchError = "未找到匹配地点或换电站，请尝试更具体的关键词。"
            }
        } catch {
            _ = await stationTask
            if matchedSwapStations.isEmpty {
                searchError = "地点搜索失败，请稍后重试。"
            }
        }
    }

    private func resolveCompletion(_ completion: MKLocalSearchCompletion) async {
        guard !isSearching else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        let request = MKLocalSearch.Request(completion: completion)
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let first = response.mapItems.first {
                selectMapItem(first)
            } else {
                searchError = "未能解析该地点坐标，请换一个结果试试。"
            }
        } catch {
            searchError = "解析地点失败，请稍后重试。"
        }
    }

    private func selectMapItem(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        let rawName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (rawName?.isEmpty == false ? rawName : nil) ?? item.placemark.title ?? "已选地点"
        let poi = SendRoutePoiInput(
            name: resolvedName,
            address: item.placemark.title,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        onSelect(poi)
        dismiss()
    }
}
