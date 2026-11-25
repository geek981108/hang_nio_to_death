import Charts
import MapKit
import SwiftUI

struct VehicleTripsListView: View {
    let trips: [VehicleTrip]
    var viewModel: VehicleViewModel? = nil

    private let groups: [(day: Date, trips: [VehicleTrip])]

    init(trips: [VehicleTrip], viewModel: VehicleViewModel? = nil) {
        self.trips = trips
        self.viewModel = viewModel
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
                        if let viewModel {
                            NavigationLink {
                                VehicleTripDetailView(trip: trip, viewModel: viewModel)
                            } label: {
                                VehicleTripCard(trip: trip, showsDate: false, showsDisclosure: true)
                            }
                            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.985))
                        } else {
                            VehicleTripCard(trip: trip, showsDate: false)
                        }
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
    var showsDisclosure = false

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
                HStack(spacing: 6) {
                    Text(distanceLabel(trip.distanceKilometers))
                        .font(.system(size: 27, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(AppPalette.blue)
                    if showsDisclosure {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
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
        .nioCard(cornerRadius: 24, padding: 20)
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

struct VehicleTripDetailView: View {
    let trip: VehicleTrip
    @ObservedObject var viewModel: VehicleViewModel

    @State private var track: VehicleTripTrack?
    @State private var isLoadingTrack = false
    @State private var trackNotFound = false
    @State private var trackErrorMessage: String?
    @State private var cameraPosition: MapCameraPosition = .automatic

    private let metricsColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                mapCard
                routeCard
                metricsCard
                if speedSamples.count >= 3 {
                    speedChartCard
                }
                if hasDrivingBehaviorData {
                    drivingBehaviorCard
                }
            }
            .padding(16)
        }
        .background(AppPalette.canvas)
        .navigationTitle(VehicleDateParser.displayDate(trip.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: trip.id) {
            await loadTrack()
        }
    }

    private var trackPoints: [VehicleTripTrackPoint] {
        track?.validPoints ?? []
    }

    private var trackCoordinates: [CLLocationCoordinate2D] {
        trackPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var startCoordinate: CLLocationCoordinate2D? {
        if let first = trackCoordinates.first { return first }
        guard let lat = trip.startLocation.latitude, let lon = trip.startLocation.longitude else { return nil }
        let coord = VehicleCoordinate(latitude: lat, longitude: lon)
        return coord.isValid ? CLLocationCoordinate2D(latitude: lat, longitude: lon) : nil
    }

    private var endCoordinate: CLLocationCoordinate2D? {
        if let last = trackCoordinates.last { return last }
        guard let lat = trip.endLocation.latitude, let lon = trip.endLocation.longitude else { return nil }
        let coord = VehicleCoordinate(latitude: lat, longitude: lon)
        return coord.isValid ? CLLocationCoordinate2D(latitude: lat, longitude: lon) : nil
    }

    private var speedSamples: [(date: Date, speed: Double)] {
        trackPoints.compactMap { point in
            guard let speed = point.speedKPH, speed.isFinite, speed >= 0 else { return nil }
            return (point.sampledAt, speed)
        }
    }

    private var assistedDrivingPercent: Int? {
        let labeled = trackPoints.compactMap(\.npStatus)
        guard !labeled.isEmpty else { return nil }
        let activeCount = labeled.filter { $0 > 0 }.count
        guard activeCount > 0 else { return nil }
        return Int((Double(activeCount) / Double(labeled.count) * 100).rounded())
    }

    private var hasDrivingBehaviorData: Bool {
        trip.rapidAccelerationCount != nil
            || trip.rapidDecelerationCount != nil
            || trip.rapidSwerveCount != nil
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !trackCoordinates.isEmpty || startCoordinate != nil || endCoordinate != nil {
                Map(position: $cameraPosition) {
                    if trackCoordinates.count >= 2 {
                        MapPolyline(coordinates: trackCoordinates)
                            .stroke(
                                AppPalette.blue,
                                style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                            )
                    }
                    if let start = startCoordinate {
                        Annotation("起点", coordinate: start) {
                            routeMarker(color: AppPalette.green, icon: "play.fill")
                        }
                    }
                    if let end = endCoordinate {
                        Annotation("终点", coordinate: end) {
                            routeMarker(color: AppPalette.blue, icon: "flag.fill")
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .frame(height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topLeading) {
                    mapBadge
                        .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            cameraPosition = fittedCameraPosition
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.blue)
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                    }
                    .accessibilityLabel("缩放以显示完整路线")
                    .padding(12)
                }
                .onAppear { cameraPosition = fittedCameraPosition }
                .onChange(of: trackPoints.count) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        cameraPosition = fittedCameraPosition
                    }
                }
            } else if isLoadingTrack {
                HStack {
                    Spacer()
                    ProgressView("正在加载官方行程轨迹…")
                    Spacer()
                }
                .frame(height: 180)
            } else {
                ContentUnavailableView(
                    "暂无地图轨迹",
                    systemImage: "map",
                    description: Text(trackNotFound ? "该行程尚未同步 GPS 轨迹点，且缺少起终点坐标。" : "暂未获取到该行程的定位数据。")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            }

            if let error = trackErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试") {
                        Task { await loadTrack() }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .nioCard(cornerRadius: 24, padding: 14)
    }

    @ViewBuilder
    private var mapBadge: some View {
        if isLoadingTrack {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("同步轨迹中…")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
        } else if !trackPoints.isEmpty {
            HStack(spacing: 6) {
                Circle().fill(AppPalette.green).frame(width: 7, height: 7)
                Text("官方轨迹 · \(trackPoints.count) 点")
                if let npPercent = assistedDrivingPercent {
                    Text("· 领航 \(npPercent)%")
                        .foregroundStyle(AppPalette.blue)
                }
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
        } else if trackNotFound {
            Label("仅起终点定位", systemImage: "mappin.and.ellipse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(trip.isCombined ? "合并行程" : "行程路线", systemImage: "road.lanes")
                    .font(.headline)
                Spacer()
                Text(formatDistance(trip.distanceKilometers))
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppPalette.blue)
            }

            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Circle().stroke(AppPalette.green, lineWidth: 2.5).frame(width: 10, height: 10)
                    Rectangle().fill(AppPalette.blue.opacity(0.22)).frame(width: 1.5)
                    RoundedRectangle(cornerRadius: 2.5).fill(AppPalette.blue).frame(width: 10, height: 10)
                }
                .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 16) {
                    locationRow(
                        title: trip.startLocation.hasDisplayName ? trip.startLocation.displayName : "起点待更新",
                        detail: subtitleAddress(for: trip.startLocation),
                        time: trip.startedAt
                    )
                    locationRow(
                        title: trip.endLocation.hasDisplayName ? trip.endLocation.displayName : "终点待更新",
                        detail: subtitleAddress(for: trip.endLocation),
                        time: trip.endedAt
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("行程数据", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)

            LazyVGrid(columns: metricsColumns, spacing: 12) {
                metricTile("行驶时长", value: formatDuration(trip.durationMinutes), icon: "clock", tint: AppPalette.blue)
                metricTile(
                    "行程耗电",
                    value: trip.energyConsumedKWh.map { String(format: "%.2f kWh", $0) } ?? "--",
                    icon: "bolt.fill",
                    tint: AppPalette.green
                )
                metricTile(
                    "百公里电耗",
                    value: trip.averageEnergyConsumptionKWhPer100Km.map { String(format: "%.1f kWh", $0) } ?? "--",
                    icon: "leaf.fill",
                    tint: AppPalette.green
                )
                metricTile(
                    "平均速度",
                    value: trip.averageSpeedKPH.map { String(format: "%.0f km/h", $0) } ?? "--",
                    icon: "speedometer",
                    tint: AppPalette.violet
                )
                if let maxSpeed = trip.maximumSpeedKPH {
                    metricTile(
                        "最高速度",
                        value: String(format: "%.0f km/h", maxSpeed),
                        icon: "flame.fill",
                        tint: AppPalette.amber
                    )
                }
                if let odometer = trip.odometerKilometers {
                    metricTile(
                        "到达总里程",
                        value: String(format: "%.0f km", odometer),
                        icon: "car.side",
                        tint: AppPalette.graphite
                    )
                }
            }
        }
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private var speedChartCard: some View {
        let maxSpeed = speedSamples.map(\.speed).max() ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("速度曲线", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text(String(format: "峰值 %.0f km/h", maxSpeed))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppPalette.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppPalette.blue.opacity(0.11), in: Capsule())
            }

            Chart(speedSamples, id: \.date) { sample in
                AreaMark(
                    x: .value("时间", sample.date),
                    y: .value("速度", sample.speed)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppPalette.blue.opacity(0.32), AppPalette.blue.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("时间", sample.date),
                    y: .value("速度", sample.speed)
                )
                .foregroundStyle(AppPalette.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartYAxisLabel("km/h")
            .frame(height: 156)
        }
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private var drivingBehaviorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("驾驶平顺度", systemImage: "steeringwheel")
                .font(.headline)
            HStack(spacing: 10) {
                behaviorChip("急加速", count: trip.rapidAccelerationCount, tint: AppPalette.amber)
                behaviorChip("急减速", count: trip.rapidDecelerationCount, tint: .red)
                behaviorChip("急转弯", count: trip.rapidSwerveCount, tint: AppPalette.violet)
            }
        }
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private func behaviorChip(_ title: String, count: Int?, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(count.map { "\($0)" } ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle((count ?? 0) > 0 ? tint : .primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metricTile(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func locationRow(title: String, detail: String?, time: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(time.formatted(.dateTime.hour().minute()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func subtitleAddress(for location: VehicleTripLocation) -> String? {
        let primary = location.displayName
        let candidate = [location.address, location.district, location.city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != primary }
        return candidate
    }

    private func routeMarker(color: Color, icon: String) -> some View {
        Image(systemName: icon)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(7)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 3)
    }

    private var fittedCameraPosition: MapCameraPosition {
        var coords = trackCoordinates
        if coords.isEmpty {
            if let start = startCoordinate { coords.append(start) }
            if let end = endCoordinate { coords.append(end) }
        }
        guard let first = coords.first else {
            return .automatic
        }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coord in coords.dropFirst() {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(maxLat - minLat, 0.008) * 1.4,
                longitudeDelta: max(maxLon - minLon, 0.008) * 1.4
            )
        ))
    }

    private func loadTrack() async {
        guard !isLoadingTrack else { return }
        isLoadingTrack = true
        trackNotFound = false
        trackErrorMessage = nil
        defer { isLoadingTrack = false }
        do {
            track = try await viewModel.fetchVehicleTripTrack(journeyID: trip.id)
        } catch let error as BackendClientError {
            if case .serverFailure(let code, _, _) = error, code == "trip_track_not_found" {
                trackNotFound = true
            } else {
                trackErrorMessage = error.errorDescription
            }
        } catch {
            if !error.isTaskCancellation {
                trackErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func formatDistance(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.1f km", value) }
        if value >= 0.1 { return String(format: "%.2f km", value) }
        return "\(Int((value * 1000).rounded())) m"
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }
}
