import MapKit
import SwiftUI

struct TVTripsView: View {
    @ObservedObject var viewModel: TVGarageViewModel
    @State private var showingCurrentVehicleLocation = false
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var selectedTrip: VehicleTrip? {
        viewModel.trips.first { $0.id == viewModel.selectedTripID }
    }

    var body: some View {
        ZStack {
            TVPalette.canvas.ignoresSafeArea()

            HStack(spacing: 36) {
                tripListColumn
                    .frame(width: 590)

                mapDetailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 64)
            .padding(.top, 28)
            .padding(.bottom, 48)
        }
        .onChange(of: viewModel.selectedTripTrack?.journeyID) { _, _ in
            updateMapCamera()
        }
        .onChange(of: showingCurrentVehicleLocation) { _, _ in
            updateMapCamera()
        }
        .onAppear {
            updateMapCamera()
        }
    }

    // MARK: - Left Trip Selector Column

    private var tripListColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("行程与定位")
                .font(.title2.weight(.bold))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    if let location = viewModel.dashboard?.location, location.isValid {
                        Button {
                            showingCurrentVehicleLocation = true
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "car.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(TVPalette.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("车辆当前实时位置")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(
                            TVDarkFocusCardButtonStyle(
                                accentColor: TVPalette.blue,
                                cornerRadius: 22,
                                isSelected: showingCurrentVehicleLocation
                            )
                        )
                    }

                    ForEach(viewModel.trips) { trip in
                        let isSelected = !showingCurrentVehicleLocation && trip.id == viewModel.selectedTripID
                        Button {
                            showingCurrentVehicleLocation = false
                            Task { await viewModel.selectTrip(trip.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(TVFormatters.dateTime(trip.startedAt))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(TVFormatters.decimalKm(trip.distanceKilometers))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(TVPalette.blue)
                                }

                                Text("\(trip.startLocation.displayName) → \(trip.endLocation.displayName)")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)

                                HStack(spacing: 14) {
                                    Label(TVFormatters.durationMinutes(trip.durationMinutes), systemImage: "clock")
                                    if let avg = trip.averageEnergyConsumptionKWhPer100Km {
                                        Label(String(format: "%.1f kWh/100km", avg), systemImage: "bolt.fill")
                                            .foregroundStyle(TVPalette.green)
                                    }
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(
                            TVDarkFocusCardButtonStyle(
                                accentColor: TVPalette.blue,
                                cornerRadius: 22,
                                isSelected: isSelected
                            )
                        )
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
        }
    }

    // MARK: - Right Big-Screen MapKit Column

    private var mapDetailColumn: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition, interactionModes: []) {
                if showingCurrentVehicleLocation,
                   let loc = viewModel.dashboard?.location,
                   loc.isValid {
                    Annotation(
                        viewModel.vehicleTitle,
                        coordinate: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                    ) {
                        ZStack {
                            Circle()
                                .fill(TVPalette.blue.opacity(0.28))
                                .frame(width: 58, height: 58)
                            Image(systemName: "car.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(TVPalette.blue, in: Circle())
                        }
                    }
                } else if let track = viewModel.selectedTripTrack, !track.validPoints.isEmpty {
                    let coords = track.validPoints.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    MapPolyline(coordinates: coords)
                        .stroke(TVPalette.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

                    if let start = coords.first, let end = coords.last,
                       Self.areCoordinatesClose(start, end) {
                        Annotation("起终点", coordinate: end) {
                            Circle()
                                .fill(TVPalette.green)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    } else {
                        if let start = coords.first {
                            Annotation("起点", coordinate: start) {
                                Circle()
                                    .fill(TVPalette.green)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(.white, lineWidth: 3))
                            }
                        }
                        if let end = coords.last {
                            Annotation("终点", coordinate: end) {
                                Circle()
                                    .fill(TVPalette.blue)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(.white, lineWidth: 3))
                            }
                        }
                    }
                } else if let trip = selectedTrip {
                    let startCoord: CLLocationCoordinate2D? = {
                        guard let lat = trip.startLocation.latitude, let lon = trip.startLocation.longitude,
                              VehicleCoordinate(latitude: lat, longitude: lon).isValid else { return nil }
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }()
                    let endCoord: CLLocationCoordinate2D? = {
                        guard let lat = trip.endLocation.latitude, let lon = trip.endLocation.longitude,
                              VehicleCoordinate(latitude: lat, longitude: lon).isValid else { return nil }
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }()

                    if let startCoord, let endCoord, Self.areCoordinatesClose(startCoord, endCoord) {
                        Annotation("起终点", coordinate: endCoord) {
                            Circle()
                                .fill(TVPalette.green)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    } else {
                        if let startCoord {
                            Annotation("起点", coordinate: startCoord) {
                                Circle()
                                    .fill(TVPalette.green)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            }
                        }
                        if let endCoord {
                            Annotation("终点", coordinate: endCoord) {
                                Circle()
                                    .fill(TVPalette.blue)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(TVPalette.hairline, lineWidth: 1.5)
            }

            if viewModel.isLoadingTripTrack && !showingCurrentVehicleLocation {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载行程 GPS 轨迹…")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().strokeBorder(TVPalette.hairline, lineWidth: 1))
                .padding(.bottom, 128)
            }

            if !showingCurrentVehicleLocation, let trip = selectedTrip {
                tripTelemetryOverlay(trip)
                    .padding(24)
            }
        }
    }

    private func tripTelemetryOverlay(_ trip: VehicleTrip) -> some View {
        HStack(spacing: 28) {
            overlayStat(title: "里程", value: TVFormatters.decimalKm(trip.distanceKilometers), tint: TVPalette.blue)
            overlayStat(title: "时长", value: TVFormatters.durationMinutes(trip.durationMinutes), tint: .white)
            if let speed = trip.averageSpeedKPH {
                overlayStat(title: "均速", value: String(format: "%.0f km/h", speed), tint: TVPalette.cyan)
            }
            if let energy = trip.energyConsumedKWh {
                overlayStat(title: "耗电", value: String(format: "%.1f kWh", energy), tint: TVPalette.amber)
            }
            if let avg = trip.averageEnergyConsumptionKWhPer100Km {
                overlayStat(
                    title: "平均能耗",
                    value: String(format: "%.1f", avg),
                    unit: "kWh/100km",
                    tint: TVPalette.green
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            Color(red: 0.05, green: 0.07, blue: 0.11).opacity(0.86),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.2)
        }
    }

    private func overlayStat(title: String, value: String, unit: String? = nil, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let unit {
                    Text(unit)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private static func areCoordinatesClose(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locA.distance(from: locB) < 50
    }

    private func updateMapCamera() {
        if showingCurrentVehicleLocation,
           let loc = viewModel.dashboard?.location,
           loc.isValid {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
                )
            )
            return
        }

        if let track = viewModel.selectedTripTrack {
            let valid = track.validPoints
            if !valid.isEmpty {
                let lats = valid.map(\.latitude)
                let lons = valid.map(\.longitude)
                if let minLat = lats.min(), let maxLat = lats.max(),
                   let minLon = lons.min(), let maxLon = lons.max() {
                    let center = CLLocationCoordinate2D(
                        latitude: (minLat + maxLat) / 2.0,
                        longitude: (minLon + maxLon) / 2.0
                    )
                    let span = MKCoordinateSpan(
                        latitudeDelta: max(0.012, (maxLat - minLat) * 1.45),
                        longitudeDelta: max(0.012, (maxLon - minLon) * 1.45)
                    )
                    cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
                    return
                }
            }
        }

        if let trip = selectedTrip {
            var coords: [CLLocationCoordinate2D] = []
            if let lat = trip.startLocation.latitude, let lon = trip.startLocation.longitude,
               VehicleCoordinate(latitude: lat, longitude: lon).isValid {
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            if let lat = trip.endLocation.latitude, let lon = trip.endLocation.longitude,
               VehicleCoordinate(latitude: lat, longitude: lon).isValid {
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            if !coords.isEmpty {
                let lats = coords.map(\.latitude)
                let lons = coords.map(\.longitude)
                if let minLat = lats.min(), let maxLat = lats.max(),
                   let minLon = lons.min(), let maxLon = lons.max() {
                    let center = CLLocationCoordinate2D(
                        latitude: (minLat + maxLat) / 2.0,
                        longitude: (minLon + maxLon) / 2.0
                    )
                    let span = MKCoordinateSpan(
                        latitudeDelta: max(0.012, (maxLat - minLat) * 1.6),
                        longitudeDelta: max(0.012, (maxLon - minLon) * 1.6)
                    )
                    cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
                    return
                }
            }
        }
        cameraPosition = .automatic
    }
}
