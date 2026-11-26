import SwiftUI

struct BackendSettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VehicleViewModel
    @State private var baseURLString: String
    @State private var apiKey: String
    @State private var controlKey: String
    @State private var revealAPIKey = false
    @State private var revealControlKey = false
    @State private var errorMessage: String?
    @State private var batteryFilter: String
    @State private var showingNIOLogin = false
    @State private var showingAppleTVPairing = false
    @State private var feedbackTick = 0

    private let filterColumns = [
        GridItem(.adaptive(minimum: 84), spacing: 8)
    ]

    init(isPresented: Binding<Bool>, viewModel: VehicleViewModel) {
        _isPresented = isPresented
        self.viewModel = viewModel
        _baseURLString = State(initialValue: viewModel.baseURLString)
        _apiKey = State(initialValue: viewModel.savedAPIKey)
        _controlKey = State(initialValue: viewModel.savedControlKey)
        _batteryFilter = State(initialValue: StationViewModel.preferredBatteryTypeSetting)
    }

    private var trimmedURL: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedControlKey: String {
        controlKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedURL.isEmpty && !trimmedAPIKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionStatusCard
                    backendConfigCard
                    if viewModel.isConfigured {
                        nioAccountCard
                        appleTVSyncCard
                    }
                    stationPreferencesCard
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppPalette.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomSaveBar
            }
            .navigationTitle("车辆后端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
            }
            .sensoryFeedback(.selection, trigger: feedbackTick)
            .sheet(isPresented: $showingNIOLogin) {
                NIOLoginView(
                    isPresented: $showingNIOLogin,
                    viewModel: viewModel,
                    openSettings: nil
                )
            }
            .sheet(isPresented: $showingAppleTVPairing) {
                AppleTVPairingSheet(
                    isPresented: $showingAppleTVPairing,
                    viewModel: viewModel
                )
            }
        }
    }

    private var appleTVSyncCard: some View {
        Button {
            feedbackTick += 1
            showingAppleTVPairing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppPalette.blue)
                    .frame(width: 40, height: 40)
                    .background(AppPalette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("同步配置到 Apple TV")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("局域网一键推送后端密钥、常用换电站与常用路线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .nioCard(cornerRadius: 20, padding: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connection Status Hero

    private var connectionStatusCard: some View {
        let stateColor: Color = {
            if !viewModel.isConfigured { return AppPalette.graphite }
            if viewModel.needsBackendLogin { return AppPalette.amber }
            return AppPalette.green
        }()
        let titleText: String = {
            if !viewModel.isConfigured { return "尚未连接后端" }
            if viewModel.needsBackendLogin { return "等待蔚来账号登录" }
            return "后端已就绪"
        }()

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: viewModel.isConfigured ? "server.rack" : "externaldrive.badge.plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .frame(width: 44, height: 44)
                    .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(stateColor.opacity(0.20), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        LivePulseDot(
                            color: stateColor,
                            size: 7,
                            isPulsing: viewModel.isConfigured && !viewModel.needsBackendLogin
                        )
                        Text(titleText)
                            .font(.headline)
                    }
                    Text(viewModel.isConfigured ? viewModel.debugBaseURLString : "填入自建 Actix 后端地址与 API Key")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                statusPill(
                    title: "车辆凭证",
                    value: !viewModel.isConfigured
                        ? "未配置"
                        : (viewModel.needsBackendLogin ? "待登录" : "正常"),
                    color: !viewModel.isConfigured
                        ? .secondary
                        : (viewModel.needsBackendLogin ? AppPalette.amber : AppPalette.green)
                )
                statusPill(
                    title: "车控/下单",
                    value: viewModel.isVehicleControlConfigured ? "已启用" : "未开启",
                    color: viewModel.isVehicleControlConfigured ? AppPalette.blue : .secondary
                )
                statusPill(
                    title: "实时通道",
                    value: eventStreamLabel,
                    color: eventStreamColor
                )
            }
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private func statusPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var eventStreamLabel: String {
        switch viewModel.eventStreamStatus {
        case .connected: return "已连接"
        case .connecting, .reconnecting: return "连接中"
        case .authenticationFailed: return "鉴权失败"
        case .idle, .stopped: return "待机"
        }
    }

    private var eventStreamColor: Color {
        switch viewModel.eventStreamStatus {
        case .connected: return AppPalette.green
        case .connecting, .reconnecting: return AppPalette.amber
        case .authenticationFailed: return AppPalette.red
        case .idle, .stopped: return .secondary
        }
    }

    // MARK: - Backend Connection Inputs

    private var backendConfigCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("服务连接与密钥", systemImage: "key.horizontal.fill")
                    .font(.headline)
                Text("两套 Key 均保存在系统 Keychain，彼此独立")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("后端地址")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.blue)
                        .frame(width: 20)
                    TextField("https://your-server:8080", text: $baseURLString)
                        .font(.subheadline.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !baseURLString.isEmpty {
                        Button {
                            baseURLString = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空后端地址")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(AppPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            secretInputField(
                label: "后端 API Key",
                placeholder: "必填，用于读取车辆与站点状态",
                icon: "key.fill",
                iconColor: AppPalette.blue,
                text: $apiKey,
                isRevealed: $revealAPIKey,
                statusBadge: trimmedAPIKey.count >= 32 ? "已填入" : nil
            )

            secretInputField(
                label: "车控 Key（可选）",
                placeholder: "留空则关闭远程车控与换电下单",
                icon: "lock.shield.fill",
                iconColor: AppPalette.violet,
                text: $controlKey,
                isRevealed: $revealControlKey,
                statusBadge: trimmedControlKey.isEmpty
                    ? "已关闭"
                    : (trimmedControlKey.count >= 32 ? "已启用" : "长度不足")
            )

            Label("远程车控与换电下单共用车控 Key，修改后自动同步至 Apple Watch 与小组件。", systemImage: "applewatch.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private func secretInputField(
        label: String,
        placeholder: String,
        icon: String,
        iconColor: Color,
        text: Binding<String>,
        isRevealed: Binding<Bool>,
        statusBadge: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let statusBadge {
                    Text(statusBadge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusBadge == "长度不足" ? AppPalette.amber : .secondary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                Group {
                    if isRevealed.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .font(.subheadline.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    isRevealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed.wrappedValue ? "隐藏密钥" : "显示密钥")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(AppPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - NIO Account Login Card

    private var nioAccountCard: some View {
        let needsLogin = viewModel.needsBackendLogin
        let accent = needsLogin ? AppPalette.amber : AppPalette.green

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: needsLogin ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("蔚来账号凭证")
                        .font(.headline)
                    Text(needsLogin ? "后端缺少有效 Token，需通过短信登录补齐" : "Token 过期时可随时热更新，无需重启后端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let status = viewModel.backendServiceStatus {
                    Text(status.vehicleConfigured ? "已配置" : "未完成")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(status.vehicleConfigured ? AppPalette.green : AppPalette.amber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            (status.vehicleConfigured ? AppPalette.green : AppPalette.amber).opacity(0.12),
                            in: Capsule()
                        )
                }
            }

            Button {
                feedbackTick += 1
                showingNIOLogin = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "message.badge.filled.fill")
                    Text(needsLogin ? "立即短信验证码登录" : "短信验证码刷新登录凭证")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .opacity(0.75)
                }
                .font(.subheadline)
                .foregroundStyle(needsLogin ? .white : AppPalette.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(
                    needsLogin ? AppPalette.amber : AppPalette.blue.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            }
            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))

            Text("登录请求由后端代理完成并自动热更新内存凭证，App 本地不会保存蔚来 Token。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .nioCard(cornerRadius: 24, padding: 18)
        .overlay {
            if needsLogin {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(AppPalette.amber.opacity(0.35), lineWidth: 1.2)
            }
        }
    }

    // MARK: - Swap Station Battery Filter

    private var stationPreferencesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("换电站默认电池档位", systemImage: "battery.100percent.bolt")
                    .font(.headline)
                Text("换电站顶部只统计匹配档位的可换电池数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: filterColumns, spacing: 8) {
                ForEach(StationViewModel.batteryFilterOptions, id: \.self) { option in
                    let isSelected = batteryFilter == option
                    Button {
                        feedbackTick += 1
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                            batteryFilter = option
                            StationViewModel.preferredBatteryTypeSetting = option
                        }
                    } label: {
                        Text(option)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                isSelected ? AppPalette.stationNight : AppPalette.surfaceSecondary,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? Color.clear : AppPalette.hairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.94))
                }
            }
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    // MARK: - Error & Sticky Bottom Bar

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppPalette.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AppPalette.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppPalette.red.opacity(0.24), lineWidth: 1)
        }
    }

    private var bottomSaveBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            Button(action: save) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("保存并连接")
                        .fontWeight(.semibold)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    canSave ? AppPalette.blue : AppPalette.graphite.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
            }
            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))
            .disabled(!canSave)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .background(.ultraThinMaterial)
    }

    private func save() {
        feedbackTick += 1
        do {
            try viewModel.saveSettings(
                baseURLString: baseURLString,
                apiKey: apiKey,
                controlKey: controlKey
            )
            isPresented = false
            Task { await viewModel.refresh() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "后端配置保存失败。"
        }
    }
}

struct NIOLoginView: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VehicleViewModel
    let openSettings: (() -> Void)?

    private enum LoginField: Hashable {
        case mobile
        case code
    }

    @State private var mobile = ""
    @State private var verificationCode = ""
    @State private var challenge: NIOLoginSMSChallenge?
    @State private var isSendingSMS = false
    @State private var isSubmittingLogin = false
    @State private var cooldownRemaining = 0
    @State private var errorMessage: String?
    @State private var loginOutcome: NIOLoginOutcome?
    @State private var loginSuccessTick = 0
    @State private var loginErrorTick = 0
    @FocusState private var focusedField: LoginField?

    private var sanitizedMobile: String {
        mobile.filter(\.isNumber)
    }

    private var sanitizedCode: String {
        String(verificationCode.filter(\.isNumber).prefix(6))
    }

    private var canSendSMS: Bool {
        viewModel.isConfigured
            && sanitizedMobile.count == 11
            && !isSendingSMS
            && !isSubmittingLogin
            && cooldownRemaining == 0
    }

    private var canSubmitLogin: Bool {
        viewModel.isConfigured
            && challenge != nil
            && sanitizedCode.count == 6
            && !isSendingSMS
            && !isSubmittingLogin
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    stepOneCard
                    stepTwoCard

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppPalette.red)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(AppPalette.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(AppPalette.red.opacity(0.24), lineWidth: 1)
                        }
                    }

                    if let loginOutcome {
                        outcomeBanner(loginOutcome)
                            .nioCard(cornerRadius: 22, padding: 18)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppPalette.canvas)
            .navigationTitle("蔚来账号登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loginOutcome == nil ? "稍后" : "完成") {
                        isPresented = false
                    }
                }
            }
            .onAppear {
                if mobile.isEmpty && viewModel.isConfigured {
                    focusedField = .mobile
                }
            }
            .sensoryFeedback(.success, trigger: loginSuccessTick)
            .sensoryFeedback(.error, trigger: loginErrorTick)
            .task(id: cooldownRemaining) {
                guard cooldownRemaining > 0 else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                cooldownRemaining = max(0, cooldownRemaining - 1)
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "car.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(viewModel.needsBackendLogin ? AppPalette.amber : AppPalette.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.needsBackendLogin ? "补全后端蔚来凭证" : "蔚来短信验证码登录")
                        .font(.headline)
                    Text(viewModel.debugBaseURLString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            Text(
                viewModel.needsBackendLogin
                    ? "当前后端缺少完整的蔚来车辆凭证。通过短信验证登录后，后端自动托管并热更新凭证，App 本地不保存 Token。"
                    : "通过后端代理发送短信验证码，登录成功后立即热更新运行中的车辆凭证，无需重启服务。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !viewModel.isConfigured, let openSettings {
                Button {
                    isPresented = false
                    openSettings()
                } label: {
                    Label("先配置后端地址与 API Key", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppPalette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))
            }
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private var stepOneCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                stepBadge(1, completed: challenge != nil)
                Text("输入手机号获取验证码")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if challenge != nil {
                    Text("已发送")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppPalette.green)
                }
            }

            HStack(spacing: 10) {
                Text("+86")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider().frame(height: 18)
                TextField("11 位手机号", text: $mobile)
                    .font(.body.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .focused($focusedField, equals: .mobile)
                    .disabled(isSendingSMS || isSubmittingLogin)
                    .onChange(of: mobile) { _, newValue in
                        var digits = newValue.filter(\.isNumber)
                        if digits.count == 13, digits.hasPrefix("86") {
                            digits = String(digits.dropFirst(2))
                        }
                        let clamped = String(digits.prefix(11))
                        if clamped != newValue {
                            mobile = clamped
                        }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                Task { await requestSMS() }
            } label: {
                HStack(spacing: 8) {
                    if isSendingSMS {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(cooldownRemaining > 0 ? "重新获取（\(cooldownRemaining)s）" : (challenge == nil ? "获取短信验证码" : "重新获取验证码"))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(canSendSMS ? .white : .secondary)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    canSendSMS ? AppPalette.blue : AppPalette.surfaceSecondary,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))
            .disabled(!canSendSMS)

            Text(
                challenge.map { "验证码有效期 \(max(1, $0.expiresInSeconds / 60)) 分钟，每次提交仅发送一次，不自动重试。" }
                    ?? "后端需已配置 API_KEY 与 32 位 NIO_DEVICE_ID 才可代理发送短信。"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private var stepTwoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                stepBadge(2, completed: loginOutcome != nil)
                Text("输入 6 位验证码登录")
                    .font(.subheadline.weight(.semibold))
            }

            TextField("6 位短信验证码", text: $verificationCode)
                .font(.title3.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
                .disabled(challenge == nil || isSubmittingLogin)
                .onChange(of: verificationCode) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue {
                        verificationCode = filtered
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(AppPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(challenge == nil ? 0.55 : 1)

            Button {
                Task { await submitLogin() }
            } label: {
                HStack(spacing: 8) {
                    if isSubmittingLogin {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield.fill")
                    }
                    Text(isSubmittingLogin ? "正在登录…" : "登录并同步到后端")
                        .fontWeight(.semibold)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    canSubmitLogin ? AppPalette.green : AppPalette.graphite.opacity(0.32),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            }
            .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))
            .disabled(!canSubmitLogin)
        }
        .nioCard(cornerRadius: 24, padding: 18)
    }

    private func stepBadge(_ step: Int, completed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(completed ? AppPalette.green : AppPalette.blue.opacity(0.14))
                .frame(width: 24, height: 24)
            if completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(step)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(AppPalette.blue)
            }
        }
    }

    @ViewBuilder
    private func outcomeBanner(_ outcome: NIOLoginOutcome) -> some View {
        let hotReloaded = outcome.vehicleClientReloaded == true
        switch outcome.backendConfigSaved {
        case true:
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    hotReloaded ? "登录成功，后端已保存并热更新凭证" : "登录成功，凭证已加密写入后端",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(AppPalette.green)
                .font(.subheadline.weight(.semibold))
                Text(
                    hotReloaded && !viewModel.needsBackendLogin
                        ? "车辆凭证已立即生效，无需重启后端服务，可以关闭此页面查看车辆状态。"
                        : (viewModel.needsBackendLogin
                            ? "后端缺少初始车辆配置（如 NIO_VEHICLE_ID），请补全配置并重启后端服务后返回下拉刷新。"
                            : "车辆凭证已生效，可以关闭此页面查看车辆状态。")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case false:
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    hotReloaded ? "登录成功，内存凭证已热更新（持久化失败）" : "蔚来登录成功，但后端写入配置失败",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(AppPalette.amber)
                .font(.subheadline.weight(.semibold))
                Text(
                    hotReloaded
                        ? "本次进程内可立即使用，但未能写入数据库，重启服务后可能失效，请检查后端日志。"
                        : "请检查后端数据库与日志状态，确认租户凭据是否正确持久化。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case nil:
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    hotReloaded ? "登录成功，后端已热更新凭证（单租户）" : "蔚来登录成功（单租户模式）",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(hotReloaded ? AppPalette.green : AppPalette.blue)
                .font(.subheadline.weight(.semibold))
                Text(
                    hotReloaded
                        ? "当前进程内的车辆凭证已立即生效，无需重启即可使用；如需重启后保留，请同步更新 .env 中的 NIO_BEARER_TOKEN。"
                        : "当前后端运行在单租户 .env 模式，且未热更新车辆客户端。请按服务端部署流程更新 NIO_BEARER_TOKEN 并重启服务。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func requestSMS() async {
        guard canSendSMS else { return }
        isSendingSMS = true
        errorMessage = nil
        loginOutcome = nil
        defer { isSendingSMS = false }
        do {
            let received = try await viewModel.sendNIOLoginSMS(mobile: sanitizedMobile)
            challenge = received
            verificationCode = ""
            cooldownRemaining = 60
            focusedField = .code
        } catch {
            challenge = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            loginErrorTick += 1
        }
    }

    private func submitLogin() async {
        guard let activeChallenge = challenge, canSubmitLogin else { return }
        isSubmittingLogin = true
        errorMessage = nil
        // The backend consumes the SMS challenge before sending the upstream login request,
        // so clear it on completion to prevent accidentally reusing a consumed challenge.
        defer { isSubmittingLogin = false }
        do {
            let outcome = try await viewModel.submitNIOLogin(
                challengeID: activeChallenge.challengeID,
                verificationCode: sanitizedCode
            )
            challenge = nil
            verificationCode = ""
            focusedField = nil
            loginOutcome = outcome
            loginSuccessTick += 1
        } catch {
            challenge = nil
            verificationCode = ""
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            loginErrorTick += 1
        }
    }
}
