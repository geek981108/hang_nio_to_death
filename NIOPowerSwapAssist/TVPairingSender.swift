import Foundation
import Network
import SwiftUI

struct DiscoveredAppleTV: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let lanHost: String?
    let lanPort: UInt16?

    var preferredEndpoint: NWEndpoint {
        if let lanHost, !lanHost.isEmpty,
           let lanPort, lanPort > 0,
           let nwPort = NWEndpoint.Port(rawValue: lanPort) {
            return .hostPort(host: NWEndpoint.Host(lanHost), port: nwPort)
        }
        return endpoint
    }

    var addressSummary: String {
        if let lanHost, !lanHost.isEmpty, let lanPort, lanPort > 0 {
            return "\(lanHost):\(String(lanPort))"
        }
        return "同局域网 Bonjour 服务"
    }

    static func == (lhs: DiscoveredAppleTV, rhs: DiscoveredAppleTV) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.lanHost == rhs.lanHost && lhs.lanPort == rhs.lanPort
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(lanHost)
        hasher.combine(lanPort)
    }
}

@MainActor
final class AppleTVDiscoveryBrowser: ObservableObject {
    @Published private(set) var devices: [DiscoveredAppleTV] = []
    @Published private(set) var isSearching = false
    @Published private(set) var discoveryError: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.shuto.happyvalley.tv.browser")

    func start() {
        stop()
        discoveryError = nil
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: TVPairingConstants.bonjourType, domain: TVPairingConstants.bonjourDomain),
            using: params
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                    self.discoveryError = nil
                case .waiting(let error):
                    self.isSearching = true
                    if Self.isLocalNetworkPermissionDenied(error) {
                        self.discoveryError = "请前往系统「设置 → 隐私与安全性 → 本地网络」允许本 App 访问局域网。"
                    }
                case .failed(let error):
                    self.isSearching = false
                    self.discoveryError = "局域网扫描失败：\(error.localizedDescription)"
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [DiscoveredAppleTV] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var lanHost: String?
                var lanPort: UInt16?
                if case .bonjour(let txt) = result.metadata {
                    lanHost = txt["host"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let rawPort = txt["port"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let parsedPort = UInt16(rawPort), parsedPort > 0 {
                        lanPort = parsedPort
                    }
                }
                return DiscoveredAppleTV(
                    id: name,
                    name: name,
                    endpoint: result.endpoint,
                    lanHost: lanHost,
                    lanPort: lanPort
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                self?.devices = list
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private nonisolated static func isLocalNetworkPermissionDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
            return true
        }
        if case .posix(let code) = error, code == .EPERM || code == .EACCES {
            return true
        }
        return false
    }
}

enum AppleTVPairingSenderError: LocalizedError {
    case backendNotConfigured
    case invalidEndpoint
    case invalidPairingCode
    case rejected(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "请先在 iPhone 端配置并保存后端地址与 API Key。"
        case .invalidEndpoint:
            return "请先选择发现的 Apple TV，或展开下方手动输入局域网 IP 与端口。"
        case .invalidPairingCode:
            return "请输入 Apple TV 屏幕上显示的 6 位数字配对码。"
        case .rejected(let message):
            return message
        case .network(let message):
            return "连接 Apple TV 失败：\(message)"
        }
    }
}

enum AppleTVPairingSender {
    static func send(
        envelope: TVPairingEnvelope,
        to endpoint: NWEndpoint
    ) async throws {
        let normalizedCode = TVPairingEndpoint.normalizePairingCode(envelope.code)
        guard TVPairingEndpoint.isValidPairingCode(normalizedCode) else {
            throw AppleTVPairingSenderError.invalidPairingCode
        }
        let normalizedEnvelope = TVPairingEnvelope(code: normalizedCode, payload: envelope.payload)
        let body = try JSONEncoder().encode(normalizedEnvelope)
        let header = "POST /pair HTTP/1.1\r\n"
            + "Host: apple-tv.local\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var wireBytes = Data(header.utf8)
        wireBytes.append(body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.shuto.happyvalley.tv.pair-sender")
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let connection = NWConnection(to: endpoint, using: params)
            let gate = PairingContinuationGate(continuation: continuation)
            var didSend = false

            let timeout = DispatchWorkItem {
                connection.cancel()
                gate.resume(throwing: AppleTVPairingSenderError.network("连接超时，请确认手机与 Apple TV 在同一 Wi-Fi，且电视停留在配对页面。"))
            }
            queue.asyncAfter(deadline: .now() + 12, execute: timeout)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didSend else { return }
                    didSend = true
                    connection.send(content: wireBytes, completion: .contentProcessed { sendError in
                        if let sendError {
                            timeout.cancel()
                            connection.cancel()
                            gate.resume(throwing: AppleTVPairingSenderError.network(sendError.localizedDescription))
                            return
                        }
                        Self.readResponse(on: connection, buffer: Data(), timeout: timeout, gate: gate)
                    })
                case .failed(let error):
                    timeout.cancel()
                    connection.cancel()
                    gate.resume(throwing: AppleTVPairingSenderError.network(error.localizedDescription))
                case .waiting(let error):
                    // Bonjour (.service) endpoints frequently enter `.waiting` briefly during mDNS resolution.
                    // Only abort early if local-network access is explicitly denied; otherwise let it resolve or time out.
                    if case .dns(let dnsCode) = error, dnsCode == kDNSServiceErr_PolicyDenied {
                        timeout.cancel()
                        connection.cancel()
                        gate.resume(throwing: AppleTVPairingSenderError.network("未获得本地网络权限，请在系统设置中开启后重试。"))
                    } else if case .posix(let code) = error, code == .EPERM || code == .EACCES {
                        timeout.cancel()
                        connection.cancel()
                        gate.resume(throwing: AppleTVPairingSenderError.network("未获得本地网络权限，请在系统设置中开启后重试。"))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func readResponse(
        on connection: NWConnection,
        buffer: Data,
        timeout: DispatchWorkItem,
        gate: PairingContinuationGate
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let error {
                timeout.cancel()
                connection.cancel()
                gate.resume(throwing: AppleTVPairingSenderError.network(error.localizedDescription))
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if isComplete || accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                timeout.cancel()
                connection.cancel()
                let text = String(data: accumulated, encoding: .utf8) ?? ""
                if text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200") {
                    gate.resume(returning: ())
                } else if text.contains("403") {
                    gate.resume(throwing: AppleTVPairingSenderError.rejected("配对码不正确，请核对 Apple TV 上的 6 位数字。"))
                } else if text.contains("410") {
                    gate.resume(throwing: AppleTVPairingSenderError.rejected("Apple TV 配对窗口已关闭，请在电视端重新打开配对页面。"))
                } else {
                    gate.resume(throwing: AppleTVPairingSenderError.rejected("Apple TV 拒绝了配对请求，请重试。"))
                }
            } else {
                readResponse(on: connection, buffer: accumulated, timeout: timeout, gate: gate)
            }
        }
    }
}

private final class PairingContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

struct AppleTVPairingSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VehicleViewModel
    let initialEndpoint: TVPairingEndpoint?

    @StateObject private var browser = AppleTVDiscoveryBrowser()
    @State private var selectedDevice: DiscoveredAppleTV?
    @State private var manualHost: String
    @State private var manualPort: String
    @State private var pairingCode: String
    @State private var showingManualAddress: Bool
    @State private var includeControlKey = false
    @State private var includeStation = true
    @State private var includeRoutePresets = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @FocusState private var isCodeFieldFocused: Bool

    private let savedPresetsCount: Int

    init(
        isPresented: Binding<Bool>,
        viewModel: VehicleViewModel,
        initialEndpoint: TVPairingEndpoint? = nil
    ) {
        _isPresented = isPresented
        self.viewModel = viewModel
        self.initialEndpoint = initialEndpoint
        _manualHost = State(initialValue: initialEndpoint?.host ?? "")
        _manualPort = State(initialValue: initialEndpoint.map { String($0.port) } ?? "")
        _pairingCode = State(initialValue: initialEndpoint?.code ?? "")
        _showingManualAddress = State(initialValue: initialEndpoint != nil)
        self.savedPresetsCount = SavedRouteStore().loadPresets().count
    }

    private var normalizedCode: String {
        TVPairingEndpoint.normalizePairingCode(pairingCode)
    }

    private var hasValidManualAddress: Bool {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              let port = UInt16(manualPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else {
            return false
        }
        return true
    }

    private var hasTargetDevice: Bool {
        selectedDevice != nil || hasValidManualAddress
    }

    private var isReadyToSend: Bool {
        viewModel.isConfigured && hasTargetDevice && TVPairingEndpoint.isValidPairingCode(normalizedCode)
    }

    var body: some View {
        NavigationStack {
            List {
                if let initialEndpoint {
                    Section("扫码识别的 Apple TV") {
                        Label(
                            initialEndpoint.tvName?.isEmpty == false
                                ? "\(initialEndpoint.tvName!) (\(initialEndpoint.host):\(String(initialEndpoint.port)))"
                                : "\(initialEndpoint.host):\(String(initialEndpoint.port))",
                            systemImage: "appletv.fill"
                        )
                        .foregroundStyle(AppPalette.blue)
                    }
                }

                Section {
                    if let discoveryError = browser.discoveryError {
                        Label(discoveryError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppPalette.amber)
                    }
                    if browser.devices.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在扫描同一 Wi-Fi 下的 Apple TV…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(browser.devices) { device in
                            let isSelected = selectedDevice?.id == device.id
                            Button {
                                selectedDevice = device
                                errorMessage = nil
                                successMessage = nil
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "appletv.fill")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? AppPalette.blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(device.addressSummary)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppPalette.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text("局域网发现的 Apple TV")
                        Spacer()
                        Button("重新扫描") {
                            browser.start()
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                } footer: {
                    Text("请先在 Apple TV 上打开「NIO 展厅 → 设置」让电视进入配对等待状态。")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(AppPalette.blue)
                        TextField("输入电视端 6 位配对码（如 525688）", text: $pairingCode)
                            .keyboardType(.numberPad)
                            .font(.body.monospacedDigit())
                            .focused($isCodeFieldFocused)
                            .onChange(of: pairingCode) { _, newValue in
                                let cleaned = TVPairingEndpoint.normalizePairingCode(newValue)
                                if cleaned != newValue {
                                    pairingCode = cleaned
                                }
                                if errorMessage != nil {
                                    errorMessage = nil
                                }
                            }
                        if !pairingCode.isEmpty {
                            Text("\(normalizedCode.count)/6")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(normalizedCode.count == 6 ? AppPalette.green : .secondary)
                        }
                    }
                } header: {
                    Text("电视配对码（必填）")
                } footer: {
                    Text("直接输入电视屏幕显示的 6 位数字，系统会自动忽略空格。")
                }

                Section {
                    DisclosureGroup("手动输入局域网 IP 与端口（可选）", isExpanded: $showingManualAddress) {
                        TextField("Apple TV 局域网 IP（如 192.168.1.211）", text: $manualHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: manualHost) { _, newValue in
                                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    selectedDevice = nil
                                }
                            }
                        TextField("端口（显示在电视端）", text: $manualPort)
                            .keyboardType(.numberPad)
                            .onChange(of: manualPort) { _, newValue in
                                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    selectedDevice = nil
                                }
                            }
                    }
                }

                Section("同步内容") {
                    Toggle("同步当前选择的换电站", isOn: $includeStation)
                    if savedPresetsCount > 0 {
                        Toggle("同步常用路线（\(savedPresetsCount) 条）", isOn: $includeRoutePresets)
                    }
                    if viewModel.isVehicleControlConfigured {
                        Toggle("同时同步车控 Key（用于电视端开空调/守卫/寻车）", isOn: $includeControlKey)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppPalette.red)
                            .font(.footnote)
                    }
                }

                if let successMessage {
                    Section {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppPalette.green)
                            .font(.subheadline.weight(.semibold))
                    }
                }

                Section {
                    Button {
                        isCodeFieldFocused = false
                        Task { await sendNow() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSending {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("正在同步至 Apple TV…")
                                    .fontWeight(.semibold)
                            } else {
                                Label("一键同步到 Apple TV", systemImage: "paperplane.fill")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(isReadyToSend ? AppPalette.blue : .secondary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSending)
                } footer: {
                    if !isReadyToSend {
                        Text(missingRequirementHint)
                            .foregroundStyle(AppPalette.amber)
                    }
                }
            }
            .navigationTitle("同步到 Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
            }
            .onAppear {
                browser.start()
            }
            .onDisappear {
                browser.stop()
            }
            .onChange(of: browser.devices) { _, devices in
                if let current = selectedDevice {
                    if let updated = devices.first(where: { $0.id == current.id }) {
                        selectedDevice = updated
                    } else if !hasValidManualAddress {
                        selectedDevice = devices.first
                    }
                } else if !hasValidManualAddress, let first = devices.first {
                    selectedDevice = first
                }
            }
        }
    }

    private var missingRequirementHint: String {
        if !viewModel.isConfigured {
            return "请先在 iPhone 端配置并保存后端地址与 API Key。"
        }
        if !hasTargetDevice {
            return "请等待发现 Apple TV，或展开上方手动输入 IP 与端口。"
        }
        if !TVPairingEndpoint.isValidPairingCode(normalizedCode) {
            return "请输入 Apple TV 屏幕上显示的 6 位数字配对码后即可一键同步。"
        }
        return ""
    }

    private func sendNow() async {
        errorMessage = nil
        successMessage = nil

        guard viewModel.isConfigured else {
            errorMessage = AppleTVPairingSenderError.backendNotConfigured.errorDescription
            return
        }

        let targetEndpoint: NWEndpoint
        if let selectedDevice {
            targetEndpoint = selectedDevice.preferredEndpoint
        } else if let portValue = UInt16(manualPort.trimmingCharacters(in: .whitespacesAndNewlines)),
                  portValue > 0,
                  let nwPort = NWEndpoint.Port(rawValue: portValue),
                  !manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetEndpoint = .hostPort(
                host: NWEndpoint.Host(manualHost.trimmingCharacters(in: .whitespacesAndNewlines)),
                port: nwPort
            )
        } else {
            errorMessage = AppleTVPairingSenderError.invalidEndpoint.errorDescription
            return
        }

        let code = normalizedCode
        guard TVPairingEndpoint.isValidPairingCode(code) else {
            errorMessage = AppleTVPairingSenderError.invalidPairingCode.errorDescription
            isCodeFieldFocused = true
            return
        }

        let watchConfig = BackendSettingsStore.shared.watchConfiguration()
        let presets: [TVPairingRoutePreset]? = includeRoutePresets
            ? SavedRouteStore().loadPresets().map { preset in
                TVPairingRoutePreset(
                    id: preset.id,
                    name: preset.name,
                    customOrigin: preset.customOrigin,
                    waypoints: preset.waypoints,
                    destination: preset.destination,
                    enableEnergyPlanning: preset.enableEnergyPlanning,
                    preferredPlanTag: preset.preferredPlanTag
                )
            }
            : nil

        let payload = TVPairingPayload(
            baseURLString: watchConfig.baseURLString,
            apiKey: watchConfig.apiKey,
            controlKey: includeControlKey ? watchConfig.controlKey : nil,
            stationID: includeStation ? watchConfig.stationID : nil,
            stationName: includeStation ? watchConfig.stationName : nil,
            routePresets: presets
        )
        let envelope = TVPairingEnvelope(code: code, payload: payload)

        isSending = true
        defer { isSending = false }
        do {
            try await AppleTVPairingSender.send(envelope: envelope, to: targetEndpoint)
            successMessage = "已成功将配置同步至 Apple TV！"
        } catch {
            // If direct LAN IP from TXT failed, retry once via Bonjour `.service` endpoint in case host IP changed.
            if let selectedDevice, selectedDevice.lanHost != nil {
                do {
                    try await AppleTVPairingSender.send(envelope: envelope, to: selectedDevice.endpoint)
                    successMessage = "已成功将配置同步至 Apple TV！"
                    return
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    return
                }
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
