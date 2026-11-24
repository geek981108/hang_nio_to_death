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
                    .fill(statusColor.opacity(0.10))
                    .frame(width: 46, height: 54)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(statusColor.opacity(0.18), lineWidth: 1)
                    }
                VStack(spacing: 1) {
                    Text("\(batteryModel.slotID)")
                        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                        .foregroundStyle(statusColor)
                    Text("号仓")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(statusColor.opacity(0.8))
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(batteryModel.batteryType.isEmpty ? "未知电池" : batteryModel.batteryType)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Label(batteryModel.status.rawValue, systemImage: statusIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.11), in: Capsule())
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(statusColor.opacity(0.14))
                        Capsule()
                            .fill(statusColor)
                            .frame(width: max(6, proxy.size.width * min(max(batteryModel.progressFraction, 0), 1)))
                    }
                }
                .frame(height: 7)
                .accessibilityHidden(true)

                HStack(spacing: 10) {
                    if let manufactureDate = batteryModel.manufactureDate {
                        Label(manufactureDate, systemImage: "calendar")
                    }
                    if batteryModel.status == .charging,
                       let minutes = batteryModel.chargingRemainingMinutes {
                        Label("约 \(minutes) 分钟", systemImage: "clock")
                            .foregroundStyle(AppPalette.amber)
                    }
                    Spacer(minLength: 4)
                    Text(batteryModel.progressText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(statusColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .nioCard(cornerRadius: 20, padding: 16)
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
