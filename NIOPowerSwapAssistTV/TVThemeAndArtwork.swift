import ImageIO
import SwiftUI
import UIKit

enum TVPalette {
    static let canvas = Color(red: 0.04, green: 0.055, blue: 0.085)
    static let surface = Color.white.opacity(0.08)
    static let surfaceElevated = Color.white.opacity(0.13)
    static let hairline = Color.white.opacity(0.14)
    static let blue = Color(red: 0.25, green: 0.58, blue: 1.0)
    static let green = Color(red: 0.22, green: 0.85, blue: 0.54)
    static let cyan = Color(red: 0.22, green: 0.82, blue: 0.96)
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.22)
    static let violet = Color(red: 0.64, green: 0.48, blue: 1.0)
    static let red = Color(red: 0.96, green: 0.34, blue: 0.34)
}

struct TVStatusVisuals {
    let label: String
    let icon: String
    let color: Color
    let isPulsing: Bool

    static func resolve(for dashboard: VehicleDashboard?) -> TVStatusVisuals {
        guard let dashboard else {
            return TVStatusVisuals(label: "等待数据", icon: "clock", color: .secondary, isPulsing: false)
        }
        if let special = dashboard.primarySpecialStatus {
            switch special {
            case .svt:
                return TVStatusVisuals(label: "防盗追踪中", icon: "exclamationmark.shield.fill", color: TVPalette.red, isPulsing: true)
            case .repairing:
                return TVStatusVisuals(label: "维修中", icon: "wrench.and.screwdriver.fill", color: TVPalette.amber, isPulsing: true)
            case .fota:
                let title = dashboard.fotaPreparingCountdownSeconds != nil ? "准备系统升级" : "系统升级中"
                return TVStatusVisuals(label: title, icon: "arrow.down.circle.fill", color: TVPalette.violet, isPulsing: true)
            case .swapping:
                return TVStatusVisuals(label: "正在换电", icon: "arrow.triangle.2.circlepath", color: TVPalette.cyan, isPulsing: true)
            }
        }
        if dashboard.chargeStateCode == 1 || dashboard.stateCode == 3 {
            return TVStatusVisuals(label: "正在充电", icon: "bolt.fill", color: TVPalette.green, isPulsing: true)
        }
        if dashboard.isDriving {
            return TVStatusVisuals(label: "行驶中", icon: "car.rear.road.lane", color: TVPalette.blue, isPulsing: true)
        }
        if dashboard.stateCode == 2 {
            return TVStatusVisuals(
                label: "已驻车",
                icon: "parkingsign.circle.fill",
                color: dashboard.isConnected ? TVPalette.green : .secondary,
                isPulsing: false
            )
        }
        return TVStatusVisuals(
            label: dashboard.isConnected ? "车辆在线" : "车辆离线",
            icon: dashboard.isConnected ? "antenna.radiowaves.left.and.right" : "wifi.slash",
            color: dashboard.isConnected ? TVPalette.blue : .secondary,
            isPulsing: false
        )
    }

    static func specialColor(_ kind: VehicleDashboard.SpecialStatusKind) -> Color {
        switch kind {
        case .svt: return TVPalette.red
        case .repairing: return TVPalette.amber
        case .fota: return TVPalette.violet
        case .swapping: return TVPalette.cyan
        }
    }

    static func specialIcon(_ kind: VehicleDashboard.SpecialStatusKind) -> String {
        switch kind {
        case .svt: return "exclamationmark.shield.fill"
        case .repairing: return "wrench.and.screwdriver.fill"
        case .fota: return "arrow.down.circle.fill"
        case .swapping: return "arrow.triangle.2.circlepath"
        }
    }

    static func specialTitle(_ kind: VehicleDashboard.SpecialStatusKind, dashboard: VehicleDashboard) -> String {
        switch kind {
        case .svt: return "防盗追踪已触发"
        case .repairing: return "车辆维修中"
        case .fota: return dashboard.fotaPreparingCountdownSeconds != nil ? "系统升级准备中" : "车辆系统升级中"
        case .swapping: return "车辆正在换电"
        }
    }

    static func specialDescription(_ kind: VehicleDashboard.SpecialStatusKind, dashboard: VehicleDashboard) -> String {
        switch kind {
        case .svt:
            return "防盗追踪模式（SVT）已激活，请立即确认车辆状态与停放位置。"
        case .repairing:
            return "车辆当前处于维修模式，服务中心可能正在检修作业。"
        case .fota:
            if let code = dashboard.fotaStatusCode {
                return "车辆正在准备或执行系统升级（状态码 \(code)），升级期间请耐心等待。"
            }
            return "车辆正在准备或执行系统升级，请耐心等待升级完成。"
        case .swapping:
            return "换电站正在为车辆更换电池，完成后将自动同步最新电量与续航。"
        }
    }
}

struct TVLivePulseDot: View {
    let color: Color
    var size: CGFloat = 12
    var isPulsing: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isPulsing && !reduceMotion {
                Circle()
                    .fill(color.opacity(pulse ? 0.0 : 0.45))
                    .frame(width: pulse ? size * 2.4 : size, height: pulse ? size * 2.4 : size)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .onAppear { pulse = true }
    }
}

extension View {
    func tvGlassCard(cornerRadius: CGFloat = 28, padding: CGFloat = 28, borderColor: Color = TVPalette.hairline) -> some View {
        self
            .padding(padding)
            .background(TVPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            }
    }
}

/// Custom tvOS dark-mode card focus style that avoids the bright-grey `.card` washout
/// while keeping unmistakable Siri Remote focus feedback (scale + luminous border + subtle glow).
struct TVDarkFocusCardButtonStyle: ButtonStyle {
    var accentColor: Color = TVPalette.blue
    var cornerRadius: CGFloat = 24
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVDarkFocusCardSurface(
            configuration: configuration,
            accentColor: accentColor,
            cornerRadius: cornerRadius,
            isSelected: isSelected
        )
    }

    private struct TVDarkFocusCardSurface: View {
        let configuration: Configuration
        let accentColor: Color
        let cornerRadius: CGFloat
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        private var borderColor: Color {
            if isFocused { return accentColor.opacity(0.95) }
            if isSelected { return accentColor.opacity(0.65) }
            return Color.white.opacity(0.13)
        }

        private var fillColor: Color {
            if isFocused { return Color(red: 0.13, green: 0.16, blue: 0.22).opacity(0.96) }
            if isSelected { return Color(red: 0.10, green: 0.13, blue: 0.19).opacity(0.92) }
            return Color.white.opacity(0.075)
        }

        var body: some View {
            configuration.label
                .background(fillColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isFocused ? 3.0 : (isSelected ? 2.0 : 1.5))
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.035 : 1.0))
                .shadow(
                    color: isFocused ? accentColor.opacity(0.32) : .black.opacity(0.25),
                    radius: isFocused ? 22 : 8,
                    x: 0,
                    y: isFocused ? 10 : 4
                )
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Custom dark focus style for capsule status pills (e.g. tappable special-status badge).
struct TVCapsuleFocusButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, tint: tint)
    }

    private struct Surface: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(
                    tint.opacity(isFocused ? 0.28 : 0.18),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            tint.opacity(isFocused ? 0.95 : 0.35),
                            lineWidth: isFocused ? 2.5 : 1.2
                        )
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.05 : 1.0))
                .shadow(color: isFocused ? tint.opacity(0.38) : .clear, radius: 14, x: 0, y: 6)
                .animation(.easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// Compact, zero-bloat tvOS action button style with controlled padding so labels never truncate
/// like system `.bordered` buttons do inside multi-button rows.
struct TVActionPillButtonStyle: ButtonStyle {
    var tint: Color = TVPalette.blue
    var isProminent: Bool = false
    var cornerRadius: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Surface(
            configuration: configuration,
            tint: tint,
            isProminent: isProminent,
            cornerRadius: cornerRadius
        )
    }

    private struct Surface: View {
        let configuration: Configuration
        let tint: Color
        let isProminent: Bool
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        private var fill: Color {
            if isProminent {
                return isFocused ? tint : tint.opacity(0.84)
            }
            return isFocused ? Color(red: 0.17, green: 0.21, blue: 0.29) : Color.white.opacity(0.085)
        }

        private var border: Color {
            if isFocused { return isProminent ? Color.white.opacity(0.95) : tint.opacity(0.92) }
            return isProminent ? tint.opacity(0.45) : Color.white.opacity(0.13)
        }

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.38))
                .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(border, lineWidth: isFocused ? 2.5 : 1.2)
                }
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.05 : 1.0))
                .shadow(
                    color: isFocused ? tint.opacity(isProminent ? 0.48 : 0.30) : .clear,
                    radius: isFocused ? 16 : 0,
                    x: 0,
                    y: isFocused ? 6 : 0
                )
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

struct TVSOCRingView: View {
    let soc: Double?
    let color: Color
    var lineWidth: CGFloat = 18
    var diameter: CGFloat = 180
    var isCharging: Bool = false

    private var fraction: Double {
        min(max((soc ?? 0) / 100.0, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.6), color],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)

            VStack(spacing: 4) {
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: diameter * 0.13, weight: .bold))
                        .foregroundStyle(TVPalette.green)
                }
                Text(soc.map { "\(Int($0.rounded()))%" } ?? "--%")
                    .font(.system(size: diameter * 0.26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("电量")
                    .font(.system(size: max(14, diameter * 0.095), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct TVVehicleHeroStage: View {
    let imageData: Data?
    let fallbackAssetName: String?
    let isDriving: Bool
    let accentColor: Color
    var maxHeight: CGFloat = 460
    var showShowroomFloor: Bool = false

    var body: some View {
        ZStack {
            if showShowroomFloor {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, accentColor.opacity(0.28), Color.white.opacity(0.24), accentColor.opacity(0.28), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1.5)
                    .offset(y: maxHeight * 0.34)
            }

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            accentColor.opacity(showShowroomFloor ? 0.38 : 0.32),
                            accentColor.opacity(showShowroomFloor ? 0.10 : 0.06),
                            .clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: showShowroomFloor ? 440 : 380
                    )
                )
                .frame(height: maxHeight * 0.45)
                .offset(y: maxHeight * (showShowroomFloor ? 0.31 : 0.28))
                .blur(radius: showShowroomFloor ? 34 : 26)

            if isDriving, let gifData = NSDataAsset(name: "CarDrivingRearViewDark")?.data {
                TVAnimatedGIFView(data: gifData)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5)
                    }
            } else if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.55), radius: 34, x: 0, y: 22)
            } else if let asset = fallbackAssetName, let uiImage = UIImage(named: asset) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.55), radius: 34, x: 0, y: 22)
            } else if let defaultCar = UIImage(named: "ET5TTouringSide") {
                Image(uiImage: defaultCar)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.55), radius: 34, x: 0, y: 22)
            } else {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 140))
                    .foregroundStyle(accentColor.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, minHeight: maxHeight * 0.78, maxHeight: maxHeight)
    }
}

struct TVAnimatedGIFView: View {
    private struct Frame {
        let image: CGImage
        let duration: TimeInterval
    }

    private let frames: [Frame]
    private let totalDuration: TimeInterval

    init(data: Data) {
        var parsed: [Frame] = []
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let count = CGImageSourceGetCount(source)
            for idx in 0..<count {
                if let cgImage = CGImageSourceCreateImageAtIndex(source, idx, nil) {
                    let props = CGImageSourceCopyPropertiesAtIndex(source, idx, nil) as? [CFString: Any]
                    let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                        ?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double)
                        ?? 0.08
                    parsed.append(Frame(image: cgImage, duration: max(0.03, delay)))
                }
            }
        }
        self.frames = parsed
        self.totalDuration = max(0.1, parsed.reduce(0) { $0 + $1.duration })
    }

    var body: some View {
        if frames.isEmpty {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: totalDuration)
                let frame = frameFor(offset: elapsed)
                Image(decorative: frame.image, scale: 1.0)
                    .resizable()
                    .scaledToFill()
            }
        }
    }

    private func frameFor(offset: TimeInterval) -> Frame {
        var cursor: TimeInterval = 0
        for frame in frames {
            cursor += frame.duration
            if offset <= cursor { return frame }
        }
        return frames[0]
    }
}

enum TVFormatters {
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private static let clockTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let ambientDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter
    }()

    private static let groupedIntegerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func km(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- km" }
        return "\(Int(value.rounded())) km"
    }

    static func groupedKm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- km" }
        let rounded = Int(value.rounded())
        let text = groupedIntegerFormatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return "\(text) km"
    }

    static func decimalKm(_ value: Double) -> String {
        String(format: "%.1f km", value)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--℃" }
        return String(format: "%.1f℃", value)
    }

    static func powerKW(watts: Double?) -> String? {
        guard let watts, watts.isFinite, watts > 0 else { return nil }
        return String(format: "%.1f kW", watts / 1_000.0)
    }

    static func durationMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rem) 分"
    }

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func clockTime(_ date: Date) -> String {
        clockTimeFormatter.string(from: date)
    }

    static func ambientDate(_ date: Date) -> String {
        ambientDateFormatter.string(from: date)
    }
}
