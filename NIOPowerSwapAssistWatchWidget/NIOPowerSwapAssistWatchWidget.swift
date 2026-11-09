import SwiftUI
import WidgetKit

private struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot?
}

private struct WatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchWidgetEntry {
        WatchWidgetEntry(
            date: .now,
            snapshot: WatchSnapshot(
                stateOfCharge: 76,
                remainingRange: 362,
                isConnected: true,
                isCharging: false,
                isSwapping: false,
                stationName: "当前换电站",
                queueText: nil,
                updatedAt: .now
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        completion(WatchWidgetEntry(date: .now, snapshot: WatchSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        let entry = WatchWidgetEntry(date: .now, snapshot: WatchSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private struct WatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                rectangularView
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .privacySensitive()
    }

    private var circularView: some View {
        Gauge(value: normalizedSOC) {
            Image(systemName: statusSymbol)
        } currentValueLabel: {
            Text(socText)
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(statusColor)
        .accessibilityLabel("车辆电量 \(socText)，\(statusText)")
    }

    private var rectangularView: some View {
        HStack(spacing: 7) {
            Image(systemName: statusSymbol)
                .font(.title3)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(socText)
                        .font(.headline.monospacedDigit())
                    Text(rangeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(queueOrStatusText)
                    .font(.caption2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var inlineView: some View {
        Label("\(socText) · \(rangeText) · \(statusText)", systemImage: statusSymbol)
    }

    private var normalizedSOC: Double {
        min(max((entry.snapshot?.stateOfCharge ?? 0) / 100, 0), 1)
    }

    private var socText: String {
        guard let soc = entry.snapshot?.stateOfCharge else { return "—" }
        return "\(Int(soc.rounded()))%"
    }

    private var rangeText: String {
        guard let range = entry.snapshot?.remainingRange else { return "— km" }
        return "\(Int(range.rounded())) km"
    }

    private var statusText: String {
        guard let snapshot = entry.snapshot else { return "打开 App 刷新" }
        if snapshot.isSwapping { return "换电中" }
        if snapshot.isCharging { return "充电中" }
        return snapshot.isConnected ? "在线" : "离线"
    }

    private var queueOrStatusText: String {
        entry.snapshot?.queueText ?? entry.snapshot?.stationName ?? statusText
    }

    private var statusSymbol: String {
        guard let snapshot = entry.snapshot else { return "car.side" }
        if snapshot.isSwapping { return "arrow.triangle.2.circlepath" }
        if snapshot.isCharging { return "bolt.fill" }
        return snapshot.isConnected ? "car.side.fill" : "car.side"
    }

    private var statusColor: Color {
        guard let snapshot = entry.snapshot else { return .secondary }
        if snapshot.isSwapping { return .cyan }
        if snapshot.isCharging { return .green }
        return snapshot.isConnected ? .blue : .secondary
    }
}

@main
struct NIOPowerSwapAssistWatchWidget: Widget {
    let kind = "NIOPowerSwapAssistWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchWidgetView(entry: entry)
        }
        .configurationDisplayName("车辆状态")
        .description("查看车辆电量、续航、连接与换电状态。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
