#if DEBUG
import SwiftUI
import WidgetKit

/// Explicit, debug-only screenshot fixtures. The normal app path remains
/// unchanged and Release builds contain neither this root nor these data.
struct DesignPreviewMode {
    enum Screen: String {
        case vehicle, station, trips, tracks, charging, swap, settings, widgets, control
        case chargingRecords = "charging-records"
        case controlPanel = "control-panel"
    }
    let screen: Screen
    let dark: Bool
    let accessibility: Bool
    let controlAction: VehicleAction
    let expandMirrors: Bool

    static var current: DesignPreviewMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let value = args.first(where: { $0.hasPrefix("--design-preview=") }),
              let screen = Screen(rawValue: String(value.dropFirst("--design-preview=".count))) else { return nil }
        let actionArgument = args.first(where: { $0.hasPrefix("--design-control-action=") })
        let actionName = actionArgument.map { String($0.dropFirst("--design-control-action=".count)) }
        let controlAction = actionName.flatMap(VehicleAction.init(rawValue:)) ?? .unlockDoors
        return DesignPreviewMode(
            screen: screen,
            dark: args.contains("--design-dark"),
            accessibility: args.contains("--design-accessibility"),
            controlAction: controlAction,
            expandMirrors: args.contains("--design-expand-mirrors")
        )
    }
}

struct DesignPreviewRoot: View {
    let mode: DesignPreviewMode
    @StateObject private var model = VehicleViewModel.designPreview()
    @State private var settingsPresented = true
    private let persistence = PersistenceController(inMemory: true)

    var body: some View {
        Group {
            switch mode.screen {
            case .vehicle, .station: ContentView()
            case .trips: NavigationStack { VehicleTripsListView(trips: model.trips) }
            case .tracks:
                NavigationStack {
                    ScrollView {
                        VehicleDetailView(viewModel: model, openSettings: {}).trackCardDesignPreview
                            .padding(16)
                    }
                    .background(AppPalette.canvas)
                    .navigationTitle("位置轨迹")
                }
            case .charging: NavigationStack { ChargingCurveView(viewModel: model, session: model.chargingSessions.first) }
            case .chargingRecords: NavigationStack { ChargingRecordsListView(viewModel: model) }
            case .swap: NavigationStack { SwapEventDetailView(viewModel: model, initialEvent: model.swapEvents[0]) }
            case .settings: BackendSettingsView(isPresented: $settingsPresented, viewModel: model)
            case .control, .controlPanel: NavigationStack { VehicleDetailView(viewModel: model, openSettings: {}) }
            case .widgets:
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            Text("小号 · 车辆").font(.headline)
                            widget(.systemSmall, width: 158)
                            Text("中号 · 车辆与换电站").font(.headline)
                            widget(.systemMedium, width: 329)
                            Text("无配置状态").font(.headline)
                            VehicleWidgetView(entry: VehicleWidgetEntry(date: .now, state: .unconfigured), standalone: true, previewFamily: .systemSmall)
                                .frame(width: 158, height: 158)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        }.padding(20)
                    }.background(AppPalette.canvas).navigationTitle("小组件预览")
                }
            }
        }
        .environment(\.managedObjectContext, persistence.container.viewContext)
        .environment(\.colorScheme, mode.dark ? .dark : .light)
        .dynamicTypeSize(mode.accessibility ? .accessibility1 : .large)
        .overlay(alignment: .bottomLeading) {
            Text("设计预览 · 示例数据").font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(7).background(.thinMaterial, in: Capsule())
                .padding(.leading, 16).padding(.bottom, 8).allowsHitTesting(false)
        }
    }

    private func widget(_ family: WidgetFamily, width: CGFloat) -> some View {
        VehicleWidgetView(entry: VehicleWidgetEntry(date: .now, state: .loaded(DesignPreviewFixtures.widget)), standalone: true, previewFamily: family)
            .frame(width: width, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

enum DesignPreviewFixtures {
    static let dashboard = VehicleDashboard(
        vehicleID: "preview-vehicle", isConnected: true, stateCode: 2, mileage: 94973,
        isSwapping: false, stateOfCharge: 84, remainingRange: 398, remainingActualRange: 356,
        chargeStateCode: 0, chargingCurrent: nil, chargingPower: nil, chargingVoltage: nil,
        chargeLimitPercent: 100, batterySampledAt: .now, lockStatusCode: 1,
        location: VehicleCoordinate(latitude: 31.2304, longitude: 121.4737), locationSampledAt: .now,
        insideTemperature: 24.5, outsideTemperature: 21, updatedAt: .now
    )
    static let history: [VehicleSnapshot] = {
        let base = Date.now.addingTimeInterval(-75 * 60)
        let samples: [(Int, Double, Double)] = [
            (0, 0, 0), (2, 0.001, 0.002), (4, 0.002, 0.004), (6, 0.003, 0.006),
            (12, 0.00301, 0.00601), (22, 0.00302, 0.00602),
            (24, 0.004, 0.008), (26, 0.005, 0.010), (29, 0.006, 0.012)
        ]
        return samples.map { minute, latitude, longitude in
            VehicleSnapshot(vehicleID: "preview-vehicle", sampledAt: base.addingTimeInterval(Double(minute * 60)),
                            latitude: 31.23 + latitude, longitude: 121.47 + longitude)
        }
    }()
    static let trips: [VehicleTrip] = (0..<3).map { index in
        decode([
            "id": "preview-trip-\(index)", "started_at": "2026-10-\(index == 2 ? "11" : "12")T\(index == 1 ? "02" : "08"):30:00Z",
            "ended_at": "2026-10-\(index == 2 ? "11" : "12")T\(index == 1 ? "03" : "09"):08:00Z",
            "distance_kilometers": index == 0 ? 28.4 : 16.8, "duration_minutes": 38,
            "start_location": ["poi":"科技园区", "address":"示例起点 · 南门"],
            "end_location": ["poi":"滨海公园", "address":"示例终点 · 停车场"],
            "average_speed_kph": 44.8, "energy_consumed_kwh": 4.52,
            "average_energy_consumption_kwh_per_100km": 15.9, "is_combined": false
        ])
    }
    static let samples: [ChargingSample] = (0..<120).map { index in
        let date = Date(timeIntervalSince1970: 1_791_534_600 + Double(index) * 30)
        return decode([
            "vehicle_id":"preview-vehicle", "sampled_at":date.ISO8601Format(),
            "soc":30 + Double(index) * 0.4, "charge_state":1,
            "charging_current":index < 75 ? 150 : 90, "charging_voltage":380,
            "charging_power":index < 75 ? 57000 : 34200
        ])
    }
    static let sessions: [ChargingSession] = [
        decode([
            "id":"preview-session-1", "vehicle_id":"preview-vehicle",
            "started_at":"2026-11-05T04:19:00Z", "ended_at":"2026-11-05T05:35:00Z",
            "duration_seconds":4560, "start_soc":43, "end_soc":96, "peak_power_watts":58000,
            "energy_kwh":36.67, "sample_count":454
        ]),
        decode([
            "id":"preview-session-2", "vehicle_id":"preview-vehicle",
            "started_at":"2026-11-04T05:52:00Z", "ended_at":"2026-11-04T06:01:00Z",
            "duration_seconds":540, "start_soc":63, "end_soc":76, "peak_power_watts":72500,
            "energy_kwh":8.42, "sample_count":50
        ]),
        decode([
            "id":"preview-session-3", "vehicle_id":"preview-vehicle",
            "started_at":"2026-11-02T03:49:00Z", "ended_at":"2026-11-02T04:02:00Z",
            "duration_seconds":780, "start_soc":6, "end_soc":28, "peak_power_watts":79000,
            "sample_count":77
        ])
    ]
    static let swaps: [SwapEvent] = [decode([
        "id":"preview-swap", "status":"confirmed", "occurred_at":"2026-10-12T07:25:00Z",
        "station_key":"PS-NIO-preview", "station_name":"示例换电站 · 科技园区",
        "station_address":"示例地址 · 园区停车场", "order_no":"PREVIEW-ORDER-001",
        "order_status_name":"已完成", "price_amount":65.2, "price_currency":"CNY",
        "exact_energy_kwh":42.5, "energy_source":"order_import", "battery_source":"order_import",
        "confidence":"exact", "outgoing_battery_id":"PREVIEW-OLD-BATTERY",
        "outgoing_production_date":"2024-10-01", "outgoing_capacity_kwh":75, "outgoing_soc_percent":21,
        "incoming_battery_id":"PREVIEW-NEW-BATTERY", "incoming_production_date":"2025-09-27",
        "incoming_capacity_kwh":75, "incoming_soc_percent":98
    ])]
    static let batteries: [BatteryModel] = (0..<6).map { index in
        BatteryModel(id:"preview-\(index)", chargingProgress:index < 3 ? 100 : 78,
                     batteryType:index < 4 ? "75 kWh" : "100 kWh", chargingRemainingMinutes:index < 3 ? nil : 12,
                     isOccupied:index == 5, manufactureDate:"2025/09/27", slotID:index + 1)
    }
    static let fees = FeeInfo(currentFees: [
        FeeItem(name:"电费", fee:"0.65", unit:"度", currency:"¥"),
        FeeItem(name:"服务费", fee:"0.82", unit:"度", currency:"¥"),
        FeeItem(name:"总费用", fee:"1.47", unit:"度", currency:"¥")
    ])
    static let widget = WidgetVehicleSnapshot(
        isConnected:true, stateCode:2, isSwapping:false, stateOfCharge:84,
        remainingRange:398, remainingActualRange:356, chargeStateCode:0, outsideTemperature:21,
        updatedAt:.now, station:WidgetStationSnapshot(
            name:"示例换电站 · 科技园区", price:"¥1.47/度", available75Count:3,
            batteries:(0..<3).map { WidgetStationBattery(id:"preview-\($0)", slotID:$0 + 1, stateOfCharge:100, productionDate:"2025-09-27") }
        ), hasStationSelection:true
    )

    private static func decode<T: Decodable>(_ object: [String: Any]) -> T {
        // Fail loudly for broken checked-in fixtures; no external data enters
        // this helper, and Release builds exclude it entirely.
        try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
#endif
