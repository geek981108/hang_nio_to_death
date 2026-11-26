import SwiftUI
import UIKit

struct TVOverviewView: View {
    @ObservedObject var viewModel: TVGarageViewModel
    let enterAmbientMode: () -> Void

    @State private var showingStandardRange = false
    @State private var showingSpecialStatusSheet = false
    @State private var pendingAction: VehicleAction?
    @State private var pendingPreset: TVPairingRoutePreset?

    private var statusVisuals: TVStatusVisuals {
        TVStatusVisuals.resolve(for: viewModel.dashboard)
    }

    var body: some View {
        ZStack {
            ambientBackdrop

            VStack(spacing: 28) {
                // Top Hero Zone: Serene Vehicle Stage (left) + Unified Telemetry Panel (right)
                HStack(alignment: .center, spacing: 44) {
                    heroVehicleStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    unifiedTelemetryPanel
                        .frame(width: 660)
                }
                .frame(maxHeight: .infinity)

                // Bottom Command Shelf: Aligned cleanly on the same 2-column architectural grid
                bottomCommandShelf
            }
            .padding(.horizontal, 68)
            .padding(.top, 20)
            .padding(.bottom, 44)
        }
        .sheet(isPresented: $showingSpecialStatusSheet) {
            if let dashboard = viewModel.dashboard, dashboard.hasActiveSpecialStatus {
                TVSpecialStatusSheet(dashboard: dashboard)
            }
        }
        .alert(
            actionAlertTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("确认执行") {
                let target = action
                pendingAction = nil
                Task { await viewModel.performSafeVehicleAction(target) }
            }
        } message: { action in
            Text(actionAlertMessage(for: action))
        }
        .alert(
            "发送常用路线到车机？",
            isPresented: Binding(
                get: { pendingPreset != nil },
                set: { if !$0 { pendingPreset = nil } }
            ),
            presenting: pendingPreset
        ) { preset in
            Button("取消", role: .cancel) { pendingPreset = nil }
            Button("立即发送") {
                let target = preset
                pendingPreset = nil
                Task { await viewModel.sendFavoriteRoute(target) }
            }
        } message: { preset in
            Text("将「\(preset.name)」（\(preset.summarySubtitle)，\(preset.enableEnergyPlanning ? "含加电补能规划" : "不自动补能")）发送到当前绑定车辆。")
        }
    }

    private var ambientBackdrop: some View {
        ZStack {
            Color(red: 0.025, green: 0.032, blue: 0.050)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    statusVisuals.color.opacity(0.22),
                    statusVisuals.color.opacity(0.05),
                    .clear
                ],
                center: UnitPoint(x: 0.24, y: 0.22),
                startRadius: 30,
                endRadius: 820
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Top-Left: Serene Hero Vehicle Stage

    private var heroVehicleStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Minimal, breathable identity header
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(viewModel.vehicleTitle)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let colorName = viewModel.vehicleColorLabel {
                        Text(colorName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 16) {
                    if viewModel.dashboard?.hasActiveSpecialStatus == true {
                        Button {
                            showingSpecialStatusSheet = true
                        } label: {
                            HStack(spacing: 10) {
                                TVLivePulseDot(color: statusVisuals.color, size: 10, isPulsing: true)
                                Text(statusVisuals.label)
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(statusVisuals.color)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(statusVisuals.color.opacity(0.85))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(TVCapsuleFocusButtonStyle(tint: statusVisuals.color))
                    } else {
                        HStack(spacing: 10) {
                            TVLivePulseDot(color: statusVisuals.color, size: 10, isPulsing: statusVisuals.isPulsing)
                            Text(statusVisuals.label)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(statusVisuals.isPulsing ? statusVisuals.color : .white.opacity(0.86))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.07), in: Capsule())
                    }

                    // Quiet single-line live sync status (never wraps, zero extra bubble noise)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewModel.eventStreamStatus == .connected ? TVPalette.green : TVPalette.amber)
                            .frame(width: 8, height: 8)
                        Text(liveSyncLabel)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            Spacer(minLength: 4)

            TVVehicleHeroStage(
                imageData: viewModel.vehicleImageData,
                fallbackAssetName: viewModel.vehicleProfile?.bundledArtworkAssetName,
                isDriving: viewModel.dashboard?.isDriving == true,
                accentColor: statusVisuals.color,
                maxHeight: 410,
                showShowroomFloor: true
            )

            Spacer(minLength: 4)

            // Only show an inline banner here for urgent live events (active swap queue or error)
            if let order = viewModel.activeServiceOrders.first {
                activeSwapOrderBanner(order)
            } else if let errorMessage = viewModel.errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TVPalette.amber)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                }
                .tvGlassCard(cornerRadius: 20, padding: 16, borderColor: TVPalette.amber.opacity(0.4))
            }
        }
    }

    private var liveSyncLabel: String {
        let base = viewModel.eventStreamStatus == .connected ? "实时同步" : viewModel.eventStreamStatus.title
        if let lastRefreshAt = viewModel.lastRefreshAt {
            return "\(base) · \(TVFormatters.clockTime(lastRefreshAt))"
        }
        return base
    }

    private func activeSwapOrderBanner(_ order: ActiveServiceOrder) -> some View {
        HStack(spacing: 20) {
            Image(systemName: "bolt.car.fill")
                .font(.title3)
                .foregroundStyle(TVPalette.amber)
                .frame(width: 48, height: 48)
                .background(TVPalette.amber.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("换电排队进行中")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(TVPalette.amber)
                    if let queueNo = order.queueNumber {
                        Text(String(format: "#%02d", queueNo))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(TVPalette.blue.opacity(0.32), in: Capsule())
                    }
                }
                Text(order.stationName ?? order.stationAddress ?? "蔚来换电站")
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
                if let ahead = order.vehiclesAhead {
                    Text(ahead == 0 ? "已到你换电" : "前方 \(ahead) 辆")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(ahead == 0 ? TVPalette.green : TVPalette.amber)
                }
                if let wait = order.estimatedWaitMinutes, wait > 0 {
                    Text("约 \(wait) 分钟")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tvGlassCard(cornerRadius: 22, padding: 18, borderColor: TVPalette.amber.opacity(0.45))
    }

    // MARK: - Top-Right: Single Unified Telemetry Panel

    private var unifiedTelemetryPanel: some View {
        let dashboard = viewModel.dashboard
        let usesStandard = dashboard?.remainingActualRange == nil
            || (showingStandardRange && dashboard?.remainingRange != nil)
        let primaryRange = usesStandard ? dashboard?.remainingRange : dashboard?.remainingActualRange
        let secondaryRangeLabel: String? = {
            guard dashboard?.remainingRange != nil, dashboard?.remainingActualRange != nil else { return nil }
            return usesStandard
                ? "预计实际 \(TVFormatters.km(dashboard?.remainingActualRange))"
                : "标准续航 \(TVFormatters.km(dashboard?.remainingRange))"
        }()
        let isLocked = dashboard?.lockStatusCode == 1
        let lockText: String = {
            switch dashboard?.lockStatusCode {
            case 1: return "已锁车"
            case 0: return "未锁车"
            default: return "未知"
            }
        }()
        let lockColor: Color = dashboard?.lockStatusCode == 1 ? TVPalette.green : TVPalette.amber

        return VStack(spacing: 24) {
            // Section 1: SOC Ring + Range (tap to toggle standard/actual)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showingStandardRange.toggle()
                }
            } label: {
                HStack(spacing: 28) {
                    TVSOCRingView(
                        soc: dashboard?.stateOfCharge,
                        color: batteryAccentColor,
                        lineWidth: 15,
                        diameter: 156,
                        isCharging: dashboard?.chargeStateCode == 1
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(usesStandard ? "标准续航" : "预计可行驶")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.55))

                        Text(TVFormatters.km(primaryRange))
                            .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        if let secondaryRangeLabel {
                            Text(secondaryRangeLabel)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }

                        if dashboard?.chargeStateCode == 1,
                           let power = TVFormatters.powerKW(watts: dashboard?.chargingPower) {
                            HStack(spacing: 10) {
                                Label(power, systemImage: "bolt.fill")
                                    .font(.callout.weight(.bold).monospacedDigit())
                                    .foregroundStyle(TVPalette.green)
                                if let energy = viewModel.currentChargingEnergyKWh, energy > 0 {
                                    Text(String(format: "+%.1f kWh", energy))
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(TVPalette.green.opacity(0.85))
                                }
                            }
                        } else if let limit = dashboard?.chargeLimitPercent {
                            Text("上限 \(Int(limit.rounded()))%  ·  总里程 \(TVFormatters.groupedKm(dashboard?.mileage))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TVDarkFocusCardButtonStyle(accentColor: batteryAccentColor, cornerRadius: 24))

            panelDivider

            // Section 2: Cabin / Outdoor / Lock cluster
            HStack(spacing: 20) {
                metricTile(
                    title: "车内温度",
                    value: TVFormatters.temperature(dashboard?.insideTemperature),
                    icon: "thermometer.medium",
                    tint: TVPalette.blue
                )
                Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 48)
                metricTile(
                    title: "车外温度",
                    value: TVFormatters.temperature(dashboard?.outsideTemperature),
                    icon: "sun.max.fill",
                    tint: TVPalette.cyan
                )
                Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 48)
                metricTile(
                    title: "门锁状态",
                    value: lockText,
                    icon: isLocked ? "lock.fill" : "lock.open.fill",
                    tint: lockColor
                )
            }
            .padding(.horizontal, 8)

            panelDivider

            // Section 3: Ambient Screensaver + Refresh (clean full-breath buttons, zero truncation)
            HStack(spacing: 16) {
                Button {
                    enterAmbientMode()
                } label: {
                    Label("进入展厅屏保", systemImage: "sparkles.tv")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: statusVisuals.color, cornerRadius: 18))

                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    HStack(spacing: 10) {
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("刷新车况")
                    }
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 196)
                    .padding(.vertical, 16)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.blue, cornerRadius: 18))
                .disabled(viewModel.isLoading)
            }
        }
        .padding(28)
        .background(
            Color(red: 0.062, green: 0.075, blue: 0.105).opacity(0.84),
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private var batteryAccentColor: Color {
        guard let soc = viewModel.dashboard?.stateOfCharge else { return TVPalette.blue }
        if viewModel.dashboard?.chargeStateCode == 1 { return TVPalette.green }
        if soc < 20 { return TVPalette.red }
        if soc < 45 { return TVPalette.amber }
        return TVPalette.green
    }

    private func metricTile(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom Architectural Command Shelf (2 Aligned Zones)

    private var bottomCommandShelf: some View {
        HStack(alignment: .bottom, spacing: 44) {
            // Left Zone (aligned with Hero Vehicle Stage): Quick Controls OR Station Glance
            if viewModel.hasControlKey {
                bottomControlsZone
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                bottomReadOnlyZone
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Right Zone (660pt, aligned with Telemetry Panel): Favorite Routes OR Station Glance
            if !viewModel.routePresets.isEmpty {
                bottomRoutesZone
                    .frame(width: 660, alignment: .leading)
            } else if let snapshot = viewModel.stationSnapshot, !snapshot.batteries.isEmpty {
                bottomStationCompactCard(snapshot)
                    .frame(width: 660, alignment: .leading)
            }
        }
    }

    private var bottomControlsZone: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("出门前快捷控制")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                if viewModel.isPerformingAction {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }

            // Single uncluttered horizontal row of custom compact focus pills — mathematically guaranteed ZERO truncation
            HStack(spacing: 14) {
                // Temperature stepper
                HStack(spacing: 8) {
                    Button {
                        viewModel.targetACTemperature = max(16.0, viewModel.clampedACTemperature - 1.0)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.blue, cornerRadius: 14))
                    .disabled(viewModel.isPerformingAction)

                    Text(String(format: "%.0f℃", viewModel.clampedACTemperature))
                        .font(.system(size: 25, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 66)

                    Button {
                        viewModel.targetACTemperature = min(30.0, viewModel.clampedACTemperature + 1.0)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.blue, cornerRadius: 14))
                    .disabled(viewModel.isPerformingAction)
                }
                .padding(8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                }

                // Couch-safe action pills (`unlockStart` strictly excluded)
                Button {
                    pendingAction = .acOn
                } label: {
                    Label("开空调", systemImage: "fanblades.fill")
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 20)
                        .frame(height: 64)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.blue, isProminent: true, cornerRadius: 18))
                .disabled(viewModel.isPerformingAction)

                Button {
                    pendingAction = .acOff
                } label: {
                    Label("关空调", systemImage: "power")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 18)
                        .frame(height: 64)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.blue, cornerRadius: 18))
                .disabled(viewModel.isPerformingAction)

                Button {
                    pendingAction = .guardOn
                } label: {
                    Label("守卫", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 18)
                        .frame(height: 64)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.cyan, cornerRadius: 18))
                .disabled(viewModel.isPerformingAction)

                Button {
                    pendingAction = .lock
                } label: {
                    Label("锁车", systemImage: "lock.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 18)
                        .frame(height: 64)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.green, cornerRadius: 18))
                .disabled(viewModel.isPerformingAction)

                Button {
                    pendingAction = .find
                } label: {
                    Label("寻车", systemImage: "horn.blast.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 18)
                        .frame(height: 64)
                }
                .buttonStyle(TVActionPillButtonStyle(tint: TVPalette.amber, cornerRadius: 18))
                .disabled(viewModel.isPerformingAction)
            }
        }
    }

    private var bottomReadOnlyZone: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(viewModel.stationSnapshot != nil ? "换电站速览" : "车控模式")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))

            if let snapshot = viewModel.stationSnapshot, !snapshot.batteries.isEmpty {
                bottomStationCompactCard(snapshot)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("当前为只读展厅模式 · 在「设置」同步车控 Key 后可远程开空调、守卫、锁车与寻车")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: 92)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
        }
    }

    private func bottomStationCompactCard(_ snapshot: SwapStationSnapshot) -> some View {
        let totalReady = snapshot.batteries.filter { $0.status == .ready }.count
        let stationTitle = viewModel.stationLive?.displayName ?? viewModel.settings?.stationName ?? "附近换电站"
        let shortTitle = stationTitle
            .replacingOccurrences(of: "蔚来换电站", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 22) {
            Image(systemName: "bolt.car.fill")
                .font(.title2)
                .foregroundStyle(TVPalette.cyan)
                .frame(width: 48, height: 48)
                .background(TVPalette.cyan.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(shortTitle.isEmpty ? stationTitle : shortTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(viewModel.stationSourceMode == .nearest ? "距离车辆最近换电站" : "已选常用换电站")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            HStack(spacing: 22) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("可换电池")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(totalReady)/\(snapshot.batteries.count)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(totalReady > 0 ? TVPalette.green : TVPalette.amber)
                }
                if let total = snapshot.feeInfo?.total {
                    let currency = snapshot.feeInfo?.totalCurrency ?? "¥"
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("当前电价")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%@%.2f", currency, total))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(TVPalette.amber)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 92)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(TVPalette.cyan.opacity(0.24), lineWidth: 1.2)
        }
    }

    private var bottomRoutesZone: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("常用路线 · 一键发车机")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                if viewModel.routePresets.count > 1 {
                    Text("\(viewModel.routePresets.count) 条")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(TVPalette.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(TVPalette.blue.opacity(0.16), in: Capsule())
                }
                Spacer()
                if viewModel.isSendingRoute {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }

            if viewModel.routePresets.count == 1, let preset = viewModel.routePresets.first {
                routePresetTile(preset, fillsColumn: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(viewModel.routePresets) { preset in
                            routePresetTile(preset, fillsColumn: false)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func routePresetTile(_ preset: TVPairingRoutePreset, fillsColumn: Bool) -> some View {
        Button {
            pendingPreset = preset
        } label: {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(preset.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(preset.enableEnergyPlanning ? "自动补能" : "直达")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(preset.enableEnergyPlanning ? TVPalette.green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (preset.enableEnergyPlanning ? TVPalette.green : Color.white).opacity(0.14),
                                in: Capsule()
                            )
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(preset.summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(TVPalette.blue)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: fillsColumn ? .infinity : 440, minHeight: 84, maxHeight: 84, alignment: .leading)
        }
        .buttonStyle(TVDarkFocusCardButtonStyle(accentColor: TVPalette.blue, cornerRadius: 22))
        .disabled(viewModel.isSendingRoute)
    }

    private var actionAlertTitle: String {
        switch pendingAction {
        case .acOn: return "开启车内空调？"
        case .acOff: return "关闭车内空调？"
        case .guardOn: return "开启守卫模式？"
        case .find: return "执行寻车指令？"
        case .lock: return "远程锁车？"
        default: return "确认执行车控指令？"
        }
    }

    private func actionAlertMessage(for action: VehicleAction) -> String {
        switch action {
        case .acOn:
            return String(format: "将以 %.0f℃ 发送一次开启空调指令，不会自动重试。", viewModel.clampedACTemperature)
        case .acOff:
            return "将发送一次关闭空调指令，不会自动重试。"
        case .guardOn:
            return "后端检查驻车状态后开启守卫模式并展开后视镜，不会自动重试。"
        case .lock:
            return "将发送一次远程锁车指令，不会自动重试。"
        case .find:
            return "车辆将鸣笛并闪灯，不会自动重试。"
        default:
            return "指令只发送一次，请确认车辆状态安全。"
        }
    }
}

struct TVSpecialStatusSheet: View {
    let dashboard: VehicleDashboard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let primary = dashboard.primarySpecialStatus {
            let tint = TVStatusVisuals.specialColor(primary)
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    Image(systemName: TVStatusVisuals.specialIcon(primary))
                        .font(.largeTitle)
                        .foregroundStyle(tint)
                        .frame(width: 72, height: 72)
                        .background(tint.opacity(0.18), in: Circle())

                    VStack(alignment: .leading, spacing: 6) {
                        Text(TVStatusVisuals.specialTitle(primary, dashboard: dashboard))
                            .font(.title2.weight(.bold))
                        if let time = sampleTimeText(primary) {
                            Text(time)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Text(TVStatusVisuals.specialDescription(primary, dashboard: dashboard))
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if primary == .repairing && dashboard.lockStatusCode == 0 {
                        Label("当前未锁车", systemImage: "lock.open.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(TVPalette.amber)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(TVPalette.amber.opacity(0.16), in: Capsule())
                    }
                    if primary == .repairing && dashboard.stateCode == 1 {
                        Label("车辆通电/移动中", systemImage: "car.side.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(TVPalette.blue)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(TVPalette.blue.opacity(0.16), in: Capsule())
                    }
                    ForEach(Array(dashboard.activeSpecialStatuses.dropFirst()), id: \.self) { extra in
                        Label(
                            TVStatusVisuals.specialTitle(extra, dashboard: dashboard),
                            systemImage: TVStatusVisuals.specialIcon(extra)
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(TVStatusVisuals.specialColor(extra))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(TVStatusVisuals.specialColor(extra).opacity(0.16), in: Capsule())
                    }
                }

                Button("知道了") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
            }
            .padding(54)
            .frame(maxWidth: 920)
        }
    }

    private func sampleTimeText(_ kind: VehicleDashboard.SpecialStatusKind) -> String? {
        switch kind {
        case .svt: return dashboard.svtSampledAt.map { "触发采样 \(TVFormatters.dateTime($0))" }
        case .repairing: return dashboard.repairSampledAt.map { "状态更新 \(TVFormatters.dateTime($0))" }
        case .fota: return dashboard.fotaPreparingSampledAt.map { "准备时间 \(TVFormatters.dateTime($0))" }
        case .swapping: return nil
        }
    }
}

/// Distraction-free luxury living room ambient showroom screensaver with opaque cinema canvas,
/// OLED pixel-shift protection, live telemetry dock, and idle-timer lock.
struct TVAmbientGarageView: View {
    @ObservedObject var viewModel: TVGarageViewModel
    let exit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var visuals: TVStatusVisuals {
        TVStatusVisuals.resolve(for: viewModel.dashboard)
    }

    private var batteryTint: Color {
        guard let soc = viewModel.dashboard?.stateOfCharge else { return TVPalette.blue }
        if viewModel.dashboard?.chargeStateCode == 1 { return TVPalette.green }
        if soc < 20 { return TVPalette.red }
        if soc < 45 { return TVPalette.amber }
        return TVPalette.green
    }

    private var readyStationSummary: (name: String, detail: String)? {
        guard let snapshot = viewModel.stationSnapshot, !snapshot.batteries.isEmpty else { return nil }
        let readyCount = snapshot.batteries.filter { $0.status == .ready }.count
        let rawName = viewModel.stationLive?.displayName ?? viewModel.settings?.stationName ?? "附近换电站"
        let shortName = rawName
            .replacingOccurrences(of: "蔚来换电站", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (shortName.isEmpty ? rawName : shortName, "可换 \(readyCount) / \(snapshot.batteries.count) 块")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let drift = pixelShiftOffset(for: context.date)

            ZStack {
                // 100% opaque obsidian cinema base prevents any underlying bleed-through.
                Color(red: 0.015, green: 0.018, blue: 0.026)
                    .ignoresSafeArea()

                // Soft breathing top ambient studio dome
                RadialGradient(
                    colors: [
                        visuals.color.opacity(breathe ? 0.24 : 0.16),
                        visuals.color.opacity(0.05),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.08),
                    startRadius: 40,
                    endRadius: 960
                )
                .ignoresSafeArea()
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 7.0).repeatForever(autoreverses: true),
                    value: breathe
                )

                // Subtle bottom-center ambient reflection glow
                RadialGradient(
                    colors: [
                        visuals.color.opacity(breathe ? 0.18 : 0.11),
                        .clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.66),
                    startRadius: 20,
                    endRadius: 640
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    ambientHeader(now: context.date)
                        .padding(.horizontal, 84)
                        .padding(.top, 56)

                    Spacer(minLength: 12)

                    TVVehicleHeroStage(
                        imageData: viewModel.vehicleImageData,
                        fallbackAssetName: viewModel.vehicleProfile?.bundledArtworkAssetName,
                        isDriving: viewModel.dashboard?.isDriving == true,
                        accentColor: visuals.color,
                        maxHeight: 500,
                        showShowroomFloor: true
                    )
                    .padding(.horizontal, 120)

                    Spacer(minLength: 12)

                    ambientBottomDock
                        .padding(.horizontal, 84)
                        .padding(.bottom, 52)
                }
                .offset(x: drift.width, y: drift.height)
                .animation(.easeInOut(duration: 4.0), value: drift.width)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            breathe = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onExitCommand { exit() }
    }

    private func ambientHeader(now: Date) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(viewModel.vehicleTitle)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let colorName = viewModel.vehicleColorLabel {
                        Text(colorName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }

                HStack(spacing: 14) {
                    HStack(spacing: 10) {
                        TVLivePulseDot(color: visuals.color, size: 10, isPulsing: visuals.isPulsing)
                        Text(visuals.label)
                            .font(.headline)
                            .foregroundStyle(visuals.color)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(visuals.color.opacity(0.16), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(visuals.color.opacity(0.35), lineWidth: 1)
                    }

                    if let order = viewModel.activeServiceOrders.first,
                       let ahead = order.vehiclesAhead {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.car.fill")
                                .foregroundStyle(TVPalette.amber)
                            Text("\(order.stationName ?? "换电站") · \(ahead == 0 ? "已到你换电" : "前方 \(ahead) 辆")")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(TVPalette.amber)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(TVPalette.amber.opacity(0.15), in: Capsule())
                    }

                    if viewModel.eventStreamStatus == .connected {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(TVPalette.green)
                                .frame(width: 7, height: 7)
                            Text("实时")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.48))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 24)

            VStack(alignment: .trailing, spacing: 6) {
                Text(TVFormatters.clockTime(now))
                    .font(.system(size: 86, weight: .ultraLight, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(TVFormatters.ambientDate(now))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }
        }
    }

    private var ambientBottomDock: some View {
        let dashboard = viewModel.dashboard
        let soc = dashboard?.stateOfCharge
        let actualRange = dashboard?.remainingActualRange ?? dashboard?.remainingRange
        let standardRange = dashboard?.remainingActualRange != nil ? dashboard?.remainingRange : nil
        let lockText: String = {
            switch dashboard?.lockStatusCode {
            case 1: return "已锁车"
            case 0: return "未锁车"
            default: return "未知"
            }
        }()
        let lockTint: Color = dashboard?.lockStatusCode == 1 ? TVPalette.green : TVPalette.amber

        return HStack(spacing: 28) {
            // SOC + compact progress bar
            VStack(alignment: .leading, spacing: 8) {
                Text("剩余电量")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(soc.map { "\(Int($0.rounded()))%" } ?? "--%")
                        .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(batteryTint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 74, height: 8)
                        Capsule()
                            .fill(batteryTint)
                            .frame(width: max(6, 74 * min(max((soc ?? 0) / 100.0, 0), 1)), height: 8)
                    }
                }
            }

            dockDivider

            // Range
            VStack(alignment: .leading, spacing: 6) {
                Text(dashboard?.remainingActualRange != nil ? "预计续航" : "标准续航")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TVFormatters.km(actualRange))
                        .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let standardRange {
                        Text("标准 \(TVFormatters.km(standardRange))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            dockDivider

            // Charging power OR Cabin / Outdoor Temp
            if dashboard?.chargeStateCode == 1,
               let power = TVFormatters.powerKW(watts: dashboard?.chargingPower) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("实时充电功率")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(power)
                            .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(TVPalette.green)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if let energy = viewModel.currentChargingEnergyKWh, energy > 0 {
                            Text(String(format: "+%.1f kWh", energy))
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(TVPalette.green.opacity(0.8))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("车内 / 车外温度")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                    Text("\(TVFormatters.temperature(dashboard?.insideTemperature)) / \(TVFormatters.temperature(dashboard?.outsideTemperature))")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(TVPalette.cyan)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            dockDivider

            // Lock status
            VStack(alignment: .leading, spacing: 6) {
                Text("门锁状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
                Label(lockText, systemImage: dashboard?.lockStatusCode == 1 ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(lockTint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let station = readyStationSummary {
                dockDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text(station.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .frame(maxWidth: 210, alignment: .leading)
                    Text(station.detail)
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 12)

            Button {
                exit()
            } label: {
                Label("按返回键退出", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .buttonStyle(TVAmbientDiscreetExitButtonStyle())
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
        .background(
            Color(red: 0.055, green: 0.068, blue: 0.095).opacity(0.82),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.2
                )
        }
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 48)
    }

    /// Gentle ±12pt pixel-shift cycle to prevent static burn-in on OLED TVs.
    private func pixelShiftOffset(for date: Date) -> CGSize {
        guard !reduceMotion else { return .zero }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 360) / 360.0 * .pi * 2.0
        return CGSize(width: cos(phase) * 12.0, height: sin(phase * 2.0) * 6.0)
    }
}

private struct TVAmbientDiscreetExitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? .white : .white.opacity(0.45))
                .background(
                    Color.white.opacity(isFocused ? 0.18 : 0.05),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(isFocused ? 0.65 : 0.12), lineWidth: isFocused ? 2 : 1)
                }
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.05 : 1.0))
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
