import MapKit
import SwiftUI

struct VehiclePathMap: View {
    let currentCoordinate: VehicleCoordinate?
    let key: String
    let segments: [VehiclePathSegment]
    let visibleSegmentIDs: Set<String>
    let samplePoint: VehicleSnapshot?
    @State private var position: MapCameraPosition = .automatic

    init(
        segments: [VehiclePathSegment],
        visibleSegmentIDs: Set<String>,
        samplePoint: VehicleSnapshot? = nil,
        currentCoordinate: VehicleCoordinate?,
        key: String
    ) {
        self.segments = segments
        self.visibleSegmentIDs = visibleSegmentIDs
        self.samplePoint = samplePoint
        self.currentCoordinate = currentCoordinate
        self.key = key
    }

    static func color(for index: Int) -> Color {
        let colors: [Color] = [AppPalette.blue, AppPalette.amber, AppPalette.violet, AppPalette.green, .pink, .teal]
        return colors[index % colors.count]
    }

    private var visibleSegments: [(offset: Int, element: VehiclePathSegment)] {
        Array(segments.enumerated()).filter { visibleSegmentIDs.contains($0.element.id) }
    }

    private var coordinates: [CLLocationCoordinate2D] {
        visibleSegments.flatMap { entry in
            entry.element.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    private var mapPosition: MapCameraPosition {
        var allCoordinates = coordinates
        if let samplePoint {
            allCoordinates.append(CLLocationCoordinate2D(latitude: samplePoint.latitude, longitude: samplePoint.longitude))
        }
        if let currentCoordinate {
            allCoordinates.append(CLLocationCoordinate2D(
                latitude: currentCoordinate.latitude,
                longitude: currentCoordinate.longitude
            ))
        }
        guard let first = allCoordinates.first else {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            ))
        }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for coordinate in allCoordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(maxLatitude - minLatitude, 0.008) * 1.35,
                longitudeDelta: max(maxLongitude - minLongitude, 0.008) * 1.35
            )
        ))
    }

    private var recenteredPosition: MapCameraPosition {
        guard let currentCoordinate else { return mapPosition }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: currentCoordinate.latitude,
                longitude: currentCoordinate.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        ))
    }

    var body: some View {
        Map(position: $position) {
            ForEach(visibleSegments, id: \.element.id) { entry in
                let segment = entry.element
                let color = Self.color(for: entry.offset)
                let segmentCoordinates = segment.points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                if segmentCoordinates.count >= 2 {
                    MapPolyline(coordinates: segmentCoordinates)
                        .stroke(color, lineWidth: 4)
                }
                if let start = segmentCoordinates.first {
                    Annotation("第\(entry.offset + 1)段起点", coordinate: start) {
                        mapDot(color: color, icon: "play.fill")
                    }
                }
                if let end = segmentCoordinates.last {
                    Annotation("第\(entry.offset + 1)段终点", coordinate: end) {
                        mapDot(color: color, icon: "flag.fill")
                    }
                }
            }
            if let samplePoint {
                Annotation(
                    "采样点",
                    coordinate: CLLocationCoordinate2D(latitude: samplePoint.latitude, longitude: samplePoint.longitude)
                ) {
                    mapDot(color: AppPalette.violet, icon: "mappin")
                }
            }
            if let currentCoordinate {
                Annotation(
                    "当前位置",
                    coordinate: CLLocationCoordinate2D(
                        latitude: currentCoordinate.latitude,
                        longitude: currentCoordinate.longitude
                    )
                ) {
                    mapDot(color: AppPalette.violet, icon: "car.fill")
                }
            }
        }
        .id(key)
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .bottomTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    position = recenteredPosition
                }
            } label: {
                Image(systemName: "location.fill.viewfinder")
                    .font(.headline)
                    .foregroundStyle(AppPalette.blue)
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            }
            .accessibilityLabel(currentCoordinate == nil ? "显示完整轨迹" : "归中车辆位置")
            .padding(12)
        }
        .onAppear { position = mapPosition }
        .onChange(of: key) { _, _ in position = mapPosition }
        .onChange(of: visibleSegmentIDs) { _, _ in position = mapPosition }
    }

    private func mapDot(color: Color, icon: String) -> some View {
        Image(systemName: icon)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(7)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 3)
    }
}
