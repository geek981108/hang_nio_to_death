import CoreData
import SwiftUI

struct RequestEditorView: View {
    @Binding var isPresented: Bool
    let viewContext: NSManagedObjectContext
    let onSaved: (InfoRequest, String) -> Void

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
            onSaved(request, normalizedName)
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
    let onRequestSelected: (InfoRequest?, String?) -> Void
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
            onRequestSelected(InfoRequest(url: item.url, headers: item.headers), item.name)
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
                    replacement?.name
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
    let onAdded: (InfoRequest, String) -> Void

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

                if templateRequest == nil {
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
                    .disabled(templateRequest == nil || savedIDs.contains(station.stationID))
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
        guard let templateRequest else {
            errorMessage = "请先通过 cURL 添加一个可用的换电站请求。"
            return
        }
        do {
            let request = try templateRequest.replacingStationID(station.stationID)
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
            onAdded(request, station.stationName)
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
