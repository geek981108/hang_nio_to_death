import Charts
import SwiftUI

struct FeeInfoView: View {
    let feeInfo: FeeInfo
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("当前费率", systemImage: "yensign.circle.fill")
                    .font(.headline)
                Spacer()
                if !feeInfo.periods.isEmpty {
                    Button("详情", systemImage: "chart.bar.xaxis") {
                        showingDetails = true
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            if let total = feeInfo.total {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(feeInfo.totalCurrency)\(total, specifier: "%.2f")")
                        .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(AppPalette.amber)
                    if !feeInfo.totalUnit.isEmpty {
                        Text("/\(feeInfo.totalUnit)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(feeInfo.componentFees) { item in
                HStack {
                    Text(item.name).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(item.currency)\(item.fee)/\(item.unit)").fontWeight(.semibold)
                }
                .font(.subheadline)
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sheet(isPresented: $showingDetails) {
            FeeDetailView(feeInfo: feeInfo)
        }
    }
}

private struct FeeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let feeInfo: FeeInfo

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let minute = Self.minuteOfDay(context.date)
                let current = feeInfo.period(atMinute: minute)
                let next = current.flatMap(feeInfo.nextPeriod(after:))

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        periodSummary(current: current, next: next)
                        trendChart(current: current, next: next, minute: minute)
                        feeTable(current: current, next: next)
                        if !feeInfo.notices.isEmpty {
                            notices
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("分时费率详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func periodSummary(current: FeePeriod?, next: FeePeriod?) -> some View {
        HStack(spacing: 12) {
            periodCard(title: "当前时段", period: current, color: .teal)
            periodCard(title: "下一时段", period: next, color: .indigo)
        }
    }

    private func periodCard(title: String, period: FeePeriod?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: title == "当前时段" ? "clock.fill" : "forward.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(period?.timePeriod ?? "暂无")
                .font(.headline)
            if let period, let total = period.total {
                Text("\(period.currency)\(total, specifier: "%.2f")\(period.unit.isEmpty ? "" : "/\(period.unit)")")
                    .font(.title3.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func trendChart(current: FeePeriod?, next: FeePeriod?, minute: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全天费用趋势")
                .font(.headline)

            Chart(feeInfo.periods) { period in
                if let start = period.startMinute, let end = period.endMinute, let total = period.total {
                    BarMark(
                        xStart: .value("开始", Double(start) / 60),
                        xEnd: .value("结束", Double(end) / 60),
                        y: .value("总费用", total)
                    )
                    .foregroundStyle(color(for: period, current: current, next: next))
                    .cornerRadius(4)
                }
            }
            .chartXScale(domain: 0...24)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, through: 24, by: 4).map(Double.init)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hour = value.as(Double.self) {
                            Text(String(format: "%02d:00", Int(hour)))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 230)

            HStack(spacing: 16) {
                legend("当前", color: .teal)
                legend("下一时段", color: .indigo)
                legend("其他时段", color: .secondary.opacity(0.28))
                Spacer()
                Text(String(format: "现在 %02d:%02d", minute / 60, minute % 60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func feeTable(current: FeePeriod?, next: FeePeriod?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("全部时段")
                .font(.headline)
                .padding(.bottom, 10)
            ForEach(feeInfo.periods) { period in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: period, current: current, next: next))
                        .frame(width: 4, height: 34)
                    Text(period.timePeriod)
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let total = period.total {
                            Text("\(period.currency)\(total, specifier: "%.2f")/\(period.unit)")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(period.componentFees.map { "\($0.name) \($0.fee)" }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                if period.id != feeInfo.periods.last?.id { Divider() }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("计费说明", systemImage: "info.circle.fill")
                .font(.headline)
            ForEach(Array(feeInfo.notices.enumerated()), id: \.offset) { _, notice in
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func color(for period: FeePeriod, current: FeePeriod?, next: FeePeriod?) -> Color {
        if period.id == current?.id { return .teal }
        if period.id == next?.id { return .indigo.opacity(0.72) }
        return .secondary.opacity(0.28)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
