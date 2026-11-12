import SwiftUI
import UIKit

struct VehicleDetailView: View {
    @ObservedObject var viewModel: VehicleViewModel
    let openSettings: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDay: Date?
    @State private var hiddenPathSegmentIDs: Set<String> = []
    @State private var showsAllPathSegments = false
    @State private var showingStandardRange = false
    @State private var batteryPulseID: UUID?
    @State private var batteryTapCount = 0
    @State private var vehicleControlPresentation: VehicleControlPresentation?
    @State private var queuedVehicleAction: PendingVehicleAction?
    @State private var queuedVehicleExecution: PendingVehicleAction?
    @State private var vehicleControlNotice: VehicleControlNotice?
    @State private var showingDebugDiagnostics = false

    private var dailyPaths: [DailyVehiclePath] {
        viewModel.dailyPaths
    }

    private var selectedPath: DailyVehiclePath? {
        if let selectedDay,
           let selected = dailyPaths.first(where: { $0.day == selectedDay }) {
            return selected
        }
        return dailyPaths.first
    }

    private var currentCoordinate: VehicleCoordinate? {
        if let location = viewModel.dashboard?.location, location.isValid { return location }
        return viewModel.history.first(where: { $0.coordinate.isValid })?.coordinate
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if viewModel.isShowingCachedDashboard {
                    Label {
                        HStack(spacing: 4) {
                            Text("先显示上次数据，正在刷新")
                            if let date = viewModel.lastDashboardRefreshAt {
                                Text("·")
                                Text(date, style: .relative)
                            }
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }

                if let dashboard = viewModel.dashboard {
                    statusHero(dashboard)
                    metricsGrid(dashboard)
                    batterySection(dashboard)
                    locationSection(dashboard)
                } else if viewModel.isConfigured {
                    ContentUnavailableView(
                        "暂无车辆状态",
                        systemImage: "car.side",
                        description: Text("刷新后即可查看车辆详情、当前位置和历史行程。")
                    )
                    .padding(.top, 80)
                } else {
                    ContentUnavailableView {
                        Label("连接车辆后端", systemImage: "server.rack")
                    } description: {
                        Text("NIO 凭证保留在后端，App 只读取车辆状态和位置历史。")
                    } actions: {
                        Button("配置后端", action: openSettings)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 80)
                }

                if viewModel.isConfigured {
                    tripsSection
                    locationTrackSection
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(16)
        }
        .background(AppPalette.canvas)
        .refreshable { await viewModel.refresh() }
        .navigationTitle("车辆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("设置", systemImage: "gearshape", action: openSettings)
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await viewModel.refresh() }
                        }
                        .disabled(!viewModel.isConfigured)
                    }
                }
            }
        }
        .onChange(of: dailyPaths.map(\.day)) { _, days in
            if selectedDay == nil || !days.contains(selectedDay!) {
                selectedDay = days.first
            }
        }
        #if DEBUG
        .task {
            if DesignPreviewMode.current?.screen == .controlPanel {
                let scopeArgument = ProcessInfo.processInfo.arguments.first {
                    $0.hasPrefix("--design-control-scope=")
                }
                let scopeName = scopeArgument.map {
                    String($0.dropFirst("--design-control-scope=".count))
                }
                vehicleControlPresentation = .panel(scopeName.flatMap(VehicleControlScope.init(rawValue:)) ?? .all)
            } else if DesignPreviewMode.current?.screen == .control {
                // Exercise the actual sheet-dismissal/confirmation path with
                // a preview model that rejects every vehicle command.
                vehicleControlPresentation = .panel(.all)
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let action = DesignPreviewMode.current?.controlAction ?? .unlockDoors
                queuedVehicleAction = PendingVehicleAction(
                    action: action,
                    temperature: action == .acOn ? 22 : nil,
                    expandMirrors: action == .guardOn && (DesignPreviewMode.current?.expandMirrors ?? false)
                )
                vehicleControlPresentation = nil
            }
        }
        #endif
        .sheet(item: $vehicleControlPresentation, onDismiss: {
            if let queuedVehicleAction {
                self.queuedVehicleAction = nil
                vehicleControlPresentation = .confirmation(queuedVehicleAction)
            } else if let queuedVehicleExecution {
                self.queuedVehicleExecution = nil
                executeVehicleAction(queuedVehicleExecution)
            }
        }) { presentation in
            switch presentation {
            case .panel(let scope):
                VehicleControlPanel(
                    dashboard: viewModel.dashboard,
                    scope: scope,
                    vehicleTitle: viewModel.vehicleTitle
                ) { action, temperature, expandMirrors in
                    queuedVehicleAction = PendingVehicleAction(
                        action: action,
                        temperature: temperature,
                        expandMirrors: expandMirrors
                    )
                    vehicleControlPresentation = nil
                }
            case .confirmation(let pending):
                VehicleActionConfirmation(
                    pending: pending,
                    warning: vehicleActionWarning(pending),
                    vehicleTitle: viewModel.vehicleTitle,
                    onCancel: { vehicleControlPresentation = nil },
                    onConfirm: {
                        queuedVehicleExecution = pending
                        vehicleControlPresentation = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showingDebugDiagnostics) {
            DebugDiagnosticsView(viewModel: viewModel)
        }
        .alert(item: $vehicleControlNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("知道了")))
        }
    }

    private func statusHero(_ dashboard: VehicleDashboard) -> some View {
        let vehicleTitle = viewModel.vehicleTitle
        let vehicleColor = viewModel.vehicleColorLabel
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(vehicleTitle)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    HStack(spacing: 7) {
                        Circle()
                            .fill(dashboard.isConnected ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(vehicleStateLabel(dashboard))
                        if let vehicleColor {
                            Text("· \(vehicleColor)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Label(lockStateLabel(dashboard.lockStatusCode), systemImage: dashboard.lockStatusCode == 1 ? "lock.fill" : "lock.open.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(dashboard.lockStatusCode == 1 ? AppPalette.green : AppPalette.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.background.opacity(0.75), in: Capsule())
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)

            VehicleHeroArtwork(
                imageData: viewModel.vehicleImageData,
                fallbackAssetName: viewModel.vehicleProfile?.bundledArtworkAssetName
            )
                .padding(.horizontal, 4)
                .padding(.top, 22)
                .padding(.bottom, 18)
                .contentShape(Rectangle())
                .onTapGesture(count: 5) {
                    showingDebugDiagnostics = true
                }
                .accessibilityLabel(
                    vehicleColor.map { "\($0) \(vehicleTitle)" } ?? vehicleTitle
                )
                .accessibilityHint("连续点击五次打开诊断页面")

            VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                rangeReadout(dashboard)
                Spacer()
                batteryReadout(dashboard)
            }
            HStack {
                if dashboard.remainingRange != nil && dashboard.remainingActualRange != nil {
                    Text(usesStandardRange(dashboard)
                         ? "预计可行驶 \(formatKilometers(dashboard.remainingActualRange))"
                         : "标准续航 \(formatKilometers(dashboard.remainingRange))")
                }
                Spacer(minLength: 8)
                Text("总里程 \(formatKilometers(dashboard.mileage))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Divider().opacity(0.65)
            quickControls(dashboard)
            }
            .padding(22)
            .background(.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .background(
            LinearGradient(colors: [AppPalette.blue.opacity(0.09), AppPalette.canvas, AppPalette.canvas], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
    }


    private func usesStandardRange(_ dashboard: VehicleDashboard) -> Bool {
        dashboard.remainingActualRange == nil
            || (showingStandardRange && dashboard.remainingRange != nil)
    }

    private func rangeReadout(_ dashboard: VehicleDashboard) -> some View {
        let standard = usesStandardRange(dashboard)
        let value = standard ? dashboard.remainingRange : dashboard.remainingActualRange
        let canSwitch = dashboard.remainingRange != nil && dashboard.remainingActualRange != nil
        return Button {
            guard canSwitch else { return }
            withAnimation(.smooth(duration: 0.3)) {
                showingStandardRange.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value.map { String(format: "%.0f", $0) } ?? "--")
                        .font(.system(size: 42, weight: .medium, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("km").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Text(standard ? "标准续航" : "预计可行驶")
                    if canSwitch {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(standard ? "标准续航" : "预计可行驶") \(formatKilometers(value))")
        .accessibilityHint(canSwitch ? "轻点切换续航类型" : "当前只有一种续航数据")
    }

    private func batteryReadout(_ dashboard: VehicleDashboard) -> some View {
        Button {
            batteryTapCount += 1
            guard !reduceMotion else { return }
            let pulseID = UUID()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                batteryPulseID = pulseID
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard batteryPulseID == pulseID else { return }
                withAnimation(.easeOut(duration: 0.2)) { batteryPulseID = nil }
            }
        } label: {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "battery.75percent")
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : batteryTapCount)
                        .overlay {
                            if let batteryPulseID {
                                BatteryPulseRing().id(batteryPulseID)
                            }
                        }
                    Text(dashboard.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "--")
                        .contentTransition(.numericText())
                }
                .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(AppPalette.green)
                .scaleEffect(batteryPulseID == nil ? 1 : 1.07, anchor: .trailing)
                Text("剩余电量").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: batteryTapCount)
        .accessibilityLabel("剩余电量 \(dashboard.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "未知")")
        .accessibilityHint("轻点播放电量动画")
    }

    private func quickControls(_ dashboard: VehicleDashboard) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if viewModel.isPerformingVehicleAction || !viewModel.isVehicleControlConfigured {
                HStack {
                    Text("车辆控制").font(.subheadline.weight(.semibold))
                    Spacer()
                    if viewModel.isPerformingVehicleAction {
                    ProgressView().controlSize(.small)
                    Text("指令执行中").font(.caption).foregroundStyle(.secondary)
                    } else {
                    Button("配置车控 Key", action: openSettings)
                        .font(.caption.weight(.semibold))
                    }
                }
            }

            HStack(spacing: 8) {
                quickControlButton(
                    title: dashboard.lockStatusCode == 1 ? "解锁" : "落锁",
                    icon: dashboard.lockStatusCode == 1 ? "lock.open.fill" : "lock.fill",
                    color: AppPalette.graphite,
                    enabled: dashboard.lockStatusCode == 0 || dashboard.lockStatusCode == 1
                ) {
                    if dashboard.lockStatusCode == 1 {
                        vehicleControlPresentation = .panel(.unlock)
                    } else {
                        vehicleControlPresentation = .confirmation(PendingVehicleAction(action: .lock))
                    }
                }
                quickControlButton(title: "守卫", icon: "shield.lefthalf.filled", color: AppPalette.violet) {
                    vehicleControlPresentation = .panel(.guardMode)
                }
                quickControlButton(title: "寻车", icon: "horn.blast.fill", color: AppPalette.amber) {
                    vehicleControlPresentation = .panel(.finding)
                }
                quickControlButton(
                    title: "位置",
                    icon: "location.fill",
                    color: AppPalette.violet,
                    enabled: currentCoordinate != nil,
                    requiresControlKey: false
                ) {
                    if let currentCoordinate { openInMaps(currentCoordinate) }
                }
                quickControlButton(title: "更多", icon: "ellipsis", color: AppPalette.graphite) {
                    vehicleControlPresentation = .panel(.all)
                }
            }

        }
    }

    private func quickControlButton(
        title: String,
        icon: String,
        color: Color,
        enabled: Bool = true,
        requiresControlKey: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let canUse = enabled
            && !viewModel.isPerformingVehicleAction
            && (!requiresControlKey || viewModel.isVehicleControlConfigured)
        return Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 56, height: 56)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!canUse)
        .opacity(canUse ? 1 : 0.42)
    }

    private func metricsGrid(_ dashboard: VehicleDashboard) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("座舱温度", systemImage: "sun.max")
                        .font(.subheadline.weight(.medium)).foregroundStyle(AppPalette.amber)
                    Text(formatTemperature(dashboard.insideTemperature))
                        .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
                    Text("车外 \(formatTemperature(dashboard.outsideTemperature))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "fan")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(AppPalette.amber.opacity(0.55))
                if viewModel.isVehicleControlConfigured {
                    Button {
                        vehicleControlPresentation = .panel(.climate)
                    } label: {
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 44)
                    }
                    .tint(AppPalette.amber)
                    .disabled(viewModel.isPerformingVehicleAction)
                    .accessibilityLabel("空调控制")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.climate, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func locationSection(_ dashboard: VehicleDashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("车辆位置", systemImage: "location.fill")
                    .font(.headline)
                Spacer()
                if let coordinate = currentCoordinate {
                    Button("地图打开") { openInMaps(coordinate) }
                        .font(.subheadline.weight(.semibold))
                }
            }

            if let coordinate = currentCoordinate {
                VehiclePathMap(
                    segments: [],
                    visibleSegmentIDs: [],
                    currentCoordinate: coordinate,
                    key: "current-\(coordinate.latitude)-\(coordinate.longitude)"
                )
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack {
                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    Spacer()
                    if let sampledAt = dashboard.locationSampledAt {
                        Text(formatDateTime(sampledAt))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "暂无有效位置",
                    systemImage: "location.slash",
                    description: Text("车辆上报有效 GPS 后会在这里显示。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func batterySection(_ dashboard: VehicleDashboard) -> some View {
        NavigationLink {
            energyRecordsPage
        } label: {
            batteryCard(dashboard)
        }
        .buttonStyle(.plain)
    }

    private func batteryCard(_ dashboard: VehicleDashboard) -> some View {
        let isCharging = dashboard.chargeStateCode == 1
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    "电池与充电",
                    systemImage: isCharging ? "battery.100percent.bolt" : "battery.75percent"
                )
                    .font(.headline)
                    .foregroundStyle(isCharging ? AppPalette.green : .primary)
                Spacer()
                HStack(spacing: 5) {
                    Text("充换电记录")
                    Image(systemName: "chevron.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.green)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(dashboard.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                Spacer()
                Text("充电上限 \(dashboard.chargeLimitPercent.map { "\(Int($0.rounded()))%" } ?? "--")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<20) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Double(index) * 5 < (dashboard.stateOfCharge ?? 0)
                              ? AppPalette.green : AppPalette.green.opacity(0.12))
                        .frame(height: 18)
                }
            }
            .accessibilityHidden(true)
            if isCharging {
                HStack {
                    chargingValue("功率", formatChargingPower(dashboard.chargingPower))
                    Spacer()
                    chargingValue("电压", formatMeasurement(dashboard.chargingVoltage, unit: "V"))
                    Spacer()
                    chargingValue("电流", formatMeasurement(dashboard.chargingCurrent, unit: "A"))
                }
            }
            HStack {
                Text(chargeStateLabel(dashboard.chargeStateCode))
                    .font(.caption)
                    .foregroundStyle(isCharging ? AppPalette.green : .secondary)
                Spacer()
                if let sampledAt = dashboard.batterySampledAt {
                    Text("更新于 \(formatDateTime(sampledAt))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var energyRecordsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.dashboard?.chargeStateCode == 1 {
                    NavigationLink {
                        ChargingCurveView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Label("本次充电曲线", systemImage: "waveform.path.ecg")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(AppPalette.green)
                        .padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                }
                chargingRecordsSection
                swapRecordsSection
            }
            .padding(16)
        }
        .background(AppPalette.canvas)
        .navigationTitle("充换电记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refresh() }
    }

    private func chargingValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.subheadline.weight(.medium).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chargingRecordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("充电记录", systemImage: "bolt.badge.clock")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    ChargingRecordsListView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 5) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if let error = viewModel.chargingSessionsErrorMessage {
                sectionError(error)
            }

            if viewModel.chargingSessions.isEmpty {
                Text("暂无充电记录。后端检测到车辆进入充电状态后，会自动形成可查看曲线的充电会话。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                ForEach(Array(viewModel.chargingSessions.prefix(3))) { session in
                    NavigationLink {
                        ChargingCurveView(viewModel: viewModel, session: session)
                    } label: {
                        ChargingSessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                    .task(id: session.energyKWh == nil ? session.id : nil) {
                        await viewModel.hydrateChargingSessionEnergyIfNeeded(id: session.id)
                    }

                    if session.id != viewModel.chargingSessions.prefix(3).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var swapRecordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("换电记录", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    SwapRecordsListView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 5) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if let error = viewModel.swapEventsErrorMessage {
                sectionError(error)
            }
            if let error = viewModel.activeServiceOrdersErrorMessage {
                sectionError("进行中订单：\(error)")
            }

            if viewModel.activeServiceOrders.isEmpty && viewModel.swapEvents.isEmpty {
                Text("暂无已完成的换电记录。后端同步到历史换电订单后，会显示时间、换电站、价格和可核验的电池信息。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                ForEach(Array(viewModel.activeServiceOrders.prefix(3))) { order in
                    ActiveServiceOrderRow(
                        order: order,
                        notificationsEnabled: viewModel.queueNotificationsEnabled
                    ) {
                        Task {
                            await viewModel.setQueueNotificationsEnabled(
                                !viewModel.queueNotificationsEnabled
                            )
                        }
                    }

                    if order.id != viewModel.activeServiceOrders.prefix(3).last?.id
                        || !viewModel.swapEvents.isEmpty {
                        Divider()
                    }
                }
                ForEach(Array(viewModel.swapEvents.prefix(3))) { event in
                    NavigationLink {
                        SwapEventDetailView(viewModel: viewModel, initialEvent: event)
                    } label: {
                        SwapEventRow(event: event)
                    }
                    .buttonStyle(.plain)

                    if event.id != viewModel.swapEvents.prefix(3).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("最近行程", systemImage: "road.lanes")
                    .font(.headline)
                Spacer()
                if !viewModel.trips.isEmpty {
                    NavigationLink {
                        VehicleTripsListView(trips: viewModel.trips)
                    } label: {
                        HStack(spacing: 5) {
                            Text("全部")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if let error = viewModel.tripsErrorMessage {
                sectionError(error)
            }

            if viewModel.trips.isEmpty {
                Text("暂无行程记录，完成出行后可在这里查看。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                ForEach(Array(viewModel.trips.prefix(3))) { trip in
                    VehicleTripCard(trip: trip)
                }
            }
        }
        .padding(.top, 6)
    }

    private var locationTrackSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppPalette.violet)
                    .frame(width: 42, height: 42)
                    .background(AppPalette.violet.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("位置轨迹").font(.headline)
                    Text("车辆定位采样").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !dailyPaths.isEmpty {
                    Text("\(dailyPaths.count) 天记录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppPalette.violet)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppPalette.violet.opacity(0.10), in: Capsule())
                }
            }

            if let error = viewModel.historyErrorMessage {
                sectionError(error)
            }

            if dailyPaths.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "location.slash")
                        .font(.title2)
                        .foregroundStyle(AppPalette.violet)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂无采样轨迹").font(.subheadline.weight(.semibold))
                        Text("收到有效车辆定位后，这里会按天显示采样路径。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                .padding(.horizontal, 16)
                .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 16))
            } else {
                if dailyPaths.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(dailyPaths) { path in
                                let isSelected = selectedPath?.day == path.day
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                        selectedDay = path.day
                                    }
                                } label: {
                                    Text(formatDate(path.day))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(isSelected ? .white : .primary)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 9)
                                        .background(
                                            isSelected ? AppPalette.stationNight : AppPalette.canvas,
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("查看 \(formatDate(path.day)) 的采样轨迹")
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                            }
                        }
                    }
                }

                if let path = selectedPath {
                    let visibleIDs = Set(path.segments.map(\.id)).subtracting(hiddenPathSegmentIDs)
                    VehiclePathMap(
                        segments: path.segments,
                        visibleSegmentIDs: visibleIDs,
                        samplePoint: path.segments.isEmpty ? path.points.last : nil,
                        currentCoordinate: Calendar.current.isDateInToday(path.day) ? currentCoordinate : nil,
                        key: path.day.description
                    )
                    .frame(height: 224)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            Circle().fill(AppPalette.green).frame(width: 7, height: 7)
                            Text(Calendar.current.isDateInToday(path.day) ? "今日采样" : formatDate(path.day))
                            Text("· \(path.segments.count) 段")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(distanceLabel(path.distanceKilometers))
                                .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(AppPalette.graphite)
                            Text("采样路径距离")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 7) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(AppPalette.violet)
                            Text("\(path.segments.count) 段 · \(path.points.count) 点")
                        }
                        .font(.subheadline.weight(.medium))
                    }

                    if path.segments.isEmpty {
                        Text("当天暂无可辨认的行驶段")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        pathSegmentTimeline(path)
                    }

                    Text("静止 15 分钟或采样中断 30 分钟切段；过滤长时小范围定位漂移。采样距离并非官方行程里程。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    #if DEBUG
    var trackCardDesignPreview: some View { locationTrackSection }
    #endif

    private func pathSegmentTimeline(_ path: DailyVehiclePath) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("采样时间轴")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("点按眼睛显示/隐藏")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(path.segments.indices.prefix(showsAllPathSegments ? path.segments.count : 4)), id: \.self) { index in
                let segment = path.segments[index]
                if index > 0 {
                    let gapMinutes = max(0, Int(segment.startTime.timeIntervalSince(path.segments[index - 1].endTime) / 60))
                    HStack(spacing: 7) {
                        Image(systemName: "pause.fill")
                        Text("间隔 \(gapMinutes) 分钟")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
                }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(VehiclePathMap.color(for: index))
                        .frame(width: 4, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第\(index + 1)段 · \(formatTime(segment.startTime))–\(formatTime(segment.endTime))")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(distanceLabel(segment.distanceKilometers))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if !hiddenPathSegmentIDs.insert(segment.id).inserted {
                            hiddenPathSegmentIDs.remove(segment.id)
                        }
                    } label: {
                        Image(systemName: hiddenPathSegmentIDs.contains(segment.id) ? "eye.slash" : "eye")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(hiddenPathSegmentIDs.contains(segment.id) ? .secondary : VehiclePathMap.color(for: index))
                            .frame(width: 38, height: 38)
                            .background(AppPalette.canvas, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(hiddenPathSegmentIDs.contains(segment.id) ? "显示" : "隐藏")第\(index + 1)段轨迹")
                }
                .padding(.vertical, 2)
            }

            if path.segments.count > 4 {
                Button(showsAllPathSegments ? "收起其余路段" : "查看全部 \(path.segments.count) 段") {
                    showsAllPathSegments.toggle()
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(14)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 16))
    }





    private func sectionError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d/%02d/%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func formatTime(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private func formatDateTime(_ date: Date) -> String {
        "\(formatDate(date)) \(formatTime(date))"
    }


    private func vehicleStateLabel(_ dashboard: VehicleDashboard) -> String {
        if dashboard.isSwapping { return "正在换电" }
        switch dashboard.stateCode {
        case 1: return "行驶中"
        case 2: return "已驻车"
        case 3: return "充电中"
        case 4: return "换电中"
        default: return dashboard.isConnected ? "车辆在线" : "车辆离线"
        }
    }

    private func lockStateLabel(_ code: Int?) -> String {
        switch code {
        case 1: return "已锁车"
        case 0: return "未锁车"
        default: return "状态未知"
        }
    }

    private func vehicleActionWarning(_ pending: PendingVehicleAction) -> String {
        switch pending.action {
        case .unlockDoors:
            return "只解锁车门，不授予启动权限。\n请先确认车辆已挂 P 挡、四门关闭且周围安全。执行后请现场核对门锁状态。"
        case .unlockStart:
            return "将解锁车辆并授予启动权限。后端会检查车辆已驻车且车门关闭。请确认车辆周围安全，并在执行后现场核对。"
        case .lock:
            return "后端会先检查车辆已驻车且车门关闭，再发送一次落锁指令。"
        case .acOn:
            let value = pending.temperature.map { String(format: "%.0f℃", $0) } ?? "22℃"
            return "将以 \(value) 发送一次空调开启指令。"
        case .acOff:
            return "将发送一次空调关闭指令。"
        case .find:
            return "将发送一次寻车指令，车辆可能鸣笛或闪灯。"
        case .findStop:
            return "将发送一次停止寻车指令。"
        case .guardOn:
            return pending.expandMirrors
                ? "后端检查驻车状态后开启守卫模式，再单独发送展开后视镜指令。后视镜结果需另外核对。"
                : "后端检查驻车状态后开启守卫模式；后视镜保持原状。"
        case .guardOff:
            return "将发送一次守卫模式关闭指令，后端会检查车辆驻车状态。"
        }
    }

    private func executeVehicleAction(_ pending: PendingVehicleAction) {
        Task {
            do {
                let outcome = try await viewModel.performVehicleAction(
                    pending.action,
                    temperature: pending.temperature,
                    expandMirrors: pending.expandMirrors
                )
                let message: String
                switch outcome.status {
                case "verified":
                    message = "后端已轮询确认车辆达到目标状态。"
                case "already_desired":
                    message = "车辆原本已经处于目标状态，没有重复发送指令。"
                case "accepted_unverified":
                    message = "上游已接受指令，但后端未确认最终车辆状态。请查看车辆现场或刷新状态后再判断；App 不会自动重试。"
                default:
                    message = "后端返回状态：\(outcome.status)。请结合车辆现场确认。"
                }
                let mirrorMessage: String
                switch outcome.mirrors {
                case "already_expanded": mirrorMessage = "后视镜原本已展开。"
                case "accepted_unverified": mirrorMessage = "后视镜展开指令已接受，但未确认最终状态；请现场核对。"
                case nil: mirrorMessage = ""
                default: mirrorMessage = "后视镜结果：\(outcome.mirrors ?? "未知")；请现场核对。"
                }
                vehicleControlNotice = VehicleControlNotice(
                    title: outcome.verified && (outcome.mirrors == nil || outcome.mirrors == "already_expanded")
                        ? "已确认" : "请核对车辆",
                    message: message + (mirrorMessage.isEmpty ? "" : "\n\(mirrorMessage)")
                )
            } catch {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                vehicleControlNotice = VehicleControlNotice(
                    title: "指令未完成",
                    message: pending.expandMirrors
                        ? "\(detail)\n守卫模式可能已开启，后视镜状态也可能已变化；请现场核对，App 不会重发指令。"
                        : detail
                )
            }
        }
    }


    private func formatKilometers(_ value: Double?) -> String {
        value.map { String(format: "%.0f km", $0) } ?? "--"
    }

    private func formatTemperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f℃", $0) } ?? "--"
    }

    private func formatMeasurement(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite, value > 0 else { return "--" }
        return String(format: "%.1f %@", value, unit)
    }

    private func formatChargingPower(_ watts: Double?) -> String {
        guard let watts, watts.isFinite, watts > 0 else { return "--" }
        return String(format: "%.1f kW", watts / 1_000)
    }

    private func chargeStateLabel(_ code: Int?) -> String {
        switch code {
        case 1: return "充电中"
        case 2: return "充电完成"
        case 3: return "充电故障"
        case 0: return "未充电"
        default: return "--"
        }
    }

    private func distanceLabel(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.1f km", value) }
        if value >= 0.1 { return String(format: "%.2f km", value) }
        return "\(Int((value * 1000).rounded())) m"
    }

    private func openInMaps(_ coordinate: VehicleCoordinate) {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: "车辆位置")
        ]
        if let url = components?.url { openURL(url) }
    }
}

private struct BatteryPulseRing: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(AppPalette.green.opacity(0.55), lineWidth: 2)
            .frame(width: 36, height: 36)
            .scaleEffect(expanded ? 2.0 : 0.7)
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.75)) { expanded = true }
            }
            .accessibilityHidden(true)
    }
}

private struct VehicleHeroArtwork: View {
    let imageData: Data?
    let fallbackAssetName: String?

    // Frame the car and its original ground shadow, excluding the large
    // transparent margins of the official 1080 × 675 asset.
    private let visibleWidth: CGFloat = 925
    private let visibleHeight: CGFloat = 425

    var body: some View {
        Group {
            if let imageData,
               let image = VehicleArtworkCropper.heroImage(from: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let fallbackAssetName {
                GeometryReader { geometry in
                    let scale = geometry.size.width / visibleWidth
                    Image(fallbackAssetName)
                        .resizable()
                        .frame(width: 1080 * scale, height: 675 * scale)
                        .offset(x: -75 * scale, y: -205 * scale)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 58, weight: .thin))
                        .foregroundStyle(AppPalette.graphite.opacity(0.45))
                    Text("车辆图片暂不可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(visibleWidth / visibleHeight, contentMode: .fit)
        .clipped()
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.03),
                .init(color: .black, location: 0.97),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityElement(children: .ignore)
    }
}

private enum VehicleArtworkCropper {
    private static let cache = NSCache<NSString, UIImage>()
    private static let heroAspectRatio: CGFloat = 925 / 425

    static func heroImage(from data: Data) -> UIImage? {
        let key = "\(data.count)-\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = UIImage(data: data),
              let cropped = cropToVehicle(source) else { return nil }
        cache.setObject(cropped, forKey: key)
        return cropped
    }

    private static func cropToVehicle(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        let scanScale = min(1, 480 / CGFloat(max(sourceWidth, sourceHeight)))
        let width = max(1, Int(CGFloat(sourceWidth) * scanScale))
        let height = max(1, Int(CGFloat(sourceHeight) * scanScale))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        // Bitmap row indices and CGImage.cropping use the same image-row order.
        // Flipping here mirrors the detected bounds relative to the source.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = y * bytesPerRow + x * 4
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                let luminance = (red * 54 + green * 183 + blue * 19) / 256
                let distanceFromWhite = max(255 - red, 255 - green, 255 - blue)
                guard luminance < 222 || distanceFromWhite > 38 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX > minX,
              maxY > minY,
              maxX - minX > width / 5,
              maxY - minY > height / 12 else { return image }

        let inverseScale = 1 / scanScale
        var subject = CGRect(
            x: CGFloat(minX) * inverseScale,
            y: CGFloat(minY) * inverseScale,
            width: CGFloat(maxX - minX + 1) * inverseScale,
            height: CGFloat(maxY - minY + 1) * inverseScale
        )
        subject = subject.insetBy(
            dx: -subject.width * 0.10,
            dy: -subject.height * 0.13
        )
        let center = CGPoint(x: subject.midX, y: subject.midY)
        if subject.width / subject.height < heroAspectRatio {
            subject.size.width = subject.height * heroAspectRatio
        } else {
            subject.size.height = subject.width / heroAspectRatio
        }
        subject.origin = CGPoint(
            x: center.x - subject.width / 2,
            y: center.y - subject.height / 2
        )

        let sourceBounds = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        if subject.width > sourceBounds.width || subject.height > sourceBounds.height {
            let widthScale = sourceBounds.width / subject.width
            let heightScale = sourceBounds.height / subject.height
            let fitScale = min(widthScale, heightScale)
            subject.size.width *= fitScale
            subject.size.height *= fitScale
        }
        subject.origin.x = min(max(0, subject.origin.x), sourceBounds.width - subject.width)
        subject.origin.y = min(max(0, subject.origin.y), sourceBounds.height - subject.height)
        subject = subject.integral

        guard let result = cgImage.cropping(to: subject) else { return image }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }
}

private struct PendingVehicleAction: Identifiable {
    let id = UUID()
    let action: VehicleAction
    let temperature: Double?
    let expandMirrors: Bool

    init(action: VehicleAction, temperature: Double? = nil, expandMirrors: Bool = false) {
        self.action = action
        self.temperature = temperature
        self.expandMirrors = action == .guardOn && expandMirrors
    }
}

private struct VehicleControlNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum VehicleControlPresentation: Identifiable {
    case panel(VehicleControlScope)
    case confirmation(PendingVehicleAction)

    var id: String {
        switch self {
        case .panel(let scope): "panel-\(scope.rawValue)"
        case .confirmation(let pending): pending.id.uuidString
        }
    }
}

private struct VehicleActionConfirmation: View {
    let pending: PendingVehicleAction
    let warning: String
    let vehicleTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var didConfirm = false

    private var confirmationTitle: String {
        pending.expandMirrors ? "开启守卫并展开后视镜" : pending.action.title
    }

    private var accent: Color {
        switch pending.action {
        case .unlockDoors, .unlockStart: .red
        case .lock: AppPalette.green
        case .acOn, .acOff: AppPalette.blue
        case .find, .findStop: AppPalette.amber
        case .guardOn, .guardOff: AppPalette.violet
        }
    }

    private var buttonFill: Color {
        switch pending.action {
        case .unlockDoors, .unlockStart: Color(red: 0.85, green: 0.18, blue: 0.22)
        case .lock: Color(red: 0.19, green: 0.48, blue: 0.34)
        case .acOn, .acOff: Color(red: 0.28, green: 0.43, blue: 0.66)
        case .find, .findStop: Color(red: 0.65, green: 0.38, blue: 0.17)
        case .guardOn, .guardOff: Color(red: 0.49, green: 0.43, blue: 0.65)
        }
    }
    private var icon: String {
        switch pending.action {
        case .unlockDoors: "lock.open"
        case .unlockStart: "car.side"
        case .lock: "lock"
        case .acOn: "fan"
        case .acOff: "fan.slash"
        case .find: "horn.blast"
        case .findStop: "speaker.slash"
        case .guardOn: "shield.lefthalf.filled"
        case .guardOff: "shield.slash"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 56, height: 56)
                        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("执行前确认").font(.caption).foregroundStyle(.secondary)
                        Text(confirmationTitle).font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).disabled(didConfirm)
                    .accessibilityLabel("取消车控操作")
                }

                HStack(spacing: 12) {
                    Image(systemName: "car.side").font(.title2)
                        .foregroundStyle(AppPalette.graphite)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vehicleTitle).font(.subheadline.weight(.semibold))
                        Text("本次操作的车辆").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if pending.action == .acOn, let temperature = pending.temperature {
                        Text("\(Int(temperature))℃")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(AppPalette.blue)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))

                if pending.action == .guardOn {
                    Label(
                        pending.expandMirrors ? "守卫开启后展开后视镜" : "后视镜保持原状",
                        systemImage: pending.expandMirrors ? "arrow.up.left.and.arrow.down.right" : "minus"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.violet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppPalette.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label(pending.action.isHighRisk ? "请确认车辆安全" : "操作说明", systemImage: "exclamationmark.shield")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppPalette.amber)
                    Text(warning).font(.subheadline).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.primary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))

                Text(pending.expandMirrors
                    ? "守卫与后视镜分别发送，均不自动重试。两步可能部分成功，请分别核对结果。"
                    : "每次确认仅发送一次指令，不自动重试。提交不等于生效，请查看执行结果并核对车辆状态。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("取消").font(.headline).foregroundStyle(.primary)
                        .frame(width: 90)
                        .frame(minHeight: 54)
                        .background(AppPalette.graphite.opacity(0.08), in: RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain).disabled(didConfirm)

                Button(role: pending.action.isHighRisk ? .destructive : nil) {
                    guard !didConfirm else { return }
                    didConfirm = true
                    onConfirm()
                } label: {
                    Text("确认\(confirmationTitle)")
                        .font(.headline).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .padding(.horizontal, 12)
                        .background(buttonFill, in: RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain).disabled(didConfirm)
            }
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 18)
            .background(AppPalette.canvas)
        }
        .background(AppPalette.canvas)
        .presentationDetents([.height(530), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .presentationBackground(AppPalette.canvas)
        .interactiveDismissDisabled(didConfirm)
    }
}

private enum VehicleControlScope: String {
    case all, unlock, climate, finding
    case guardMode = "guard-mode"

    var title: String {
        switch self {
        case .all: "远程车控"
        case .unlock: "解锁车辆"
        case .climate: "空调控制"
        case .finding: "寻车控制"
        case .guardMode: "守卫模式"
        }
    }

    var initialHeight: CGFloat {
        switch self {
        case .all: 700
        case .unlock, .climate: 470
        case .finding: 390
        case .guardMode: 500
        }
    }
}

private struct VehicleControlPanel: View {
    let dashboard: VehicleDashboard?
    let scope: VehicleControlScope
    let vehicleTitle: String
    let onSelect: (VehicleAction, Double?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var temperature = 22.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope.title).font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(vehicleTitle)
                        Text("·")
                        Text(lockLabel)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭远程车控")
            }
            .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 20)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if scope == .all || scope == .unlock {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeading("门锁与启动", subtitle: "两种解锁权限不同，请按实际用途选择")
                        actionButton(.unlockDoors, icon: "lock.open", color: AppPalette.graphite)
                        actionButton(.unlockStart, icon: "car.side", color: .red)
                        if scope == .all {
                            actionButton(.lock, icon: "lock", color: AppPalette.green)
                        }
                    }
                    .controlCard()
                    .id("first")
                    }

                    if scope == .all || scope == .climate {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center) {
                            sectionHeading("空调", subtitle: "开启时使用下方设定温度")
                            Spacer(minLength: 8)
                            Text("\(Int(temperature))°")
                                .font(.system(size: 34, weight: .medium, design: .rounded))
                                .monospacedDigit().foregroundStyle(AppPalette.blue)
                                .accessibilityLabel("设定温度 \(Int(temperature)) 摄氏度")
                        }
                        HStack(spacing: 12) {
                            Text("16°").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Slider(value: $temperature, in: 16...30, step: 1)
                                .tint(AppPalette.blue)
                                .accessibilityLabel("空调设定温度")
                            Text("30°").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            actionButton(.acOn, icon: "fan", color: AppPalette.blue, temperature: temperature)
                            actionButton(.acOff, icon: "fan.slash", color: AppPalette.graphite)
                        }
                    }
                    .controlCard()
                    .id(scope == .climate ? "first" : "climate")
                    }

                    if scope == .all || scope == .finding {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeading("寻车", subtitle: "车辆可能鸣笛或闪灯，请留意周围环境")
                        HStack(spacing: 10) {
                            actionButton(.find, icon: "horn.blast", color: AppPalette.amber)
                            actionButton(.findStop, icon: "speaker.slash", color: AppPalette.graphite)
                        }
                    }
                    .controlCard()
                    .id(scope == .finding ? "first" : "finding")
                    }

                    if scope == .all || scope == .guardMode {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeading("守卫模式", subtitle: "开启时明确选择后视镜状态")
                        actionButton(
                            .guardOn,
                            icon: "shield.lefthalf.filled",
                            color: AppPalette.violet,
                            title: "开启守卫 · 不展开后视镜"
                        )
                        actionButton(
                            .guardOn,
                            icon: "arrow.up.left.and.arrow.down.right",
                            color: AppPalette.violet,
                            title: "开启守卫 · 展开后视镜",
                            expandMirrors: true
                        )
                        actionButton(.guardOff, icon: "shield.slash", color: AppPalette.graphite)
                    }
                    .controlCard()
                    .id(scope == .guardMode ? "first" : "guard-mode")
                    }

                    Label("选择操作后还需确认。每项指令均不自动重试。", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.bottom, 12)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                proxy.scrollTo("first", anchor: .top)
            }
            }
        }
        .background(AppPalette.canvas)
        .presentationDetents(scope == .all ? [.large] : [.height(scope.initialHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .presentationBackground(AppPalette.canvas)
    }

    private var lockLabel: String {
        switch dashboard?.lockStatusCode {
        case 1: "上报状态：已锁车"
        case 0: "上报状态：未锁车"
        default: "门锁状态未知"
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(
        _ action: VehicleAction,
        icon: String,
        color: Color,
        temperature: Double? = nil,
        title: String? = nil,
        expandMirrors: Bool = false
    ) -> some View {
        Button {
            onSelect(action, temperature, expandMirrors)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(color)
                Text(title ?? action.title).font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 8)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func controlCard() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
