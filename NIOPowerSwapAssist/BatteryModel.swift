import Foundation

struct BatteryModel: Identifiable, Hashable {
    enum Status: String {
        case occupied = "使用中"
        case ready = "可换电"
        case charging = "充电中"
    }

    let id: String
    let chargingProgress: Double
    let batteryType: String
    let chargingRemainingMinutes: Int?
    let isOccupied: Bool
    let manufactureDate: String?
    let slotID: Int

    var status: Status {
        if isOccupied { return .occupied }
        return chargingProgress >= 92 ? .ready : .charging
    }

    var progressFraction: Double {
        min(max(chargingProgress / 100, 0), 1)
    }

    var progressText: String {
        "\(Int(chargingProgress.rounded()))%"
    }

    var groupName: String {
        let normalized = batteryType
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains("70/75") || normalized.contains("70-75") {
            return "70/75 kWh"
        }
        if normalized.contains("150") { return "150 kWh" }
        if normalized.contains("102") { return "102 kWh" }
        if normalized.contains("100") { return "100 kWh" }
        if normalized.contains("75") { return "75 kWh" }
        if normalized.contains("70") { return "70 kWh" }
        return batteryType.isEmpty ? "其他电池" : batteryType
    }
}

struct FeeItem: Hashable, Identifiable {
    var id: String { "\(name)-\(unit)" }
    let type: String?
    let name: String
    let fee: String
    let unit: String
    let currency: String

    init(type: String? = nil, name: String, fee: String, unit: String, currency: String) {
        self.type = type
        self.name = name
        self.fee = fee
        self.unit = unit
        self.currency = currency
    }

    var isTotal: Bool {
        if type?.lowercased().contains("total_fee") == true { return true }
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return normalizedName == "合计"
            || normalizedName == "总计"
            || normalizedName.contains("总费用")
            || normalizedName == "total"
            || normalizedName == "totalfee"
    }
}

struct FeePeriod: Hashable, Identifiable {
    let timePeriod: String
    let fees: [FeeItem]

    var id: String { timePeriod }

    var startMinute: Int? { Self.minute(from: timePeriod, at: 0) }
    var endMinute: Int? { Self.minute(from: timePeriod, at: 1) }

    var totalItem: FeeItem? {
        fees.first(where: \.isTotal)
    }

    var componentFees: [FeeItem] {
        fees.filter { !$0.isTotal }
    }

    var total: Double? {
        if let explicitTotal = totalItem.flatMap({ Double($0.fee) }) {
            return explicitTotal
        }
        let values = componentFees.compactMap { Double($0.fee) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var currency: String {
        totalItem?.currency ?? componentFees.first?.currency ?? "¥"
    }

    var unit: String {
        totalItem?.unit ?? componentFees.first?.unit ?? ""
    }

    func contains(minute: Int) -> Bool {
        guard let startMinute, let endMinute else { return false }
        if endMinute > startMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    private static func minute(from period: String, at index: Int) -> Int? {
        let parts = period.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.indices.contains(index) else { return nil }
        let time = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let components = time.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...24).contains(hour),
              (0...59).contains(minute),
              hour < 24 || minute == 0 else { return nil }
        return hour * 60 + minute
    }
}

struct FeeInfo: Hashable {
    let currentFees: [FeeItem]
    let periods: [FeePeriod]
    let notices: [String]

    init(currentFees: [FeeItem], periods: [FeePeriod] = [], notices: [String] = []) {
        self.currentFees = currentFees
        self.periods = periods.sorted { ($0.startMinute ?? Int.max) < ($1.startMinute ?? Int.max) }
        self.notices = notices
    }

    var totalItem: FeeItem? {
        currentFees.first(where: \.isTotal)
    }

    var componentFees: [FeeItem] {
        currentFees.filter { !$0.isTotal }
    }

    var total: Double? {
        if let explicitTotal = totalItem.flatMap({ Double($0.fee) }) {
            return explicitTotal
        }

        let values = componentFees.compactMap { Double($0.fee) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    var totalCurrency: String {
        totalItem?.currency ?? componentFees.first?.currency ?? "¥"
    }

    var totalUnit: String {
        totalItem?.unit ?? componentFees.first?.unit ?? ""
    }

    func period(atMinute minute: Int) -> FeePeriod? {
        periods.first { $0.contains(minute: minute) }
    }

    func nextPeriod(after period: FeePeriod) -> FeePeriod? {
        guard periods.count > 1,
              let index = periods.firstIndex(where: { $0.id == period.id }) else { return nil }
        return periods[(index + 1) % periods.count]
    }
}

struct SwapStationSnapshot: Hashable {
    let batteries: [BatteryModel]
    let feeInfo: FeeInfo?
}

extension BatteryModel {
    static let sampleData: [BatteryModel] = [
        BatteryModel(id: "P007-sample-1", chargingProgress: 100, batteryType: "70 kWh", chargingRemainingMinutes: nil, isOccupied: true, manufactureDate: "2025-01", slotID: 1),
        BatteryModel(id: "P007-sample-2", chargingProgress: 100, batteryType: "75 kWh", chargingRemainingMinutes: nil, isOccupied: false, manufactureDate: "2025-01", slotID: 2),
        BatteryModel(id: "P010-sample-3", chargingProgress: 80, batteryType: "100 kWh", chargingRemainingMinutes: 15, isOccupied: false, manufactureDate: "2025-01", slotID: 3)
    ]
}
