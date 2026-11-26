import SwiftUI

struct TVSettingsView: View {
    @ObservedObject var viewModel: TVGarageViewModel
    let enterAmbientMode: () -> Void

    @StateObject private var pairingServer = TVPairingServer()
    @State private var baseURLString = ""
    @State private var apiKey = ""
    @State private var controlKey = ""
    @State private var formError: String?
    @State private var showingClearAlert = false

    var body: some View {
        ZStack {
            TVPalette.canvas.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 36) {
                    HStack(alignment: .top, spacing: 36) {
                        pairingCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        manualConfigCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    diagnosticsAndActionsCard
                }
                .padding(.horizontal, 72)
                .padding(.top, 34)
                .padding(.bottom, 64)
            }
        }
        .onAppear {
            syncFormFields()
            pairingServer.start { payload in
                do {
                    try viewModel.applyPairingPayload(payload)
                    syncFormFields()
                } catch {
                    formError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .onDisappear {
            pairingServer.stop()
        }
        .alert("清除全部本地配置？", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("确认清除", role: .destructive) {
                viewModel.clearConfiguration()
                syncFormFields()
            }
        } message: {
            Text("将从本机钥匙串移除后端地址、API Key、车控 Key 与已同步的常用路线。")
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("iPhone 局域网一键配对", systemImage: "iphone.and.arrow.forward")
                .font(.title3.weight(.bold))
                .foregroundStyle(TVPalette.blue)

            Text("在同 Wi-Fi 的 iPhone 上打开「车辆后端设置 → 同步到 Apple TV」，或直接用相机扫描下方二维码，即可免输入同步后端配置、换电站与常用路线。")
                .font(.callout)
                .foregroundStyle(.secondary)

            switch pairingServer.state {
            case .idle, .starting:
                HStack(spacing: 14) {
                    ProgressView()
                    Text("正在启动局域网配对服务…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)

            case .listening(let code, let host, let port):
                HStack(spacing: 28) {
                    if let qr = pairingServer.qrImage {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 210, height: 210)
                            .padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("6 位配对码")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(Self.spacedCode(code))
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("局域网地址：\(host):\(String(port))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button("刷新配对码") {
                            pairingServer.regenerateCode()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Spacer(minLength: 8)

                Label("配对码仅在当前局域网内 5 分钟有效，传输完成后自动失效", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            case .paired:
                VStack(alignment: .leading, spacing: 14) {
                    Label("已成功接收来自 iPhone 的配置", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(TVPalette.green)
                    Button("重新开启配对接收") {
                        pairingServer.regenerateCode()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 14) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(TVPalette.amber)
                    Button("重试启动配对") {
                        pairingServer.regenerateCode()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            }
        }
        .tvGlassCard(cornerRadius: 30, padding: 30, borderColor: TVPalette.blue.opacity(0.32))
    }

    private var manualConfigCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("手动配置后端", systemImage: "server.rack")
                    .font(.title3.weight(.bold))
                Text("选中输入框后可使用 iPhone 远程键盘快捷输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("后端地址").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://your-backend.example.com", text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("只读 API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureField("32 位以上只读 Key", text: $apiKey)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("车控 Key（可选，留空为只读展厅）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureField("可选车控 Key", text: $controlKey)
            }

            if let formError {
                Text(formError)
                    .font(.callout)
                    .foregroundStyle(TVPalette.red)
            }

            Button {
                do {
                    try viewModel.saveManualConfiguration(
                        baseURLString: baseURLString,
                        apiKey: apiKey,
                        controlKey: controlKey,
                        stationID: viewModel.settings?.stationID,
                        stationName: viewModel.settings?.stationName
                    )
                    formError = nil
                } catch {
                    formError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } label: {
                Label("保存并连接后端", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(TVPalette.green)
        }
        .tvGlassCard(cornerRadius: 30, padding: 30)
    }

    private var diagnosticsAndActionsCard: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("连接状态与数据摘要")
                    .font(.headline)
                Text("SSE 通道：\(viewModel.eventStreamStatus.title) · 常用路线：\(viewModel.routePresets.count) 条 · 车控 Key：\(viewModel.hasControlKey ? "已配置" : "未配置")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let lastEventName = viewModel.lastEventName, let lastEventAt = viewModel.lastEventAt {
                    Text("最近实时事件：\(lastEventName) · \(TVFormatters.dateTime(lastEventAt))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if viewModel.isConfigured {
                Button {
                    enterAmbientMode()
                } label: {
                    Label("进入展厅屏保", systemImage: "sparkles.tv")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showingClearAlert = true
                } label: {
                    Label("清除配置", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .tvGlassCard(cornerRadius: 26, padding: 26)
    }

    private func syncFormFields() {
        baseURLString = viewModel.settings?.baseURLString ?? ""
        apiKey = viewModel.settings?.apiKey ?? ""
        controlKey = viewModel.settings?.controlKey ?? ""
    }

    private static func spacedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let idx = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<idx]) \(code[idx...])"
    }
}

struct TVOnboardingView: View {
    @ObservedObject var viewModel: TVGarageViewModel
    @State private var showingManualSetup = false
    @StateObject private var pairingServer = TVPairingServer()
    @State private var pairingError: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TVPalette.blue.opacity(0.28), TVPalette.canvas, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 64) {
                VStack(alignment: .leading, spacing: 26) {
                    Label("NIO 客厅展厅", systemImage: "car.side.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TVPalette.blue)

                    Text("在大屏上实时掌握爱车与换电站")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("无需在遥控器上输入密钥。在同 Wi-Fi 的 iPhone 上打开「设置 → 同步到 Apple TV」或用相机扫右侧二维码，一秒完成安全配对。")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 20) {
                        Button {
                            showingManualSetup = true
                        } label: {
                            Label("手动输入后端地址", systemImage: "keyboard")
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            pairingServer.regenerateCode()
                        } label: {
                            Label("刷新配对码", systemImage: "arrow.clockwise")
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let pairingError {
                        Text(pairingError)
                            .font(.callout)
                            .foregroundStyle(TVPalette.red)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)

                pairingPanel
                    .frame(width: 580)
            }
            .padding(84)
        }
        .onAppear {
            pairingServer.start { payload in
                do {
                    try viewModel.applyPairingPayload(payload)
                } catch {
                    pairingError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .onDisappear {
            pairingServer.stop()
        }
        .sheet(isPresented: $showingManualSetup) {
            TVSettingsView(viewModel: viewModel, enterAmbientMode: {})
        }
    }

    private var pairingPanel: some View {
        VStack(spacing: 24) {
            switch pairingServer.state {
            case .idle, .starting:
                ProgressView()
                Text("正在准备局域网配对服务…")
                    .foregroundStyle(.secondary)
            case .listening(let code, let host, let port):
                if let qr = pairingServer.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 280, height: 280)
                        .padding(18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                Text("配对码")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("\(host):\(String(port))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            case .paired:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(TVPalette.green)
                Text("配对成功，正在进入展厅…")
                    .font(.title3.weight(.semibold))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(TVPalette.amber)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 520)
        .tvGlassCard(cornerRadius: 36, padding: 36, borderColor: TVPalette.blue.opacity(0.35))
    }
}
