import CoreData
import SwiftUI

struct ContentView: View {
    private enum AppTab: Hashable {
        case vehicle
        case station
        case insights
    }

    private struct StationAutoRefreshContext: Equatable {
        let scenePhase: ScenePhase
        let selectedTab: AppTab
    }

    private struct VehicleMonitorContext: Equatable {
        let scenePhase: ScenePhase
        let configurationRevision: UUID
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default
    ) private var items: FetchedResults<SwapStations>

    @StateObject private var viewModel = StationViewModel()
    @StateObject private var vehicleViewModel = VehicleViewModel()
    @State private var showingRequestEditor = false
    @State private var showingSavedRequests = false
    @State private var showingBackendStations = false
    @State private var showingBackendSettings = false
    @State private var showingSwapOrderConfirmation = false
    @State private var selectedTab: AppTab = .vehicle
    @State private var didInitialLoad = false
    @State private var failureToast: APIErrorNotice?
    /// Follow the station closest to the vehicle instead of a saved station.
    @AppStorage("stationUsesNearest") private var usesNearestStation = false
    @State private var nearestStationID: String?

    init() {
        #if DEBUG
        if let preview = DesignPreviewMode.current {
            _viewModel = StateObject(wrappedValue: StationViewModel.designPreview())
            _vehicleViewModel = StateObject(wrappedValue: VehicleViewModel.designPreview())
            _selectedTab = State(initialValue: preview.screen == .station ? .station : .vehicle)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                VehicleDetailView(viewModel: vehicleViewModel) {
                    showingBackendSettings = true
                }
            }
            .tabItem { Label("车辆", systemImage: "car.side.fill") }
            .tag(AppTab.vehicle)

            NavigationStack {
                stationContent
            }
            .tabItem { Label("换电站", systemImage: "bolt.car.fill") }
            .tag(AppTab.station)

            NavigationStack {
                EnergyAndCouponsView(
                    viewModel: vehicleViewModel,
                    isActive: selectedTab == .insights
                ) {
                    showingBackendSettings = true
                }
            }
            .tabItem { Label("数据", systemImage: "chart.bar.xaxis") }
            .tag(AppTab.insights)
        }
        .tint(AppPalette.blue)
        .overlay(alignment: .top) {
            if let failureToast {
                APIErrorToast(message: failureToast.message) {
                    withAnimation(.easeOut(duration: 0.2)) { self.failureToast = nil }
                }
                .padding(.horizontal, 16)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .onChange(of: viewModel.failureNotice) { _, notice in
            presentFailureToast(notice)
        }
        .onChange(of: vehicleViewModel.failureNotice) { _, notice in
            presentFailureToast(notice)
        }
        .task(id: failureToast?.id) {
            guard failureToast != nil else { return }
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) { failureToast = nil }
        }
        .task(id: VehicleMonitorContext(
            scenePhase: scenePhase,
            configurationRevision: vehicleViewModel.monitorConfigurationRevision
        )) {
            #if DEBUG
            if DesignPreviewMode.current != nil { return }
            #endif
            guard scenePhase == .active else { return }
            if !didInitialLoad {
                vehicleViewModel.prepareForInitialDisplay()
                async let vehicleRefresh: Void = vehicleViewModel.refresh()
                async let stationRefresh: Void = refreshWithCurrentRequest()
                _ = await (vehicleRefresh, stationRefresh)
                guard !Task.isCancelled else { return }
                didInitialLoad = true
            } else {
                await vehicleViewModel.refreshLiveData()
            }
            await vehicleViewModel.monitorForegroundRefresh()
        }
        .task(id: StationAutoRefreshContext(scenePhase: scenePhase, selectedTab: selectedTab)) {
            #if DEBUG
            if DesignPreviewMode.current != nil { return }
            #endif
            guard scenePhase == .active, selectedTab == .station else { return }
            await refreshWithCurrentRequest(updateWidgetConfiguration: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await refreshWithCurrentRequest(updateWidgetConfiguration: false)
            }
        }
        .sheet(isPresented: $showingRequestEditor) {
            RequestEditorView(isPresented: $showingRequestEditor, viewContext: viewContext) { request, name, stationID in
                leaveNearestStationMode()
                Task { await refreshSavedStation(request: request, name: name, stationID: stationID) }
            }
        }
        .sheet(isPresented: $showingSavedRequests) {
            SavedRequestsView(isPresented: $showingSavedRequests) { request, name, stationID in
                leaveNearestStationMode()
                if let request {
                    Task { await refreshSavedStation(request: request, name: name, stationID: stationID) }
                } else {
                    viewModel.showNeedsConfiguration()
                }
            }
        }
        .sheet(isPresented: $showingBackendStations) {
            BackendStationPickerView(
                isPresented: $showingBackendStations,
                vehicleViewModel: vehicleViewModel,
                templateRequest: stationRequestTemplate
            ) { request, name, stationID in
                leaveNearestStationMode()
                Task { await refreshSavedStation(request: request, name: name, stationID: stationID) }
            }
        }
        .sheet(isPresented: $showingBackendSettings) {
            BackendSettingsView(
                isPresented: $showingBackendSettings,
                viewModel: vehicleViewModel
            )
        }
        .alert("创建真实换电订单", isPresented: $showingSwapOrderConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认下单", role: .destructive) {
                guard let stationID = selectedStationID else { return }
                Task { _ = try? await vehicleViewModel.createSwapOrder(stationID: stationID) }
            }
        } message: {
            Text("将为当前站点“\(viewModel.currentRequestName ?? "未命名换电站")”创建真实换电订单。请求只发送一次，不会自动重试。")
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "niopowerswapassist" else { return }
            if url.host?.lowercased() == "vehicle" {
                selectedTab = .vehicle
            } else if url.host?.lowercased() == "station" {
                selectedTab = .station
            } else if url.host?.lowercased() == "insights" {
                selectedTab = .insights
            }
        }
    }

    private func presentFailureToast(_ notice: APIErrorNotice?) {
        guard let notice else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            failureToast = notice
        }
    }

    private var stationContent: some View {
        ZStack {
            AppPalette.canvas.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 22) {
                    stationHeader

                    if let outcome = vehicleViewModel.lastSwapOrderOutcome {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("换电订单已创建", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("订单号：\(outcome.orderID)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text("目标电池档位：\(outcome.targetBatteryCapLevel ?? outcome.requestedBatteryCapLevel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }

                    if let error = viewModel.errorMessage {
                        ErrorBanner(message: error) {
                            Task { await refreshWithCurrentRequest() }
                        } dismiss: {
                            viewModel.dismissError()
                        }
                    }

                    if !viewModel.batteries.isEmpty {
                        summaryGrid
                        if let feeInfo = viewModel.feeInfo {
                            FeeInfoView(feeInfo: feeInfo)
                        }
                        batterySections
                    } else if !viewModel.isLoading {
                        emptyState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable { await refreshWithCurrentRequest() }

            if viewModel.isLoading && viewModel.batteries.isEmpty {
                ProgressView("正在获取换电站状态…")
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .navigationTitle("换电站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        usesNearestStation = true
                        nearestStationID = nil
                        Task { await refreshWithCurrentRequest() }
                    } label: {
                        Label(
                            "自动：离车最近换电站",
                            systemImage: usesNearestStation ? "checkmark" : "location.viewfinder"
                        )
                    }
                    .disabled(!vehicleViewModel.isConfigured)
                    Button("已保存的站点", systemImage: "list.bullet") {
                        showingSavedRequests = true
                    }
                    Button("从后端搜索", systemImage: "magnifyingglass") {
                        showingBackendStations = true
                    }
                    Button("手动添加 cURL", systemImage: "plus") {
                        showingRequestEditor = true
                    }
                    Divider()
                    Button("后端设置", systemImage: "server.rack") {
                        showingBackendSettings = true
                    }
                } label: {
                    Label("站点操作", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var stationHeader: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("换电站实况")
                        .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.6))
                    Text(viewModel.currentRequestName ?? "选择你的换电站")
                        .font(.title3.weight(.semibold)).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await refreshWithCurrentRequest() }
                } label: {
                    Group {
                        if viewModel.isLoading { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold)) }
                    }
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.10), in: Circle())
                }
                .disabled(viewModel.isLoading || (selectedItem == nil && !usesNearestStation))
                .accessibilityLabel("刷新换电站状态")
            }
            if !viewModel.batteries.isEmpty {
                HStack(alignment: .bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(viewModel.readyCount)")
                            .font(.system(size: 56, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(red: 0.65, green: 0.87, blue: 0.72))
                        Text(viewModel.preferredBatteryType == StationViewModel.allBatteryTypes
                             ? "块电池可换"
                             : "块可换 · \(viewModel.preferredBatteryType)")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: "bolt.car")
                        .font(.system(size: 43, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.bottom, 7)
                }
            }
            if let lastUpdated = viewModel.lastUpdated {
                Text("更新于 \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
            } else {
                Text("选择站点，查看电池与实时费率")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Button {
                if vehicleViewModel.isVehicleControlConfigured {
                    showingSwapOrderConfirmation = true
                } else {
                    showingBackendSettings = true
                }
            } label: {
                HStack {
                    if vehicleViewModel.isCreatingSwapOrder {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(vehicleViewModel.isVehicleControlConfigured ? "发起换电" : "配置车控 Key")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.18, green: 0.58, blue: 0.86))
            .disabled(
                selectedStationID == nil
                    || vehicleViewModel.isCreatingSwapOrder
                    || !vehicleViewModel.isConfigured
            )
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(
            LinearGradient(colors: [AppPalette.stationNight, Color(red: 0.12, green: 0.18, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }

    private var summaryGrid: some View {
        HStack(spacing: 0) {
            stationMetric("充电中", viewModel.chargingCount, AppPalette.amber)
            Divider().frame(height: 32)
            stationMetric("使用中", viewModel.occupiedCount, AppPalette.blue)
            Divider().frame(height: 32)
            stationMetric("电池总数", viewModel.batteries.count, .secondary)
        }
        .padding(.vertical, 4)
    }

    private func stationMetric(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 7) {
            Text("\(value)").font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var batterySections: some View {
        ForEach(viewModel.groupedBatteries, id: \.name) { group in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(group.name)
                        .font(.title3.weight(.bold))
                    Spacer()
                    Text("\(group.batteries.count) 块")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(group.batteries) { battery in
                    CardView(batteryModel: battery)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if selectedItem == nil && !usesNearestStation {
            ContentUnavailableView {
                Label("添加换电站", systemImage: "bolt.car")
            } description: {
                Text("从蔚来 App 请求中复制 cURL，保存后即可刷新电池和费率信息。")
            } actions: {
                Button("添加请求") { showingRequestEditor = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        } else if viewModel.errorMessage == nil {
            ContentUnavailableView("暂无电池信息", systemImage: "battery.0percent", description: Text("该站点当前没有返回可展示的电池。"))
                .padding(.top, 40)
        }
    }

    private var selectedItem: SwapStations? {
        items.first(where: \.selected)
    }

    private var selectedStationID: String? {
        if usesNearestStation { return nearestStationID }
        guard let selectedItem else { return nil }
        return selectedItem.stationID ?? NIOSwapRequestSigner.stationID(from: selectedItem.url)
    }

    private var stationRequestTemplate: InfoRequest? {
        let candidates = [selectedItem].compactMap { $0 } + Array(items)
        guard let item = candidates.first(where: {
            NIOSwapRequestSigner.stationID(from: $0.url) != nil
        }) else { return nil }
        return InfoRequest(url: item.url, headers: item.headers)
    }

    private func leaveNearestStationMode() {
        usesNearestStation = false
        nearestStationID = nil
    }

    private func refreshNearestStation(updateWidgetConfiguration: Bool) async {
        // Never keep a previous nearest station eligible for a real order while
        // the current vehicle position is still being resolved.
        nearestStationID = nil
        if updateWidgetConfiguration {
            BackendSettingsStore.shared.clearWidgetStation()
        }
        let token = viewModel.beginExternalRefresh(name: nil)
        do {
            let nearest = try await vehicleViewModel.fetchNearestStationLive()
            guard usesNearestStation, viewModel.isExternalRefreshActive(token) else { return }
            nearestStationID = nearest.stationID
            viewModel.apply(snapshot: nearest.stationSnapshot(), name: nearest.displayName, token: token)
            if updateWidgetConfiguration {
                try? BackendSettingsStore.shared.saveWidgetStation(
                    id: nearest.stationID,
                    name: nearest.stationName
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard usesNearestStation, viewModel.isExternalRefreshActive(token) else { return }
            nearestStationID = nil
            viewModel.failExternalRefresh(
                "最近换电站获取失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                token: token
            )
        }
    }

    private func refreshSavedStation(
        request: InfoRequest,
        name: String?,
        stationID explicitStationID: String? = nil,
        updateWidgetConfiguration: Bool = true
    ) async {
        let stationID = explicitStationID ?? NIOSwapRequestSigner.stationID(from: request.url)
        let displayName = name ?? stationID
        if updateWidgetConfiguration {
            if let stationID {
                try? BackendSettingsStore.shared.saveWidgetStation(
                    id: stationID,
                    name: displayName ?? stationID
                )
            } else {
                BackendSettingsStore.shared.clearWidgetStation()
            }
        }

        // Query the backend immediately after a saved station is selected. A
        // configured backend owns the renewable NIO session, so do not replay
        // a captured request when that backend reports an error.
        if vehicleViewModel.isConfigured, let stationID {
            let resolvedName = displayName ?? stationID
            let token = viewModel.beginExternalRefresh(name: resolvedName)
            do {
                let live = try await vehicleViewModel.fetchStationLive(id: stationID)
                guard !usesNearestStation, viewModel.isExternalRefreshActive(token) else { return }
                viewModel.apply(snapshot: live.stationSnapshot(), name: resolvedName, token: token)
                return
            } catch is CancellationError {
                return
            } catch {
                guard !usesNearestStation, viewModel.isExternalRefreshActive(token) else { return }
                viewModel.failExternalRefresh(
                    "换电站获取失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)",
                    token: token
                )
                return
            }
        }
        guard !usesNearestStation else { return }
        await viewModel.refresh(request: request, name: name)
    }

    private func refreshWithCurrentRequest(updateWidgetConfiguration: Bool = true) async {
        #if DEBUG
        if DesignPreviewMode.current != nil { return }
        #endif
        if usesNearestStation {
            await refreshNearestStation(updateWidgetConfiguration: updateWidgetConfiguration)
            return
        }
        guard let selectedItem else {
            if updateWidgetConfiguration {
                BackendSettingsStore.shared.clearWidgetStation()
            }
            viewModel.showNeedsConfiguration()
            return
        }
        await refreshSavedStation(
            request: InfoRequest(url: selectedItem.url, headers: selectedItem.headers),
            name: selectedItem.name,
            stationID: selectedItem.stationID,
            updateWidgetConfiguration: updateWidgetConfiguration
        )
    }

}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry).font(.subheadline.weight(.semibold))
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .accessibilityLabel("关闭错误提示")
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct APIErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "wifi.exclamationmark")
                .font(.headline)
                .foregroundStyle(.red)
                .frame(width: 28, height: 28)
                .background(Color.red.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("请求失败")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .accessibilityLabel("关闭失败提示")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.red.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}

private struct EnergyAndCouponsView: View {
    private enum Period: String, CaseIterable, Identifiable {
        case month = "本月至今"
        case sevenDays = "近 7 天"
        case thirtyDays = "近 30 天"
        case custom = "自定义"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: VehicleViewModel
    let isActive: Bool
    let openSettings: () -> Void
    @State private var period: Period = .month
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customTo = Date()
    @State private var didLoad = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            AppPalette.canvas.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 14) {
                    rangeCard

                    if let error = viewModel.energyStatsErrorMessage {
                        ErrorBanner(message: error) {
                            Task { await refreshStats() }
                        }
                    }

                    if let stats = viewModel.energyStats {
                        statisticsContent(stats)
                    } else if viewModel.isLoadingEnergyStats {
                        loadingCard("正在计算区间统计…")
                    }

                    couponsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable { await refreshAll() }
        }
        .navigationTitle("用车账本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("后端设置", systemImage: "server.rack", action: openSettings)
            }
        }
        .task(id: isActive) {
            guard isActive, !didLoad else { return }
            didLoad = true
            await refreshAll()
        }
        .onChange(of: customFrom) { _, newValue in
            if customTo < newValue { customTo = newValue }
        }
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("用车概览", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                if viewModel.isLoadingEnergyStats { ProgressView() }
            }

            Picker("统计区间", selection: $period) {
                ForEach(Period.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { _, _ in Task { await refreshStats() } }

            if period == .custom {
                DatePicker("开始日期", selection: $customFrom, in: ...Date(), displayedComponents: .date)
                DatePicker("结束日期", selection: $customTo, in: customFrom...Date(), displayedComponents: .date)
            }

            Text(rangeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await refreshStats() }
            } label: {
                Label("更新统计", systemImage: "arrow.clockwise")
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoadingEnergyStats)
        }
        .dataCard()
    }

    @ViewBuilder
    private func statisticsContent(_ stats: EnergyStats) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            metricCard("区间换电", "\(stats.swapCount) 次", "arrow.triangle.2.circlepath", AppPalette.blue)
            metricCard("本月换电", "\(stats.currentMonthSwapCount) 次", "calendar.badge.clock", AppPalette.violet)
            metricCard("实际支付", moneyText(stats.actualPaidCNYKnown, covered: stats.paidAmountCoveredCount, total: stats.swapCount), "creditcard.fill", AppPalette.graphite)
            metricCard("优惠券减免", moneyText(stats.couponDiscountCNYKnown, covered: stats.feeBreakdownCoveredCount, total: stats.swapCount), "ticket.fill", AppPalette.amber)
        }

        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("费用明细", icon: "yensign.circle.fill")
            valueRow("电费", moneyText(stats.swapElectricityFeeCNYKnown, covered: stats.feeBreakdownCoveredCount, total: stats.swapCount))
            valueRow("服务费", moneyText(stats.swapServiceFeeCNYKnown, covered: stats.feeBreakdownCoveredCount, total: stats.swapCount))
            valueRow("电费 + 服务费", moneyText(stats.swapTotalFeeCNYKnown, covered: stats.feeBreakdownCoveredCount, total: stats.swapCount))
            Divider()
            Text("费用分项覆盖 \(stats.feeBreakdownCoveredCount)/\(stats.swapCount) 笔；实付金额覆盖 \(stats.paidAmountCoveredCount)/\(stats.swapCount) 笔。未覆盖记录不会按 0 元计入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dataCard()

        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("能量统计", icon: "bolt.circle.fill")

            if stats.energyCoverageComplete {
                coverageBanner("能量覆盖完整", detail: "区间内换电与充电采样均有可用依据。", color: .green, icon: "checkmark.circle.fill")
            } else {
                coverageBanner("能量覆盖不完整", detail: "以下电量及比例只代表有依据的已知部分，不能视为实际总量。", color: .orange, icon: "exclamationmark.triangle.fill")
            }

            valueRow(
                "换电电量",
                energyText(stats.swapEnergyKWhKnown, covered: stats.swapEnergyCoveredCount, total: stats.swapCount)
            )
            valueRow("充电电量", stats.chargingEnergyKWhEstimated.map { kWh($0) } ?? "暂无可估算数据")
            valueRow("已知能量合计", hasKnownEnergy(stats) ? kWh(stats.totalEnergyKWhKnown) : "暂无已知电量")

            Divider()
            sourceRow(
                title: "功率积分",
                value: stats.chargingSegmentsFromPower > 0 ? kWh(stats.chargingEnergyKWhFromPower) : "无有效采样段",
                detail: "\(stats.chargingSegmentsFromPower) 个采样段"
            )
            sourceRow(
                title: "容量 × SOC 估算",
                value: stats.chargingSegmentsFromSOC > 0 ? kWh(stats.chargingEnergyKWhFromSOC) : "未使用估算",
                detail: "\(stats.chargingSegmentsFromSOC) 个回退采样段"
            )

            if stats.chargingSegmentsUncovered > 0 {
                Text("另有 \(stats.chargingSegmentsUncovered) 个充电采样段缺少有效功率，且无法用可信电池容量与 SOC 增量估算。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let swapShare = stats.swapEnergySharePercentOfKnown,
               let chargingShare = stats.chargingEnergySharePercentOfKnown {
                Divider()
                Text(stats.energyCoverageComplete ? "能量占比" : "已知部分占比")
                    .font(.subheadline.weight(.semibold))
                valueRow("换电", percent(swapShare))
                valueRow("充电", percent(chargingShare))
            } else {
                Text("当前没有足够的已知电量计算占比。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("纳入计算窗口的充电采样：\(stats.chargingSampleCount) 条；精确换电电量覆盖：\(stats.swapEnergyCoveredCount)/\(stats.swapCount) 笔。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dataCard()
    }

    private var couponsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("可用卡券", icon: "ticket.fill")
                Spacer()
                if viewModel.availableCouponCount > 0 {
                    Text(viewModel.totalCouponQuantity.map { "共 \($0) 张" } ?? "已加载 \(viewModel.availableCoupons.count) 项 · 总张数待确认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await viewModel.refreshAvailableCoupons() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingCoupons)
                .accessibilityLabel("刷新可用卡券")
            }

            if let error = viewModel.couponsErrorMessage {
                ErrorBanner(message: error) {
                    Task { await viewModel.refreshAvailableCoupons() }
                }
            } else if viewModel.isLoadingCoupons && viewModel.availableCoupons.isEmpty {
                HStack { Spacer(); ProgressView("正在读取卡包…"); Spacer() }
                    .padding(.vertical, 24)
            } else if viewModel.availableCoupons.isEmpty {
                ContentUnavailableView(
                    "暂无可用卡券",
                    systemImage: "ticket",
                    description: Text("新的优惠券会在这里显示。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(viewModel.availableCoupons.enumerated()), id: \.offset) { _, coupon in
                    couponRow(coupon)
                }

                if viewModel.couponsHaveMore {
                    Button {
                        Task { await viewModel.refreshAvailableCoupons(reset: false) }
                    } label: {
                        HStack {
                            if viewModel.isLoadingCoupons { ProgressView() }
                            Text(viewModel.isLoadingCoupons ? "加载中…" : "加载更多")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoadingCoupons)
                }
            }
        }
        .dataCard()
    }

    private func couponRow(_ coupon: AvailableCoupon) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ticket.fill")
                .font(.title2)
                .foregroundStyle(AppPalette.blue)
                .frame(width: 38, height: 38)
                .background(AppPalette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                if let value = coupon.faceValueCNY {
                    Text("¥\(value)").font(.title2.bold()).foregroundStyle(AppPalette.amber)
                }
                Text(coupon.title).font(.subheadline.weight(.semibold))
                if let subtitle = coupon.subtitle, subtitle != coupon.title {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let validity = coupon.validityText {
                    Label(validity, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(coupon.quantity.map { "\($0)" } ?? "—")
                    .font(.title2.bold().monospacedDigit())
                Text(coupon.quantity == nil ? "张数待确认" : "张可用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(AppPalette.amber)
            .padding(.leading, 10)
        }
        .padding(12)
        .background(AppPalette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private func refreshAll() async {
        async let stats: Void = refreshStats()
        async let coupons: Void = viewModel.refreshAvailableCoupons()
        _ = await (stats, coupons)
    }

    private func refreshStats() async {
        let range = selectedRange
        await viewModel.refreshEnergyStats(from: range.from, to: range.to)
    }

    private var selectedRange: (from: Date, to: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        switch period {
        case .month:
            let components = calendar.dateComponents([.year, .month], from: now)
            return (calendar.date(from: components) ?? today, now)
        case .sevenDays:
            return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, now)
        case .thirtyDays:
            return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, now)
        case .custom:
            let start = calendar.startOfDay(for: customFrom)
            let endDay = calendar.startOfDay(for: max(customFrom, customTo))
            return (start, calendar.date(byAdding: .day, value: 1, to: endDay) ?? now)
        }
    }

    private var rangeDescription: String {
        let range = selectedRange
        return "\(range.from.formatted(date: .abbreviated, time: .omitted)) – \(range.to.formatted(date: .abbreviated, time: .omitted))"
    }

    private func metricCard(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func sourceRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            valueRow(title, value)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func coverageBanner(_ title: String, detail: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadingCard(_ text: String) -> some View {
        HStack { Spacer(); ProgressView(text); Spacer() }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func moneyText(_ value: Double, covered: Int, total: Int) -> String {
        guard total == 0 || covered > 0 else { return "暂无已知金额" }
        return "¥" + String(format: "%.2f", value)
    }

    private func energyText(_ value: Double, covered: Int, total: Int) -> String {
        guard total == 0 || covered > 0 else { return "暂无精确电量" }
        return kWh(value)
    }

    private func hasKnownEnergy(_ stats: EnergyStats) -> Bool {
        stats.swapEnergyCoveredCount > 0
            || stats.chargingEnergyKWhEstimated != nil
    }

    private func kWh(_ value: Double) -> String { String(format: "%.2f kWh", value) }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
}

private extension View {
    func dataCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.04), lineWidth: 1))
    }
}
