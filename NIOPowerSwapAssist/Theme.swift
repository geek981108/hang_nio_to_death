//
//  Theme.swift
//  NIOPowerSwapAssist
//
//  Created by 许懿赫 on 2025/1/2.
//

import Foundation
import SwiftUI

enum AppPalette {
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        : UIColor(red: 0.955, green: 0.958, blue: 0.965, alpha: 1) })
    static let surface = adaptive(
        light: UIColor.systemBackground,
        dark: UIColor(red: 0.11, green: 0.125, blue: 0.155, alpha: 1))
    static let surfaceSecondary = adaptive(
        light: UIColor(red: 0.945, green: 0.95, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.155, green: 0.175, blue: 0.215, alpha: 1))
    static let hairline = adaptive(
        light: UIColor.black.withAlphaComponent(0.055),
        dark: UIColor.white.withAlphaComponent(0.085))
    static let cardShadow = adaptive(
        light: UIColor.black.withAlphaComponent(0.045),
        dark: UIColor.clear)
    static let blue = adaptive(
        light: UIColor(red: 0.24, green: 0.44, blue: 0.72, alpha: 1),
        dark: UIColor(red: 0.56, green: 0.74, blue: 0.95, alpha: 1))
    static let green = adaptive(
        light: UIColor(red: 0.15, green: 0.52, blue: 0.36, alpha: 1),
        dark: UIColor(red: 0.45, green: 0.82, blue: 0.62, alpha: 1))
    static let amber = adaptive(
        light: UIColor(red: 0.72, green: 0.41, blue: 0.14, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.71, blue: 0.39, alpha: 1))
    static let red = adaptive(
        light: UIColor(red: 0.74, green: 0.21, blue: 0.19, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.49, blue: 0.46, alpha: 1))
    static let violet = adaptive(
        light: UIColor(red: 0.46, green: 0.39, blue: 0.69, alpha: 1),
        dark: UIColor(red: 0.74, green: 0.65, blue: 0.94, alpha: 1))
    static let graphite = adaptive(
        light: UIColor(red: 0.17, green: 0.21, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.78, green: 0.83, blue: 0.90, alpha: 1))
    static let stationNight = Color(red: 0.13, green: 0.17, blue: 0.24)
    static let climate = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.18, green: 0.15, blue: 0.12, alpha: 1)
        : UIColor(red: 0.985, green: 0.94, blue: 0.865, alpha: 1) })

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Battery glyph buckets follow the fill steps of the SF Symbols battery family.
enum BatteryIndicator {
    static func symbolName(stateOfCharge: Double?) -> String {
        guard let stateOfCharge else { return "battery.100percent" }
        switch stateOfCharge {
        case ..<12.5: return "battery.0percent"
        case ..<37.5: return "battery.25percent"
        case ..<62.5: return "battery.50percent"
        case ..<87.5: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func tint(stateOfCharge: Double?) -> Color {
        guard let stateOfCharge else { return AppPalette.graphite }
        if stateOfCharge < 20 { return AppPalette.red }
        if stateOfCharge < 50 { return AppPalette.amber }
        return AppPalette.green
    }
}

/// Tactile pressable button style for interactive cards and tiles.
struct TactileScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// A rounded-rectangle path starting at exact 12 o'clock (top center) and tracing
/// strictly clockwise so `.trim(from: 0, to: progress)` sweeps around an icon cleanly.
struct ClockwiseRoundedRect: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> ClockwiseRoundedRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let r = min(max(cornerRadius - insetAmount, 0), min(insetRect.width, insetRect.height) / 2)
        var path = Path()
        let topCenter = CGPoint(x: insetRect.midX, y: insetRect.minY)
        path.move(to: topCenter)
        path.addArc(
            tangent1End: CGPoint(x: insetRect.maxX, y: insetRect.minY),
            tangent2End: CGPoint(x: insetRect.maxX, y: insetRect.midY),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: insetRect.maxX, y: insetRect.maxY),
            tangent2End: CGPoint(x: insetRect.midX, y: insetRect.maxY),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: insetRect.minX, y: insetRect.maxY),
            tangent2End: CGPoint(x: insetRect.minX, y: insetRect.midY),
            radius: r
        )
        path.addArc(
            tangent1End: CGPoint(x: insetRect.minX, y: insetRect.minY),
            tangent2End: topCenter,
            radius: r
        )
        path.addLine(to: topCenter)
        return path
    }
}

/// Always-mounted clockwise progress ring wrapping an icon. Keeping the trimmed
/// shape mounted ensures SwiftUI smoothly interpolates `0 -> 1` on hold.
struct IconHoldProgressRing: View {
    enum ShapeKind {
        case circle
        case roundedRect(cornerRadius: CGFloat)
    }

    let progress: CGFloat
    let isVisible: Bool
    let color: Color
    var lineWidth: CGFloat = 3.5
    var shape: ShapeKind = .circle

    var body: some View {
        ZStack {
            switch shape {
            case .circle:
                Circle()
                    .stroke(color.opacity(isVisible ? 0.22 : 0), lineWidth: lineWidth)
                    .animation(.easeOut(duration: 0.16), value: isVisible)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: isVisible)
            case .roundedRect(let cornerRadius):
                ClockwiseRoundedRect(cornerRadius: cornerRadius)
                    .inset(by: lineWidth / 2)
                    .stroke(color.opacity(isVisible ? 0.22 : 0), lineWidth: lineWidth)
                    .animation(.easeOut(duration: 0.16), value: isVisible)
                ClockwiseRoundedRect(cornerRadius: cornerRadius)
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .opacity(isVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: isVisible)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Supports quick tap and hold-to-execute with a live 0...1 progress value,
/// using SwiftUI's native Button press state so ScrollView gestures never conflict.
struct HoldToExecuteButton<Content: View>: View {
    let holdDuration: TimeInterval
    let gracePeriod: TimeInterval
    let isHoldEnabled: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    @ViewBuilder let content: (_ progress: CGFloat, _ isHolding: Bool, _ didComplete: Bool) -> Content

    @State private var isPressed = false
    @State private var holdProgress: CGFloat = 0
    @State private var didEnterHoldPhase = false
    @State private var didCompleteHold = false
    @State private var holdStartHapticTick = 0
    @State private var holdCompleteHapticTick = 0

    init(
        holdDuration: TimeInterval = 0.85,
        gracePeriod: TimeInterval = 0.10,
        isHoldEnabled: Bool = true,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        @ViewBuilder content: @escaping (_ progress: CGFloat, _ isHolding: Bool, _ didComplete: Bool) -> Content
    ) {
        self.holdDuration = holdDuration
        self.gracePeriod = gracePeriod
        self.isHoldEnabled = isHoldEnabled
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.content = content
    }

    var body: some View {
        Button {
            if !didEnterHoldPhase {
                onTap()
            }
        } label: {
            content(holdProgress, didEnterHoldPhase && isPressed, didCompleteHold)
        }
        .buttonStyle(HoldPressTrackingButtonStyle(isPressed: $isPressed))
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: holdStartHapticTick)
        .sensoryFeedback(.success, trigger: holdCompleteHapticTick)
        .task(id: isPressed) {
            if isPressed {
                didEnterHoldPhase = false
                didCompleteHold = false
                holdProgress = 0
                guard isHoldEnabled else { return }
                do {
                    try await Task.sleep(for: .milliseconds(Int(gracePeriod * 1000)))
                } catch {
                    return
                }
                guard !Task.isCancelled, isPressed else { return }
                didEnterHoldPhase = true
                holdStartHapticTick += 1
                withAnimation(.linear(duration: holdDuration)) {
                    holdProgress = 1
                }
                do {
                    try await Task.sleep(for: .milliseconds(Int(holdDuration * 1000)))
                } catch {
                    return
                }
                guard !Task.isCancelled, isPressed else { return }
                didCompleteHold = true
                holdCompleteHapticTick += 1
                onLongPress()
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    holdProgress = 0
                    didCompleteHold = false
                }
            } else {
                if didCompleteHold {
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled, !isPressed else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        holdProgress = 0
                    }
                    didEnterHoldPhase = false
                    didCompleteHold = false
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        holdProgress = 0
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, !isPressed else { return }
                    didEnterHoldPhase = false
                }
            }
        }
    }
}

private struct HoldPressTrackingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

/// Subtle breathing status dot for live vehicle/queue states.
struct LivePulseDot: View {
    let color: Color
    var size: CGFloat = 7
    var isPulsing: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            if isPulsing && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.32))
                    .frame(width: size * 2.1, height: size * 2.1)
                    .scaleEffect(animate ? 1.15 : 0.55)
                    .opacity(animate ? 0 : 0.85)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onAppear {
            guard isPulsing && !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
        .onChange(of: isPulsing) { _, pulsing in
            if pulsing && !reduceMotion {
                animate = false
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    animate = true
                }
            } else {
                animate = false
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    func nioCard(cornerRadius: CGFloat = 24, padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            }
            .shadow(color: AppPalette.cardShadow, radius: 10, x: 0, y: 4)
    }
}

enum Theme: String {
    case bubblegum
    case buttercup
    case indigo
    case lavender
    case magenta
    case navy
    case orange
    case oxblood
    case periwinkle
    case poppy
    case purple
    case seafoam
    case sky
    case tan
    case teal
    case yellow

    var accentColor: Color {
        switch self {
        case .bubblegum, .buttercup, .lavender, .orange, .periwinkle, .poppy, .seafoam, .sky, .tan, .teal, .yellow: return .black
        case .indigo, .magenta, .navy, .oxblood, .purple: return .white
        }
    }
    var mainColor: Color {
        Color(rawValue)
    }
}
