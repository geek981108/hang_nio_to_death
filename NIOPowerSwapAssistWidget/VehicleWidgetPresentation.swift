import AppIntents
import Foundation
import SwiftUI
import WidgetKit

enum NIOWidgetKind {
  static let vehicle = "NIOVehicleWidget"
}

struct RefreshVehicleWidgetIntent: AppIntent {
  static var title: LocalizedStringResource = "刷新车辆状态"
  static var description = IntentDescription("立即重新获取车辆和换电站数据。")
  static var openAppWhenRun = false
  static var isDiscoverable = false

  func perform() async throws -> some IntentResult {
    WidgetCenter.shared.reloadTimelines(ofKind: NIOWidgetKind.vehicle)
    return .result()
  }
}

struct WidgetVehicleSnapshot: Equatable, Sendable {
  let isConnected: Bool
  let stateCode: Int?
  let isSwapping: Bool
  let stateOfCharge: Double?
  let remainingRange: Double?
  let remainingActualRange: Double?
  let chargeStateCode: Int?
  let outsideTemperature: Double?
  let updatedAt: Date
  let station: WidgetStationSnapshot?
  let hasStationSelection: Bool

  var prefersFrequentRefresh: Bool {
    isSwapping || chargeStateCode == 1 || stateCode == 1 || stateCode == 3 || stateCode == 4
  }

  var preferredRefreshInterval: TimeInterval {
    prefersFrequentRefresh ? 5 * 60 : 15 * 60
  }

  var statusText: String {
    if isSwapping { return "正在换电" }
    if chargeStateCode == 1 || stateCode == 3 { return "正在充电" }
    switch stateCode {
    case 1: return "行驶中"
    case 2: return "已驻车"
    case 4: return "正在换电"
    default: return isConnected ? "车辆在线" : "车辆离线"
    }
  }

  var statusIcon: String {
    if isSwapping { return "bolt.circle.fill" }
    if chargeStateCode == 1 || stateCode == 3 { return "bolt.fill" }
    if stateCode == 1 { return "car.side.fill" }
    return isConnected ? "antenna.radiowaves.left.and.right" : "wifi.slash"
  }

  var statusColor: Color {
    if isSwapping { return .orange }
    if chargeStateCode == 1 || stateCode == 3 { return .green }
    return isConnected ? .teal : .secondary
  }
}

struct WidgetStationSnapshot: Equatable, Sendable {
  let name: String
  let price: String?
  let available75Count: Int
  let batteries: [WidgetStationBattery]
}

struct WidgetStationBattery: Equatable, Sendable, Identifiable {
  let id: String
  let slotID: Int?
  let stateOfCharge: Double?
  let productionDate: String?
}

enum WidgetEntryState: Equatable {
  case loaded(WidgetVehicleSnapshot)
  case unconfigured
  case failed(String)
}

struct VehicleWidgetEntry: TimelineEntry {
  let date: Date
  let state: WidgetEntryState
}

private enum NIOWidgetPalette {
  static let mist = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
      : UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
  })
  static let ink = Color.primary
  static let mutedInk = Color.secondary
  static let nioBlue = Color(red: 0.31, green: 0.48, blue: 0.70)
  static let green = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.52, green: 0.79, blue: 0.62, alpha: 1)
      : UIColor(red: 0.19, green: 0.48, blue: 0.34, alpha: 1)
  })
  static let amber = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.91, green: 0.69, blue: 0.41, alpha: 1)
      : UIColor(red: 0.65, green: 0.38, blue: 0.17, alpha: 1)
  })
  static let panel = Color.primary.opacity(0.045)
  static let hairline = Color.primary.opacity(0.10)
}

struct VehicleWidgetView: View {
  @Environment(\.widgetFamily) private var actualFamily
  let entry: VehicleWidgetEntry
  var standalone = false
  var previewFamily: WidgetFamily?

  private var family: WidgetFamily { previewFamily ?? actualFamily }

  var body: some View {
    Group {
      switch entry.state {
      case .loaded(let snapshot):
        loadedView(snapshot)
      case .unconfigured:
        messageView(
          icon: "server.rack",
          title: "尚未配置",
          message: "打开 NIO PS 配置车辆后端"
        )
      case .failed(let message):
        messageView(
          icon: "exclamationmark.arrow.triangle.2.circlepath",
          title: "暂时无法更新",
          message: message
        )
      }
    }
    .modifier(WidgetBackgroundModifier(standalone: standalone))
    .foregroundStyle(NIOWidgetPalette.ink)
    .widgetURL(URL(string: "niopowerswapassist://vehicle"))
  }

  @ViewBuilder
  private func loadedView(_ snapshot: WidgetVehicleSnapshot) -> some View {
    if family == .systemSmall {
      VStack(alignment: .leading, spacing: 4) {
        brandHeader(snapshot)
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(formatNumber(snapshot.remainingActualRange ?? snapshot.remainingRange))
            .font(.system(size: 42, weight: .medium, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)
          Text("km")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(NIOWidgetPalette.mutedInk)
        }
        HStack(spacing: 5) {
          Label(formatPercent(snapshot.stateOfCharge), systemImage: "battery.75percent")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(NIOWidgetPalette.green)
          Spacer(minLength: 0)
          if let temperature = snapshot.outsideTemperature {
            Text(formatTemperature(temperature))
              .font(.system(size: 11, weight: .medium).monospacedDigit())
              .foregroundStyle(NIOWidgetPalette.mutedInk)
          }
        }
        batteryProgress(snapshot.stateOfCharge)
        Spacer(minLength: 0)
        HStack(spacing: 4) {
          Text(snapshot.statusText).lineLimit(1)
          Spacer(minLength: 3)
          Text("更新")
          Text(snapshot.updatedAt, style: .time).monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
      }
    } else {
      HStack(alignment: .top, spacing: 14) {
        vehicleStatus(snapshot)
          .frame(width: 96, alignment: .leading)
          .frame(maxHeight: .infinity, alignment: .topLeading)
        Rectangle().fill(NIOWidgetPalette.hairline).frame(width: 1)
        Link(destination: URL(string: "niopowerswapassist://station")!) {
          stationView(snapshot)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.buttonStyle(.plain)
      }
    }
  }

  private func brandHeader(_ snapshot: WidgetVehicleSnapshot) -> some View {
    HStack(spacing: 6) {
      Text("NIO")
        .font(.system(size: 11, weight: .bold))
        .tracking(1.8)
      Spacer(minLength: 4)
      Button(intent: RefreshVehicleWidgetIntent()) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(NIOWidgetPalette.nioBlue)
          .frame(width: 25, height: 25)
          .background(NIOWidgetPalette.panel, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("立即刷新小组件")
    }
  }

  private func vehicleStatus(_ snapshot: WidgetVehicleSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      brandHeader(snapshot)
      Spacer(minLength: 0)
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(formatNumber(snapshot.remainingActualRange ?? snapshot.remainingRange))
          .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
          .lineLimit(1).minimumScaleFactor(0.7)
        Text("km").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Label(formatPercent(snapshot.stateOfCharge), systemImage: "battery.75percent")
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(NIOWidgetPalette.green)
      batteryProgress(snapshot.stateOfCharge)
      Spacer(minLength: 0)
      Text(snapshot.statusText).font(.system(size: 10, weight: .medium)).lineLimit(1)
      HStack(spacing: 3) {
        Text("更新")
        Text(snapshot.updatedAt, style: .time).monospacedDigit()
      }
      .font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }

  private func batteryProgress(_ stateOfCharge: Double?) -> some View {
    GeometryReader { proxy in
      let progress = min(max((stateOfCharge ?? 0) / 100, 0), 1)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(NIOWidgetPalette.ink.opacity(0.10))
        Capsule()
          .fill(NIOWidgetPalette.green)
          .frame(width: proxy.size.width * progress)
      }
    }
    .frame(height: 5)
  }

  @ViewBuilder
  private func stationView(_ snapshot: WidgetVehicleSnapshot) -> some View {
    if let station = snapshot.station {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 5) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(NIOWidgetPalette.green)
          Text(station.name)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
        }
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text("\(station.available75Count)")
            .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(NIOWidgetPalette.green)
          VStack(alignment: .leading, spacing: 1) {
            Text("块可换")
            Text("75 kWh")
          }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(NIOWidgetPalette.mutedInk)
          Spacer(minLength: 0)
          Text(station.price ?? "费率暂无")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(NIOWidgetPalette.amber)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        if station.batteries.isEmpty {
          Text("暂无可换 75 kWh 电池")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(NIOWidgetPalette.mutedInk)
            .padding(.top, 6)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(station.batteries.prefix(3))) { battery in
              HStack(spacing: 5) {
                Circle()
                  .fill(NIOWidgetPalette.green)
                  .frame(width: 3, height: 3)
                Text(battery.slotID.map { "\($0)号仓" } ?? "仓位 —")
                  .frame(width: 30, alignment: .leading)
                Text(formatProductionDate(battery.productionDate))
                  .frame(maxWidth: .infinity, alignment: .leading)
                Text(formatPercent(battery.stateOfCharge))
              }
              .font(.system(size: 10, weight: .medium).monospacedDigit())
              .foregroundStyle(NIOWidgetPalette.mutedInk)
              .lineLimit(1)
              .frame(height: 18)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("\(battery.slotID.map { "\($0)号仓" } ?? "未知仓位")，生产日期 \(formatProductionDate(battery.productionDate))，电量 \(formatPercent(battery.stateOfCharge))")
              if battery.id != station.batteries.prefix(3).last?.id {
                Rectangle()
                  .fill(NIOWidgetPalette.hairline)
                  .frame(height: 0.5)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        Text(snapshot.hasStationSelection ? "站点暂不可用" : "尚未选择换电站")
          .font(.system(size: 11, weight: .semibold))
        Text(
          snapshot.hasStationSelection
            ? "车辆信息已更新，点此查看站点。"
            : "点此选择站点，查看费率与可换电池。"
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(NIOWidgetPalette.mutedInk)
        .lineLimit(3)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        NIOWidgetPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private func messageView(icon: String, title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(NIOWidgetPalette.nioBlue)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.caption)
        .foregroundStyle(NIOWidgetPalette.mutedInk)
        .lineLimit(family == .systemSmall ? 3 : 2)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func formatPercent(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "--%"
  }

  private func formatNumber(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))" } ?? "--"
  }

  private func formatKilometers(_ value: Double?) -> String {
    value.map { String(format: "%.0f km", $0) } ?? "--"
  }

  private func formatProductionDate(_ value: String?) -> String {
    value?.replacingOccurrences(of: "-", with: "/") ?? "日期未知"
  }

  private func formatTemperature(_ value: Double) -> String {
    "\(Int(value.rounded()))°"
  }
}


private struct WidgetBackgroundModifier: ViewModifier {
  let standalone: Bool
  func body(content: Content) -> some View {
    if standalone {
      content.padding(16).background(NIOWidgetPalette.mist)
    } else {
      content.containerBackground(for: .widget) { NIOWidgetPalette.mist }
    }
  }
}
