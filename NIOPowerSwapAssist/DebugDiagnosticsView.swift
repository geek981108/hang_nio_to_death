import Network
import SwiftUI
import UIKit

@MainActor
final class DebugNetworkMonitor: ObservableObject {
    @Published private(set) var status = "检测中"
    @Published private(set) var interface = "—"
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var supportsIPv4 = false
    @Published private(set) var supportsIPv6 = false
    @Published private(set) var supportsDNS = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.shuto.happyvalley.debug-network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = switch path.status {
                case .satisfied: "可用"
                case .requiresConnection: "等待连接"
                case .unsatisfied: "不可用"
                @unknown default: "未知"
                }
                self.interface = Self.interfaceName(path)
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
                self.supportsIPv4 = path.supportsIPv4
                self.supportsIPv6 = path.supportsIPv6
                self.supportsDNS = path.supportsDNS
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private nonisolated static func interfaceName(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return "蜂窝网络" }
        if path.usesInterfaceType(.wiredEthernet) { return "有线网络" }
        if path.usesInterfaceType(.loopback) { return "本机回环" }
        if path.usesInterfaceType(.other) { return "其他" }
        return "—"
    }
}

@MainActor
final class DebugLiveActivityPushTester: ObservableObject {
    @Published var mode: LiveActivitySimulationMode = .charging
    @Published var intervalSeconds: Int = 5
    @Published var steps: Int = 6
    @Published private(set) var pushStatus: LiveActivityPushStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var errorMessage: String?

    private var pollTask: Task<Void, Never>?

    deinit {
        pollTask?.cancel()
    }

    var isBackendSimulationRunning: Bool {
        pushStatus?.simulation?.running == true
    }

    func refreshStatus() async {
        guard let config = try? BackendSettingsStore.shared.configuration() else {
            pushStatus = nil
            return
        }
        let client = BackendClient(configuration: config)
        do {
            let status = try await client.fetchLiveActivityPushStatus()
            pushStatus = status
            if status.simulation?.running == true {
                startPollingIfNeeded()
            } else {
                stopPolling()
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func syncTokensAndRefresh() async {
        isBusy = true
        errorMessage = nil
        feedbackMessage = nil
        defer { isBusy = false }

        await VehicleLiveActivityManager.shared.syncRegisteredTokensIfNeeded(force: true)
        await refreshStatus()
        if let uploadError = VehicleLiveActivityManager.shared.lastTokenUploadError {
            errorMessage = "本机令牌上传失败：\(uploadError)"
        } else if !VehicleLiveActivityManager.shared.hasPushToStartToken {
            feedbackMessage = "已刷新后端状态；本机尚未拿到 pushToStartToken（请使用真机运行并开启实时活动权限）。"
        } else {
            feedbackMessage = "本机 Push-to-Start / 活动更新令牌已同步至后端。"
        }
    }

    func startBackendSimulation() async {
        guard let config = try? BackendSettingsStore.shared.configuration() else {
            errorMessage = "请先配置后端地址与 API Key。"
            return
        }
        isBusy = true
        errorMessage = nil
        feedbackMessage = nil
        defer { isBusy = false }

        // Ensure the latest pushToStart / update token is registered before asking Rust to push.
        await VehicleLiveActivityManager.shared.syncRegisteredTokensIfNeeded(force: true)
        let client = BackendClient(configuration: config)
        do {
            let request = LiveActivitySimulationRequest(
                mode: mode,
                intervalSeconds: intervalSeconds,
                steps: steps,
                deviceID: VehicleLiveActivityManager.shared.deviceID
            )
            let outcome = try await client.startLiveActivitySimulation(request)
            let delivered = outcome.startDelivered + outcome.updateDelivered
            let targeted = outcome.startTokensTargeted + outcome.updateTokensTargeted
            if delivered > 0 {
                feedbackMessage = "后端已投递初始推送（\(delivered)/\(targeted)），接下来每 \(outcome.intervalSeconds) 秒自动推送 1 次更新，共 \(outcome.totalSteps) 步后自动结束。可立即切回桌面或锁屏观察灵动岛变化。"
            } else {
                errorMessage = "模拟任务已创建，但初始 APNs 推送投递数为 0/\(targeted)，请检查后端 APNs 日志与沙盒/生产环境配置。"
            }
            await refreshStatus()
            startPollingIfNeeded()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await refreshStatus()
        }
    }

    func stopBackendSimulation() async {
        guard let config = try? BackendSettingsStore.shared.configuration() else {
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        stopPolling()
        let client = BackendClient(configuration: config)
        do {
            let outcome = try await client.stopLiveActivitySimulation(
                deviceID: VehicleLiveActivityManager.shared.deviceID
            )
            feedbackMessage = outcome.stopped
                ? "已停止后端模拟推送，并向 \(outcome.endDelivered)/\(outcome.endedTokens) 个活动发送 APNs end。"
                : "当前没有运行中的后端模拟推送。"
            await refreshStatus()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { break }
                guard let config = try? BackendSettingsStore.shared.configuration() else { break }
                let client = BackendClient(configuration: config)
                if let status = try? await client.fetchLiveActivityPushStatus() {
                    self.pushStatus = status
                    if status.simulation?.running != true {
                        self.feedbackMessage = "后端模拟推送已自动完成并发送 end。"
                        break
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.pollTask = nil
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

struct DebugDiagnosticsView: View {
    @ObservedObject var viewModel: VehicleViewModel
    @StateObject private var network = DebugNetworkMonitor()
    @StateObject private var pushTester = DebugLiveActivityPushTester()
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("网络") {
                    statusRow("网络状态", value: network.status, healthy: network.status == "可用")
                    valueRow("当前通道", network.interface)
                    valueRow("低数据模式", network.isConstrained ? "是" : "否")
                    valueRow("计费/热点网络", network.isExpensive ? "是" : "否")
                    valueRow("协议能力", protocolSummary)
                }

                if TemporaryBackendTLS.isEnabled {
                    Section("安全警告") {
                        Label("后端 TLS 证书校验已临时关闭", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                        Text("仅对当前配置的后端主机生效；其他域名仍使用系统证书校验。修复服务器证书后应立即关闭此兼容模式。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("SSE 实时通讯") {
                    statusRow(
                        "连接状态",
                        value: viewModel.eventStreamStatus.title,
                        healthy: viewModel.eventStreamStatus == .connected
                    )
                    valueRow("最近事件", viewModel.lastEventStreamEventName ?? "—")
                    valueRow("事件游标", viewModel.lastEventStreamEventID ?? "—")
                    dateRow("事件时间", viewModel.lastEventStreamEventAt)
                    valueRow("连续重连", "\(viewModel.eventStreamReconnectAttempt) 次")
                    if let message = viewModel.lastEventStreamError {
                        diagnosticMessage(message)
                    }
                }

                Section("REST 与数据") {
                    statusRow("后端配置", value: viewModel.isConfigured ? "已配置" : "未配置", healthy: viewModel.isConfigured)
                    valueRow("后端地址", viewModel.debugBaseURLString)
                    dateRow("最近实时刷新", viewModel.lastLiveDataRefreshAt)
                    dateRow("Dashboard 时间", viewModel.lastDashboardRefreshAt)
                    valueRow("当前数据来源", viewModel.isShowingCachedDashboard ? "本地缓存" : "网络响应")
                    valueRow("活动订单", "\(viewModel.activeServiceOrders.count) 条")
                    valueRow("车辆连接", vehicleConnectionSummary)
                    valueRow("特殊状态", specialStatusSummary)
                    if let message = viewModel.debugLatestAPIError {
                        diagnosticMessage(message)
                    }
                }

                Section("灵动岛与实时活动（Rust APNs 模拟推送）") {
                    statusRow(
                        "实时活动系统权限",
                        value: VehicleLiveActivityManager.shared.areActivitiesEnabled ? "已开启" : "未开启",
                        healthy: VehicleLiveActivityManager.shared.areActivitiesEnabled
                    )
                    statusRow(
                        "本机 Push-to-Start 令牌",
                        value: VehicleLiveActivityManager.shared.hasPushToStartToken
                            ? "已获取 (\(VehicleLiveActivityManager.currentAPNsEnvironment.rawValue))"
                            : "等待系统下发（需真机）",
                        healthy: VehicleLiveActivityManager.shared.hasPushToStartToken
                    )
                    valueRow(
                        "本机活动 / 更新令牌",
                        "\(VehicleLiveActivityManager.shared.activeActivityCount) 个活动 · \(VehicleLiveActivityManager.shared.activeActivityPushTokenCount) 个更新令牌"
                    )
                    if let status = pushTester.pushStatus {
                        statusRow(
                            "后端 APNs 通道",
                            value: status.apnsConfigured
                                ? "已配置 (\(status.defaultEnvironment?.rawValue ?? "—"))"
                                : "未配置",
                            healthy: status.apnsConfigured
                        )
                        valueRow(
                            "后端已登记令牌",
                            "Start \(status.pushToStartTokenCount) · Update \(status.activityUpdateTokenCount)"
                        )
                        if let sim = status.simulation {
                            statusRow(
                                "后端模拟推送状态",
                                value: sim.running
                                    ? "运行中 · 第 \(sim.currentStep + 1)/\(sim.totalSteps + 1) 步 (\(sim.lastEvent ?? "start"))"
                                    : "已结束 (\(sim.lastEvent ?? "end"))",
                                healthy: sim.running || sim.lastError == nil
                            )
                            valueRow("最近投递成功数", "\(sim.lastDeliveredCount)")
                            if let simError = sim.lastError {
                                diagnosticMessage(simError)
                            }
                        }
                    } else if viewModel.isConfigured {
                        valueRow("后端 APNs 状态", "读取中…")
                    }

                    Picker("模拟场景", selection: $pushTester.mode) {
                        ForEach(LiveActivitySimulationMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("推送间隔", selection: $pushTester.intervalSeconds) {
                        Text("5 秒").tag(5)
                        Text("8 秒").tag(8)
                        Text("12 秒").tag(12)
                    }

                    Button {
                        Task { await pushTester.startBackendSimulation() }
                    } label: {
                        HStack {
                            Label(
                                pushTester.isBackendSimulationRunning
                                    ? "重新开启后端模拟推送"
                                    : "开启 Rust 后端模拟推送",
                                systemImage: "paperplane.circle.fill"
                            )
                            Spacer()
                            if pushTester.isBusy {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!viewModel.isConfigured || pushTester.isBusy)

                    Button(role: .destructive) {
                        Task { await pushTester.stopBackendSimulation() }
                    } label: {
                        Label("停止后端模拟推送（发送 End）", systemImage: "stop.circle")
                    }
                    .disabled(!viewModel.isConfigured || pushTester.isBusy)

                    Button {
                        Task { await pushTester.syncTokensAndRefresh() }
                    } label: {
                        Label("同步本机令牌并刷新 APNs 状态", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!viewModel.isConfigured || pushTester.isBusy)

                    #if DEBUG
                    HStack(spacing: 10) {
                        Button("本地预览充电") {
                            Task { await VehicleLiveActivityManager.shared.applyDebugSimulation(.charging) }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("本地预览换电") {
                            Task { await VehicleLiveActivityManager.shared.applyDebugSimulation(.swap) }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        Button("清除本地") {
                            Task { await VehicleLiveActivityManager.shared.applyDebugSimulation(.end) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .font(.caption)
                    }
                    #endif

                    if let uploadError = VehicleLiveActivityManager.shared.lastTokenUploadError {
                        diagnosticMessage("令牌上传异常：\(uploadError)")
                    }
                    if let errorMessage = pushTester.errorMessage {
                        diagnosticMessage(errorMessage)
                    }
                    if let feedback = pushTester.feedbackMessage {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("App") {
                    valueRow("版本", appVersion)
                    valueRow("系统", "iOS \(UIDevice.current.systemVersion)")
                    valueRow("设备", UIDevice.current.model)
                    valueRow("车控配置", viewModel.isVehicleControlConfigured ? "已配置" : "未配置")
                }

                Section {
                    Button {
                        Task { await viewModel.refreshLiveData() }
                    } label: {
                        Label("立即执行只读刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(!viewModel.isConfigured)
                } footer: {
                    Text("此页面不会显示 API Key、车控密钥或完整服务端响应，也不会执行车控、下单或签到操作。")
                }
            }
            .navigationTitle("Debug 诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await pushTester.refreshStatus()
            }
            .onDisappear {
                pushTester.stopPolling()
            }
        }
    }

    private var protocolSummary: String {
        [
            network.supportsIPv4 ? "IPv4" : nil,
            network.supportsIPv6 ? "IPv6" : nil,
            network.supportsDNS ? "DNS" : nil
        ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—"
    }

    private var vehicleConnectionSummary: String {
        guard let dashboard = viewModel.dashboard else { return "暂无数据" }
        return dashboard.isConnected ? "在线" : "离线"
    }

    private var specialStatusSummary: String {
        guard let dashboard = viewModel.dashboard else { return "暂无数据" }
        let flags = [
            dashboard.isSVTActive ? "svt=1" : nil,
            dashboard.isRepairing ? "repairing=1" : nil,
            dashboard.isFotaActive ? "fota=\(dashboard.fotaStatusCode ?? 1)" : nil,
            dashboard.isSwapping ? "swapping=1" : nil
        ].compactMap { $0 }
        let rawSummary = dashboard.rawSpecialStatusFields
            .map { fields in
                fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: ", ")
            }
        if flags.isEmpty {
            if let rawSummary, !rawSummary.isEmpty {
                return "正常（\(rawSummary)）"
            }
            return "正常（无特殊工况）"
        }
        if let rawSummary, !rawSummary.isEmpty {
            return "\(flags.joined(separator: " · ")) [\(rawSummary)]"
        }
        return flags.joined(separator: " · ")
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func dateRow(_ title: String, _ date: Date?) -> some View {
        LabeledContent(title) {
            if let date {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(date, format: .dateTime.month().day().hour().minute().second())
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ title: String, value: String, healthy: Bool) -> some View {
        LabeledContent(title) {
            Label(value, systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(healthy ? .green : .orange)
        }
    }

    private func diagnosticMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption.monospaced())
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
