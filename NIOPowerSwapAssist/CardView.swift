import SwiftUI

struct CardView: View {
    let batteryModel: BatteryModel

    private var statusColor: Color {
        switch batteryModel.status {
        case .occupied: return .secondary
        case .ready: return AppPalette.green
        case .charging: return AppPalette.amber
        }
    }

    private var statusIcon: String {
        switch batteryModel.status {
        case .occupied: return "car.fill"
        case .ready: return "bolt.fill"
        case .charging: return "battery.75percent"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(statusColor.opacity(0.08))
                    .frame(width: 44, height: 52)
                Text("\(batteryModel.slotID)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(statusColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(batteryModel.batteryType.isEmpty ? "未知电池" : batteryModel.batteryType)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Label(batteryModel.status.rawValue, systemImage: statusIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.1), in: Capsule())
                }

                ProgressView(value: batteryModel.progressFraction)
                    .tint(statusColor)

                HStack(spacing: 10) {
                    if let manufactureDate = batteryModel.manufactureDate {
                        Label(manufactureDate, systemImage: "calendar")
                    }
                    if batteryModel.status == .charging,
                       let minutes = batteryModel.chargingRemainingMinutes {
                        Label("约 \(minutes) 分钟", systemImage: "clock")
                    }
                    Spacer(minLength: 4)
                    Text(batteryModel.progressText)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(batteryModel.slotID) 号仓，\(batteryModel.batteryType)，\(batteryModel.status.rawValue)，电量 \(batteryModel.progressText)")
    }
}

#Preview {
    ZStack {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
        CardView(batteryModel: BatteryModel.sampleData[2]).padding()
    }
}
