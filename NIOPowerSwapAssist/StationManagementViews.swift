import CoreData
import MapKit
import SwiftUI

struct RequestEditorView: View {
    @Binding var isPresented: Bool
    let viewContext: NSManagedObjectContext
    let onSaved: (InfoRequest, String, String?) -> Void

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)])
    private var items: FetchedResults<SwapStations>

    @State private var name = ""
    @State private var curlCommand = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("站点名称") {
                    TextField("例如：滨江换电站", text: $name)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    TextEditor(text: $curlCommand)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("cURL 请求")
                } footer: {
                    Text("BFF 换电接口会在每次刷新前自动更新时间戳和 sign。授权信息仅用于访问接口，请勿分享请求内容。")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("添加换电站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || curlCommand.isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            let request = try CurlCommandParser.parse(curlCommand)
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let stationID = NIOSwapRequestSigner.stationID(from: request.url)
            let insertionIndex = nextIndex
            let item = stationID.flatMap { stationID in
                items.first {
                    ($0.stationID ?? NIOSwapRequestSigner.stationID(from: $0.url)) == stationID
                }
            } ?? SwapStations(context: viewContext)

            if item.isInserted { item.index = insertionIndex }
            item.name = normalizedName
            item.url = request.url
            item.headers = request.headers
            item.stationID = stationID
            for savedItem in items {
                savedItem.selected = (savedItem == item)
            }
            item.selected = true
            try viewContext.save()
            onSaved(request, normalizedName, stationID)
            isPresented = false
        } catch {
            viewContext.rollback()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存失败：\(error.localizedDescription)"
        }
    }

    private var nextIndex: Int16 {
        let maximum = items.map(\.index).max() ?? -1
        return maximum == Int16.max ? Int16.max : maximum + 1
    }
}

struct SavedRequestsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default
    ) private var items: FetchedResults<SwapStations>

    @Binding var isPresented: Bool
    let onRequestSelected: (InfoRequest?, String?, String?) -> Void
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView("还没有保存的站点", systemImage: "bolt.car")
                }
                ForEach(items) { item in
                    Button {
                        select(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.selected ? .teal : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name ?? "未命名站点").font(.headline)
                                if let stationID = item.stationID
                                    ?? NIOSwapRequestSigner.stationID(from: item.url) {
                                    Text(stationID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                } else if let host = item.url?.host {
                                    Text(host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteItems)

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("换电站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }

    private func select(_ item: SwapStations) {
        for savedItem in items {
            savedItem.selected = (savedItem == item)
        }
        do {
            try viewContext.save()
            onRequestSelected(
                InfoRequest(url: item.url, headers: item.headers),
                item.name,
                item.stationID ?? NIOSwapRequestSigner.stationID(from: item.url)
            )
            isPresented = false
        } catch {
            viewContext.rollback()
            errorMessage = "无法保存站点选择：\(error.localizedDescription)"
        }
    }

    private func deleteItems(offsets: IndexSet) {
        let deletingSelected = offsets.contains { items[$0].selected }
        offsets.map { items[$0] }.forEach(viewContext.delete)
        let replacement = deletingSelected ? items.first(where: { !$0.isDeleted }) : nil
        if let replacement {
            replacement.selected = true
        }
        do {
            try viewContext.save()
            if deletingSelected {
                onRequestSelected(
                    replacement.map { InfoRequest(url: $0.url, headers: $0.headers) },
                    replacement?.name,
                    replacement.flatMap {
                        $0.stationID ?? NIOSwapRequestSigner.stationID(from: $0.url)
                    }
                )
            }
        } catch {
            viewContext.rollback()
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

struct BackendStationPickerView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default
    ) private var savedStations: FetchedResults<SwapStations>

    @Binding var isPresented: Bool
    @ObservedObject var vehicleViewModel: VehicleViewModel
    let templateRequest: InfoRequest?
    let onAdded: (InfoRequest, String, String) -> Void

    @State private var query = ""
    @State private var stations: [SwapStation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadToken = UUID()

    var body: some View {
        let savedIDs = savedStationIDs

        NavigationStack {
            List {
                if !vehicleViewModel.isConfigured {
                    Section {
                        Label(
                            "请先从换电站页面右上角的菜单配置车辆后端。",
                            systemImage: "server.rack"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                if templateRequest == nil && !vehicleViewModel.isConfigured {
                    Section {
                        Label(
                            "请先通过 cURL 添加一个换电站，后续站点将复用它的授权和请求参数。",
                            systemImage: "key.horizontal"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                if isLoading && stations.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("正在查询后端站点…")
                        Spacer()
                    }
                } else if stations.isEmpty && errorMessage == nil
                    && vehicleViewModel.isConfigured {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "后端暂无换电站" : "没有匹配的换电站",
                        systemImage: "bolt.car",
                        description: Text("可按站点名称、ID、地址或运营方搜索。")
                    )
                }

                if isLoading && !stations.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("正在更新结果…")
                        Spacer()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                ForEach(stations) { station in
                    Button {
                        add(station)
                    } label: {
                        stationRow(station, isSaved: savedIDs.contains(station.stationID))
                    }
                    .foregroundStyle(.primary)
                    .disabled(
                        (templateRequest == nil && !vehicleViewModel.isConfigured)
                            || savedIDs.contains(station.stationID)
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("从后端添加")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "名称、站点 ID 或地址")
            .refreshable { await loadStations(debounce: false) }
            .task(id: query) { await loadStations(debounce: true) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
        }
    }

    private func stationRow(_ station: SwapStation, isSaved: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSaved ? "checkmark.circle.fill" : "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(isSaved ? .green : .teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(station.stationName)
                    .font(.headline)
                Text(station.stationID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let address = station.stationAddress, !address.isEmpty {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if isSaved {
                Text("已添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var savedStationIDs: Set<String> {
        Set(savedStations.compactMap {
            $0.stationID ?? NIOSwapRequestSigner.stationID(from: $0.url)
        })
    }

    private func loadStations(debounce: Bool) async {
        let token = UUID()
        loadToken = token
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard vehicleViewModel.isConfigured else {
            stations = []
            errorMessage = nil
            isLoading = false
            return
        }

        if debounce && !normalizedQuery.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
        }
        guard loadToken == token, !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer {
            if loadToken == token { isLoading = false }
        }

        do {
            let result = try await vehicleViewModel.fetchSwapStations(
                search: normalizedQuery.isEmpty ? nil : normalizedQuery
            )
            guard loadToken == token, !Task.isCancelled else { return }
            stations = result
        } catch is CancellationError {
            return
        } catch {
            guard loadToken == token, !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            stations = []
        }
    }

    private func add(_ station: SwapStation) {
        do {
            // The backend queries saved stations itself, so a captured request is
            // only needed when there is no backend to ask.
            let request: InfoRequest
            if let templateRequest {
                request = try templateRequest.replacingStationID(station.stationID)
            } else if vehicleViewModel.isConfigured {
                request = InfoRequest(url: NIOSwapRequestSigner.stationURL(for: station.stationID), headers: [:])
            } else {
                errorMessage = "请先配置车辆后端，或通过 cURL 添加一个可用的换电站请求。"
                return
            }
            let insertionIndex = nextIndex
            let newItem = SwapStations(context: viewContext)
            newItem.stationID = station.stationID
            newItem.name = station.stationName
            newItem.url = request.url
            newItem.headers = request.headers
            newItem.index = insertionIndex
            savedStations.forEach { $0.selected = false }
            newItem.selected = true
            try viewContext.save()
            onAdded(request, station.stationName, station.stationID)
            isPresented = false
        } catch {
            viewContext.rollback()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "添加换电站失败：\(error.localizedDescription)"
        }
    }

    private var nextIndex: Int16 {
        let maximum = savedStations.map(\.index).max() ?? -1
        return maximum == Int16.max ? Int16.max : maximum + 1
    }
}

struct NearbyStationsSheetView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default
    ) private var savedStations: FetchedResults<SwapStations>

    @Binding var isPresented: Bool
    @ObservedObject var vehicleViewModel: VehicleViewModel
    let templateRequest: InfoRequest?
    let onStationSelected: (InfoRequest, String, String) -> Void

    @State private var stations: [NearbyStation] = []
    @State private var selectedStationID: String?
    @State private var energyEstimates: [String: StraightLineEnergyEstimate] = [:]
    @State private var loadingEstimateID: String?
    @State private var estimateErrorMessage: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var stationToSendToVehicle: NearbyStation?

    private var vehicleCoordinate: VehicleCoordinate? {
        guard let location = vehicleViewModel.dashboard?.location, location.isValid else { return nil }
        return location
    }

    private var selectedStation: NearbyStation? {
        guard let selectedStationID else { return stations.first }
        return stations.first(where: { $0.stationID == selectedStationID }) ?? stations.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        if let vehicleCoordinate {
                            mapSection(vehicleCoordinate: vehicleCoordinate)

                            if let selected = selectedStation {
                                selectedStationCard(selected, from: vehicleCoordinate)
                            }

                            if let errorMessage {
                                errorCard(errorMessage)
                            } else if isLoading && stations.isEmpty {
                                HStack {
                                    Spacer()
                                    ProgressView("正在搜索车辆附近换电站…")
                                    Spacer()
                                }
                                .nioCard(cornerRadius: 20, padding: 24)
                            } else if stations.isEmpty {
                                ContentUnavailableView(
                                    "附近暂无换电站",
                                    systemImage: "bolt.car",
                                    description: Text("当前视野范围内未返回蔚来换电站，可刷新重试。")
                                )
                                .nioCard(cornerRadius: 20, padding: 20)
                            } else {
                                stationListCard
                            }
                        } else {
                            ContentUnavailableView {
                                Label("暂未获取到车辆定位", systemImage: "location.slash")
                            } description: {
                                Text("需要车辆最新有效坐标才能查询附近换电站与直线能耗估算。")
                            } actions: {
                                Button("刷新车辆定位") {
                                    Task {
                                        await vehicleViewModel.refreshLiveData()
                                        await loadNearbyStations()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .nioCard(cornerRadius: 22, padding: 22)
                        }
                    }
                    .padding(16)
                }
                .refreshable { await loadNearbyStations() }
            }
            .navigationTitle("附近换电站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadNearbyStations() }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading || vehicleCoordinate == nil)
                    .accessibilityLabel("刷新附近换电站")
                }
            }
            .task {
                await loadNearbyStations()
            }
            .task(id: selectedStation?.stationID) {
                guard let selected = selectedStation, let vehicleCoordinate else { return }
                await loadEnergyEstimate(for: selected, from: vehicleCoordinate)
            }
            .sheet(item: $stationToSendToVehicle) { station in
                SendRouteToVehicleSheet(
                    isPresented: Binding(
                        get: { stationToSendToVehicle != nil },
                        set: { shown in if !shown { stationToSendToVehicle = nil } }
                    ),
                    viewModel: vehicleViewModel,
                    initialDestination: SendRoutePoiInput(
                        name: station.displayName,
                        address: station.displayName,
                        latitude: station.latitude,
                        longitude: station.longitude,
                        resourceID: station.stationID,
                        stationType: .dest
                    )
                )
            }
        }
    }

    private func mapSection(vehicleCoordinate: VehicleCoordinate) -> some View {
        Map(position: $cameraPosition) {
            Annotation(
                "当前车辆",
                coordinate: CLLocationCoordinate2D(
                    latitude: vehicleCoordinate.latitude,
                    longitude: vehicleCoordinate.longitude
                )
            ) {
                Image(systemName: "car.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(AppPalette.violet, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 3)
            }

            ForEach(stations) { station in
                let isSelected = station.stationID == selectedStation?.stationID
                Annotation(
                    station.displayName,
                    coordinate: CLLocationCoordinate2D(
                        latitude: station.latitude,
                        longitude: station.longitude
                    )
                ) {
                    Button {
                        selectStation(station, centerOnMap: true)
                    } label: {
                        Image(systemName: "bolt.car.fill")
                            .font(.system(size: isSelected ? 14 : 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(isSelected ? 9 : 7)
                            .background(
                                isSelected ? AppPalette.green : AppPalette.blue,
                                in: Circle()
                            )
                            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2.5 : 1.8))
                            .shadow(radius: isSelected ? 5 : 2.5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .frame(height: 256)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) {
            if !stations.isEmpty {
                Label("视野内 \(stations.count) 座换电站", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    cameraPosition = overviewCameraPosition(vehicleCoordinate: vehicleCoordinate)
                }
            } label: {
                Image(systemName: "location.fill.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.blue)
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            }
            .accessibilityLabel("显示全部附近换电站")
            .padding(12)
        }
        .nioCard(cornerRadius: 24, padding: 10)
    }

    private func selectedStationCard(
        _ station: NearbyStation,
        from vehicleCoordinate: VehicleCoordinate
    ) -> some View {
        let estimate = energyEstimates[station.stationID]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.displayName)
                        .font(.headline)
                    Text(station.stationID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(String(format: "直线 %.1f km", station.straightLineDistanceKm))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppPalette.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppPalette.blue.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                if loadingEstimateID == station.stationID && estimate == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("正在按近期百公里电耗估算直线能耗…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let estimate {
                    HStack(spacing: 12) {
                        if let kwh = estimate.estimatedEnergyForStraightLineKWh {
                            Label(
                                String(format: "直线约耗电 %.2f kWh", kwh),
                                systemImage: "bolt.fill"
                            )
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(AppPalette.green)
                        } else {
                            Label("暂无近期电耗基准", systemImage: "bolt.slash")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let rate = estimate.energyCache.summary?.consumptionKWhPer100Km {
                            Text(String(format: "%.1f kWh/100km", rate))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("基于车辆近期行程缓存的直线距离估算，未含路网绕行与实时路况。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let estimateErrorMessage {
                    Text("能耗估算暂不可用：\(estimateErrorMessage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    inspectStation(station)
                } label: {
                    Label("查看该站实况", systemImage: "bolt.car.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(.white)
                        .background(AppPalette.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.97))

                Button {
                    stationToSendToVehicle = station
                } label: {
                    Label("发车机", systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .foregroundStyle(AppPalette.green)
                        .background(AppPalette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.95))

                Button {
                    openDirections(to: station)
                } label: {
                    Label("导航", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .foregroundStyle(AppPalette.blue)
                        .background(AppPalette.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(TactileScaleButtonStyle(pressedScale: 0.95))
            }
        }
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private var stationListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("按直线距离排序", systemImage: "list.bullet")
                    .font(.headline)
                Spacer()
                Text("\(stations.count) 座")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(stations) { station in
                let isSelected = station.stationID == selectedStation?.stationID
                Button {
                    selectStation(station, centerOnMap: true)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "bolt.car.circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? AppPalette.green : AppPalette.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(station.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let estimate = energyEstimates[station.stationID]?.estimatedEnergyForStraightLineKWh {
                                Text(String(format: "直线约耗电 %.2f kWh", estimate))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(AppPalette.green)
                            } else {
                                Text(station.stationID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f km", station.straightLineDistanceKm))
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(isSelected ? AppPalette.green : .secondary)
                    }
                    .padding(12)
                    .background(
                        isSelected ? AppPalette.green.opacity(0.09) : AppPalette.canvas,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .nioCard(cornerRadius: 22, padding: 18)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") {
                Task { await loadNearbyStations() }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    private func selectStation(_ station: NearbyStation, centerOnMap: Bool) {
        selectedStationID = station.stationID
        if centerOnMap {
            withAnimation(.easeInOut(duration: 0.3)) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                ))
            }
        }
    }

    private func overviewCameraPosition(vehicleCoordinate: VehicleCoordinate) -> MapCameraPosition {
        var coords = stations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        coords.append(CLLocationCoordinate2D(latitude: vehicleCoordinate.latitude, longitude: vehicleCoordinate.longitude))
        guard let first = coords.first else { return .automatic }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coord in coords.dropFirst() {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(maxLat - minLat, 0.02) * 1.35,
                longitudeDelta: max(maxLon - minLon, 0.02) * 1.35
            )
        ))
    }

    private func loadNearbyStations() async {
        guard let vehicleCoordinate, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await vehicleViewModel.fetchNearbyStations(
                latitude: vehicleCoordinate.latitude,
                longitude: vehicleCoordinate.longitude
            )
            stations = result.stations
            if selectedStationID == nil || !result.stations.contains(where: { $0.stationID == selectedStationID }) {
                selectedStationID = result.stations.first?.stationID
            }
            cameraPosition = overviewCameraPosition(vehicleCoordinate: vehicleCoordinate)
        } catch {
            if !error.isTaskCancellation {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadEnergyEstimate(
        for station: NearbyStation,
        from vehicleCoordinate: VehicleCoordinate
    ) async {
        guard energyEstimates[station.stationID] == nil else { return }
        loadingEstimateID = station.stationID
        estimateErrorMessage = nil
        defer {
            if loadingEstimateID == station.stationID { loadingEstimateID = nil }
        }
        do {
            let estimate = try await vehicleViewModel.fetchStraightLineEnergy(
                stationID: station.stationID,
                latitude: vehicleCoordinate.latitude,
                longitude: vehicleCoordinate.longitude,
                stationLatitude: station.latitude,
                stationLongitude: station.longitude
            )
            energyEstimates[station.stationID] = estimate
        } catch {
            if !error.isTaskCancellation {
                estimateErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func inspectStation(_ station: NearbyStation) {
        do {
            let request: InfoRequest
            if let templateRequest {
                request = try templateRequest.replacingStationID(station.stationID)
            } else {
                request = InfoRequest(
                    url: NIOSwapRequestSigner.stationURL(for: station.stationID),
                    headers: [:]
                )
            }
            let existing = savedStations.first {
                ($0.stationID ?? NIOSwapRequestSigner.stationID(from: $0.url)) == station.stationID
            }
            let item = existing ?? SwapStations(context: viewContext)
            if item.isInserted {
                let maximum = savedStations.map(\.index).max() ?? -1
                item.index = maximum == Int16.max ? Int16.max : maximum + 1
            }
            item.stationID = station.stationID
            item.name = station.displayName
            item.url = request.url
            item.headers = request.headers
            savedStations.forEach { $0.selected = ($0 == item) }
            item.selected = true
            try viewContext.save()
            onStationSelected(request, station.displayName, station.stationID)
            isPresented = false
        } catch {
            viewContext.rollback()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "切换站点失败：\(error.localizedDescription)"
        }
    }

    private func openDirections(to station: NearbyStation) {
        let placemark = MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        )
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = station.displayName
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}
