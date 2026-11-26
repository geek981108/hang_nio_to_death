import SwiftUI

@main
struct NIOPowerSwapAssistTVApp: App {
    @StateObject private var viewModel = TVGarageViewModel()

    var body: some Scene {
        WindowGroup {
            TVRootView(viewModel: viewModel)
        }
    }
}

struct TVRootView: View {
    @ObservedObject var viewModel: TVGarageViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAmbientModePresented = false

    var body: some View {
        ZStack(alignment: .top) {
            if isAmbientModePresented && viewModel.isConfigured {
                TVAmbientGarageView(viewModel: viewModel) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        isAmbientModePresented = false
                    }
                }
                .transition(.opacity)
                .zIndex(2)
            } else if viewModel.isConfigured {
                TabView {
                    TVOverviewView(viewModel: viewModel) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isAmbientModePresented = true
                        }
                    }
                    .tabItem {
                        Label("总览", systemImage: "car.side.fill")
                    }

                    TVStationView(viewModel: viewModel)
                        .tabItem {
                            Label("换电站", systemImage: "bolt.car.fill")
                        }

                    TVEnergyView(viewModel: viewModel)
                        .tabItem {
                            Label("充电能耗", systemImage: "chart.bar.xaxis")
                        }

                    TVTripsView(viewModel: viewModel)
                        .tabItem {
                            Label("行程轨迹", systemImage: "map.fill")
                        }

                    TVSettingsView(viewModel: viewModel) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isAmbientModePresented = true
                        }
                    }
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                }
                .transition(.opacity)
            } else {
                TVOnboardingView(viewModel: viewModel)
            }

            if let feedback = viewModel.feedback, !isAmbientModePresented {
                HStack(spacing: 12) {
                    Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isError ? TVPalette.amber : TVPalette.green)
                    Text(feedback.message)
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 26)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.feedback?.id)
        .task(id: viewModel.feedback?.id) {
            guard let id = viewModel.feedback?.id else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, viewModel.feedback?.id == id else { return }
            viewModel.feedback = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && viewModel.isConfigured {
                viewModel.startMonitoring()
            } else if phase == .background {
                viewModel.stopMonitoring()
            }
        }
        .task {
            if viewModel.isConfigured {
                viewModel.startMonitoring()
            }
        }
        .alert(
            "车机发送确认",
            isPresented: Binding(
                get: { viewModel.pendingRoutePopup != nil },
                set: { if !$0 { viewModel.dismissPendingRoutePopup() } }
            ),
            presenting: viewModel.pendingRoutePopup
        ) { popup in
            if let leftText = popup.leftBtnText?.trimmingCharacters(in: .whitespacesAndNewlines), !leftText.isEmpty {
                Button(leftText) {
                    if let action = popup.leftBtnAction {
                        Task { await viewModel.confirmPendingRoute(btnAction: action) }
                    } else {
                        viewModel.dismissPendingRoutePopup()
                    }
                }
            }
            if let rightText = popup.rightBtnText?.trimmingCharacters(in: .whitespacesAndNewlines), !rightText.isEmpty {
                Button(rightText) {
                    if let action = popup.rightBtnAction {
                        Task { await viewModel.confirmPendingRoute(btnAction: action) }
                    } else {
                        viewModel.dismissPendingRoutePopup()
                    }
                }
            }
            if (popup.leftBtnText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && (popup.rightBtnText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                Button("知道了", role: .cancel) { viewModel.dismissPendingRoutePopup() }
            }
        } message: { popup in
            Text(popup.content ?? "请确认是否继续发送到车机。")
        }
    }
}
