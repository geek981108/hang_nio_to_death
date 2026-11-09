import Foundation

struct VehicleSnapshot: Decodable, Equatable, Identifiable, Sendable {
    let vehicleID: String
    let sampledAt: Date
    let latitude: Double
    let longitude: Double
    let soc: Double?
    let remainingRange: Double?
    let remainingActualRange: Double?
    let mileage: Double?
    let insideTemperature: Double?
    let outsideTemperature: Double?

    var id: String {
        "\(vehicleID):\(sampledAt.timeIntervalSince1970):\(latitude):\(longitude)"
    }

    var coordinate: VehicleCoordinate {
        VehicleCoordinate(latitude: latitude, longitude: longitude)
    }

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case sampledAt = "sampled_at"
        case latitude, longitude, soc, mileage
        case remainingRange = "remaining_range"
        case remainingActualRange = "remaining_actual_range"
        case insideTemperature = "inside_temperature"
        case outsideTemperature = "outside_temperature"
    }

    init(
        vehicleID: String,
        sampledAt: Date,
        latitude: Double,
        longitude: Double,
        soc: Double? = nil,
        remainingRange: Double? = nil,
        remainingActualRange: Double? = nil,
        mileage: Double? = nil,
        insideTemperature: Double? = nil,
        outsideTemperature: Double? = nil
    ) {
        self.vehicleID = vehicleID
        self.sampledAt = sampledAt
        self.latitude = latitude
        self.longitude = longitude
        self.soc = soc
        self.remainingRange = remainingRange
        self.remainingActualRange = remainingActualRange
        self.mileage = mileage
        self.insideTemperature = insideTemperature
        self.outsideTemperature = outsideTemperature
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vehicleID = try values.decode(String.self, forKey: .vehicleID)
        let timestamp = try values.decode(String.self, forKey: .sampledAt)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sampledAt,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        sampledAt = date
        latitude = try values.decode(Double.self, forKey: .latitude)
        longitude = try values.decode(Double.self, forKey: .longitude)
        soc = try values.decodeIfPresent(Double.self, forKey: .soc)
        remainingRange = try values.decodeIfPresent(Double.self, forKey: .remainingRange)
        remainingActualRange = try values.decodeIfPresent(Double.self, forKey: .remainingActualRange)
        mileage = try values.decodeIfPresent(Double.self, forKey: .mileage)
        insideTemperature = try values.decodeIfPresent(Double.self, forKey: .insideTemperature)
        outsideTemperature = try values.decodeIfPresent(Double.self, forKey: .outsideTemperature)
    }
}

struct VehicleSnapshotPage: Decodable, Sendable {
    let items: [VehicleSnapshot]
    let limit: Int
}

struct ChargingSample: Decodable, Identifiable, Equatable, Sendable {
    let vehicleID: String
    let sampledAt: Date
    let soc: Double?
    let chargeStateCode: Int
    let currentAmps: Double?
    let powerWatts: Double?
    let voltageVolts: Double?

    var id: String { "\(vehicleID):\(sampledAt.timeIntervalSince1970)" }

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case sampledAt = "sampled_at"
        case soc
        case chargeStateCode = "charge_state"
        case currentAmps = "charging_current"
        case powerWatts = "charging_power"
        case voltageVolts = "charging_voltage"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vehicleID = try values.decode(String.self, forKey: .vehicleID)
        let timestamp = try values.decode(String.self, forKey: .sampledAt)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sampledAt,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        sampledAt = date
        soc = try values.decodeIfPresent(Double.self, forKey: .soc)
        chargeStateCode = try values.decode(Int.self, forKey: .chargeStateCode)
        currentAmps = try values.decodeIfPresent(Double.self, forKey: .currentAmps)
        powerWatts = try values.decodeIfPresent(Double.self, forKey: .powerWatts)
        voltageVolts = try values.decodeIfPresent(Double.self, forKey: .voltageVolts)
    }
}

struct VehicleChargingSamplePage: Decodable, Sendable {
    let items: [ChargingSample]
    let energyKWh: Double?
    let energyFinalized: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case energyKWh = "energy_kwh"
        case energyFinalized = "energy_finalized"
    }

    init(items: [ChargingSample], energyKWh: Double? = nil, energyFinalized: Bool = false) {
        self.items = items
        self.energyKWh = energyKWh
        self.energyFinalized = energyFinalized
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([ChargingSample].self, forKey: .items)
        energyKWh = try values.decodeIfPresent(Double.self, forKey: .energyKWh)
        energyFinalized = try values.decodeIfPresent(Bool.self, forKey: .energyFinalized) ?? false
    }
}

extension ChargingSample {
    /// The backend returns session samples in chronological order. A chart
    /// selection needs one nearest point, not a scan inside every Chart mark.
    static func nearest(in samples: [ChargingSample], to date: Date) -> ChargingSample? {
        guard !samples.isEmpty else { return nil }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].sampledAt < date { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return samples.first }
        if lower == samples.count { return samples.last }
        let before = samples[lower - 1]
        let after = samples[lower]
        return date.timeIntervalSince(before.sampledAt) <= after.sampledAt.timeIntervalSince(date)
            ? before : after
    }
}

struct ChargingSession: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let vehicleID: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let startSOC: Double?
    let endSOC: Double?
    let peakPowerWatts: Double?
    let energyKWh: Double?
    let sampleCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case vehicleID = "vehicle_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case startSOC = "start_soc"
        case endSOC = "end_soc"
        case peakPowerWatts = "peak_power_watts"
        case energyKWh = "energy_kwh"
        case sampleCount = "sample_count"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        vehicleID = try values.decode(String.self, forKey: .vehicleID)
        durationSeconds = try values.decode(Int.self, forKey: .durationSeconds)
        startSOC = try values.decodeIfPresent(Double.self, forKey: .startSOC)
        endSOC = try values.decodeIfPresent(Double.self, forKey: .endSOC)
        peakPowerWatts = try values.decodeIfPresent(Double.self, forKey: .peakPowerWatts)
        energyKWh = try values.decodeIfPresent(Double.self, forKey: .energyKWh)
        sampleCount = try values.decode(Int.self, forKey: .sampleCount)
        startedAt = try Self.decodeDate(.startedAt, from: values)
        endedAt = try Self.decodeDate(.endedAt, from: values)
    }

    func replacingEnergyKWh(_ energyKWh: Double) -> ChargingSession {
        ChargingSession(
            id: id,
            vehicleID: vehicleID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            startSOC: startSOC,
            endSOC: endSOC,
            peakPowerWatts: peakPowerWatts,
            energyKWh: energyKWh,
            sampleCount: sampleCount
        )
    }

    private init(
        id: String,
        vehicleID: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        startSOC: Double?,
        endSOC: Double?,
        peakPowerWatts: Double?,
        energyKWh: Double?,
        sampleCount: Int
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.startSOC = startSOC
        self.endSOC = endSOC
        self.peakPowerWatts = peakPowerWatts
        self.energyKWh = energyKWh
        self.sampleCount = sampleCount
    }

    private static func decodeDate(
        _ key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        let timestamp = try values.decode(String.self, forKey: key)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        return date
    }
}

struct ChargingSessionPage: Decodable, Sendable {
    let items: [ChargingSession]
    let limit: Int
}

struct SwapPaymentItem: Decodable, Equatable, Sendable {
    let name: String
    let amount: Double
    let paymentType: Int?

    enum CodingKeys: String, CodingKey {
        case name, amount
        case paymentType = "payment_type"
    }
}

struct ActiveServiceOrder: Decodable, Equatable, Identifiable, Sendable {
    let orderNo: String
    let orderType: String
    let orderStatus: String?
    let orderStatusName: String?
    let orderCreatedAt: Date
    let stationKey: String?
    let stationName: String?
    let stationAddress: String?
    let baselineCapturedAt: Date?
    let queueNumber: Int?
    let targetBatteryCapLevel: Int?
    let vehiclesAhead: Int?
    let estimatedWaitMinutes: Int?
    let estimatedWaitSource: String?
    let queueStatusText: String?
    let queueUpdatedAt: Date?
    let firstSeenAt: Date
    let lastSeenAt: Date

    var id: String { orderNo }

    enum CodingKeys: String, CodingKey {
        case orderNo = "order_no"
        case orderType = "order_type"
        case orderStatus = "order_status"
        case orderStatusName = "order_status_name"
        case orderCreatedAt = "order_created_at"
        case stationKey = "station_key"
        case stationName = "station_name"
        case stationAddress = "station_address"
        case baselineCapturedAt = "baseline_captured_at"
        case queueNumber = "queue_number"
        case targetBatteryCapLevel = "target_battery_cap_level"
        case vehiclesAhead = "vehicles_ahead"
        case estimatedWaitMinutes = "estimated_wait_minutes"
        case estimatedWaitSource = "estimated_wait_source"
        case queueStatusText = "queue_status_text"
        case queueUpdatedAt = "queue_updated_at"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        orderNo = try values.decode(String.self, forKey: .orderNo)
        orderType = try values.decode(String.self, forKey: .orderType)
        orderStatus = try values.decodeIfPresent(String.self, forKey: .orderStatus)
        orderStatusName = try values.decodeIfPresent(String.self, forKey: .orderStatusName)
        orderCreatedAt = try Self.decodeDate(.orderCreatedAt, from: values)
        stationKey = try values.decodeIfPresent(String.self, forKey: .stationKey)
        stationName = try values.decodeIfPresent(String.self, forKey: .stationName)
        stationAddress = try values.decodeIfPresent(String.self, forKey: .stationAddress)
        baselineCapturedAt = try Self.decodeOptionalDate(.baselineCapturedAt, from: values)
        queueNumber = try values.decodeIfPresent(Int.self, forKey: .queueNumber)
        targetBatteryCapLevel = try values.decodeIfPresent(Int.self, forKey: .targetBatteryCapLevel)
        vehiclesAhead = try values.decodeIfPresent(Int.self, forKey: .vehiclesAhead)
        estimatedWaitMinutes = try values.decodeIfPresent(Int.self, forKey: .estimatedWaitMinutes)
        estimatedWaitSource = try values.decodeIfPresent(String.self, forKey: .estimatedWaitSource)
        queueStatusText = try values.decodeIfPresent(String.self, forKey: .queueStatusText)
        queueUpdatedAt = try Self.decodeOptionalDate(.queueUpdatedAt, from: values)
        firstSeenAt = try Self.decodeDate(.firstSeenAt, from: values)
        lastSeenAt = try Self.decodeDate(.lastSeenAt, from: values)
    }

    private static func decodeDate(
        _ key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        let timestamp = try values.decode(String.self, forKey: key)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        return date
    }

    private static func decodeOptionalDate(
        _ key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        guard let timestamp = try values.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        return date
    }
}

struct ActiveServiceOrderPage: Decodable, Sendable {
    let items: [ActiveServiceOrder]
}

struct SwapEvent: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let status: String
    let occurredAt: Date
    let stationKey: String?
    let stationName: String?
    let stationAddress: String?
    let orderNo: String?
    let orderStatusName: String?
    let priceAmount: Double?
    let priceCurrency: String?
    let priceDescription: String?
    let paymentItems: [SwapPaymentItem]
    let exactEnergyKWh: Double?
    let estimatedEnergyKWh: Double?
    let energySource: String
    let outgoingBatteryID: String?
    let outgoingProductionDate: String?
    let outgoingCapacityKWh: Double?
    let outgoingSOCPercent: Double?
    let incomingBatteryID: String?
    let incomingProductionDate: String?
    let incomingCapacityKWh: Double?
    let incomingSOCPercent: Double?
    let batterySource: String
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case id, status, confidence
        case occurredAt = "occurred_at"
        case stationKey = "station_key"
        case stationName = "station_name"
        case stationAddress = "station_address"
        case orderNo = "order_no"
        case orderStatusName = "order_status_name"
        case priceAmount = "price_amount"
        case priceCurrency = "price_currency"
        case priceDescription = "price_description"
        case paymentItems = "payment_items"
        case exactEnergyKWh = "exact_energy_kwh"
        case estimatedEnergyKWh = "estimated_energy_kwh"
        case energySource = "energy_source"
        case outgoingBatteryID = "outgoing_battery_id"
        case outgoingProductionDate = "outgoing_production_date"
        case outgoingCapacityKWh = "outgoing_capacity_kwh"
        case outgoingSOCPercent = "outgoing_soc_percent"
        case incomingBatteryID = "incoming_battery_id"
        case incomingProductionDate = "incoming_production_date"
        case incomingCapacityKWh = "incoming_capacity_kwh"
        case incomingSOCPercent = "incoming_soc_percent"
        case batterySource = "battery_source"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        let timestamp = try values.decode(String.self, forKey: .occurredAt)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        occurredAt = date
        stationKey = try values.decodeIfPresent(String.self, forKey: .stationKey)
        stationName = try values.decodeIfPresent(String.self, forKey: .stationName)
        stationAddress = try values.decodeIfPresent(String.self, forKey: .stationAddress)
        orderNo = try values.decodeIfPresent(String.self, forKey: .orderNo)
        orderStatusName = try values.decodeIfPresent(String.self, forKey: .orderStatusName)
        priceAmount = try values.decodeIfPresent(Double.self, forKey: .priceAmount)
        priceCurrency = try values.decodeIfPresent(String.self, forKey: .priceCurrency)
        priceDescription = try values.decodeIfPresent(String.self, forKey: .priceDescription)
        paymentItems = try values.decodeIfPresent([SwapPaymentItem].self, forKey: .paymentItems) ?? []
        exactEnergyKWh = try values.decodeIfPresent(Double.self, forKey: .exactEnergyKWh)
        estimatedEnergyKWh = try values.decodeIfPresent(Double.self, forKey: .estimatedEnergyKWh)
        energySource = try values.decode(String.self, forKey: .energySource)
        outgoingBatteryID = try values.decodeIfPresent(String.self, forKey: .outgoingBatteryID)
        outgoingProductionDate = try values.decodeIfPresent(String.self, forKey: .outgoingProductionDate)
        outgoingCapacityKWh = try values.decodeIfPresent(Double.self, forKey: .outgoingCapacityKWh)
        outgoingSOCPercent = try values.decodeIfPresent(Double.self, forKey: .outgoingSOCPercent)
        incomingBatteryID = try values.decodeIfPresent(String.self, forKey: .incomingBatteryID)
        incomingProductionDate = try values.decodeIfPresent(String.self, forKey: .incomingProductionDate)
        incomingCapacityKWh = try values.decodeIfPresent(Double.self, forKey: .incomingCapacityKWh)
        incomingSOCPercent = try values.decodeIfPresent(Double.self, forKey: .incomingSOCPercent)
        batterySource = try values.decode(String.self, forKey: .batterySource)
        confidence = try values.decode(String.self, forKey: .confidence)
    }
}

struct SwapEventPage: Decodable, Sendable {
    let items: [SwapEvent]
    let limit: Int
    let offset: Int
}

struct SwapStation: Decodable, Equatable, Identifiable, Sendable {
    let stationID: String
    let stationName: String
    let stationAddress: String?
    let operatorID: String?
    let operatorName: String?
    let sourceOrderNo: String?
    let firstSeenAt: Date
    let lastSeenAt: Date
    let updatedAt: Date

    var id: String { stationID }

    enum CodingKeys: String, CodingKey {
        case stationID = "station_id"
        case stationName = "station_name"
        case stationAddress = "station_address"
        case operatorID = "operator_id"
        case operatorName = "operator_name"
        case sourceOrderNo = "source_order_no"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try values.decode(String.self, forKey: .stationID)
        stationName = try values.decode(String.self, forKey: .stationName)
        stationAddress = try values.decodeIfPresent(String.self, forKey: .stationAddress)
        operatorID = try values.decodeIfPresent(String.self, forKey: .operatorID)
        operatorName = try values.decodeIfPresent(String.self, forKey: .operatorName)
        sourceOrderNo = try values.decodeIfPresent(String.self, forKey: .sourceOrderNo)
        firstSeenAt = try Self.decodeDate(.firstSeenAt, from: values)
        lastSeenAt = try Self.decodeDate(.lastSeenAt, from: values)
        updatedAt = try Self.decodeDate(.updatedAt, from: values)
    }

    private static func decodeDate(
        _ key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        let timestamp = try values.decode(String.self, forKey: key)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        return date
    }
}

struct SwapStationPage: Decodable, Sendable {
    let items: [SwapStation]
    let limit: Int
    let offset: Int
}

struct VehicleTripLocation: Decodable, Equatable, Sendable {
    let address: String?
    let poi: String?
    let roadName: String?
    let town: String?
    let district: String?
    let city: String?
    let province: String?
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case address, poi, town, district, city, province, latitude, longitude
        case roadName = "road_name"
    }

    var hasDisplayName: Bool { firstNonEmptyName != nil }

    var displayName: String { firstNonEmptyName ?? "未知地点" }

    private var firstNonEmptyName: String? {
        [poi, address, roadName, town, district, city, province]
            .compactMap { value in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }
            .first
    }
}

struct VehicleTrip: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let tripID: String?
    let startedAt: Date
    let endedAt: Date
    let distanceKilometers: Double
    let durationMinutes: Int
    let startLocation: VehicleTripLocation
    let endLocation: VehicleTripLocation
    let averageSpeedKPH: Double?
    let averageEnergyConsumptionKWhPer100Km: Double?
    let energyConsumedKWh: Double?
    let maximumSpeedKPH: Double?
    let odometerKilometers: Double?
    let rapidAccelerationCount: Int?
    let rapidDecelerationCount: Int?
    let rapidSwerveCount: Int?
    let isCombined: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case tripID = "trip_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceKilometers = "distance_kilometers"
        case durationMinutes = "duration_minutes"
        case startLocation = "start_location"
        case endLocation = "end_location"
        case averageSpeedKPH = "average_speed_kph"
        case averageEnergyConsumptionKWhPer100Km = "average_energy_consumption_kwh_per_100km"
        case energyConsumedKWh = "energy_consumed_kwh"
        case maximumSpeedKPH = "maximum_speed_kph"
        case odometerKilometers = "odometer_kilometers"
        case rapidAccelerationCount = "rapid_acceleration_count"
        case rapidDecelerationCount = "rapid_deceleration_count"
        case rapidSwerveCount = "rapid_swerve_count"
        case isCombined = "is_combined"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        tripID = try values.decodeIfPresent(String.self, forKey: .tripID)
        startedAt = try Self.decodeDate(.startedAt, from: values)
        endedAt = try Self.decodeDate(.endedAt, from: values)
        distanceKilometers = try values.decode(Double.self, forKey: .distanceKilometers)
        durationMinutes = try values.decode(Int.self, forKey: .durationMinutes)
        startLocation = try values.decode(VehicleTripLocation.self, forKey: .startLocation)
        endLocation = try values.decode(VehicleTripLocation.self, forKey: .endLocation)
        averageSpeedKPH = try values.decodeIfPresent(Double.self, forKey: .averageSpeedKPH)
        averageEnergyConsumptionKWhPer100Km = try values.decodeIfPresent(
            Double.self,
            forKey: .averageEnergyConsumptionKWhPer100Km
        )
        energyConsumedKWh = try values.decodeIfPresent(Double.self, forKey: .energyConsumedKWh)
        maximumSpeedKPH = try values.decodeIfPresent(Double.self, forKey: .maximumSpeedKPH)
        odometerKilometers = try values.decodeIfPresent(Double.self, forKey: .odometerKilometers)
        rapidAccelerationCount = try values.decodeIfPresent(Int.self, forKey: .rapidAccelerationCount)
        rapidDecelerationCount = try values.decodeIfPresent(Int.self, forKey: .rapidDecelerationCount)
        rapidSwerveCount = try values.decodeIfPresent(Int.self, forKey: .rapidSwerveCount)
        isCombined = try values.decode(Bool.self, forKey: .isCombined)
    }

    private static func decodeDate(
        _ key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        let timestamp = try values.decode(String.self, forKey: key)
        guard let date = VehicleDateParser.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Unsupported RFC3339 timestamp"
            )
        }
        return date
    }
}

struct VehicleTripPage: Decodable, Sendable {
    let items: [VehicleTrip]
    let hasMore: Bool
    let nextQueryTime: Int64?
    let serverTime: Int64?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextQueryTime = "next_query_time"
        case serverTime = "server_time"
    }
}

struct DailyVehiclePath: Identifiable, Equatable, Sendable {
    let day: Date
    let points: [VehicleSnapshot]
    let segments: [VehiclePathSegment]
    let distanceKilometers: Double
    let startTime: Date
    let endTime: Date

    var id: Date { day }
}

struct VehiclePathSegment: Identifiable, Equatable, Sendable {
    let points: [VehicleSnapshot]
    let distanceKilometers: Double
    let startTime: Date
    let endTime: Date

    var id: String { "\(points[0].vehicleID):\(startTime.timeIntervalSince1970):\(endTime.timeIntervalSince1970)" }
}

enum VehiclePathBuilder {
    /// Coordinates inside this radius are treated as the same parked location.
    /// Vehicle GPS can drift by several dozen metres while the car is stationary.
    static let samePlaceRadiusMeters = 80.0
    /// A sustained stop, rather than a single slow or noisy GPS sample.
    static let stationarySplitInterval: TimeInterval = 15 * 60
    /// Slow GPS wander can escape the tight parked radius without a real trip.
    static let driftRadiusMeters = 150.0
    static let driftInterval: TimeInterval = 20 * 60
    /// A missing-data break must not be drawn as a continuous drive.
    static let missingSampleSplitInterval: TimeInterval = 30 * 60

    static func buildDailyPaths(
        from history: [VehicleSnapshot],
        calendar: Calendar = .current
    ) -> [DailyVehiclePath] {
        let valid = history.filter { $0.coordinate.isValid }
        let grouped = Dictionary(grouping: valid) { calendar.startOfDay(for: $0.sampledAt) }
        return grouped.compactMap { day, rawPoints in
            let sorted = rawPoints.sorted { $0.sampledAt < $1.sampledAt }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            let segments = buildSegments(sorted)
            let points = segments.isEmpty ? simplify(sorted) : segments.flatMap(\.points)
            return DailyVehiclePath(
                day: day,
                points: points,
                segments: segments,
                distanceKilometers: segments.reduce(0) { $0 + $1.distanceKilometers },
                startTime: segments.first?.startTime ?? movementStartTime(in: sorted) ?? first.sampledAt,
                endTime: segments.last?.endTime ?? last.sampledAt
            )
        }
        .sorted { $0.day > $1.day }
    }

    static func buildSegments(_ sortedPoints: [VehicleSnapshot]) -> [VehiclePathSegment] {
        guard !sortedPoints.isEmpty else { return [] }
        // First separate actual telemetry gaps. No line may bridge missing samples.
        var batches: [[VehicleSnapshot]] = []
        var batch: [VehicleSnapshot] = []
        for point in sortedPoints {
            if let previous = batch.last,
               point.sampledAt.timeIntervalSince(previous.sampledAt) >= missingSampleSplitInterval {
                batches.append(batch)
                batch = []
            }
            batch.append(point)
        }
        if !batch.isEmpty { batches.append(batch) }

        var segments: [VehiclePathSegment] = []
        for samples in batches {
            var start = 0
            var index = 0
            while index < samples.count - 1 {
                let nextParked = firstOutsideRadius(samples, from: index, radius: samePlaceRadiusMeters)
                let nextDrift = firstOutsideRadius(samples, from: index, radius: driftRadiusMeters)
                let parkedDuration = samples[nextParked - 1].sampledAt.timeIntervalSince(samples[index].sampledAt)
                let driftDuration = samples[nextDrift - 1].sampledAt.timeIntervalSince(samples[index].sampledAt)
                let stopEnd: Int?
                if driftDuration >= driftInterval {
                    stopEnd = nextDrift - 1
                } else if parkedDuration >= stationarySplitInterval {
                    stopEnd = nextParked - 1
                } else {
                    stopEnd = nil
                }
                if let lastParked = stopEnd {
                    if let segment = movementSegment(in: Array(samples[start...index])) {
                        segments.append(segment)
                    }
                    // The final parked fix anchors the departure, but the long
                    // stationary stretch is not counted as driven distance.
                    start = lastParked
                    index = lastParked
                } else {
                    index = nextParked < samples.count ? nextParked : samples.count - 1
                }
            }
            if let segment = movementSegment(in: Array(samples[start...])) {
                segments.append(segment)
            }
        }
        return segments
    }

    private static func firstOutsideRadius(
        _ samples: [VehicleSnapshot],
        from start: Int,
        radius: Double
    ) -> Int {
        var index = start + 1
        while index < samples.count,
              haversineMeters(
                latitude1: samples[start].latitude,
                longitude1: samples[start].longitude,
                latitude2: samples[index].latitude,
                longitude2: samples[index].longitude
              ) < radius {
            index += 1
        }
        return index
    }

    private static func movementSegment(in samples: [VehicleSnapshot]) -> VehiclePathSegment? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if last.sampledAt.timeIntervalSince(first.sampledAt) >= driftInterval {
            let minLatitude = samples.map(\.latitude).min() ?? first.latitude
            let maxLatitude = samples.map(\.latitude).max() ?? first.latitude
            let minLongitude = samples.map(\.longitude).min() ?? first.longitude
            let maxLongitude = samples.map(\.longitude).max() ?? first.longitude
            if haversineMeters(
                latitude1: minLatitude, longitude1: minLongitude,
                latitude2: maxLatitude, longitude2: maxLongitude
            ) <= driftRadiusMeters {
                return nil
            }
        }
        var points = simplify(samples)
        guard points.count > 1 else { return nil }
        if points.last != last {
            points.append(last)
        }
        return VehiclePathSegment(
            points: points,
            distanceKilometers: distanceMeters(points) / 1000,
            startTime: movementStartTime(in: samples) ?? first.sampledAt,
            endTime: last.sampledAt
        )
    }

    static func simplify(_ points: [VehicleSnapshot]) -> [VehicleSnapshot] {
        guard points.count > 1 else { return points }
        let sorted = points.sorted { $0.sampledAt < $1.sampledAt }
        var result = [sorted[0]]
        for point in sorted.dropFirst() {
            guard let last = result.last else { continue }
            let moved = haversineMeters(
                latitude1: last.latitude,
                longitude1: last.longitude,
                latitude2: point.latitude,
                longitude2: point.longitude
            )
            if moved >= samePlaceRadiusMeters {
                result.append(point)
            }
        }
        return result
    }

    /// Uses the last sample still inside the initial parked area as the route start.
    /// This avoids showing the first background poll of the day as the departure time.
    static func movementStartTime(in sortedPoints: [VehicleSnapshot]) -> Date? {
        guard let origin = sortedPoints.first else { return nil }
        guard let firstMovedIndex = sortedPoints.dropFirst().firstIndex(where: { point in
            haversineMeters(
                latitude1: origin.latitude,
                longitude1: origin.longitude,
                latitude2: point.latitude,
                longitude2: point.longitude
            ) >= samePlaceRadiusMeters
        }) else {
            return origin.sampledAt
        }
        return sortedPoints[firstMovedIndex - 1].sampledAt
    }

    static func distanceMeters(_ points: [VehicleSnapshot]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + haversineMeters(
                latitude1: pair.0.latitude,
                longitude1: pair.0.longitude,
                latitude2: pair.1.latitude,
                longitude2: pair.1.longitude
            )
        }
    }

    static func haversineMeters(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        let radius = 6_371_000.0
        let toRadians = { (degrees: Double) in degrees * .pi / 180 }
        let deltaLatitude = toRadians(latitude2 - latitude1)
        let deltaLongitude = toRadians(longitude2 - longitude1)
        let value = pow(sin(deltaLatitude / 2), 2)
            + cos(toRadians(latitude1)) * cos(toRadians(latitude2))
            * pow(sin(deltaLongitude / 2), 2)
        return 2 * radius * asin(sqrt(value))
    }
}
