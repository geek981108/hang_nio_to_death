import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct NIOVehicleLiveActivityAttributes: ActivityAttributes, Hashable, Sendable {
  enum Mode: String, Codable, Hashable, Sendable {
    case swapQueue
    case charging
  }

  struct ContentState: Codable, Hashable, Sendable {
    let mode: Mode
    let title: String
    let subtitle: String?
    let updatedAt: Date

    // Swap queue fields
    let orderNo: String?
    let queueNumber: Int?
    let vehiclesAhead: Int?
    let estimatedWaitMinutes: Int?

    // Charging fields
    let stateOfCharge: Double?
    let chargeLimitPercent: Double?
    let chargingPowerKW: Double?
    let remainingRangeKm: Double?
    let chargedEnergyKWh: Double?

    /// Compares all rendered fields while ignoring timestamp-only ticks.
    func hasSameDisplayedContent(as other: ContentState) -> Bool {
      mode == other.mode
        && title == other.title
        && subtitle == other.subtitle
        && orderNo == other.orderNo
        && queueNumber == other.queueNumber
        && vehiclesAhead == other.vehiclesAhead
        && estimatedWaitMinutes == other.estimatedWaitMinutes
        && stateOfCharge == other.stateOfCharge
        && chargeLimitPercent == other.chargeLimitPercent
        && chargingPowerKW == other.chargingPowerKW
        && remainingRangeKm == other.remainingRangeKm
        && chargedEnergyKWh == other.chargedEnergyKWh
    }

    var deepLinkURL: URL {
      URL(
        string: mode == .swapQueue
          ? "niopowerswapassist://station"
          : "niopowerswapassist://vehicle"
      )!
    }

    var swapHeadline: String {
      if let ahead = vehiclesAhead {
        return ahead == 0 ? "已到你换电" : "前方 \(ahead) 辆"
      }
      return subtitle ?? "正在换电"
    }

    var swapCompactTrailing: String {
      if let ahead = vehiclesAhead {
        return ahead == 0 ? "到你了" : "前\(ahead)辆"
      }
      return "换电中"
    }

    var formattedSOC: String {
      stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "--%"
    }

    var formattedPowerKW: String? {
      guard let power = chargingPowerKW, power.isFinite, power > 0 else { return nil }
      return String(format: "%.1f kW", power)
    }

    var formattedRangeKm: String? {
      guard let range = remainingRangeKm, range.isFinite, range >= 0 else { return nil }
      return "\(Int(range.rounded())) km"
    }

    var formattedChargedEnergy: String? {
      guard let energy = chargedEnergyKWh, energy.isFinite, energy > 0 else { return nil }
      return String(format: "+%.1f kWh", energy)
    }

    var socFraction: Double {
      min(max((stateOfCharge ?? 0) / 100.0, 0), 1)
    }
  }

  let sessionKey: String
  let vehicleName: String
}

struct NIOVehicleLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: NIOVehicleLiveActivityAttributes.self) { context in
      NIOVehicleLiveActivityLockScreenView(
        attributes: context.attributes,
        state: context.state
      )
      .widgetURL(context.state.deepLinkURL)
      .activityBackgroundTint(
        context.state.mode == .swapQueue
          ? Color(red: 0.09, green: 0.13, blue: 0.19)
          : Color(red: 0.08, green: 0.15, blue: 0.12)
      )
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          expandedLeading(state: context.state)
        }
        DynamicIslandExpandedRegion(.trailing) {
          expandedTrailing(state: context.state)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.92))
        }
        DynamicIslandExpandedRegion(.bottom) {
          expandedBottom(attributes: context.attributes, state: context.state)
        }
      } compactLeading: {
        Image(systemName: context.state.mode == .swapQueue ? "bolt.car.fill" : "bolt.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(accentColor(for: context.state))
      } compactTrailing: {
        Text(
          context.state.mode == .swapQueue
            ? context.state.swapCompactTrailing
            : context.state.formattedSOC
        )
        .font(.caption2.weight(.bold).monospacedDigit())
        .foregroundStyle(accentColor(for: context.state))
        .lineLimit(1)
      } minimal: {
        if context.state.mode == .swapQueue {
          Image(systemName: "bolt.car.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(accentColor(for: context.state))
        } else {
          Gauge(value: context.state.socFraction) {
            Image(systemName: "bolt.fill")
          }
          .gaugeStyle(.accessoryCircularCapacity)
          .tint(.green)
        }
      }
      .widgetURL(context.state.deepLinkURL)
      .keylineTint(accentColor(for: context.state))
    }
  }

  private func accentColor(for state: NIOVehicleLiveActivityAttributes.ContentState) -> Color {
    if state.mode == .swapQueue {
      return state.vehiclesAhead == 0 ? .green : .orange
    }
    return .green
  }

  @ViewBuilder
  private func expandedLeading(state: NIOVehicleLiveActivityAttributes.ContentState) -> some View {
    if state.mode == .swapQueue {
      HStack(spacing: 5) {
        Image(systemName: "bolt.car.fill")
          .font(.headline)
          .foregroundStyle(accentColor(for: state))
        if let queueNumber = state.queueNumber {
          Text(String(format: "#%02d", queueNumber))
            .font(.system(.headline, design: .rounded, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
        }
      }
    } else {
      HStack(spacing: 5) {
        Image(systemName: "bolt.fill")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(.green)
        Text(state.formattedSOC)
          .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
          .foregroundStyle(.green)
      }
    }
  }

  @ViewBuilder
  private func expandedTrailing(state: NIOVehicleLiveActivityAttributes.ContentState) -> some View {
    if state.mode == .swapQueue {
      Text(state.swapHeadline)
        .font(.subheadline.weight(.bold).monospacedDigit())
        .foregroundStyle(accentColor(for: state))
        .lineLimit(1)
    } else {
      VStack(alignment: .trailing, spacing: 1) {
        if let power = state.formattedPowerKW {
          Text(power)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
        }
        if let range = state.formattedRangeKm {
          Text(range)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
        }
      }
    }
  }

  @ViewBuilder
  private func expandedBottom(
    attributes: NIOVehicleLiveActivityAttributes,
    state: NIOVehicleLiveActivityAttributes.ContentState
  ) -> some View {
    if state.mode == .swapQueue {
      HStack(spacing: 8) {
        Text(state.subtitle ?? attributes.vehicleName)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.75))
          .lineLimit(1)
        Spacer(minLength: 4)
        if let wait = state.estimatedWaitMinutes, wait > 0 {
          Label("约 \(wait) 分钟", systemImage: "clock")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.orange)
        } else if state.vehiclesAhead == 0 {
          Text("请准备进站")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
        }
      }
      .padding(.top, 2)
    } else {
      VStack(spacing: 6) {
        liveChargingBar(soc: state.socFraction, limit: state.chargeLimitPercent)
        HStack {
          if let limit = state.chargeLimitPercent {
            Text("上限 \(Int(limit.rounded()))%")
          } else {
            Text(attributes.vehicleName)
          }
          Spacer()
          if let energy = state.formattedChargedEnergy {
            Text("已充 \(energy)")
              .foregroundStyle(.green)
          }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.75))
      }
      .padding(.top, 2)
    }
  }
}

struct NIOVehicleLiveActivityLockScreenView: View {
  let attributes: NIOVehicleLiveActivityAttributes
  let state: NIOVehicleLiveActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: state.mode == .swapQueue ? "bolt.car.fill" : "battery.100percent.bolt")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(headerAccent)
        Text(state.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer(minLength: 6)
        headerBadge
      }

      if state.mode == .swapQueue {
        swapBody
      } else {
        chargingBody
      }

      HStack(spacing: 6) {
        if let subtitle = state.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .lineLimit(1)
        } else {
          Text(attributes.vehicleName)
        }
        Spacer(minLength: 4)
        Text("更新于")
        Text(state.updatedAt, style: .time)
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.white.opacity(0.65))
    }
    .padding(16)
  }

  private var headerAccent: Color {
    if state.mode == .swapQueue {
      return state.vehiclesAhead == 0 ? .green : .orange
    }
    return .green
  }

  @ViewBuilder
  private var headerBadge: some View {
    if state.mode == .swapQueue {
      if let queueNumber = state.queueNumber {
        Text(String(format: "换电号 %02d", queueNumber))
          .font(.caption2.weight(.bold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(headerAccent.opacity(0.28), in: Capsule())
      } else {
        Text("换电实况")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(headerAccent)
      }
    } else if let power = state.formattedPowerKW {
      Text(power)
        .font(.caption.weight(.bold).monospacedDigit())
        .foregroundStyle(.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.22), in: Capsule())
    }
  }

  private var swapBody: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(state.swapHeadline)
        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(headerAccent)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Spacer(minLength: 8)
      if let wait = state.estimatedWaitMinutes, wait > 0 {
        VStack(alignment: .trailing, spacing: 1) {
          Text("约 \(wait) 分钟")
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
          Text("预计等待")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.65))
        }
      } else if state.vehiclesAhead == 0 {
        Text("请做好进站准备")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
      }
    }
  }

  private var chargingBody: some View {
    VStack(spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(state.formattedSOC)
          .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
          .foregroundStyle(.green)
        if let range = state.formattedRangeKm {
          Text(range)
            .font(.subheadline.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.86))
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          if let energy = state.formattedChargedEnergy {
            Text(energy)
              .font(.caption.weight(.semibold).monospacedDigit())
              .foregroundStyle(.green)
          }
          if let limit = state.chargeLimitPercent {
            Text("上限 \(Int(limit.rounded()))%")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.white.opacity(0.68))
          }
        }
      }
      liveChargingBar(soc: state.socFraction, limit: state.chargeLimitPercent)
    }
  }
}

private func liveChargingBar(soc: Double, limit: Double?) -> some View {
  GeometryReader { proxy in
    let width = max(proxy.size.width, 1)
    let fillWidth = max(6, width * min(max(soc, 0), 1))
    ZStack(alignment: .leading) {
      Capsule()
        .fill(Color.white.opacity(0.16))
      Capsule()
        .fill(
          LinearGradient(
            colors: [Color(red: 0.28, green: 0.85, blue: 0.56), .green],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(width: fillWidth)
      if let limit, limit.isFinite, (1...99).contains(limit) {
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.white.opacity(0.85))
          .frame(width: 2, height: 10)
          .offset(x: width * (limit / 100.0) - 1)
      }
    }
  }
  .frame(height: 7)
}
