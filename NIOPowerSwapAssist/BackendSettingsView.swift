import SwiftUI

struct BackendSettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VehicleViewModel
    @State private var baseURLString: String
    @State private var apiKey: String
    @State private var controlKey: String
    @State private var errorMessage: String?

    init(isPresented: Binding<Bool>, viewModel: VehicleViewModel) {
        _isPresented = isPresented
        self.viewModel = viewModel
        _baseURLString = State(initialValue: viewModel.baseURLString)
        _apiKey = State(initialValue: viewModel.savedAPIKey)
        _controlKey = State(initialValue: viewModel.savedControlKey)
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

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
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
