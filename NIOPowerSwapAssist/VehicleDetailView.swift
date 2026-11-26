import ImageIO
import SwiftUI
import UIKit

struct VehicleDetailView: View {
    @ObservedObject var viewModel: VehicleViewModel
    let openSettings: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDay: Date?
    @State private var hiddenPathSegmentIDs: Set<String> = []
    @State private var showsAllPathSegments = false
    @State private var showingStandardRange = false
    @State private var batteryPulseID: UUID?
    @State private var batteryTapCount = 0
    @State private var quickControlHapticCount = 0
    @State private var vehicleControlPresentation: VehicleControlPresentation?
    @State private var queuedVehicleAction: PendingVehicleAction?
    @State private var queuedVehicleExecution: PendingVehicleAction?
    @State private var vehicleControlNotice: VehicleControlNotice?
    @State private var showingDebugDiagnostics = false
    @State private var showingSendRouteSheet = false
    @State private var showingSpecialStatusDetail = false

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

                if viewModel.isConfigured && viewModel.needsBackendLogin && viewModel.dashboard != nil {
                    HStack(spacing: 12) {
                        Label("后端配置不完整，需登录蔚来账号", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button("去登录") {
                            viewModel.presentLoginSheet()
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }

                if let dashboard = viewModel.dashboard {
                    statusHero(dashboard)
                    if let activeOrder = viewModel.activeServiceOrders.first {
                        activeOrderHomeCard(activeOrder)
                    }
                    metricsGrid(dashboard)
                    batterySection(dashboard)
                    locationSection(dashboard)
                } else if viewModel.isConfigured && viewModel.needsBackendLogin {
                    ContentUnavailableView {
                        Label("需要登录蔚来账号", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text("当前后端配置不完整（缺少蔚来车辆凭证），请先通过短信验证码登录以完成配置。")
                    } actions: {
                        Button("短信验证码登录") {
                            viewModel.presentLoginSheet()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("后端设置", action: openSettings)
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 80)
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
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppPalette.red)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("重试") {
                            Task { await viewModel.refresh() }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppPalette.red)
                    }
                    .padding(14)
                    .background(AppPalette.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AppPalette.red.opacity(0.20), lineWidth: 1)
                    }
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
                    vehicleTitle: viewModel.vehicleTitle,
                    onSelect: { action, temperature, expandMirrors in
                        queuedVehicleAction = PendingVehicleAction(
                            action: action,
                            temperature: temperature,
                            expandMirrors: expandMirrors
                        )
                        vehicleControlPresentation = nil
                    },
                    onDirectExecute: { action, temperature, expandMirrors in
                        queuedVehicleExecution = PendingVehicleAction(
                            action: action,
                            temperature: temperature,
                            expandMirrors: expandMirrors
                        )
                        vehicleControlPresentation = nil
                    }
                )
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
        .sheet(isPresented: $showingSendRouteSheet) {
            SendRouteToVehicleSheet(
                isPresented: $showingSendRouteSheet,
                viewModel: viewModel
            )
        }
        .sheet(isPresented: $showingSpecialStatusDetail) {
            if let dashboard = viewModel.dashboard, dashboard.hasActiveSpecialStatus {
                specialStatusDetailSheet(dashboard)
                    .presentationDetents([.height(300), .medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert(item: $vehicleControlNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("知道了")))
        }
    }

    private func statusHero(_ dashboard: VehicleDashboard) -> some View {
        let vehicleTitle = viewModel.vehicleTitle
        let vehicleColor = viewModel.vehicleColorLabel
        let isActiveState = dashboard.hasActiveSpecialStatus
            || dashboard.isDriving
            || dashboard.chargeStateCode == 1
        let statusDotColor: Color = {
            if let special = dashboard.primarySpecialStatus {
                return specialStatusColor(special)
            }
            if dashboard.chargeStateCode == 1 { return AppPalette.green }
            if dashboard.isDriving { return AppPalette.blue }
            return dashboard.isConnected ? AppPalette.green : .secondary
        }()
        let canToggleLock = viewModel.isVehicleControlConfigured
            && !viewModel.isPerformingVehicleAction
            && (dashboard.lockStatusCode == 0 || dashboard.lockStatusCode == 1)

        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(vehicleTitle)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    HStack(spacing: 6) {
                        if dashboard.hasActiveSpecialStatus {
                            Button {
                                quickControlHapticCount += 1
                                showingSpecialStatusDetail = true
                            } label: {
                                HStack(spacing: 5) {
                                    LivePulseDot(color: statusDotColor, size: 7, isPulsing: true)
                                    Text(vehicleStateLabel(dashboard))
                                        .fontWeight(.semibold)
                                        .foregroundStyle(statusDotColor)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(statusDotColor.opacity(0.75))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(statusDotColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.95))
                            .accessibilityLabel("\(vehicleStateLabel(dashboard))，查看详情")
                        } else {
                            LivePulseDot(color: statusDotColor, size: 7, isPulsing: isActiveState)
                            Text(vehicleStateLabel(dashboard))
                                .fontWeight(isActiveState ? .semibold : .regular)
                                .foregroundStyle(isActiveState ? statusDotColor : .secondary)
                        }
                        if let vehicleColor {
                            Text("· \(vehicleColor)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    guard canToggleLock else { return }
                    quickControlHapticCount += 1
                    if dashboard.lockStatusCode == 1 {
                        vehicleControlPresentation = .panel(.unlock)
                    } else {
                        vehicleControlPresentation = .confirmation(PendingVehicleAction(action: .lock))
                    }
                } label: {
                    Label(
                        lockStateLabel(dashboard.lockStatusCode),
                        systemImage: dashboard.lockStatusCode == 1 ? "lock.fill" : "lock.open.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dashboard.lockStatusCode == 1 ? AppPalette.green : AppPalette.amber)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(AppPalette.surface.opacity(0.88), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                (dashboard.lockStatusCode == 1 ? AppPalette.green : AppPalette.amber).opacity(0.24),
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.94))
                .disabled(!canToggleLock)
                .accessibilityHint(canToggleLock ? "轻点执行门锁控制" : "")
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)

            VehicleHeroArtwork(
                imageData: viewModel.vehicleImageData,
                fallbackAssetName: viewModel.vehicleProfile?.bundledArtworkAssetName,
                isDriving: dashboard.isDriving,
                isSceneActive: scenePhase == .active
            )
                .padding(.horizontal, dashboard.isDriving ? 0 : 4)
                .padding(.top, dashboard.isDriving ? 8 : 20)
                .padding(.bottom, dashboard.isDriving ? -10 : 16)
                .contentShape(Rectangle())
                .onTapGesture(count: 5) {
                    showingDebugDiagnostics = true
                }
                .accessibilityLabel(
                    heroAccessibilityLabel(
                        vehicleTitle: vehicleTitle,
                        vehicleColor: vehicleColor,
                        isDriving: dashboard.isDriving
                    )
                )
                .accessibilityHint("连续点击五次打开诊断页面")

            VStack(spacing: 18) {
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
                        .contentTransition(.numericText())
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                Divider().opacity(0.55)
                quickControls(dashboard)
            }
            .padding(22)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            }
            .zIndex(1)
        }
        .background(heroCardBackground(isDriving: dashboard.isDriving, statusDotColor: statusDotColor))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(AppPalette.hairline, lineWidth: 1)
        }
        .shadow(color: AppPalette.cardShadow, radius: 12, x: 0, y: 5)
    }

    @ViewBuilder
    private func heroCardBackground(isDriving: Bool, statusDotColor: Color) -> some View {
        if isDriving && colorScheme == .light {
            // Exact tone match to the light driving GIF's studio sky/road backdrop.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.922, green: 0.942, blue: 0.966), location: 0.0),
                    .init(color: Color(red: 0.948, green: 0.954, blue: 0.960), location: 0.34),
                    .init(color: Color(red: 0.958, green: 0.960, blue: 0.957), location: 0.62),
                    .init(color: AppPalette.canvas, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else if isDriving && colorScheme == .dark {
            // Exact tone match to the dark driving GIF's midnight studio backdrop.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.084, green: 0.104, blue: 0.144), location: 0.0),
                    .init(color: Color(red: 0.074, green: 0.089, blue: 0.118), location: 0.36),
                    .init(color: Color(red: 0.065, green: 0.076, blue: 0.100), location: 0.64),
                    .init(color: AppPalette.canvas, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                colors: [statusDotColor.opacity(0.11), AppPalette.blue.opacity(0.05), AppPalette.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func specialStatusColor(_ kind: VehicleDashboard.SpecialStatusKind) -> Color {
        switch kind {
        case .svt: return AppPalette.red
        case .repairing: return AppPalette.amber
        case .fota: return AppPalette.violet
        case .swapping: return .cyan
        }
    }

    private func specialStatusIcon(_ kind: VehicleDashboard.SpecialStatusKind) -> String {
        switch kind {
        case .svt: return "exclamationmark.shield.fill"
        case .repairing: return "wrench.and.screwdriver.fill"
        case .fota: return "arrow.down.circle.fill"
        case .swapping: return "arrow.triangle.2.circlepath"
        }
    }

    private func specialStatusShortLabel(_ kind: VehicleDashboard.SpecialStatusKind) -> String {
        switch kind {
        case .svt: return "防盗追踪中"
        case .repairing: return "维修中"
        case .fota: return "系统升级中"
        case .swapping: return "正在换电"
        }
    }

    @ViewBuilder
    private func specialStatusDetailSheet(_ dashboard: VehicleDashboard) -> some View {
        if let primary = dashboard.primarySpecialStatus {
            let tint = specialStatusColor(primary)
            let secondary = Array(dashboard.activeSpecialStatuses.dropFirst())
            let chips = specialStatusContextChips(primary, dashboard: dashboard, secondary: secondary)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: specialStatusIcon(primary))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 44, height: 44)
                        .background(tint.opacity(0.14), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            LivePulseDot(color: tint, size: 7, isPulsing: true)
                            Text(specialStatusCardTitle(primary, dashboard: dashboard))
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        if let timeText = specialStatusTimeCaption(primary, dashboard: dashboard) {
                            Text(timeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 4)

                    if primary == .fota, let countdown = dashboard.fotaPreparingCountdownSeconds, countdown > 0 {
                        Text(formatCountdown(countdown))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(tint.opacity(0.14), in: Capsule())
                    }
                }

                Text(specialStatusCardBody(primary, dashboard: dashboard))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !chips.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.title) { chip in
                            Label(chip.title, systemImage: chip.icon)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(chip.tint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(chip.tint.opacity(0.12), in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    if primary == .svt, let coordinate = currentCoordinate {
                        Button {
                            showingSpecialStatusDetail = false
                            openInMaps(coordinate)
                        } label: {
                            Label("查看位置", systemImage: "location.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(tint)
                                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else if primary == .swapping {
                        liveActivityTogglePill(tint: tint)
                    }

                    Button {
                        showingSpecialStatusDetail = false
                    } label: {
                        Text("知道了")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .background(AppPalette.canvas.ignoresSafeArea())
        }
    }

    private func specialStatusCardTitle(
        _ kind: VehicleDashboard.SpecialStatusKind,
        dashboard: VehicleDashboard
    ) -> String {
        switch kind {
        case .svt:
            return "防盗追踪已触发"
        case .repairing:
            return "车辆维修中"
        case .fota:
            return dashboard.fotaPreparingCountdownSeconds != nil ? "系统升级准备中" : "车辆系统升级中"
        case .swapping:
            return "车辆正在换电"
        }
    }

    private func specialStatusTimeCaption(
        _ kind: VehicleDashboard.SpecialStatusKind,
        dashboard: VehicleDashboard
    ) -> String? {
        switch kind {
        case .svt:
            return dashboard.svtSampledAt.map { "触发采样 \(formatDateTime($0))" }
        case .repairing:
            return dashboard.repairSampledAt.map { "状态更新时间 \(formatDateTime($0))" }
        case .fota:
            return dashboard.fotaPreparingSampledAt.map { "准备时间 \(formatDateTime($0))" }
        case .swapping:
            return nil
        }
    }

    private func specialStatusCardBody(
        _ kind: VehicleDashboard.SpecialStatusKind,
        dashboard: VehicleDashboard
    ) -> String {
        switch kind {
        case .svt:
            return "防盗追踪模式（SVT）已激活，请立即确认车辆状态与停放位置。"
        case .repairing:
            return "车辆当前处于维修模式，服务中心可能正在检修作业。"
        case .fota:
            if let code = dashboard.fotaStatusCode {
                return "车辆正在准备或执行系统升级（状态码 \(code)），升级期间请耐心等待。"
            }
            return "车辆正在准备或执行系统升级，请耐心等待升级完成。"
        case .swapping:
            return "换电站正在为车辆更换电池，完成后将自动同步最新电量与续航。"
        }
    }

    private struct SpecialStatusChip {
        let title: String
        let icon: String
        let tint: Color
    }

    private func specialStatusContextChips(
        _ primary: VehicleDashboard.SpecialStatusKind,
        dashboard: VehicleDashboard,
        secondary: [VehicleDashboard.SpecialStatusKind]
    ) -> [SpecialStatusChip] {
        var chips: [SpecialStatusChip] = []
        if primary == .repairing {
            if dashboard.stateCode == 1 {
                chips.append(SpecialStatusChip(title: "车辆通电/移动中", icon: "car.side.fill", tint: AppPalette.blue))
            }
            if dashboard.lockStatusCode == 0 {
                chips.append(SpecialStatusChip(title: "当前未锁车", icon: "lock.open.fill", tint: AppPalette.amber))
            }
        }
        for extra in secondary {
            chips.append(
                SpecialStatusChip(
                    title: specialStatusShortLabel(extra),
                    icon: specialStatusIcon(extra),
                    tint: specialStatusColor(extra)
                )
            )
        }
        return chips
    }

    private func formatCountdown(_ seconds: Int64) -> String {
        if seconds >= 60 {
            let minutes = max(1, (seconds + 30) / 60)
            return "约 \(minutes) 分钟后"
        }
        return "约 \(seconds) 秒后"
    }

    private func activeOrderHomeCard(_ order: ActiveServiceOrder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LivePulseDot(color: AppPalette.amber, size: 7, isPulsing: true)
                Text("换电排队进行中")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.amber)
                Spacer()
                liveActivityTogglePill(tint: AppPalette.amber)
                NavigationLink {
                    SwapRecordsListView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 3) {
                        Text("查看订单")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.amber)
                }
            }
            ActiveServiceOrderRow(
                order: order,
                notificationsEnabled: viewModel.queueNotificationsEnabled
            ) {
                quickControlHapticCount += 1
                Task {
                    await viewModel.setQueueNotificationsEnabled(!viewModel.queueNotificationsEnabled)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppPalette.amber.opacity(0.32), lineWidth: 1.2)
        }
        .shadow(color: AppPalette.cardShadow, radius: 10, x: 0, y: 4)
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
        .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.96))
        .sensoryFeedback(.selection, trigger: showingStandardRange)
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
                    Image(systemName: BatteryIndicator.symbolName(stateOfCharge: dashboard.stateOfCharge))
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : batteryTapCount)
                        .overlay {
                            if let batteryPulseID {
                                BatteryPulseRing(tint: BatteryIndicator.tint(stateOfCharge: dashboard.stateOfCharge))
                                    .id(batteryPulseID)
                            }
                        }
                    Text(dashboard.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "--")
                        .contentTransition(.numericText())
                }
                .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(BatteryIndicator.tint(stateOfCharge: dashboard.stateOfCharge))
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
                    color: dashboard.lockStatusCode == 1 ? AppPalette.red : AppPalette.green,
                    enabled: dashboard.lockStatusCode == 0 || dashboard.lockStatusCode == 1,
                    directAction: VehicleControlQuickDefaults.lockToggleAction(
                        lockStatusCode: dashboard.lockStatusCode
                    ).map { PendingVehicleAction(action: $0.action, expandMirrors: $0.expandMirrors) },
                    directActionLabel: dashboard.lockStatusCode == 1 ? "直接解锁并启动" : "直接落锁"
                ) {
                    if dashboard.lockStatusCode == 1 {
                        vehicleControlPresentation = .panel(.unlock)
                    } else {
                        vehicleControlPresentation = .confirmation(PendingVehicleAction(action: .lock))
                    }
                }
                quickControlButton(
                    title: "守卫",
                    icon: "shield.lefthalf.filled",
                    color: AppPalette.violet,
                    directAction: PendingVehicleAction(
                        action: VehicleControlQuickDefaults.guardModeAction.action,
                        expandMirrors: VehicleControlQuickDefaults.guardModeAction.expandMirrors
                    ),
                    directActionLabel: "直接开启守卫并展开后视镜"
                ) {
                    vehicleControlPresentation = .panel(.guardMode)
                }
                quickControlButton(
                    title: "寻车",
                    icon: "horn.blast.fill",
                    color: AppPalette.amber,
                    directAction: PendingVehicleAction(action: VehicleControlQuickDefaults.findAction),
                    directActionLabel: "直接开始寻车"
                ) {
                    vehicleControlPresentation = .panel(.finding)
                }
                quickControlButton(
                    title: "位置",
                    icon: "location.fill",
                    color: AppPalette.blue,
                    enabled: currentCoordinate != nil,
                    requiresControlKey: false
                ) {
                    if let currentCoordinate { openInMaps(currentCoordinate) }
                }
                quickControlButton(title: "更多", icon: "ellipsis", color: AppPalette.graphite) {
                    vehicleControlPresentation = .panel(.all)
                }
            }

            if viewModel.isVehicleControlConfigured && !viewModel.isPerformingVehicleAction {
                Text("轻点选择 · 长按图标直接执行（解锁默认启动 / 守卫展开后视镜）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func quickControlButton(
        title: String,
        icon: String,
        color: Color,
        enabled: Bool = true,
        requiresControlKey: Bool = true,
        directAction: PendingVehicleAction? = nil,
        directActionLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let canUse = enabled
            && !viewModel.isPerformingVehicleAction
            && (!requiresControlKey || viewModel.isVehicleControlConfigured)
        return HoldToExecuteButton(
            isHoldEnabled: canUse && directAction != nil,
            onTap: {
                quickControlHapticCount += 1
                action()
            },
            onLongPress: {
                guard let directAction, canUse else { return }
                executeVehicleAction(directAction)
            }
        ) { progress, isHolding, didComplete in
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(color.opacity(0.11 + 0.16 * progress))
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(color.opacity(isHolding ? 0.08 : 0.14), lineWidth: 1)
                    IconHoldProgressRing(
                        progress: progress,
                        isVisible: isHolding || didComplete,
                        color: color,
                        lineWidth: 3.5,
                        shape: .roundedRect(cornerRadius: 20)
                    )
                    Image(systemName: didComplete ? "checkmark" : icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(color)
                        .scaleEffect(didComplete ? 1.12 : 1)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 56, height: 56)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isHolding ? color : .primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: quickControlHapticCount)
        .disabled(!canUse)
        .opacity(canUse ? 1 : 0.42)
        .accessibilityHint(directActionLabel.map { "轻点打开选项，长按\($0)" } ?? "")
        .accessibilityAction(named: Text(directActionLabel ?? "")) {
            guard let directAction, canUse else { return }
            executeVehicleAction(directAction)
        }
    }

    private func metricsGrid(_ dashboard: VehicleDashboard) -> some View {
        let canControlClimate = viewModel.isVehicleControlConfigured && !viewModel.isPerformingVehicleAction
        let quickClimate = VehicleControlQuickDefaults.climateAction
        return HoldToExecuteButton(
            isHoldEnabled: canControlClimate,
            onTap: {
                guard canControlClimate else { return }
                quickControlHapticCount += 1
                vehicleControlPresentation = .panel(.climate)
            },
            onLongPress: {
                guard canControlClimate else { return }
                executeVehicleAction(
                    PendingVehicleAction(
                        action: quickClimate.action,
                        temperature: quickClimate.temperature
                    )
                )
            }
        ) { progress, isHolding, didComplete in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Label("座舱温度", systemImage: "thermometer.medium")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppPalette.amber)
                    Spacer(minLength: 8)
                    if viewModel.isVehicleControlConfigured {
                        HStack(spacing: 4) {
                            Text(isHolding ? "松手取消 · 直开 \(Int(quickClimate.temperature))℃" : "调温 · 长按直开")
                                .lineLimit(1)
                            if !isHolding {
                                Image(systemName: "chevron.right")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppPalette.amber.opacity(0.13), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(formatTemperature(dashboard.insideTemperature))
                            .font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                            .foregroundStyle(.primary)
                        Text("车外 \(formatTemperature(dashboard.outsideTemperature))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ZStack {
                        Circle()
                            .fill(AppPalette.amber.opacity(0.08 + 0.14 * progress))
                        Circle()
                            .stroke(AppPalette.amber.opacity(isHolding ? 0.08 : 0.16), lineWidth: 2)
                        IconHoldProgressRing(
                            progress: progress,
                            isVisible: isHolding || didComplete,
                            color: AppPalette.amber,
                            lineWidth: 3.8,
                            shape: .circle
                        )
                        Image(systemName: didComplete ? "checkmark" : "fan")
                            .font(.system(size: didComplete ? 26 : 34, weight: didComplete ? .semibold : .light))
                            .foregroundStyle(AppPalette.amber.opacity(isHolding || didComplete ? 0.95 : 0.65))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 64, height: 64)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [AppPalette.climate, AppPalette.climate.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(AppPalette.amber.opacity(isHolding ? 0.42 : 0.18), lineWidth: 1)
            }
            .shadow(color: AppPalette.cardShadow, radius: 10, x: 0, y: 4)
        }
        .disabled(!canControlClimate)
        .accessibilityLabel("座舱温度 \(formatTemperature(dashboard.insideTemperature))，车外 \(formatTemperature(dashboard.outsideTemperature))")
        .accessibilityHint(canControlClimate ? "轻点打开空调控制，长按直接开启 22 度空调" : "")
    }

    private func locationSection(_ dashboard: VehicleDashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("车辆位置", systemImage: "location.fill")
                    .font(.headline)
                Spacer()
                if viewModel.isConfigured {
                    Button {
                        quickControlHapticCount += 1
                        showingSendRouteSheet = true
                    } label: {
                        Label("发目的地到车机", systemImage: "paperplane.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppPalette.blue.opacity(0.11), in: Capsule())
                    }
                    .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.95))
                }
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
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private func batterySection(_ dashboard: VehicleDashboard) -> some View {
        NavigationLink {
            energyRecordsPage
        } label: {
            batteryCard(dashboard)
        }
        .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.985))
    }

    private func batteryCard(_ dashboard: VehicleDashboard) -> some View {
        let isCharging = dashboard.chargeStateCode == 1
        let barColor = isCharging ? AppPalette.green : BatteryIndicator.tint(stateOfCharge: dashboard.stateOfCharge)
        let limitIndex: Int? = dashboard.chargeLimitPercent.map {
            min(19, max(0, Int(($0 / 5.0).rounded()) - 1))
        }
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    "电池与充电",
                    systemImage: isCharging
                        ? "battery.100percent.bolt"
                        : BatteryIndicator.symbolName(stateOfCharge: dashboard.stateOfCharge)
                )
                    .font(.headline)
                    .foregroundStyle(isCharging ? AppPalette.green : .primary)
                Spacer()
                HStack(spacing: 4) {
                    Text("充换电记录")
                    Image(systemName: "chevron.right")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(barColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(barColor.opacity(0.11), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline) {
                Text(dashboard.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(barColor)
                Spacer()
                Text("充电上限 \(dashboard.chargeLimitPercent.map { "\(Int($0.rounded()))%" } ?? "--")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<20, id: \.self) { index in
                    let isFilled = Double(index) * 5 < (dashboard.stateOfCharge ?? 0)
                    let isLimitMarker = limitIndex == index
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isFilled ? barColor : barColor.opacity(0.13))
                        .frame(height: 19)
                        .overlay {
                            if isLimitMarker {
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
                            }
                        }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: dashboard.stateOfCharge)
            .accessibilityHidden(true)
            if isCharging {
                VStack(spacing: 10) {
                    HStack {
                        chargingValue("功率", formatChargingPower(dashboard.chargingPower))
                        Spacer()
                        chargingValue("电压", formatMeasurement(dashboard.chargingVoltage, unit: "V"))
                        Spacer()
                        chargingValue("电流", formatMeasurement(dashboard.chargingCurrent, unit: "A"))
                    }
                    HStack {
                        Label("灵动岛实时充电进度", systemImage: "iphone.gen3.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        liveActivityTogglePill(tint: AppPalette.green)
                    }
                }
                .padding(12)
                .background(AppPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack {
                HStack(spacing: 6) {
                    if isCharging {
                        LivePulseDot(color: AppPalette.green, size: 6, isPulsing: true)
                    }
                    Text(chargeStateLabel(dashboard.chargeStateCode))
                        .font(.caption.weight(isCharging ? .semibold : .regular))
                        .foregroundStyle(isCharging ? AppPalette.green : .secondary)
                }
                Spacer()
                if let sampledAt = dashboard.batterySampledAt {
                    Text("更新于 \(formatDateTime(sampledAt))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .nioCard(cornerRadius: 24, padding: 22)
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

    private func liveActivityTogglePill(tint: Color) -> some View {
        Button {
            quickControlHapticCount += 1
            Task { await viewModel.toggleLiveActivity() }
        } label: {
            Label(
                viewModel.isLiveActivityRunning ? "灵动岛已开启" : "贴到灵动岛",
                systemImage: viewModel.isLiveActivityRunning
                    ? "checkmark.circle.fill"
                    : "platter.filled.top.and.arrow.up.iphone"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(viewModel.isLiveActivityRunning ? tint : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                (viewModel.isLiveActivityRunning ? tint : Color.primary).opacity(0.11),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isLiveActivityRunning ? "关闭灵动岛实时活动" : "在灵动岛显示实时活动")
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
        .nioCard(cornerRadius: 22, padding: 18)
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
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("最近行程", systemImage: "road.lanes")
                    .font(.headline)
                Spacer()
                if !viewModel.trips.isEmpty {
                    NavigationLink {
                        VehicleTripsListView(trips: viewModel.trips, viewModel: viewModel)
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
                    NavigationLink {
                        VehicleTripDetailView(trip: trip, viewModel: viewModel)
                    } label: {
                        VehicleTripCard(trip: trip, showsDisclosure: true)
                    }
                    .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.985))
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
        .nioCard(cornerRadius: 24, padding: 20)
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
        if let special = dashboard.primarySpecialStatus {
            if special == .fota && dashboard.fotaPreparingCountdownSeconds != nil {
                return "准备系统升级"
            }
            return specialStatusShortLabel(special)
        }
        switch dashboard.stateCode {
        case 1: return "行驶中"
        case 2: return "已驻车"
        case 3: return "充电中"
        case 4: return "换电中"
        default: return dashboard.isConnected ? "车辆在线" : "车辆离线"
        }
    }

    private func heroAccessibilityLabel(
        vehicleTitle: String,
        vehicleColor: String?,
        isDriving: Bool
    ) -> String {
        let base = vehicleColor.map { "\($0) \(vehicleTitle)" } ?? vehicleTitle
        return isDriving ? "\(base)，行驶中" : base
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
    let tint: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(tint.opacity(0.55), lineWidth: 2)
            .frame(width: 36, height: 36)
            .scaleEffect(expanded ? 2.0 : 0.7)
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.75)) { expanded = true }
            }
            .accessibilityHidden(true)
    }
}

final class AnimatedGIFSequence {
    static let drivingRearViewAssetName = "CarDrivingRearView"
    static let drivingRearViewDarkAssetName = "CarDrivingRearViewDark"
    private static let cache = NSCache<NSString, AnimatedGIFSequence>()

    let frames: [UIImage]
    let duration: TimeInterval

    init(frames: [UIImage], duration: TimeInterval) {
        self.frames = frames
        self.duration = duration
    }

    static func cached(assetName: String, bundle: Bundle = .main) -> AnimatedGIFSequence? {
        let key = "\(bundle.bundleIdentifier ?? "main"):\(assetName)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let asset = NSDataAsset(name: assetName, bundle: bundle),
              let decoded = decode(data: asset.data) else {
            return nil
        }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    static func decode(data: Data) -> AnimatedGIFSequence? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [UIImage] = []
        frames.reserveCapacity(count)
        var totalDuration: TimeInterval = 0

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }
            frames.append(UIImage(cgImage: cgImage))
            totalDuration += frameDelay(at: index, in: source)
        }
        guard !frames.isEmpty else { return nil }
        let safeDuration = totalDuration > 0 ? totalDuration : Double(frames.count) / 24.0
        return AnimatedGIFSequence(frames: frames, duration: safeDuration)
    }

    private static func frameDelay(at index: Int, in source: CGImageSource) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifInfo = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 1.0 / 24.0
        }
        let rawDelay = (gifInfo[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gifInfo[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (1.0 / 24.0)
        // Standard browser/ImageIO minimum floor avoids zero-delay tight loops.
        return rawDelay < 0.02 ? (1.0 / 24.0) : rawDelay
    }
}

private struct AnimatedGIFView: UIViewRepresentable {
    let sequence: AnimatedGIFSequence
    let isAnimating: Bool

    final class Coordinator {
        weak var appliedSequence: AnimatedGIFSequence?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        applyAnimationState(to: imageView, coordinator: context.coordinator)
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        applyAnimationState(to: imageView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: Coordinator) {
        imageView.stopAnimating()
        imageView.animationImages = nil
        imageView.image = nil
        coordinator.appliedSequence = nil
    }

    private func applyAnimationState(to imageView: UIImageView, coordinator: Coordinator) {
        if isAnimating && sequence.frames.count > 1 {
            if coordinator.appliedSequence !== sequence || imageView.animationImages == nil {
                imageView.animationImages = sequence.frames
                imageView.animationDuration = sequence.duration
                imageView.animationRepeatCount = 0
                coordinator.appliedSequence = sequence
            }
            if imageView.image == nil {
                imageView.image = sequence.frames.first
            }
            if !imageView.isAnimating {
                imageView.startAnimating()
            }
        } else {
            if imageView.isAnimating {
                imageView.stopAnimating()
            }
            if imageView.animationImages != nil {
                imageView.animationImages = nil
            }
            coordinator.appliedSequence = nil
            imageView.image = sequence.frames.first
        }
    }
}

private struct VehicleHeroArtwork: View {
    let imageData: Data?
    let fallbackAssetName: String?
    let isDriving: Bool
    let isSceneActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // Frame the car and its original ground shadow, excluding the large
    // transparent margins of the official 1080 × 675 asset.
    private let visibleWidth: CGFloat = 925
    private let visibleHeight: CGFloat = 425

    var body: some View {
        Group {
            if isDriving,
               let drivingSequence = AnimatedGIFSequence.cached(
                   assetName: colorScheme == .dark
                       ? AnimatedGIFSequence.drivingRearViewDarkAssetName
                       : AnimatedGIFSequence.drivingRearViewAssetName
               ) ?? AnimatedGIFSequence.cached(
                   assetName: AnimatedGIFSequence.drivingRearViewAssetName
               ) {
                AnimatedGIFView(
                    sequence: drivingSequence,
                    isAnimating: isSceneActive && !reduceMotion
                )
                .scaleEffect(1.03)
                .transition(.opacity)
            } else if let imageData,
               let image = VehicleArtworkCropper.heroImage(from: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else if let fallbackAssetName {
                GeometryReader { geometry in
                    let scale = geometry.size.width / visibleWidth
                    Image(fallbackAssetName)
                        .resizable()
                        .frame(width: 1080 * scale, height: 675 * scale)
                        .offset(x: -75 * scale, y: -205 * scale)
                }
                .transition(.opacity)
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
                .transition(.opacity)
            }
        }
        .aspectRatio(visibleWidth / visibleHeight, contentMode: .fit)
        .clipped()
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: isDriving ? 0.08 : 0.03),
                .init(color: .black, location: isDriving ? 0.92 : 0.97),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
        .compositingGroup()
        .mask {
            if isDriving {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.24),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isDriving)
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
        case .unlock: 470
        case .climate: 560
        case .finding: 390
        case .guardMode: 500
        }
    }
}

enum VehicleControlQuickDefaults {
    static func lockToggleAction(lockStatusCode: Int?) -> (action: VehicleAction, expandMirrors: Bool)? {
        switch lockStatusCode {
        case 1: return (.unlockStart, false)
        case 0: return (.lock, false)
        default: return nil
        }
    }

    static let guardModeAction: (action: VehicleAction, expandMirrors: Bool) = (.guardOn, true)
    static let findAction: VehicleAction = .find
    static let climateAction: (action: VehicleAction, temperature: Double) = (.acOn, 22)
}

private struct VehicleControlPanel: View {
    let dashboard: VehicleDashboard?
    let scope: VehicleControlScope
    let vehicleTitle: String
    let onSelect: (VehicleAction, Double?, Bool) -> Void
    let onDirectExecute: (VehicleAction, Double?, Bool) -> Void
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
                        sectionHeading("门锁与启动", subtitle: "轻点进入确认 · 长按直接执行")
                        actionButton(.unlockStart, icon: "car.side", color: .red)
                        actionButton(.unlockDoors, icon: "lock.open", color: AppPalette.graphite)
                        if scope == .all {
                            actionButton(.lock, icon: "lock", color: AppPalette.green)
                        }
                    }
                    .controlCard()
                    .id("first")
                    }

                    if scope == .all || scope == .climate {
                        ClimateThermostatCard(
                            temperature: $temperature,
                            insideTemperature: dashboard?.insideTemperature,
                            outsideTemperature: dashboard?.outsideTemperature,
                            onSelect: onSelect,
                            onDirectExecute: onDirectExecute
                        )
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
                        sectionHeading("守卫模式", subtitle: "轻点进入确认 · 长按直接执行")
                        actionButton(
                            .guardOn,
                            icon: "arrow.up.left.and.arrow.down.right",
                            color: AppPalette.violet,
                            title: "开启守卫 · 展开后视镜",
                            expandMirrors: true
                        )
                        actionButton(
                            .guardOn,
                            icon: "shield.lefthalf.filled",
                            color: AppPalette.violet,
                            title: "开启守卫 · 不展开后视镜"
                        )
                        actionButton(.guardOff, icon: "shield.slash", color: AppPalette.graphite)
                    }
                    .controlCard()
                    .id(scope == .guardMode ? "first" : "guard-mode")
                    }

                    Label("轻点操作将进入二次确认，长按可直接执行。每项指令均不自动重试。", systemImage: "checkmark.shield")
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
        HoldToExecuteButton(
            onTap: {
                onSelect(action, temperature, expandMirrors)
            },
            onLongPress: {
                onDirectExecute(action, temperature, expandMirrors)
            }
        ) { progress, isHolding, didComplete in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12 + 0.16 * progress))
                    IconHoldProgressRing(
                        progress: progress,
                        isVisible: isHolding || didComplete,
                        color: color,
                        lineWidth: 3,
                        shape: .circle
                    )
                    Image(systemName: didComplete ? "checkmark" : icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(color)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 34, height: 34)
                Text(title ?? action.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isHolding ? color : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 10)
            .background(color.opacity(0.08 + 0.08 * progress), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(color.opacity(isHolding ? 0.36 : 0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ClimateThermostatCard: View {
    @Binding var temperature: Double
    let insideTemperature: Double?
    let outsideTemperature: Double?
    let onSelect: (VehicleAction, Double?, Bool) -> Void
    let onDirectExecute: (VehicleAction, Double?, Bool) -> Void

    private let minTemp: Double = 16
    private let maxTemp: Double = 30

    private var thermalColor: Color {
        switch temperature {
        case ..<20.5:
            return Color(red: 0.18, green: 0.56, blue: 0.92)
        case ..<24.5:
            return AppPalette.green
        default:
            return Color(red: 0.88, green: 0.44, blue: 0.16)
        }
    }

    private var thermalFillColor: Color {
        switch temperature {
        case ..<20.5:
            return Color(red: 0.14, green: 0.48, blue: 0.84)
        case ..<24.5:
            return Color(red: 0.14, green: 0.54, blue: 0.38)
        default:
            return Color(red: 0.82, green: 0.38, blue: 0.14)
        }
    }

    private var thermalModeLabel: String {
        switch temperature {
        case ..<19: return "极速制冷"
        case ..<21: return "清爽制冷"
        case ..<24.5: return "舒适恒温"
        case ..<27: return "温暖制热"
        default: return "强力暖风"
        }
    }

    private var thermalModeIcon: String {
        switch temperature {
        case ..<21: return "snowflake"
        case ..<24.5: return "wind"
        default: return "sun.max.fill"
        }
    }

    private let presets: [(temp: Double, label: String, icon: String)] = [
        (18, "制冷", "snowflake"),
        (22, "舒适", "sparkles"),
        (24, "微暖", "sun.haze.fill"),
        (26, "暖风", "flame.fill")
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Header row with live inside/outside context
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("座舱空调")
                        .font(.headline)
                    if let inside = insideTemperature {
                        let outText = outsideTemperature.map { String(format: " · 车外 %.1f℃", $0) } ?? ""
                        Text(String(format: "车内 %.1f℃%@", inside, outText))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("轻点确认 · 长按图标直接执行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Label(thermalModeLabel, systemImage: thermalModeIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(thermalColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(thermalColor.opacity(0.12), in: Capsule())
                    .animation(.easeInOut(duration: 0.25), value: thermalModeLabel)
            }

            // Hero Center Temperature Display + Flanking Steppers
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [thermalColor.opacity(0.18), thermalColor.opacity(0.0)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 56
                        )
                    )
                    .frame(width: 112, height: 112)
                    .animation(.easeInOut(duration: 0.3), value: Int(temperature))
                    .accessibilityHidden(true)

                HStack(spacing: 24) {
                    stepperButton(systemImage: "minus", enabled: temperature > minTemp) {
                        adjust(by: -1)
                    }
                    .accessibilityLabel("降低 1 度")

                    HStack(alignment: .top, spacing: 2) {
                        Text("\(Int(temperature))")
                            .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: temperature))
                            .foregroundStyle(.primary)
                        Text("℃")
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundStyle(thermalColor)
                            .padding(.top, 10)
                    }
                    .frame(minWidth: 108)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("设定温度 \(Int(temperature)) 摄氏度")

                    stepperButton(systemImage: "plus", enabled: temperature < maxTemp) {
                        adjust(by: 1)
                    }
                    .accessibilityLabel("升高 1 度")
                }
            }
            .sensoryFeedback(.selection, trigger: Int(temperature))

            // Custom Thermal Spectrum Scrub Bar
            ThermalSpectrumSlider(
                value: $temperature,
                range: minTemp...maxTemp,
                accentColor: thermalColor
            )

            // Semantic Quick Preset Chips
            HStack(spacing: 8) {
                ForEach(presets, id: \.temp) { preset in
                    let isSelected = Int(temperature) == Int(preset.temp)
                    Button {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                            temperature = preset.temp
                        }
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Text("\(Int(preset.temp))°")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            Text(preset.label)
                                .font(.system(size: 10, weight: .medium))
                                .opacity(isSelected ? 0.92 : 0.72)
                        }
                        .foregroundStyle(isSelected ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            isSelected ? thermalFillColor : AppPalette.surfaceSecondary,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.clear : AppPalette.hairline,
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.94))
                }
            }

            // Action Buttons (Hold to execute directly with clockwise icon ring, Tap to confirm)
            HStack(spacing: 10) {
                climateActionButton(
                    action: .acOn,
                    title: "开启 \(Int(temperature))℃",
                    icon: "fan.fill",
                    color: thermalFillColor,
                    isPrimary: true
                )
                climateActionButton(
                    action: .acOff,
                    title: "关闭空调",
                    icon: "fan.slash",
                    color: AppPalette.graphite,
                    isPrimary: false
                )
            }
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private func adjust(by delta: Double) {
        let next = min(max(temperature + delta, minTemp), maxTemp)
        guard next != temperature else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            temperature = next
        }
    }

    private func stepperButton(
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(width: 44, height: 44)
                .background(AppPalette.surfaceSecondary, in: Circle())
                .overlay {
                    Circle().strokeBorder(AppPalette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.90))
        .disabled(!enabled)
    }

    private func climateActionButton(
        action: VehicleAction,
        title: String,
        icon: String,
        color: Color,
        isPrimary: Bool
    ) -> some View {
        let tempArg: Double? = action == .acOn ? temperature : nil
        return HoldToExecuteButton(
            onTap: { onSelect(action, tempArg, false) },
            onLongPress: { onDirectExecute(action, tempArg, false) }
        ) { progress, isHolding, didComplete in
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isPrimary ? Color.white.opacity(0.20 + 0.16 * progress) : color.opacity(0.12 + 0.16 * progress))
                    IconHoldProgressRing(
                        progress: progress,
                        isVisible: isHolding || didComplete,
                        color: isPrimary ? .white : color,
                        lineWidth: 2.8,
                        shape: .circle
                    )
                    Image(systemName: didComplete ? "checkmark" : icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isPrimary ? .white : color)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 32, height: 32)

                Text(title)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isPrimary ? .white : (isHolding ? color : .primary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 10)
            .background(
                isPrimary
                    ? color.opacity(isHolding ? 0.92 : 1.0)
                    : AppPalette.surfaceSecondary,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                if !isPrimary {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(isHolding ? color.opacity(0.4) : AppPalette.hairline, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
    }
}

private struct ThermalSpectrumSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accentColor: Color

    @State private var isDragging = false

    private let trackHeight: CGFloat = 14
    private let thumbSize: CGFloat = 28
    private let tickMarks: [Int] = [16, 20, 23, 26, 30]

    private var normalized: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let usableWidth = max(proxy.size.width - thumbSize, 1)
                let thumbCenterX = thumbSize / 2 + usableWidth * normalized

                ZStack(alignment: .leading) {
                    // Full thermal spectrum track
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(red: 0.16, green: 0.56, blue: 0.94), location: 0.0),
                                    .init(color: Color(red: 0.24, green: 0.72, blue: 0.68), location: 0.42),
                                    .init(color: Color(red: 0.94, green: 0.68, blue: 0.26), location: 0.72),
                                    .init(color: Color(red: 0.90, green: 0.36, blue: 0.22), location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: trackHeight)
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                        }

                    // Tactile floating thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay {
                            Circle()
                                .fill(accentColor)
                                .frame(width: 10, height: 10)
                        }
                        .shadow(color: accentColor.opacity(0.32), radius: isDragging ? 8 : 4, x: 0, y: 2)
                        .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1)
                        .scaleEffect(isDragging ? 1.12 : 1.0)
                        .position(x: thumbCenterX, y: thumbSize / 2)
                        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isDragging)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging { isDragging = true }
                            let fraction = min(max((gesture.location.x - thumbSize / 2) / usableWidth, 0), 1)
                            let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                            let stepped = raw.rounded()
                            if stepped != value {
                                value = stepped
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(height: thumbSize)

            GeometryReader { proxy in
                let usableWidth = max(proxy.size.width - thumbSize, 1)
                let span = max(range.upperBound - range.lowerBound, 1)
                ZStack {
                    ForEach(tickMarks, id: \.self) { degree in
                        let fraction = CGFloat((Double(degree) - range.lowerBound) / span)
                        Text("\(degree)°")
                            .font(.system(size: 10, weight: Int(value) == degree ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(Int(value) == degree ? accentColor : .secondary)
                            .position(x: thumbSize / 2 + usableWidth * fraction, y: 7)
                    }
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("空调设定温度")
        .accessibilityValue("\(Int(value)) 摄氏度")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, range.upperBound)
            case .decrement: value = max(value - 1, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

private extension View {
    func controlCard() -> some View {
        self.nioCard(cornerRadius: 22, padding: 16)
    }
}
