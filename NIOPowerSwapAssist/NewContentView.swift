//
//  NewContentView.swift
//  NIOPowerSwapAssist
//
//  Created by GitHub Copilot on 2025/1/2.
//

import SwiftUI
import CoreData
import UIKit

struct NewContentView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default)
    private var items: FetchedResults<SwapStations>
    @State private var batteries: [BatteryModel] = []
    @State private var feeInfo: FeeInfo?
    @State private var showingCurlInput = false
    @State private var showingSavedRequests = false
    @State private var isLoading = false
    @State private var currentRequestName: String?
    
    // 按电池类型分组的计算属性
    private var groupedBatteries: [String: [BatteryModel]] {
        Dictionary(grouping: batteries) { battery in
            // 提取电池类型（去掉电池ID部分）
            let components = battery.batteryType.components(separatedBy: "-")
            return components.dropLast().joined(separator: "-")
        }
    }
    
    // 排序后的电池类型数组
    private var sortedBatteryTypes: [String] {
        let types = groupedBatteries.keys.sorted()
        // 将 70/25KWH 类型移到最前面
        return types.sorted { type1, type2 in
            if type1.contains("70/75") {
                return true
            }
            if type2.contains("70/75") {
                return false
            }
            return type1 < type2
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .padding()
                }
                
                List {
                    if let feeInfo = feeInfo {
                        Section {
                            NewFeeInfoView(feeInfo: feeInfo)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        } header: {
                            Spacer(minLength: 0)
                        }
                    }
                    
                    ForEach(sortedBatteryTypes, id: \.self) { batteryType in
                        Section(header: 
                            Text(batteryType)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .padding(.vertical, 4)
                        ) {
                            ForEach(groupedBatteries[batteryType] ?? [], id: \.batterySlotID) { battery in
                                NewCardView(batteryModel: battery)
                            }
                        }
                    }
                }
                .refreshable(action: {
                    await refreshWithCurrentRequest()
                })
                .listStyle(.insetGrouped)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let name = currentRequestName {
                        Text(name)
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSavedRequests = true }) {
                        Label("Saved Requests", systemImage: "list.bullet")
                    }
                }
                ToolbarItem {
                    Button(action: { showingCurlInput = true }) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCurlInput) {
                NewCurlInputView(isPresented: $showingCurlInput, viewContext: viewContext)
            }
            .sheet(isPresented: $showingSavedRequests) {
                NewSavedRequestsView(isPresented: $showingSavedRequests, onRequestSelected: { request, name in
                    Task {
                        await refreshWithRequest(request, name: name)
                    }
                })
            }
            Text("Select an item")
        }
    }

    private func refreshWithCurrentRequest() async {
        if let selectedItem = items.first(where: { $0.selected }) {
            var request = InfoRequest()
            request.url = selectedItem.url
            request.headers = selectedItem.headers
            await refreshWithRequest(request, name: selectedItem.name)
        } else {
            // 如果没有选中的请求，使用默认请求
            let request = InfoRequest()
            await refreshWithRequest(request, name: nil)
        }
    }
    
    private func refreshWithRequest(_ request: InfoRequest, name: String?) async {
        await MainActor.run {
            isLoading = true
            currentRequestName = name
        }
        
        // 使用 async/await 包装回调式的 API
        await withCheckedContinuation { continuation in
            request.doHttpRequest { infoData in
                Task { @MainActor in
                    handleListRefresh(infoData: infoData)
                    isLoading = false
                    continuation.resume()
                }
            }
        }
    }

    private func addItem() {
        showingCurlInput = true
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { items[$0] }.forEach(viewContext.delete)
            do {
                try viewContext.save()
            } catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }

    private func handleListRefresh(infoData: String?) {
        guard let infoData = infoData else {
            print("Error: infoData is nil")
            return
        }
        
        guard let data = infoData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Error: Failed to parse JSON")
            return
        }
        
        guard let batteryInfo = json["battery"] as? [String: Any] else {
            print("Error: Missing battery info in JSON")
            return
        }
        
        // Parse Fee Info
        if let feeInfoDict = json["fee_info"] as? [String: Any],
           let currentFeeList = feeInfoDict["current_fee"] as? [[String: Any]] {
            let fees = currentFeeList.map { item -> FeeItem in
                return FeeItem(
                    name: item["name"] as? String ?? "",
                    fee: item["fee"] as? String ?? "",
                    unit: item["unit"] as? String ?? "",
                    currency: item["currency"] as? String ?? ""
                )
            }
            self.feeInfo = FeeInfo(currentFees: fees)
        }
        
        var batteryList: [[String: Any]] = []
        if let sortList = batteryInfo["battery_cap_level_sort_list"] as? [[String: Any]] {
            for item in sortList {
                if let list = item["battery_list"] as? [[String: Any]] {
                    batteryList.append(contentsOf: list)
                }
            }
        } else if let list = batteryInfo["battery_list"] as? [[String: Any]] {
            batteryList = list
        } else {
            print("Warning: No battery list found")
        }
        
        batteries = batteryList.map { battery -> BatteryModel in
            let batteryId = battery["battery_id"] as? String ?? ""
            let batteryManufactureTimeRaw = String(batteryId[batteryId.index(batteryId.startIndex, offsetBy: 10)..<batteryId.index(batteryId.startIndex, offsetBy: 15)])
            let batteryManufactureTimeString = "20" + batteryManufactureTimeRaw.suffix(2) + "-" + batteryManufactureTimeRaw.prefix(3)
            let progress = battery["progress"] as? Double ?? 0.0
            let batteryType = battery["lower_case_desc"] as? String ?? ""
            let remainingTime = Int(battery["charging_time_desc"] as? String ?? "0") ?? 0
            let occupied = battery["battery_occupied"] as? Bool ?? false
            let slotId = battery["slot_id"] as? Int ?? 0
            
            return BatteryModel(
                batteryCharingProgress: "\(Int(progress))%",
                batteryType: batteryType.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") + "-" + batteryId.prefix(5),
                batteryCharingRemainingTime: remainingTime,
                batteryOccupied: occupied,
                battetyManufactureTime: batteryManufactureTimeString,
                batterySlotID: slotId
            )
        }
        print("Batteries count: \(batteries.count)")
    }
}

struct NewCurlInputView: View {
    @Binding var isPresented: Bool
    let viewContext: NSManagedObjectContext
    
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default)
    private var items: FetchedResults<SwapStations>
    
    @State private var name: String = ""
    @State private var curlCommand: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Request Name")) {
                    TextField("Enter a name for this request", text: $name)
                }
                
                Section(header: Text("Curl Command")) {
                    TextEditor(text: $curlCommand)
                        .frame(height: 200)
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Request")
            .navigationBarItems(
                leading: Button("Cancel") {
                    isPresented = false
                },
                trailing: Button("Save") {
                    saveRequest()
                }
                .disabled(name.isEmpty || curlCommand.isEmpty)
            )
            
        }
    }
    
    private func saveRequest() {
        guard let request = parseCurlCommand(curlCommand) else { return }
        
        let newItem = SwapStations(context: viewContext)
        newItem.name = name
        newItem.url = request.url
        newItem.headers = request.headers
        newItem.index = Int16(items.count)
        
        do {
            try viewContext.save()
            isPresented = false
        } catch {
            errorMessage = "Failed to save request: \(error.localizedDescription)"
        }
    }
    
    private func parseCurlCommand(_ command: String) -> InfoRequest? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard trimmedCommand.hasPrefix("curl") else {
            errorMessage = "Invalid curl command: Must start with 'curl'"
            return nil
        }
        
        // 提取 URL
        let urlPattern = "'([^']+)'"
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern),
              let urlMatch = urlRegex.firstMatch(in: trimmedCommand, range: NSRange(trimmedCommand.startIndex..., in: trimmedCommand)),
              let urlRange = Range(urlMatch.range(at: 1), in: trimmedCommand),
              let url = URL(string: String(trimmedCommand[urlRange])) else {
            errorMessage = "Invalid curl command: Could not parse URL"
            return nil
        }
        
        // 提取 headers
        var headers: [String: String] = [:]
        let headerPattern = "-H '([^:]+): ([^']*)'"
        if let headerRegex = try? NSRegularExpression(pattern: headerPattern) {
            let matches = headerRegex.matches(in: trimmedCommand, range: NSRange(trimmedCommand.startIndex..., in: trimmedCommand))
            for match in matches {
                if let headerNameRange = Range(match.range(at: 1), in: trimmedCommand),
                   let headerValueRange = Range(match.range(at: 2), in: trimmedCommand) {
                    let name = String(trimmedCommand[headerNameRange])
                    let value = String(trimmedCommand[headerValueRange])
                    headers[name] = value
                }
            }
        }
        
        // 如果没有找到任何 headers，尝试另一种格式
        if headers.isEmpty {
            let altHeaderPattern = "-H \"([^:]+): ([^\"]*)\""
            if let headerRegex = try? NSRegularExpression(pattern: altHeaderPattern) {
                let matches = headerRegex.matches(in: trimmedCommand, range: NSRange(trimmedCommand.startIndex..., in: trimmedCommand))
                for match in matches {
                    if let headerNameRange = Range(match.range(at: 1), in: trimmedCommand),
                       let headerValueRange = Range(match.range(at: 2), in: trimmedCommand) {
                        let name = String(trimmedCommand[headerNameRange])
                        let value = String(trimmedCommand[headerValueRange])
                        headers[name] = value
                    }
                }
            }
        }
        
        var request = InfoRequest()
        request.url = url
        request.headers = headers
        
        return request
    }
}

struct NewSavedRequestsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SwapStations.index, ascending: true)],
        animation: .default)
    private var items: FetchedResults<SwapStations>
    
    @Binding var isPresented: Bool
    let onRequestSelected: (InfoRequest, String?) -> Void
    
    var body: some View {
        NavigationView {
            List {
                ForEach(items) { item in
                    HStack {
                        Button(action: {
                            // 取消其他项目的选中状态
                            for otherItem in items {
                                if otherItem != item {
                                    otherItem.selected = false
                                }
                            }
                            // 切换当前项目的选中状态
                            item.selected.toggle()
                            
                            // 如果选中了，执行请求
                            if item.selected {
                                var request = InfoRequest()
                                request.url = item.url
                                request.headers = item.headers
                                onRequestSelected(request, item.name)
                                isPresented = false
                            }
                            
                            // 保存更改
                            try? viewContext.save()
                        }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Unnamed Request")
                                        .font(.headline)
                                    if let url = item.url {
                                        Text(url.absoluteString)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                                Spacer()
                                if item.selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .navigationTitle("Saved Requests")
            .navigationBarItems(trailing: Button("Done") {
                isPresented = false
            })
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { items[$0] }.forEach(viewContext.delete)
            do {
                try viewContext.save()
            } catch {
                print("Error deleting item: \(error)")
            }
        }
    }
}

struct NewFeeInfoView: View {
    let feeInfo: FeeInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Current Rates", systemImage: "yensign.circle.fill")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(feeInfo.currentFees, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(item.currency)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                Text(item.fee)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("/" + item.unit)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(minWidth: 100, alignment: .leading)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .padding(.horizontal)
    }
}

#Preview {
    NewContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
