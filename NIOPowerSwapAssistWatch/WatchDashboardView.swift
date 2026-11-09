import SwiftUI

struct WatchDashboardView: View {
    @StateObject private var viewModel = WatchDashboardViewModel()
    @StateObject private var connectivity = WatchConnectivityCoordinator.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    vehicleStatusCard
                    stationCard
                    if let order = viewModel.activeOrder {
                        activeOrderCard(order)
                    }
                    controlSection
                    messageSection
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
            }
            .navigationTitle("NIO PS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.isPerformingCommand)
                    .accessibilityLabel("刷新车辆状态")
                }
            }
            .refreshable { await viewModel.refresh() }
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
                primaryButton: command == .unlockDoors || command == .createSwapOrder
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

    private var vehicleStatusCard: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: min(max((viewModel.dashboard?.stateOfCharge ?? 0) / 100, 0), 1))
                        .stroke(statusColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(socText)
                        .font(.headline.monospacedDigit())
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                    Text(rangeText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    if let updatedAt = viewModel.updatedAt {
                        Text(updatedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var stationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("当前换电站", systemImage: "bolt.car.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
            Text(viewModel.stationName ?? (viewModel.hasStation ? "已选择换电站" : "请在 iPhone 中选择"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if viewModel.hasStation, viewModel.hasControlKey {
                Button {
                    viewModel.pendingCommand = .createSwapOrder
                } label: {
                    Label("发起换电", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(viewModel.isPerformingCommand)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private func activeOrderCard(_ order: WatchActiveOrder) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("换电进行中", systemImage: "clock.arrow.circlepath")
                Spacer()
                Text(order.orderStatusName ?? "进行中")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            Text(order.stationName ?? order.stationAddress ?? "正在确认换电站")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let text = order.queueStatusText {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let queue = order.queueNumber { Text("换电号 \(queue)") }
                if let ahead = order.vehiclesAhead { Text(ahead == 0 ? "已到你" : "前方 \(ahead) 辆") }
                if let wait = order.estimatedWaitMinutes { Text("约 \(wait) 分钟") }
            }
            .font(.caption2.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("远程车控")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                controlButton("寻车", symbol: "car.side.lock", command: .find)
                controlButton("停止", symbol: "stop.fill", command: .stopFinding)
            }
            controlButton("解锁车门", symbol: "lock.open.fill", command: .unlockDoors, tint: .red)
        }
        .disabled(!viewModel.hasControlKey || viewModel.isPerformingCommand)
    }

    private func controlButton(
        _ title: String,
        symbol: String,
        command: WatchDashboardViewModel.PendingCommand,
        tint: Color = .blue
    ) -> some View {
        Button {
            viewModel.pendingCommand = command
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    @ViewBuilder
    private var messageSection: some View {
        if let actionMessage = viewModel.actionMessage {
            Text(actionMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let errorMessage = viewModel.errorMessage ?? connectivity.lastErrorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !viewModel.hasControlKey {
            Text("车控 Key 未同步，远程操作已关闭。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var socText: String {
        guard let soc = viewModel.dashboard?.stateOfCharge else { return "—" }
        return "\(Int(soc.rounded()))%"
    }

    private var rangeText: String {
        guard let range = viewModel.dashboard?.remainingRange else { return "— km" }
        return "\(Int(range.rounded())) km"
    }

    private var statusText: String {
        guard let dashboard = viewModel.dashboard else { return "等待刷新" }
        if dashboard.isSwapping { return "正在换电" }
        if dashboard.isCharging { return "正在充电" }
        return dashboard.isConnected ? "车辆在线" : "车辆离线"
    }

    private var statusSymbol: String {
        guard let dashboard = viewModel.dashboard else { return "arrow.clockwise" }
        if dashboard.isSwapping { return "arrow.triangle.2.circlepath" }
        if dashboard.isCharging { return "bolt.fill" }
        return dashboard.isConnected ? "wifi" : "wifi.slash"
    }

    private var statusColor: Color {
        guard let dashboard = viewModel.dashboard else { return .secondary }
        if dashboard.isSwapping { return .cyan }
        if dashboard.isCharging { return .green }
        return dashboard.isConnected ? .blue : .secondary
    }
}

extension WatchDashboardViewModel.PendingCommand: Equatable {}
