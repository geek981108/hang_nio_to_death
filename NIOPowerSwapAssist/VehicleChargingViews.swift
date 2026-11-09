import Charts
import SwiftUI

struct ChargingRecordsListView: View {
    @ObservedObject var viewModel: VehicleViewModel

    var body: some View {
        Group {
            if viewModel.chargingSessions.isEmpty,
               viewModel.chargingSessionsErrorMessage == nil {
                ContentUnavailableView(
                    "暂无充电记录",
                    systemImage: "bolt.badge.clock",
                    description: Text("完成一次后端采集的充电会话后会显示在这里。")
                )
            } else {
                List {
                    if let error = viewModel.chargingSessionsErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    ForEach(viewModel.chargingSessions) { session in
                        NavigationLink {
                            ChargingCurveView(viewModel: viewModel, session: session)
                        } label: {
                            ChargingSessionRow(session: session)
                                .padding(.vertical, 5)
                        }
                        .task(id: session.energyKWh == nil ? session.id : nil) {
                            await viewModel.hydrateChargingSessionEnergyIfNeeded(id: session.id)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("充电记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refreshChargingSessions() }
        .task {
            if viewModel.chargingSessions.isEmpty {
                await viewModel.refreshChargingSessions()
            }
        }
    }
}

struct ChargingSessionRow: View {
    let session: ChargingSession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "battery.100percent.bolt")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 42, height: 42)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 7) {
                Text(formatDateTime(session.startedAt))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                VStack(alignment: .leading, spacing: 4) {
                    compactMetadata(socLabel, icon: "battery.75percent")
                    compactMetadata(durationLabel, icon: "clock")
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                if let energy = session.energyKWh {
                    Text(String(format: "充入 %.2f kWh", energy))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppPalette.blue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text("电量待计算")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if let peak = session.peakPowerWatts {
                    Text(String(format: "峰值 %.1f kW", peak / 1_000))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(session.sampleCount) 点")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private func compactMetadata(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .frame(width: 17)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .layoutPriority(1)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var socLabel: String {
        guard let start = session.startSOC, let end = session.endSOC else { return "SOC --" }
        return String(format: "%.0f%% → %.0f%%", start, end)
    }

    private var durationLabel: String {
        let minutes = max(1, Int(ceil(Double(session.durationSeconds) / 60)))
        if minutes >= 60 { return "\(minutes / 60)时\(minutes % 60)分" }
        return "\(minutes) 分钟"
    }

    private func formatDateTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d/%02d/%02d %02d:%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0,
            values.hour ?? 0,
            values.minute ?? 0
        )
    }
}

private enum ChargingChartMetric: String, CaseIterable, Identifiable {
    case soc = "SOC"
    case power = "功率"
    case voltage = "电压"
    case current = "电流"

    var id: Self { self }

    var color: Color {
        switch self {
        case .soc: AppPalette.green
        case .power: AppPalette.violet
        case .voltage: AppPalette.blue
        case .current: AppPalette.amber
        }
    }

    var unit: String {
        switch self {
        case .soc: "%"
        case .power: "kW"
        case .voltage: "V"
        case .current: "A"
        }
    }

    func value(for sample: ChargingSample) -> Double? {
        switch self {
        case .soc: sample.soc
        case .power: sample.powerWatts.map { $0 / 1_000 }
        case .voltage: sample.voltageVolts
        case .current: sample.currentAmps
        }
    }

    func label(for sample: ChargingSample) -> String {
        guard let value = value(for: sample), value.isFinite else { return "--" }
        switch self {
        case .soc: return String(format: "%.0f%%", value)
        case .power: return String(format: "%.1f kW", value)
        case .voltage: return String(format: "%.1f V", value)
        case .current: return String(format: "%.1f A", value)
        }
    }
}

struct ChargingCurveView: View {
    @ObservedObject var viewModel: VehicleViewModel
    let session: ChargingSession?
    @State private var metric: ChargingChartMetric = .soc
    @State private var selectedTime: Date?
    @State private var historicalSamples: [ChargingSample] = []
    @State private var historicalEnergyKWh: Double?
    @State private var loadError: String?
    @State private var isLoading = false

    init(viewModel: VehicleViewModel, session: ChargingSession? = nil) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.session = session
    }

    private var isCharging: Bool {
        session == nil && viewModel.dashboard?.chargeStateCode == 1
    }

    private var samples: [ChargingSample] {
        session == nil ? viewModel.chargingSamples : historicalSamples
    }

    private var errorMessage: String? {
        session == nil ? viewModel.chargingErrorMessage : loadError
    }

    private var energyKWh: Double? {
        session == nil ? viewModel.currentChargingEnergyKWh : (historicalEnergyKWh ?? session?.energyKWh)
    }

    private var selectedSample: ChargingSample? {
        guard let selectedTime else { return samples.last }
        return ChargingSample.nearest(in: samples, to: selectedTime)
    }

    var body: some View {
        let chosen = selectedSample
        ScrollView {
            VStack(spacing: 18) {
                chargingHeader
                chargingSummaryMetrics

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                if isLoading && samples.isEmpty {
                    ProgressView("读取充电曲线…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if samples.isEmpty {
                    ContentUnavailableView(
                        session == nil ? "正在等待充电采样" : "暂无曲线采样",
                        systemImage: "chart.xyaxis.line",
                        description: Text(
                            session == nil
                                ? "保持后端运行，新的 SOC、电压、电流和功率点位会自动累积。"
                                : "这条充电记录没有可用的曲线点位。"
                        )
                    )
                    .frame(minHeight: 300)
                } else {
                    Picker("曲线指标", selection: $metric) {
                        ForEach(ChargingChartMetric.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    chartCard(chosen)

                    if let sample = chosen {
                        pointDetails(sample)
                    }
                }
            }
            .padding(16)
        }
        .background(AppPalette.canvas)
        .navigationTitle(session == nil ? "本次充电" : "充电详情")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: metric) { _, _ in selectedTime = nil }
        .task {
            if let session {
                isLoading = true
                loadError = nil
                do {
                    let page = try await viewModel.fetchChargingSessionDetail(id: session.id)
                    historicalSamples = page.items
                    historicalEnergyKWh = page.energyKWh
                } catch is CancellationError {
                    return
                } catch {
                    loadError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                isLoading = false
            } else {
                while !Task.isCancelled {
                    await viewModel.refreshChargingData()
                    let interval: TimeInterval = isCharging ? 15 : 60
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        break
                    }
                }
            }
        }
    }

    private var chargingHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: "battery.100percent.bolt")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(colors: [AppPalette.green, AppPalette.blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(session == nil ? (isCharging ? "充电进行中" : "本次充电已结束") : "历史充电记录")
                    .font(.title3.bold())
                if let first = samples.first, let last = samples.last {
                    Text(session == nil
                        ? "\(formatTime(first.sampledAt)) 开始 · 已采集 \(samples.count) 个点"
                        : "\(formatDateTime(first.sampledAt)) – \(formatDateTime(last.sampledAt))"
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let firstSOC = first.soc, let lastSOC = last.soc {
                        Text(String(format: "SOC %.0f%% → %.0f%%", firstSOC, lastSOC))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppPalette.green)
                    }
                } else {
                    Text(session == nil ? "曲线将随车辆采样实时积累" : "正在读取该次充电曲线")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var chargingSummaryMetrics: some View {
        HStack(spacing: 0) {
            chargingSummaryValue(
                "充入电量",
                energyKWh.map { String(format: "%.2f kWh", $0) } ?? "待计算",
                color: energyKWh == nil ? .orange : AppPalette.blue
            )
            Divider().frame(height: 38)
            chargingSummaryValue("充电时长", summaryDurationLabel, color: .primary)
            Divider().frame(height: 38)
            chargingSummaryValue(
                "峰值功率",
                summaryPeakPower.map { String(format: "%.1f kW", $0 / 1_000) } ?? "—",
                color: AppPalette.violet
            )
        }
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chargingSummaryValue(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryPeakPower: Double? {
        session?.peakPowerWatts ?? samples.compactMap(\.powerWatts).max()
    }

    private var summaryDurationLabel: String {
        let seconds: TimeInterval
        if let session {
            seconds = TimeInterval(session.durationSeconds)
        } else if let first = samples.first, let last = samples.last {
            seconds = max(0, last.sampledAt.timeIntervalSince(first.sampledAt))
        } else {
            return "—"
        }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 60 { return "\(minutes / 60)时\(minutes % 60)分" }
        return "\(minutes)分钟"
    }

    private func chartCard(_ chosen: ChargingSample?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(metric.rawValue)曲线")
                    .font(.headline)
                Spacer()
                if let sample = chosen {
                    Text(metric.label(for: sample))
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(metric.color)
                }
            }

            Chart {
            ForEach(samples) { sample in
                if let value = metric.value(for: sample), value.isFinite {
                    LineMark(
                        x: .value("时间", sample.sampledAt),
                        y: .value(metric.rawValue, value)
                    )
                    .foregroundStyle(metric.color)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("时间", sample.sampledAt),
                        y: .value(metric.rawValue, value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [metric.color.opacity(0.24), metric.color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

            }
                if let chosen, let value = metric.value(for: chosen), value.isFinite {
                    RuleMark(x: .value("选中时间", chosen.sampledAt))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    PointMark(
                        x: .value("选中时间", chosen.sampledAt),
                        y: .value("选中数值", value)
                    )
                    .symbolSize(85)
                    .foregroundStyle(metric.color)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXSelection(value: $selectedTime)
            .frame(height: 260)

            Label("在曲线上左右拖动，可查看对应时间的全部点位数据", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func pointDetails(_ sample: ChargingSample) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("点位数据", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Text(formatDateTime(sample.sampledAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                pointMetric("SOC", ChargingChartMetric.soc.label(for: sample), "battery.75percent", ChargingChartMetric.soc.color)
                pointMetric("功率", ChargingChartMetric.power.label(for: sample), "bolt.circle.fill", ChargingChartMetric.power.color)
                pointMetric("电压", ChargingChartMetric.voltage.label(for: sample), "waveform.path.ecg", ChargingChartMetric.voltage.color)
                pointMetric("电流", ChargingChartMetric.current.label(for: sample), "arrow.right.circle.fill", ChargingChartMetric.current.color)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func pointMetric(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", values.hour ?? 0, values.minute ?? 0)
    }

    private func formatDateTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%02d/%02d %02d:%02d:%02d",
            values.month ?? 0,
            values.day ?? 0,
            values.hour ?? 0,
            values.minute ?? 0,
            values.second ?? 0
        )
    }
}
