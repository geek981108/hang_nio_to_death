import SwiftUI

struct TVStationView: View {
    @ObservedObject var viewModel: TVGarageViewModel

    private let batteryColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TVPalette.cyan.opacity(0.18), TVPalette.canvas, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    stationHeaderCard
                    stationSwitcherRail

                    if let snapshot = viewModel.stationSnapshot {
                        batteryMatrixSection(snapshot)
                        if let feeInfo = snapshot.feeInfo, !feeInfo.periods.isEmpty {
                            feePeriodsSection(feeInfo)
                        }
                    } else {
                        ContentUnavailableView(
                            "暂无换电站实时数据",
                            systemImage: "bolt.car",
                            description: Text("请确认后端已配置换电站查询模板，或按下方按钮切换附近换电站。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    }
                }
                .padding(.horizontal, 72)
                .padding(.top, 34)
                .padding(.bottom, 64)
            }
        }
    }

    private var stationHeaderCard: some View {
        let snapshot = viewModel.stationSnapshot
        let batteries = snapshot?.batteries ?? []
        let totalReady = batteries.filter { $0.status == .ready }.count
        let readyStandard = batteries.filter {
            $0.status == .ready && ($0.groupName.contains("75") || $0.groupName.contains("70"))
        }.count
        let ready100 = batteries.filter {
            $0.status == .ready && ($0.groupName.contains("100") || $0.groupName.contains("102"))
        }.count
        let allowsSwap = snapshot?.serviceState?.allowsSwap ?? true

        return HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label(
                        viewModel.stationSourceMode == .nearest ? "距离车辆最近" : "已选常用站点",
                        systemImage: "bolt.car.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TVPalette.cyan)

                    if !allowsSwap {
                        Text(snapshot?.serviceState?.statusText ?? "暂不可换电")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(TVPalette.amber)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(TVPalette.amber.opacity(0.2), in: Capsule())
                    }
                }

                Text(viewModel.stationLive?.displayName ?? viewModel.settings?.stationName ?? "正在获取换电站…")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .lineLimit(2)

                if let notice = snapshot?.serviceState?.notification, !notice.isEmpty {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(TVPalette.amber)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 28) {
                bigStat(
                    title: "可换电池",
                    value: batteries.isEmpty ? "--" : "\(totalReady)/\(batteries.count)",
                    tint: totalReady > 0 ? TVPalette.green : TVPalette.amber
                )
                bigStat(
                    title: "70/75 kWh",
                    value: "\(readyStandard)",
                    tint: readyStandard > 0 ? TVPalette.green : .secondary
                )
                bigStat(
                    title: "100 kWh",
                    value: "\(ready100)",
                    tint: ready100 > 0 ? TVPalette.cyan : .secondary
                )
                if let total = snapshot?.feeInfo?.total {
                    let currency = snapshot?.feeInfo?.totalCurrency ?? "¥"
                    bigStat(title: "当前电价", value: String(format: "%@%.2f", currency, total), tint: TVPalette.amber)
                }
            }

            Button {
                Task { await viewModel.refreshLiveOnly() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoading)
        }
        .tvGlassCard(cornerRadius: 30, padding: 30, borderColor: TVPalette.cyan.opacity(0.32))
    }

    private func bigStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var stationSwitcherRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                Button {
                    Task { await viewModel.switchStationSource(.nearest) }
                } label: {
                    Label("跟随车辆最近换电站", systemImage: "location.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.stationSourceMode == .nearest ? TVPalette.cyan : .gray.opacity(0.4))

                ForEach(viewModel.nearbyStations) { station in
                    let isSelected: Bool = {
                        if case .selected(let id, _) = viewModel.stationSourceMode {
                            return id == station.stationID
                        }
                        return false
                    }()
                    Button {
                        Task {
                            await viewModel.switchStationSource(.selected(id: station.stationID, name: station.displayName))
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(station.displayName)
                                .lineLimit(1)
                            Text(String(format: "%.1f km", station.straightLineDistanceKm))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isSelected ? TVPalette.blue : .gray.opacity(0.35))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
    }

    private func batteryMatrixSection(_ snapshot: SwapStationSnapshot) -> some View {
        let readyCount = snapshot.batteries.filter { $0.status == .ready }.count
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Text("站内电池仓位实时监控")
                    .font(.title3.weight(.semibold))
                Text("共 \(snapshot.batteries.count) 块 · \(readyCount) 块可换电")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: batteryColumns, spacing: 24) {
                ForEach(snapshot.batteries) { battery in
                    let tint = Self.batteryTint(for: battery)
                    Button {} label: {
                        batterySlotCard(battery, tint: tint)
                    }
                    .buttonStyle(TVDarkFocusCardButtonStyle(accentColor: tint, cornerRadius: 24))
                }
            }
        }
    }

    private static func batteryTint(for battery: BatteryModel) -> Color {
        switch battery.status {
        case .ready: return TVPalette.green
        case .charging: return TVPalette.blue
        case .occupied: return TVPalette.amber
        }
    }

    private func batterySlotCard(_ battery: BatteryModel, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(format: "仓位 #%02d", battery.slotID))
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(battery.groupName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline) {
                Text(battery.progressText)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                Spacer()
                Text(battery.status.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.18), in: Capsule())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(8, proxy.size.width * battery.progressFraction))
                }
            }
            .frame(height: 10)

            HStack {
                switch battery.status {
                case .occupied:
                    Label("槽位使用中", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(TVPalette.amber)
                case .charging:
                    if let minutes = battery.chargingRemainingMinutes, minutes > 0 {
                        Label("预计剩余 \(minutes) 分", systemImage: "clock")
                            .foregroundStyle(TVPalette.blue)
                    } else {
                        Label("正在充电", systemImage: "bolt.fill")
                            .foregroundStyle(TVPalette.blue)
                    }
                case .ready:
                    Text("满电待命")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = battery.manufactureDate, !date.isEmpty {
                    Text(date)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feePeriodsSection(_ feeInfo: FeeInfo) -> some View {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let currentMinute = (now.hour ?? 0) * 60 + (now.minute ?? 0)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("分时计费标准")
                    .font(.title3.weight(.semibold))
                Text("左右移动遥控器查看全天时段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(feeInfo.periods) { period in
                        let isNow = period.contains(minute: currentMinute)
                        let formattedUnit: String = {
                            let u = period.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !u.isEmpty else { return "" }
                            return u.hasPrefix("/") ? u : "/ \(u)"
                        }()
                        Button {} label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(period.timePeriod)
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                    Spacer(minLength: 6)
                                    if isNow {
                                        Text("当前时段")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(TVPalette.green)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(TVPalette.green.opacity(0.2), in: Capsule())
                                    }
                                }
                                if let total = period.total {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(String(format: "%@%.2f", period.currency, total))
                                            .font(.title3.weight(.bold).monospacedDigit())
                                            .foregroundStyle(isNow ? TVPalette.green : .white)
                                        if !formattedUnit.isEmpty {
                                            Text(formattedUnit)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(20)
                            .frame(width: 248, alignment: .leading)
                        }
                        .buttonStyle(
                            TVDarkFocusCardButtonStyle(
                                accentColor: isNow ? TVPalette.green : TVPalette.cyan,
                                cornerRadius: 20,
                                isSelected: isNow
                            )
                        )
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
        }
    }
}
