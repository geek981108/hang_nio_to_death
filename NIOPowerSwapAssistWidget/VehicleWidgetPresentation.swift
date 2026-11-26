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
  let isRepairing: Bool
  let isFotaActive: Bool
  let isSVTActive: Bool
  let stateOfCharge: Double?
  let remainingRange: Double?
  let remainingActualRange: Double?
  let chargeStateCode: Int?
  let outsideTemperature: Double?
  let updatedAt: Date
  let station: WidgetStationSnapshot?
  let hasStationSelection: Bool

  init(
    isConnected: Bool,
    stateCode: Int?,
    isSwapping: Bool,
    isRepairing: Bool = false,
    isFotaActive: Bool = false,
    isSVTActive: Bool = false,
    stateOfCharge: Double?,
    remainingRange: Double?,
    remainingActualRange: Double?,
    chargeStateCode: Int?,
    outsideTemperature: Double?,
    updatedAt: Date,
    station: WidgetStationSnapshot?,
    hasStationSelection: Bool
  ) {
    self.isConnected = isConnected
    self.stateCode = stateCode
    self.isSwapping = isSwapping
    self.isRepairing = isRepairing
    self.isFotaActive = isFotaActive
    self.isSVTActive = isSVTActive
    self.stateOfCharge = stateOfCharge
    self.remainingRange = remainingRange
    self.remainingActualRange = remainingActualRange
    self.chargeStateCode = chargeStateCode
    self.outsideTemperature = outsideTemperature
    self.updatedAt = updatedAt
    self.station = station
    self.hasStationSelection = hasStationSelection
  }

  var prefersFrequentRefresh: Bool {
    isSVTActive || isRepairing || isFotaActive || isSwapping
      || chargeStateCode == 1 || stateCode == 1 || stateCode == 3 || stateCode == 4
  }

  var preferredRefreshInterval: TimeInterval {
    prefersFrequentRefresh ? 5 * 60 : 15 * 60
  }

  var statusText: String {
    if isSVTActive { return "防盗追踪中" }
    if isRepairing { return "维修中" }
    if isFotaActive { return "系统升级中" }
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
    if isSVTActive { return "exclamationmark.shield.fill" }
    if isRepairing { return "wrench.and.screwdriver.fill" }
    if isFotaActive { return "arrow.down.circle.fill" }
    if isSwapping { return "bolt.circle.fill" }
    if chargeStateCode == 1 || stateCode == 3 { return "bolt.fill" }
    if stateCode == 1 { return "car.side.fill" }
    return isConnected ? "antenna.radiowaves.left.and.right" : "wifi.slash"
  }

  var statusColor: Color {
    if isSVTActive { return .red }
    if isRepairing { return .orange }
    if isFotaActive { return .purple }
    if isSwapping { return .cyan }
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

struct WidgetStationLivePayload: Decodable, Sendable {
  let stationName: String
  let currentFees: [Fee]
  let available75Count: Int
  let available75Batteries: [Battery]

  enum CodingKeys: String, CodingKey {
    case stationName = "station_name"
    case currentFees = "current_fees"
    case available75Count = "available_75_count"
    case available75Batteries = "available_75_batteries"
  }

  struct Fee: Decodable, Sendable {
    let fee: String
    let unit: String
    let currency: String
    let isTotal: Bool

    enum CodingKeys: String, CodingKey {
      case fee, unit, currency
      case isTotal = "is_total"
    }
  }

  struct Battery: Decodable, Sendable {
    let batteryID: String?
    let slotID: Int?
    let stateOfCharge: Double?
    let productionDate: String?

    enum CodingKeys: String, CodingKey {
      case batteryID = "battery_id"
      case slotID = "slot_id"
      case stateOfCharge = "soc_percent"
      case productionDate = "production_date"
    }
  }

  func makeSnapshot(selectedName: String?) -> WidgetStationSnapshot {
    let trimmedSelection = selectedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmedSelection.flatMap { $0.isEmpty ? nil : $0 } ?? stationName
    let total = currentFees.first(where: \.isTotal)
    let fallbackTotal = currentFees.compactMap { Double($0.fee) }.reduce(0, +)
    let representativeFee = total ?? currentFees.first
    let price: String?
    if let representativeFee {
      let amount = total.flatMap { Double($0.fee) } ?? fallbackTotal
      let amountText = amount.formatted(.number.precision(.fractionLength(2)))
      let normalizedUnit = representativeFee.unit
        .replacingOccurrences(of: "元/", with: "/")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let unitSuffix: String
      if normalizedUnit.isEmpty {
        unitSuffix = ""
      } else if normalizedUnit.hasPrefix("/") {
        unitSuffix = normalizedUnit
      } else {
        unitSuffix = "/\(normalizedUnit)"
      }
      price = "\(representativeFee.currency)\(amountText)\(unitSuffix)"
    } else {
      price = nil
    }
    var usedIDs: Set<String> = []
    let mappedBatteries = available75Batteries.enumerated().map { index, battery -> WidgetStationBattery in
      let trimmedID = battery.batteryID?.trimmingCharacters(in: .whitespacesAndNewlines)
      let baseID: String
      if let trimmedID, !trimmedID.isEmpty {
        baseID = trimmedID
      } else if let slotID = battery.slotID {
        baseID = "slot-\(slotID)"
      } else {
        baseID = "battery-\(index)"
      }
      let uniqueID = usedIDs.insert(baseID).inserted ? baseID : "\(baseID)-\(index)"
      return WidgetStationBattery(
        id: uniqueID,
        slotID: battery.slotID,
        stateOfCharge: battery.stateOfCharge,
        productionDate: battery.productionDate
      )
    }
    return WidgetStationSnapshot(
      name: name,
      price: price,
      available75Count: available75Count,
      batteries: mappedBatteries
    )
  }
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

  private var isAccessoryFamily: Bool {
    switch family {
    case .accessoryCircular, .accessoryRectangular, .accessoryInline:
      return true
    default:
      return false
    }
  }

  var body: some View {
    Group {
      switch entry.state {
      case .loaded(let snapshot):
        loadedView(snapshot)
      case .unconfigured:
        accessoryOrMessageView(
          icon: "server.rack",
          shortTitle: "未配置",
          title: "尚未配置",
          message: "打开 NIO PS 配置车辆后端"
        )
      case .failed(let message):
        accessoryOrMessageView(
          icon: "exclamationmark.arrow.triangle.2.circlepath",
          shortTitle: "离线",
          title: "暂时无法更新",
          message: message
        )
      }
    }
    .modifier(WidgetBackgroundModifier(standalone: standalone, isAccessory: isAccessoryFamily))
    .foregroundStyle(isAccessoryFamily ? Color.primary : NIOWidgetPalette.ink)
    .widgetURL(URL(string: "niopowerswapassist://vehicle"))
  }

  @ViewBuilder
  private func loadedView(_ snapshot: WidgetVehicleSnapshot) -> some View {
    switch family {
    case .accessoryCircular:
      accessoryCircularView(snapshot)
    case .accessoryRectangular:
      accessoryRectangularView(snapshot)
    case .accessoryInline:
      accessoryInlineView(snapshot)
    case .systemSmall:
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
    default:
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

  private func accessoryCircularView(_ snapshot: WidgetVehicleSnapshot) -> some View {
    let soc = min(max((snapshot.stateOfCharge ?? 0) / 100.0, 0), 1)
    return Gauge(value: soc) {
      Image(systemName: snapshot.statusIcon)
    } currentValueLabel: {
      Text(snapshot.stateOfCharge.map { "\(Int($0.rounded()))" } ?? "--")
        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
        .minimumScaleFactor(0.7)
    }
    .gaugeStyle(.accessoryCircular)
    .widgetAccentable()
    .accessibilityLabel("NIO 电量 \(formatPercent(snapshot.stateOfCharge))，续航 \(formatKilometers(snapshot.remainingActualRange ?? snapshot.remainingRange))")
  }

  private func accessoryRectangularView(_ snapshot: WidgetVehicleSnapshot) -> some View {
    let rangeText = formatKilometers(snapshot.remainingActualRange ?? snapshot.remainingRange)
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: snapshot.statusIcon)
          .font(.caption2.weight(.bold))
        Text("NIO · \(snapshot.statusText)")
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
      }
      .widgetAccentable()

      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(rangeText)
          .font(.system(.headline, design: .rounded, weight: .bold).monospacedDigit())
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text(formatPercent(snapshot.stateOfCharge))
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if let station = snapshot.station {
        HStack(spacing: 4) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 9, weight: .bold))
          Text("\(station.available75Count)块可换")
          if let price = station.price {
            Text("· \(price)")
          }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      } else {
        Gauge(value: min(max((snapshot.stateOfCharge ?? 0) / 100.0, 0), 1)) {
          EmptyView()
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .widgetAccentable()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func accessoryInlineView(_ snapshot: WidgetVehicleSnapshot) -> some View {
    let range = formatKilometers(snapshot.remainingActualRange ?? snapshot.remainingRange)
    let soc = formatPercent(snapshot.stateOfCharge)
    let stationSuffix = snapshot.station.map { " · \($0.available75Count)块可换" } ?? ""
    return Label("NIO \(range) · \(soc)\(stationSuffix)", systemImage: snapshot.statusIcon)
  }

  @ViewBuilder
  private func accessoryOrMessageView(
    icon: String,
    shortTitle: String,
    title: String,
    message: String
  ) -> some View {
    switch family {
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        VStack(spacing: 2) {
          Image(systemName: icon)
            .font(.caption)
          Text(shortTitle)
            .font(.system(size: 9, weight: .semibold))
        }
      }
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 2) {
        Label("NIO · \(shortTitle)", systemImage: icon)
          .font(.caption.weight(.semibold))
        Text(message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .accessoryInline:
      Label("NIO \(shortTitle)", systemImage: icon)
    default:
      messageView(icon: icon, title: title, message: message)
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
    guard let value, !value.isEmpty else { return "75 kWh 可换" }
    return value.replacingOccurrences(of: "-", with: "/")
  }

  private func formatTemperature(_ value: Double) -> String {
    "\(Int(value.rounded()))°"
  }
}


private struct WidgetBackgroundModifier: ViewModifier {
  let standalone: Bool
  let isAccessory: Bool
  func body(content: Content) -> some View {
    if standalone {
      content.padding(16).background(NIOWidgetPalette.mist)
    } else if isAccessory {
      content.containerBackground(.clear, for: .widget)
    } else {
      content.containerBackground(for: .widget) { NIOWidgetPalette.mist }
    }
  }
}
