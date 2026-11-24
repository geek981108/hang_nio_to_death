import SwiftUI
import WatchKit

struct WatchDashboardView: View {
    private enum WatchPage: Int, Hashable {
        case overview
        case controls
        case station
    }

    @StateObject private var viewModel = WatchDashboardViewModel()
    @StateObject private var connectivity = WatchConnectivityCoordinator.shared
    @State private var selectedPage: WatchPage = .overview

    private let controlColumns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7)
    ]

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedPage) {
                overviewPage
                    .tag(WatchPage.overview)
                controlsPage
                    .tag(WatchPage.controls)
                stationPage
                    .tag(WatchPage.station)
            }
            .tabViewStyle(.verticalPage)
            .navigationTitle(pageTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.isPerformingCommand)
                    .accessibilityLabel("刷新车辆状态")
                }
            }
        }
        .overlay(alignment: .top) {
            if let feedback = viewModel.feedback {
                HStack(spacing: 5) {
                    Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isError ? .orange : .green)
                    Text(feedback.message)
                        .lineLimit(2)
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { viewModel.feedback = nil }
                }
            }
        }
        .overlay {
            if viewModel.isPerformingCommand {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text(viewModel.activeCommandLabel ?? "正在发送…")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.feedback?.id)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isPerformingCommand)
        .task(id: viewModel.feedback?.id) {
            guard let id = viewModel.feedback?.id else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, viewModel.feedback?.id == id else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                viewModel.feedback = nil
            }
        }
        .task {
            connectivity.activate()
            await viewModel.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchConfigurationDidChange)) { _ in
            Task { await viewModel.refresh() }
        }
        .alert(item: $viewModel.pendingCommand) { command in
            Alert(
                title: Text(command.title),
                message: Text(command.message + " 不会自动重试。"),
                primaryButton: command.isDestructive
                    ? .destructive(Text("确认执行")) {
                        Task { await viewModel.confirmPendingCommand() }
                    }
                    : .default(Text("确认执行")) {
                        Task { await viewModel.confirmPendingCommand() }
                    },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - Page 1: Vehicle Overview

    private var overviewPage: some View {
        ScrollView {
            VStack(spacing: 9) {
                if !viewModel.isConfigured && viewModel.dashboard == nil {
                    unconfiguredCard
                } else {
                    heroTelemetryBlock
                    statusPillsRow
                    if let order = viewModel.activeOrder {
                        Button {
                            WKInterfaceDevice.current().play(.click)
                            withAnimation { selectedPage = .station }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.orange)
                                Text(orderPillSummary(order))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.20), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if let errorMessage = viewModel.errorMessage ?? connectivity.lastErrorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    footerTimestamp
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .containerBackground(for: .navigation) {
            LinearGradient(
                colors: [accentColor.opacity(0.38), accentColor.opacity(0.10), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var heroTelemetryBlock: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 7.5)
                Circle()
                    .trim(from: 0, to: socFraction)
                    .stroke(
                        AngularGradient(
                            colors: [batteryRingColor.opacity(0.75), batteryRingColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.45), value: socFraction)
                VStack(spacing: 0) {
                    Text(socText)
                        .font(.system(.headline, design: .rounded, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                    if viewModel.dashboard?.isCharging == true {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
            }
            .frame(width: 66, height: 66)

            VStack(alignment: .leading, spacing: 3) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accentColor)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(rangeNumberText)
                        .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    Text("km")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let temp = viewModel.dashboard?.insideTemperature {
                    Label(String(format: "车内 %.1f℃", temp), systemImage: "thermometer.medium")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var statusPillsRow: some View {
        HStack(spacing: 6) {
            if let lockCode = viewModel.dashboard?.lockStatusCode {
                let locked = lockCode == 1
                Label(locked ? "已锁车" : "未锁车", systemImage: locked ? "lock.fill" : "lock.open.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(locked ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background((locked ? Color.green : Color.orange).opacity(0.18), in: Capsule())
            }
            if viewModel.hasControlKey {
                Button {
                    WKInterfaceDevice.current().play(.click)
                    withAnimation { selectedPage = .controls }
                } label: {
                    Label("车控", systemImage: "slider.horizontal.3")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var footerTimestamp: some View {
        HStack(spacing: 4) {
            if viewModel.isLoading {
                Text("正在更新…")
            } else if let updatedAt = viewModel.updatedAt {
                Text(viewModel.isShowingCachedData ? "缓存" : "更新于")
                Text(updatedAt, style: .time)
            } else {
                Text("向下滑动进入车控")
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private var unconfiguredCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("等待 iPhone 同步", systemImage: "iphone.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
            Text("请先在 iPhone App 中配置后端，然后点击同步。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                WKInterfaceDevice.current().play(.click)
                connectivity.requestConfiguration()
                Task { await viewModel.refresh() }
            } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Page 2: Remote Controls

    private var controlsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !viewModel.hasControlKey {
                    VStack(spacing: 6) {
                        Image(systemName: "key.slash.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("未同步车控 Key")
                            .font(.caption.weight(.semibold))
                        Text("请在 iPhone 后端设置中填入车控 Key 后重新同步。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text("轻点确认 · 长按图标直发")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: controlColumns, spacing: 7) {
                        controlTile("锁车", symbol: "lock.fill", tint: .green, command: .lock)
                        controlTile("解锁启动", symbol: "lock.open.fill", tint: .red, command: .unlockStart)
                        controlTile("开空调", symbol: "fan.fill", tint: .blue, command: .acOn)
                        controlTile("寻车", symbol: "horn.blast.fill", tint: .orange, command: .find)
                        controlTile("关空调", symbol: "fan.slash", tint: .gray, command: .acOff)
                        controlTile("停寻车", symbol: "speaker.slash.fill", tint: .gray, command: .stopFinding)
                        controlTile("开守卫", symbol: "shield.lefthalf.filled", tint: .purple, command: .guardOn)
                        controlTile("关守卫", symbol: "shield.slash", tint: .gray, command: .guardOff)
                    }
                    .disabled(viewModel.isPerformingCommand)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)
        }
        .containerBackground(for: .navigation) {
            LinearGradient(
                colors: [Color.blue.opacity(0.24), Color.purple.opacity(0.10), .black],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func controlTile(
        _ title: String,
        symbol: String,
        tint: Color,
        command: WatchDashboardViewModel.PendingCommand
    ) -> some View {
        WatchHoldToExecuteButton(
            isHoldEnabled: !viewModel.isPerformingCommand,
            onTap: {
                WKInterfaceDevice.current().play(.click)
                viewModel.pendingCommand = command
            },
            onLongPress: {
                Task { await viewModel.executeDirectly(command) }
            }
        ) { progress, isHolding, didComplete in
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16 + 0.18 * progress))
                    Circle()
                        .stroke(tint.opacity(isHolding || didComplete ? 0.24 : 0), lineWidth: 3)
                        .animation(.easeOut(duration: 0.16), value: isHolding || didComplete)
                    Circle()
                        .trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .opacity(isHolding || didComplete ? 1 : 0)
                        .animation(.easeOut(duration: 0.16), value: isHolding || didComplete)
                    Image(systemName: didComplete ? "checkmark" : symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 36, height: 36)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isHolding ? tint : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(tint.opacity(0.16 + 0.10 * progress), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(isHolding ? 0.55 : 0.28), lineWidth: 1)
            }
        }
    }

    // MARK: - Page 3: Swap Station & Active Order

    private var stationPage: some View {
        ScrollView {
            VStack(spacing: 9) {
                if let order = viewModel.activeOrder {
                    activeOrderCard(order)
                }
                stationCard
                if !viewModel.hasStation {
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        connectivity.requestConfiguration()
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("从 iPhone 同步站点", systemImage: "iphone.and.arrow.forward")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)
        }
        .containerBackground(for: .navigation) {
            LinearGradient(
                colors: [(viewModel.activeOrder != nil ? Color.orange : Color.cyan).opacity(0.30), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var stationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("当前换电站", systemImage: "bolt.car.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.cyan)
            Text(viewModel.stationName ?? (viewModel.hasStation ? "已选择换电站" : "请在 iPhone 中选择"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if viewModel.hasStation, viewModel.hasControlKey {
                Button {
                    WKInterfaceDevice.current().play(.click)
                    viewModel.pendingCommand = .createSwapOrder
                } label: {
                    Label("发起换电", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(viewModel.isPerformingCommand)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.24), lineWidth: 1)
        }
    }

    private func activeOrderCard(_ order: WatchActiveOrder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("排队中", systemImage: "clock.arrow.circlepath")
                Spacer()
                Text(order.orderStatusName ?? "进行中")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)

            Text(order.stationName ?? order.stationAddress ?? "正在确认换电站")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 6) {
                if let queue = order.queueNumber {
                    Text("#\(String(format: "%02d", queue))")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.26), in: Capsule())
                }
                if let ahead = order.vehiclesAhead {
                    Text(ahead == 0 ? "已到你" : "前 \(ahead) 辆")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((ahead <= 1 ? Color.green : Color.orange).opacity(0.26), in: Capsule())
                }
                if let wait = order.estimatedWaitMinutes {
                    Text("\(wait)分")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let text = order.queueStatusText {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 1)
        }
    }

    // MARK: - Helpers

    private var pageTitle: String {
        switch selectedPage {
        case .overview: return "我的蔚来"
        case .controls: return "远程车控"
        case .station: return "换电站"
        }
    }

    private func orderPillSummary(_ order: WatchActiveOrder) -> String {
        var parts: [String] = []
        if let queue = order.queueNumber { parts.append("换电号 \(String(format: "%02d", queue))") }
        if let ahead = order.vehiclesAhead { parts.append(ahead == 0 ? "已到你" : "前方 \(ahead) 辆") }
        if parts.isEmpty { return order.orderStatusName ?? "换电进行中" }
        return parts.joined(separator: " · ")
    }

    private var socFraction: Double {
        min(max((viewModel.dashboard?.stateOfCharge ?? 0) / 100, 0), 1)
    }

    private var socText: String {
        guard let soc = viewModel.dashboard?.stateOfCharge else { return "—" }
        return "\(Int(soc.rounded()))%"
    }

    private var rangeNumberText: String {
        guard let range = viewModel.dashboard?.remainingRange else { return "—" }
        return "\(Int(range.rounded()))"
    }

    private var statusText: String {
        guard let dashboard = viewModel.dashboard else { return "等待刷新" }
        if dashboard.isSwapping { return "正在换电" }
        if dashboard.isCharging { return "正在充电" }
        if dashboard.isDriving { return "行驶中" }
        return dashboard.isConnected ? "车辆在线" : "车辆离线"
    }

    private var statusSymbol: String {
        guard let dashboard = viewModel.dashboard else { return "arrow.clockwise" }
        if dashboard.isSwapping { return "arrow.triangle.2.circlepath" }
        if dashboard.isCharging { return "bolt.fill" }
        if dashboard.isDriving { return "car.rear.road.lane" }
        return dashboard.isConnected ? "wifi" : "wifi.slash"
    }

    private var batteryRingColor: Color {
        guard let soc = viewModel.dashboard?.stateOfCharge else { return accentColor }
        if viewModel.dashboard?.isSwapping == true { return .cyan }
        if viewModel.dashboard?.isCharging == true { return .green }
        if soc < 20 { return .red }
        if soc < 50 { return .orange }
        return .green
    }

    private var accentColor: Color {
        guard let dashboard = viewModel.dashboard else { return .secondary }
        if dashboard.isSwapping { return .cyan }
        if dashboard.isCharging { return .green }
        if dashboard.isDriving { return .blue }
        if let soc = dashboard.stateOfCharge, soc < 20 { return .red }
        return dashboard.isConnected ? .blue : .secondary
    }
}

private struct WatchHoldToExecuteButton<Content: View>: View {
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
        .buttonStyle(WatchHoldPressButtonStyle(isPressed: $isPressed))
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
                WKInterfaceDevice.current().play(.click)
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

private struct WatchHoldPressButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}
