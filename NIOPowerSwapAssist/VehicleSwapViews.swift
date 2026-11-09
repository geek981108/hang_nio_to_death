import SwiftUI

struct SwapRecordsListView: View {
    @ObservedObject var viewModel: VehicleViewModel

    var body: some View {
        Group {
            if viewModel.activeServiceOrders.isEmpty,
               viewModel.swapEvents.isEmpty,
               viewModel.activeServiceOrdersErrorMessage == nil,
               viewModel.swapEventsErrorMessage == nil {
                ContentUnavailableView(
                    "暂无换电记录",
                    systemImage: "arrow.triangle.2.circlepath.circle",
                    description: Text("同步到已完成的换电订单后会显示在这里。")
                )
            } else {
                List {
                    if let error = viewModel.activeServiceOrdersErrorMessage {
                        Label("进行中订单：\(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let error = viewModel.swapEventsErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if !viewModel.activeServiceOrders.isEmpty {
                        Section("进行中") {
                            ForEach(viewModel.activeServiceOrders) { order in
                                ActiveServiceOrderRow(
                                    order: order,
                                    notificationsEnabled: viewModel.queueNotificationsEnabled
                                ) {
                                    Task {
                                        await viewModel.setQueueNotificationsEnabled(
                                            !viewModel.queueNotificationsEnabled
                                        )
                                    }
                                }
                                    .padding(.vertical, 5)
                            }
                        }
                    }
                    if !viewModel.swapEvents.isEmpty {
                        Section("已完成") {
                            ForEach(viewModel.swapEvents) { event in
                                NavigationLink {
                                    SwapEventDetailView(viewModel: viewModel, initialEvent: event)
                                } label: {
                                    SwapEventRow(event: event)
                                        .padding(.vertical, 5)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("换电记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refreshSwapEvents() }
        .task {
            if viewModel.swapEvents.isEmpty {
                await viewModel.refreshSwapEvents()
            }
        }
    }
}

struct ActiveServiceOrderRow: View {
    let order: ActiveServiceOrder
    let notificationsEnabled: Bool
    let toggleNotifications: () -> Void

    init(
        order: ActiveServiceOrder,
        notificationsEnabled: Bool = false,
        toggleNotifications: @escaping () -> Void = {}
    ) {
        self.order = order
        self.notificationsEnabled = notificationsEnabled
        self.toggleNotifications = toggleNotifications
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 5) {
                    Text(order.stationName ?? order.stationAddress ?? "正在确认换电站")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(formatDateTime(order.orderCreatedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(order.orderStatusName ?? "进行中")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }

            if order.queueNumber != nil || order.vehiclesAhead != nil {
                HStack(spacing: 8) {
                    if let queueNumber = order.queueNumber {
                        queueBadge("换电号 \(String(format: "%02d", queueNumber))", color: .blue)
                    }
                    if let vehiclesAhead = order.vehiclesAhead {
                        queueBadge(
                            vehiclesAhead == 0 ? "已到你" : "前方 \(vehiclesAhead) 辆",
                            color: vehiclesAhead <= 1 ? .green : .orange
                        )
                    }
                    if let minutes = order.estimatedWaitMinutes {
                        queueBadge(
                            order.estimatedWaitSource == "swap_order_status"
                                ? "预计等待 \(minutes) 分钟"
                                : "预计约 \(minutes) 分钟",
                            color: .secondary
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                Text(order.queueStatusText ?? "订单号 \(order.orderNo)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: toggleNotifications) {
                    Label(
                        notificationsEnabled ? "已开启临近提醒" : "临近时提醒我",
                        systemImage: notificationsEnabled ? "bell.fill" : "bell"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            if order.estimatedWaitSource == "station_queue_estimate",
               order.estimatedWaitMinutes != nil {
                Text("等待时间按当前前车数 × 约 5 分钟估算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func queueBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func formatDateTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return String(
            format: "%04d/%02d/%02d %02d:%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0,
            values.hour ?? 0,
            values.minute ?? 0
        )
    }
}

struct SwapEventRow: View {
    let event: SwapEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 42, height: 42)
                .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 5) {
                Text(event.stationName ?? event.stationAddress ?? "未知换电站")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(formatDateTime(event.occurredAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let old = event.outgoingBatteryID, let new = event.incomingBatteryID {
                    Text("旧 \(old) → 新 \(new)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(priceLabel)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                if let energy = event.exactEnergyKWh {
                    Text(String(format: "%.1f kWh", energy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let energy = event.estimatedEnergyKWh {
                    Text(String(format: "约 %.1f kWh", energy))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var priceLabel: String {
        if let amount = event.priceAmount { return moneyLabel(amount) }
        return event.priceDescription ?? "价格未知"
    }

    private func moneyLabel(_ amount: Double) -> String {
        let sign = amount < 0 ? "-" : ""
        let magnitude = abs(amount)
        if event.priceCurrency == nil || event.priceCurrency == "CNY" {
            return String(format: "%@¥%.2f", sign, magnitude)
        }
        return String(format: "%@%@ %.2f", sign, event.priceCurrency ?? "", magnitude)
    }

    private func formatDateTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d/%02d/%02d %02d:%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0,
            values.hour ?? 0,
            values.minute ?? 0
        )
    }
}

struct SwapEventDetailView: View {
    @ObservedObject var viewModel: VehicleViewModel
    let initialEvent: SwapEvent
    @State private var event: SwapEvent
    @State private var loadError: String?

    init(viewModel: VehicleViewModel, initialEvent: SwapEvent) {
        self.viewModel = viewModel
        self.initialEvent = initialEvent
        _event = State(initialValue: initialEvent)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                batteryCard(
                    title: "旧电池（从车上换下）",
                    icon: "arrow.down.to.line.circle.fill",
                    color: AppPalette.amber,
                    batteryID: event.outgoingBatteryID,
                    capacity: event.outgoingCapacityKWh,
                    soc: event.outgoingSOCPercent,
                    productionDate: event.outgoingProductionDate
                )
                batteryCard(
                    title: "新电池（换到车上）",
                    icon: "arrow.up.to.line.circle.fill",
                    color: AppPalette.green,
                    batteryID: event.incomingBatteryID,
                    capacity: event.incomingCapacityKWh,
                    soc: event.incomingSOCPercent,
                    productionDate: event.incomingProductionDate
                )
                orderCard
                sourceCard

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(AppPalette.canvas)
        .navigationTitle("换电详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                event = try await viewModel.fetchSwapEvent(id: initialEvent.id)
            } catch is CancellationError {
                return
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.stationName ?? "未知换电站")
                        .font(.title3.bold())
                    if let address = event.stationAddress {
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(priceLabel)
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(AppPalette.amber)
            }
            detailLine("记录时间", formatDateTime(event.occurredAt))
            detailLine("换电电量", energyLabel)
            if let status = event.orderStatusName { detailLine("订单状态", status) }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func batteryCard(
        title: String,
        icon: String,
        color: Color,
        batteryID: String?,
        capacity: Double?,
        soc: Double?,
        productionDate: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            detailLine("电池编号", batteryID ?? "未获取")
            if let capacity { detailLine("电池容量", String(format: "%.1f kWh", capacity)) }
            if let soc { detailLine("换电时 SOC", String(format: "%.0f%%", soc)) }
            if let productionDate { detailLine("生产日期", productionDate) }
            if batteryID == nil {
                Text("订单数据不含电池编号；只有站端库存变化可唯一匹配时才会补充。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var orderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("订单与费用", systemImage: "list.bullet.rectangle")
                .font(.headline)
            if let orderNo = event.orderNo { detailLine("订单号", orderNo) }
            if let description = event.priceDescription { detailLine("支付说明", description) }
            ForEach(Array(event.paymentItems.enumerated()), id: \.offset) { _, item in
                detailLine(item.name, moneyLabel(item.amount))
            }
            if let amount = event.priceAmount {
                if !event.paymentItems.isEmpty { Divider() }
                detailLine("实付", moneyLabel(amount))
                    .fontWeight(.semibold)
            }
            if event.orderNo == nil && event.priceDescription == nil && event.paymentItems.isEmpty {
                Text("暂无更多订单费用信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("数据说明", systemImage: "checkmark.shield")
                .font(.headline)
            detailLine("记录可信度", confidenceLabel)
            detailLine("电池信息来源", batterySourceLabel)
            detailLine("电量来源", energySourceLabel)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private var priceLabel: String {
        if let amount = event.priceAmount { return moneyLabel(amount) }
        return event.priceDescription ?? "价格未知"
    }

    private func moneyLabel(_ amount: Double) -> String {
        let sign = amount < 0 ? "-" : ""
        let magnitude = abs(amount)
        if event.priceCurrency == nil || event.priceCurrency == "CNY" {
            return String(format: "%@¥%.2f", sign, magnitude)
        }
        return String(format: "%@%@ %.2f", sign, event.priceCurrency ?? "", magnitude)
    }

    private var energyLabel: String {
        if let value = event.exactEnergyKWh { return String(format: "%.2f kWh（订单值）", value) }
        if let value = event.estimatedEnergyKWh { return String(format: "约 %.2f kWh（估算）", value) }
        return "未获取"
    }

    private var confidenceLabel: String {
        switch event.confidence {
        case "exact": return "精确"
        case "high": return "高"
        case "medium": return "中"
        default: return "低"
        }
    }

    private var batterySourceLabel: String {
        switch event.batterySource {
        case "station_inventory_delta": return "换电站库存差分"
        case "order_import": return "订单导入"
        default: return "未获取"
        }
    }

    private var energySourceLabel: String {
        switch event.energySource {
        case "order_import": return "订单值"
        case "station_inventory_estimate": return "根据容量与 SOC 估算"
        default: return "未获取"
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let values = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d/%02d/%02d %02d:%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0,
            values.hour ?? 0,
            values.minute ?? 0
        )
    }
}
