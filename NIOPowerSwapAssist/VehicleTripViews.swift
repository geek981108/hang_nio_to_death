import SwiftUI

struct VehicleTripsListView: View {
    let trips: [VehicleTrip]

    private let groups: [(day: Date, trips: [VehicleTrip])]

    init(trips: [VehicleTrip]) {
        self.trips = trips
        let calendar = Calendar.current
        groups = Dictionary(grouping: trips) { calendar.startOfDay(for: $0.startedAt) }
            .map { (day: $0.key, trips: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.day) { group in
                    Text("\(VehicleDateParser.displayDate(group.day)) · \(group.day.formatted(.dateTime.weekday()))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 8)
                    ForEach(group.trips) { trip in
                        VehicleTripCard(trip: trip, showsDate: false)
                    }
                }
            }.padding(16)
        }
        .background(AppPalette.canvas)
        .navigationTitle("全部行程")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct VehicleTripCard: View {
    let trip: VehicleTrip
    var showsDate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showsDate
                         ? VehicleDateParser.displayDate(trip.startedAt)
                         : "\(formatTime(trip.startedAt)) 出发")
                        .font(.subheadline.weight(.medium))
                    if trip.isCombined {
                        Label("合并行程", systemImage: "link").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Label(durationLabel(trip.durationMinutes), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(distanceLabel(trip.distanceKilometers))
                    .font(.system(size: 27, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppPalette.blue)
            }
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Circle().stroke(AppPalette.green, lineWidth: 2).frame(width: 8, height: 8)
                    Rectangle().fill(AppPalette.blue.opacity(0.18)).frame(width: 1)
                    RoundedRectangle(cornerRadius: 2).fill(AppPalette.blue).frame(width: 8, height: 8)
                }
                .padding(.vertical, 7)
                VStack(spacing: 16) {
                    routeStop(
                        trip.startLocation.hasDisplayName ? trip.startLocation.displayName : "起点待更新",
                        date: trip.startedAt
                    )
                    routeStop(
                        trip.endLocation.hasDisplayName ? trip.endLocation.displayName : "终点待更新",
                        date: trip.endLocation.hasDisplayName ? trip.endedAt : nil
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { metrics }
                VStack(alignment: .leading, spacing: 10) { metrics }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private var metrics: some View {
        if trip.isCombined { Label(durationLabel(trip.durationMinutes), systemImage: "clock") }
        if let speed = trip.averageSpeedKPH {
            Label(String(format: "均速 %.0f km/h", speed), systemImage: "speedometer")
        }
        if let energy = trip.energyConsumedKWh, energy.isFinite {
            Label(String(format: "耗电 %.2f kWh", energy), systemImage: "bolt")
        }
        if let average = trip.averageEnergyConsumptionKWhPer100Km, average.isFinite {
            Label(String(format: "%.1f kWh/100km", average), systemImage: "leaf")
        }
        if trip.energyConsumedKWh == nil && trip.averageEnergyConsumptionKWhPer100Km == nil {
            Text("能耗暂无数据").foregroundStyle(.tertiary)
        }
    }

    private func routeStop(_ name: String, date: Date?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if let date {
                Text(Calendar.current.isDate(trip.startedAt, inSameDayAs: date)
                     ? formatTime(date) : date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }



    private func formatTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", values.hour ?? 0, values.minute ?? 0)
    }

    private func distanceLabel(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.1f km", value) }
        if value >= 0.1 { return String(format: "%.2f km", value) }
        return "\(Int((value * 1000).rounded())) m"
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }


}
