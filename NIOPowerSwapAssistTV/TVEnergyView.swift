import Charts
import SwiftUI

struct TVEnergyView: View {
    @ObservedObject var viewModel: TVGarageViewModel

    private var activeSamples: [ChargingSample] {
        if !viewModel.chargingSamples.isEmpty && viewModel.dashboard?.chargeStateCode == 1 {
            return viewModel.chargingSamples
        }
        return viewModel.selectedSessionSamples
    }

    private var selectedSession: ChargingSession? {
        viewModel.chargingSessions.first { $0.id == viewModel.selectedChargingSessionID }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TVPalette.green.opacity(0.18), TVPalette.canvas, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    if let stats = viewModel.energyStats {
                        energySummarySection(stats)
                    }

                    chargingCurveCard

                    if !viewModel.chargingSessions.isEmpty {
                        chargingSessionsRail
                    }
                }
                .padding(.horizontal, 72)
                .padding(.top, 34)
                .padding(.bottom, 64)
            }
        }
    }

    // MARK: - 30-Day Energy Stats

    private func energySummarySection(_ stats: EnergyStats) -> some View {
        let swapShare = stats.swapEnergySharePercentOfKnown ?? 0
        let chargeShare = stats.chargingEnergySharePercentOfKnown ?? max(0, 100 - swapShare)

        return VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("近 30 天补能与费用总览", systemImage: "chart.bar.xaxis")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("本月已换电 \(stats.currentMonthSwapCount) 次")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TVPalette.cyan)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(TVPalette.cyan.opacity(0.16), in: Capsule())
            }

            HStack(spacing: 24) {
                energyMetricCard(
                    title: "总补能电量",
                    value: String(format: "%.1f kWh", stats.totalEnergyKWhKnown),
                    subtitle: "换电 \(String(format: "%.1f", stats.swapEnergyKWhKnown)) · 充电 \(String(format: "%.1f", stats.chargingEnergyKWhEstimated ?? 0))",
                    tint: TVPalette.green
                )
                energyMetricCard(
                    title: "近 30 天换电",
                    value: "\(stats.swapCount) 次",
                    subtitle: "换电占比 \(Int(swapShare.rounded()))%",
                    tint: TVPalette.cyan
                )
                energyMetricCard(
                    title: "换电实付金额",
                    value: String(format: "¥%.2f", stats.actualPaidCNYKnown),
                    subtitle: stats.couponDiscountCNYKnown > 0
                        ? String(format: "卡券抵扣 ¥%.2f", stats.couponDiscountCNYKnown)
                        : String(format: "总计费用 ¥%.2f", stats.swapTotalFeeCNYKnown),
                    tint: TVPalette.amber
                )
            }

            if stats.totalEnergyKWhKnown > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        let swapWidth = width * min(max(swapShare / 100.0, 0), 1)
                        HStack(spacing: 4) {
                            Capsule()
                                .fill(TVPalette.cyan)
                                .frame(width: max(swapShare > 0 ? 14 : 0, swapWidth))
                            Capsule()
                                .fill(TVPalette.green)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 14)

                    HStack {
                        Label("换电 \(Int(swapShare.rounded()))%", systemImage: "circle.fill")
                            .foregroundStyle(TVPalette.cyan)
                        Spacer()
                        Label("充电 \(Int(chargeShare.rounded()))%", systemImage: "circle.fill")
                            .foregroundStyle(TVPalette.green)
                    }
                    .font(.caption.weight(.semibold))
                }
                .tvGlassCard(cornerRadius: 22, padding: 20)
            }
        }
    }

    private func energyMetricCard(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvGlassCard(cornerRadius: 26, padding: 24)
    }

    // MARK: - Big-Screen Charging Power & SOC Chart

    private var chargingCurveCard: some View {
        let isLive = !viewModel.chargingSamples.isEmpty && viewModel.dashboard?.chargeStateCode == 1
        let peakKW = activeSamples.compactMap(\.powerWatts).max().map { $0 / 1_000.0 }

        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Label(isLive ? "实时充电功率曲线" : "历史充电功率曲线", systemImage: "bolt.batteryblock.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(TVPalette.green)
                        if isLive {
                            Text("LIVE")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(TVPalette.green, in: Capsule())
                        }
                    }
                    if let session = selectedSession, !isLive {
                        Text("\(TVFormatters.dateTime(session.startedAt)) · 时长 \(TVFormatters.durationMinutes(max(1, session.durationSeconds / 60))) · 电量 \(session.startSOC.map { "\(Int($0.rounded()))%" } ?? "--") → \(session.endSOC.map { "\(Int($0.rounded()))%" } ?? "--")")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let peakKW {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("峰值功率")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f kW", peakKW))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(TVPalette.green)
                    }
                }
            }

            if viewModel.isLoadingChargingSession {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("正在加载充电采样曲线…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            } else if activeSamples.count >= 2 {
                Chart(activeSamples) { sample in
                    if let watts = sample.powerWatts, watts.isFinite {
                        let kw = max(0, watts / 1_000.0)
                        AreaMark(
                            x: .value("时间", sample.sampledAt),
                            y: .value("功率(kW)", kw)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [TVPalette.green.opacity(0.42), TVPalette.green.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("时间", sample.sampledAt),
                            y: .value("功率(kW)", kw)
                        )
                        .foregroundStyle(TVPalette.green)
                        .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                            .foregroundStyle(Color.white.opacity(0.14))
                        AxisValueLabel {
                            if let kw = value.as(Double.self) {
                                Text("\(Int(kw.rounded())) kW")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.caption.monospacedDigit())
                    }
                }
                .frame(height: 360)
            } else {
                ContentUnavailableView(
                    "暂无充电曲线样本",
                    systemImage: "waveform.path.ecg",
                    description: Text("车辆开始充电或选择下方历史充电记录后将自动绘制功率曲线。")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .tvGlassCard(cornerRadius: 30, padding: 30)
    }

    // MARK: - Recent Charging Sessions Selector Rail

    private var chargingSessionsRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("近期充电记录（遥控器选中可切换上方曲线）")
                .font(.title3.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(viewModel.chargingSessions) { session in
                        let isSelected = session.id == viewModel.selectedChargingSessionID
                        Button {
                            Task { await viewModel.selectChargingSession(session.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(TVFormatters.dateTime(session.startedAt))
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                    Spacer()
                                    if let energy = session.energyKWh {
                                        Text(String(format: "+%.1f kWh", energy))
                                            .font(.callout.weight(.bold).monospacedDigit())
                                            .foregroundStyle(TVPalette.green)
                                    }
                                }
                                Text("\(session.startSOC.map { "\(Int($0.rounded()))%" } ?? "--") → \(session.endSOC.map { "\(Int($0.rounded()))%" } ?? "--")")
                                    .font(.title3.weight(.bold).monospacedDigit())
                                HStack {
                                    Text(TVFormatters.durationMinutes(max(1, session.durationSeconds / 60)))
                                    Spacer()
                                    if let peak = TVFormatters.powerKW(watts: session.peakPowerWatts) {
                                        Text("峰值 \(peak)")
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .padding(20)
                            .frame(width: 310, alignment: .leading)
                        }
                        .buttonStyle(
                            TVDarkFocusCardButtonStyle(
                                accentColor: TVPalette.green,
                                cornerRadius: 22,
                                isSelected: isSelected
                            )
                        )
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
            }
        }
    }
}
