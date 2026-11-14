import SwiftUI
import UniformTypeIdentifiers

struct BackendSettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VehicleViewModel
    @State private var baseURLString: String
    @State private var apiKey: String
    @State private var controlKey: String
    @State private var errorMessage: String?
    @State private var showingCertificateImporter = false
    @State private var certificatePassword = ""
    @State private var certificateMessage: String?
    @State private var certificateFailed = false
    @State private var hasClientCertificate: Bool

    init(isPresented: Binding<Bool>, viewModel: VehicleViewModel) {
        _isPresented = isPresented
        self.viewModel = viewModel
        _baseURLString = State(initialValue: viewModel.baseURLString)
        _apiKey = State(initialValue: viewModel.savedAPIKey)
        _controlKey = State(initialValue: viewModel.savedControlKey)
        _hasClientCertificate = State(initialValue: viewModel.hasClientCertificate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://127.0.0.1:8080", text: $baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("后端 API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("车控 Key（可选）", text: $controlKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Actix 后端")
                } footer: {
                    Text("两套 Key 均保存在系统 Keychain。车控 Key 与普通 API Key 相互独立，车辆控制和换电下单共用车控 Key；留空会关闭这两类操作入口。")
                }

                Section {
                    LabeledContent("状态", value: hasClientCertificate ? "已安装" : "未安装")
                    SecureField("证书密码（导出 .p12 时设置）", text: $certificatePassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        showingCertificateImporter = true
                    } label: {
                        Label("导入客户端证书（.p12）", systemImage: "person.text.rectangle")
                    }
                    if hasClientCertificate {
                        Button("移除客户端证书", role: .destructive) {
                            viewModel.clearClientCertificate()
                            hasClientCertificate = false
                            certificateFailed = false
                            certificateMessage = "已移除客户端证书。"
                        }
                    }
                    if let certificateMessage {
                        Text(certificateMessage)
                            .font(.footnote)
                            .foregroundStyle(certificateFailed ? .red : .green)
                    }
                } header: {
                    Text("TLS 客户端证书（可选）")
                } footer: {
                    Text("后端经 Cloudflare 等边缘网关开启 mTLS 时，没有有效客户端证书的请求会在边缘被拒绝。证书与密码保存在系统 Keychain，只向上方配置的后端地址出示。")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .fileImporter(
                isPresented: $showingCertificateImporter,
                allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data],
                allowsMultipleSelection: false
            ) { result in
                importCertificate(result)
            }
            .navigationTitle("车辆后端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并连接", action: save)
                        .disabled(baseURLString.isEmpty || apiKey.isEmpty)
                }
            }
        }
    }

    private func importCertificate(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try viewModel.saveClientCertificate(p12Data: data, password: certificatePassword)
                hasClientCertificate = true
                certificateFailed = false
                certificatePassword = ""
                certificateMessage = "客户端证书已导入，之后的请求都会出示该证书。"
            } catch {
                certificateFailed = true
                certificateMessage = "导入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        case .failure(let error):
            certificateFailed = true
            certificateMessage = "未导入：\(error.localizedDescription)"
        }
    }

    private func save() {
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
