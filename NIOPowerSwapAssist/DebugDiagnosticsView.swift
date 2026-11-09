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

struct DebugDiagnosticsView: View {
    @ObservedObject var viewModel: VehicleViewModel
    @StateObject private var network = DebugNetworkMonitor()
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
                    if let message = viewModel.debugLatestAPIError {
                        diagnosticMessage(message)
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
