//
//  NIOPowerSwapAssistTests.swift
//  NIOPowerSwapAssistTests
//
//  Created by 许懿赫 on 2025/1/2.
//

import Foundation
import Security
import Testing
import UIKit
@testable import NIOPowerSwapAssist

struct NIOPowerSwapAssistTests {

    @Test func serverSentEventParserSupportsCommentsMultilineDataAndRetry() throws {
        var parser = ServerSentEventParser()
        #expect(parser.consume(line: ": heartbeat") == nil)
        #expect(parser.consume(line: "id: 42") == nil)
        #expect(parser.consume(line: "event: vehicle_changed") == nil)
        #expect(parser.consume(line: "retry: 3000") == nil)
        #expect(parser.consume(line: "data: {\"revision\":") == nil)
        #expect(parser.consume(line: "data: 7}") == nil)

        let parsedEvent = parser.consume(line: "")
        let event = try #require(parsedEvent)
        #expect(event.id == "42")
        #expect(event.name == "vehicle_changed")
        #expect(event.data == "{\"revision\":\n7}")
        #expect(event.retryMilliseconds == 3_000)
    }

    @Test func eventStreamRequestCarriesCursorAndTenantBasePath() throws {
        let configuration = try BackendConfiguration(
            baseURLString: "https://backend.example/t/alice/",
            apiKey: String(repeating: "a", count: 64)
        )
        let request = BackendEventStreamClient(
            configuration: configuration,
            session: .shared
        ).makeRequest(lastEventID: "123")

        #expect(request.url?.absoluteString == "https://backend.example/t/alice/api/v1/events")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(configuration.apiKey)")
    }

    @Test func eventReconnectPolicyIsBoundedAndHonorsServerRetry() {
        #expect(BackendEventReconnectPolicy.delay(
            attempt: 0,
            serverRetryMilliseconds: nil,
            jitter: 1
        ) == 1)
        #expect(BackendEventReconnectPolicy.delay(
            attempt: 10,
            serverRetryMilliseconds: nil,
            jitter: 1
        ) == 30)
        #expect(BackendEventReconnectPolicy.delay(
            attempt: 0,
            serverRetryMilliseconds: 3_000,
            jitter: 1
        ) == 3)
        #expect(BackendEventReconnectPolicy.delay(
            attempt: 3,
            serverRetryMilliseconds: 3_000,
            jitter: 1
        ) == 8)
    }

    @Test func curlParserSupportsLongHeaderForm() throws {
        let request = try CurlCommandParser.parse(
            "curl 'https://app.nio.com/example?id=1' --header 'Authorization: Bearer test' -H \"x-device-id: abc\""
        )

        #expect(request.url?.host == "app.nio.com")
        #expect(request.headers?["Authorization"] == "Bearer test")
        #expect(request.headers?["x-device-id"] == "abc")
    }

    @Test func curlParserRejectsInsecureURL() {
        #expect(throws: CurlCommandParser.ParseError.insecureURL) {
            try CurlCommandParser.parse("curl http://example.com")
        }
    }

    @Test func swapSignerReplacesTimestampAndSignDeterministically() throws {
        let source = try #require(URL(string:
            "https://app.nio.com/nio/app/bff/map/resources/v1/swap/PS-NIO-test?region=cn&timestamp=1&app_id=10002&sign=outdated"
        ))

        let signed = try NIOSwapRequestSigner.signedURLIfSupported(
            source,
            headers: ["authorization": "bearer test-token"],
            timestamp: 1_234_567_890
        )
        let items = try #require(URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(values["timestamp"] == "1234567890")
        #expect(values["sign"] == "6dd508aefd50178b04833ef5af2ac1e8")
        #expect(items.filter { $0.name == "timestamp" }.count == 1)
        #expect(items.filter { $0.name == "sign" }.count == 1)
    }

    @Test func swapSignerDoesNotTouchUnverifiedEndpoints() throws {
        let source = try #require(URL(string: "https://app.nio.com/app/api/pe/v4/swap/test?timestamp=1&sign=old"))
        let result = try NIOSwapRequestSigner.signedURLIfSupported(
            source,
            headers: [:],
            timestamp: 1_234_567_890
        )
        #expect(result == source)
    }

    @Test func swapRequestTemplateReplacesOnlyStationID() throws {
        let source = try #require(URL(string:
            "https://app.nio.com/nio/app/bff/map/resources/v1/swap/PS-NIO-old?region=cn&app_id=10002"
        ))
        let request = InfoRequest(
            url: source,
            headers: ["Authorization": "Bearer test-token"]
        )
        let replaced = try request.replacingStationID("PS-NIO-3606da31-f8539ae9")

        #expect(
            replaced.url?.path
                == "/nio/app/bff/map/resources/v1/swap/PS-NIO-3606da31-f8539ae9"
        )
        #expect(replaced.url?.query == source.query)
        #expect(replaced.headers == request.headers)
        #expect(
            NIOSwapRequestSigner.stationID(from: replaced.url)
                == "PS-NIO-3606da31-f8539ae9"
        )
    }

    @Test func payloadParserHandlesShortIDsAndFlexibleValues() throws {
        let payload = """
        {
          "battery": {
            "battery_list": [{
              "battery_id": "short",
              "progress": "135",
              "lower_case_desc": "75kWh",
              "charging_time_desc": "约12分钟",
              "battery_occupied": 0,
              "slot_id": "3"
            }]
          },
          "fee_info": {
            "current_fee": [{"type":"electricity_fee","name":"电费","fee":0.65,"unit":"度","currency":"¥"}],
            "detail": [
              {"time_period":"00:00-08:00","fee":[
                {"type":"electricity_fee","name":"电费","fee":"0.36","unit":"度","currency":"¥"},
                {"type":"service_fee","name":"服务费","fee":"0.36","unit":"度","currency":"¥"},
                {"type":"total_fee_by_energy","name":"总费用","fee":"0.72","unit":"度","currency":"¥"}
              ]},
              {"time_period":"08:00-24:00","fee":[
                {"type":"total_fee_by_energy","name":"总费用","fee":"1.40","unit":"度","currency":"¥"}
              ]}
            ],
            "fee_special_desc_array": ["*分时节点订单以下一时段单价为准"]
          }
        }
        """

        let snapshot = try SwapStationPayloadParser.parse(Data(payload.utf8))
        let battery = try #require(snapshot.batteries.first)
        #expect(battery.manufactureDate == nil)
        #expect(battery.chargingProgress == 100)
        #expect(battery.chargingRemainingMinutes == 12)
        #expect(battery.slotID == 3)
        #expect(snapshot.feeInfo?.currentFees.first?.fee == "0.65")
        #expect(snapshot.feeInfo?.periods.count == 2)
        #expect(snapshot.feeInfo?.period(atMinute: 7 * 60)?.total == 0.72)
        #expect(snapshot.feeInfo?.period(atMinute: 12 * 60)?.total == 1.4)
        #expect(snapshot.feeInfo?.notices.count == 1)
    }

    @Test func malformedOptionalFeeDoesNotDiscardBatteryInventory() throws {
        let payload = """
        {
          "battery": {
            "battery_cap_level_sort_list": [],
            "battery_list": [{"battery_id":"P007-test","progress":90,"slot_id":2}]
          },
          "fee_info": []
        }
        """
        let snapshot = try SwapStationPayloadParser.parse(Data(payload.utf8))
        #expect(snapshot.batteries.count == 1)
        #expect(snapshot.batteries[0].slotID == 2)
        #expect(snapshot.feeInfo == nil)
    }

    @Test func missingInventoryReportsSafeFieldWithoutPayloadContents() {
        let payload = #"{"fee_info":{"current_fee":[]},"token":"secret-do-not-show"}"#
        do {
            _ = try SwapStationPayloadParser.parse(Data(payload.utf8))
            Issue.record("Missing battery payload must not appear as zero available batteries")
        } catch {
            #expect((error as? SwapStationError)?.errorDescription?.contains("battery") == true)
            #expect((error as? SwapStationError)?.errorDescription?.contains("secret-do-not-show") == false)
        }
    }

    @Test func progressFractionIsAlwaysClamped() {
        let battery = BatteryModel(
            id: "test", chargingProgress: -20, batteryType: "100 kWh",
            chargingRemainingMinutes: nil, isOccupied: false,
            manufactureDate: nil, slotID: 1
        )
        #expect(battery.progressFraction == 0)
    }

    @Test func seventyAndSeventyFiveKilowattHourBatteriesUseSeparateGroups() {
        let seventy = BatteryModel(
            id: "70", chargingProgress: 50, batteryType: "70kWh",
            chargingRemainingMinutes: nil, isOccupied: false,
            manufactureDate: nil, slotID: 1
        )
        let seventyFive = BatteryModel(
            id: "75", chargingProgress: 50, batteryType: "标准续航电池包（75kWh）",
            chargingRemainingMinutes: nil, isOccupied: false,
            manufactureDate: nil, slotID: 2
        )

        #expect(seventy.groupName == "70 kWh")
        #expect(seventyFive.groupName == "75 kWh")
        #expect(seventy.groupName != seventyFive.groupName)
    }

    @Test func feeTotalUsesExplicitTotalWithoutDoubleCounting() throws {
        let fees = FeeInfo(currentFees: [
            FeeItem(name: "电费", fee: "0.65", unit: "kWh", currency: "¥"),
            FeeItem(name: "服务费", fee: "0.30", unit: "kWh", currency: "¥"),
            FeeItem(name: "总费用", fee: "0.95", unit: "kWh", currency: "¥")
        ])

        #expect(try #require(fees.total) == 0.95)
        #expect(fees.componentFees.map(\.name) == ["电费", "服务费"])
        #expect(fees.totalItem?.name == "总费用")
    }

    @Test func feeTotalFallsBackToComponentSum() throws {
        let fees = FeeInfo(currentFees: [
            FeeItem(name: "电费", fee: "0.65", unit: "kWh", currency: "¥"),
            FeeItem(name: "服务费", fee: "0.30", unit: "kWh", currency: "¥")
        ])

        #expect(abs(try #require(fees.total) - 0.95) < 0.000_001)
        #expect(fees.componentFees.count == 2)
        #expect(fees.totalItem == nil)
    }

    @Test func feePeriodsResolveCurrentAndNextAcrossMidnight() throws {
        let fees = FeeInfo(currentFees: [], periods: [
            FeePeriod(timePeriod: "08:00-22:00", fees: [
                FeeItem(name: "总费用", fee: "1.40", unit: "度", currency: "¥")
            ]),
            FeePeriod(timePeriod: "22:00-24:00", fees: [
                FeeItem(name: "总费用", fee: "0.80", unit: "度", currency: "¥")
            ]),
            FeePeriod(timePeriod: "00:00-08:00", fees: [
                FeeItem(name: "总费用", fee: "0.72", unit: "度", currency: "¥")
            ])
        ])

        let current = try #require(fees.period(atMinute: 23 * 60))
        #expect(current.timePeriod == "22:00-24:00")
        #expect(fees.nextPeriod(after: current)?.timePeriod == "00:00-08:00")
    }

    @Test func backendConfigurationAllowsHTTPAndHTTPS() throws {
        let key = String(repeating: "a", count: 64)
        let loopback = try BackendConfiguration(
            baseURLString: "http://127.0.0.1:8080",
            apiKey: key
        )
        #expect(loopback.baseURL.host == "127.0.0.1")

        let secure = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: key
        )
        #expect(secure.baseURL.scheme == "https")

        let localNetwork = try BackendConfiguration(
            baseURLString: "http://192.168.1.10:8080",
            apiKey: key
        )
        #expect(localNetwork.baseURL.scheme == "http")

        #expect(throws: BackendClientError.invalidBaseURL) {
            try BackendConfiguration(baseURLString: "ftp://example.com", apiKey: key)
        }
    }

    @Test func foregroundRefreshUsesFastPollingOnlyForLiveActivity() {
        #expect(
            VehicleAutoRefreshPolicy.liveInterval(
                hasActiveOrders: false,
                isCharging: false,
                isSwapping: false
            ) == 60
        )
        #expect(
            VehicleAutoRefreshPolicy.liveInterval(
                hasActiveOrders: true,
                isCharging: false,
                isSwapping: false
            ) == 15
        )
        #expect(
            VehicleAutoRefreshPolicy.liveInterval(
                hasActiveOrders: false,
                isCharging: true,
                isSwapping: false
            ) == 15
        )
    }

    @Test func dashboardRefreshIgnoresFetchTimestampButDetectsVisibleChanges() {
        let first = VehicleDashboard(
            vehicleID: "vehicle-test",
            isConnected: true,
            stateCode: 1,
            mileage: 12_345,
            isSwapping: false,
            stateOfCharge: 80,
            remainingRange: 400,
            remainingActualRange: 380,
            chargeStateCode: 0,
            chargingCurrent: nil,
            chargingPower: nil,
            chargingVoltage: nil,
            chargeLimitPercent: 90,
            batterySampledAt: Date(timeIntervalSince1970: 100),
            lockStatusCode: 1,
            location: VehicleCoordinate(latitude: 31, longitude: 121),
            locationSampledAt: Date(timeIntervalSince1970: 100),
            insideTemperature: 24,
            outsideTemperature: 20,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let refetched = VehicleDashboard(
            vehicleID: first.vehicleID,
            isConnected: first.isConnected,
            stateCode: first.stateCode,
            mileage: first.mileage,
            isSwapping: first.isSwapping,
            stateOfCharge: first.stateOfCharge,
            remainingRange: first.remainingRange,
            remainingActualRange: first.remainingActualRange,
            chargeStateCode: first.chargeStateCode,
            chargingCurrent: first.chargingCurrent,
            chargingPower: first.chargingPower,
            chargingVoltage: first.chargingVoltage,
            chargeLimitPercent: first.chargeLimitPercent,
            batterySampledAt: first.batterySampledAt,
            lockStatusCode: first.lockStatusCode,
            location: first.location,
            locationSampledAt: first.locationSampledAt,
            insideTemperature: first.insideTemperature,
            outsideTemperature: first.outsideTemperature,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let changed = VehicleDashboard(
            vehicleID: first.vehicleID,
            isConnected: first.isConnected,
            stateCode: first.stateCode,
            mileage: first.mileage,
            isSwapping: first.isSwapping,
            stateOfCharge: 79,
            remainingRange: first.remainingRange,
            remainingActualRange: first.remainingActualRange,
            chargeStateCode: first.chargeStateCode,
            chargingCurrent: first.chargingCurrent,
            chargingPower: first.chargingPower,
            chargingVoltage: first.chargingVoltage,
            chargeLimitPercent: first.chargeLimitPercent,
            batterySampledAt: first.batterySampledAt,
            lockStatusCode: first.lockStatusCode,
            location: first.location,
            locationSampledAt: first.locationSampledAt,
            insideTemperature: first.insideTemperature,
            outsideTemperature: first.outsideTemperature,
            updatedAt: refetched.updatedAt
        )

        #expect(first.hasSameDisplayedState(as: refetched))
        #expect(!first.hasSameDisplayedState(as: changed))
    }

    @Test func backendRequestUsesOnlyBackendAPIKey() throws {
        let key = String(repeating: "b", count: 64)
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: key
        )
        let request = BackendClient(configuration: configuration)
            .makeRequest(path: "api/v1/vehicle/status")

        #expect(request.url?.absoluteString == "https://vehicle.example.com/api/v1/vehicle/status")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(request.allHTTPHeaderFields?.keys.contains("NIO_BEARER_TOKEN") == false)
    }

    @Test func vehicleImageRequestUsesBackendAuthAndConditionalETag() throws {
        let key = String(repeating: "b", count: 64)
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com/t/alice/",
            apiKey: key
        )
        let request = BackendClient(configuration: configuration)
            .makeVehicleImageRequest(cachedETag: "\"abc123\"")

        #expect(request.url?.absoluteString == "https://vehicle.example.com/t/alice/api/v1/vehicle/image")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"abc123\"")
    }

    @Test func vehicleProfileDecodesImageCacheMetadata() throws {
        let data = Data(#"""
        {
          "vehicle_id":"vehicle-1","display_name":"我的ET5T","model_type":"ET5T",
          "color":"tech_grey","image_url":"https://cdn.example/car.png",
          "image_available":true,"image_sha256":"abc123",
          "image_fetched_at":"2026-11-11T08:00:00Z"
        }
        """#.utf8)
        let profile = try JSONDecoder().decode(VehicleProfile.self, from: data)
        #expect(profile.vehicleID == "vehicle-1")
        #expect(profile.displayName == "我的ET5T")
        #expect(profile.imageAvailable)
        #expect(profile.imageSHA256 == "abc123")
        #expect(profile.localizedColorName == "星灰")
    }

    @Test func vehicleProfileTitleAndArtworkAdaptToVehicleModel() {
        func makeProfile(displayName: String?, modelType: String?) -> VehicleProfile {
            VehicleProfile(
                vehicleID: "vehicle-1",
                displayName: displayName,
                modelType: modelType,
                color: nil,
                imageURL: nil,
                imageAvailable: false,
                imageSHA256: nil,
                imageFetchedAt: nil
            )
        }

        #expect(makeProfile(displayName: "我的ES6", modelType: "ES6").displayTitle == "我的ES6")
        #expect(makeProfile(displayName: nil, modelType: "ES6").displayTitle == "NIO ES6")
        #expect(makeProfile(displayName: "   ", modelType: "").displayTitle == "我的蔚来")
        #expect(makeProfile(displayName: nil, modelType: "ES6").bundledArtworkAssetName == nil)
        #expect(makeProfile(displayName: nil, modelType: "et5t").bundledArtworkAssetName == "ET5TTouringSide")
        #expect(makeProfile(displayName: nil, modelType: nil).localizedColorName == nil)
    }

    @Test func batteryIndicatorTracksStateOfCharge() {
        #expect(BatteryIndicator.symbolName(stateOfCharge: 7) == "battery.0percent")
        #expect(BatteryIndicator.symbolName(stateOfCharge: 30) == "battery.25percent")
        #expect(BatteryIndicator.symbolName(stateOfCharge: 55) == "battery.50percent")
        #expect(BatteryIndicator.symbolName(stateOfCharge: 80) == "battery.75percent")
        #expect(BatteryIndicator.symbolName(stateOfCharge: 96) == "battery.100percent")
        #expect(BatteryIndicator.symbolName(stateOfCharge: nil) == "battery.100percent")
        #expect(BatteryIndicator.tint(stateOfCharge: 12) == AppPalette.red)
        #expect(BatteryIndicator.tint(stateOfCharge: 35) == AppPalette.amber)
        #expect(BatteryIndicator.tint(stateOfCharge: 82) == AppPalette.green)
        #expect(BatteryIndicator.tint(stateOfCharge: nil) == AppPalette.graphite)
    }

    @Test func vehicleImageDiskCacheIsScopedByBackendAndCanBeCleared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("vehicle-image.plist")
        let cache = FileVehicleImageCache(fileURL: file)
        let firstURL = try #require(URL(string: "https://vehicle.example.com/t/alice/"))
        let secondURL = try #require(URL(string: "https://vehicle.example.com/t/bob/"))
        let image = Data([0x89, 0x50, 0x4e, 0x47])
        defer { try? FileManager.default.removeItem(at: root) }

        cache.save(
            data: image,
            etag: "\"abc123\"",
            vehicleID: "vehicle-1",
            baseURL: firstURL
        )
        let loaded = try #require(cache.load(matching: firstURL, vehicleID: "vehicle-1"))
        #expect(loaded.data == image)
        #expect(loaded.etag == "\"abc123\"")
        #expect(cache.load(matching: firstURL, vehicleID: "vehicle-2") == nil)
        #expect(cache.load(matching: secondURL, vehicleID: "vehicle-1") == nil)
        cache.clear()
        #expect(cache.load(matching: firstURL, vehicleID: "vehicle-1") == nil)
    }

    @Test func vehicleActionRequestKeepsControlKeySeparateAndUsesExactConfirmation() throws {
        let apiKey = String(repeating: "a", count: 64)
        let controlKey = String(repeating: "c", count: 64)
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: apiKey
        )
        let request = try BackendClient(configuration: configuration).makeVehicleActionRequest(
            input: VehicleActionInput(action: .unlockDoors),
            controlKey: controlKey
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://vehicle.example.com/api/v1/vehicle/action")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(request.value(forHTTPHeaderField: "X-Vehicle-Control-Key") == controlKey)

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["action"] as? String == "unlock-doors")
        #expect(json["confirmation"] as? String == "UNLOCK DOORS")
        #expect(json["expand_mirrors"] as? Bool == false)
    }

    @Test func swapOrderRequestSendsOnlyStationAndExactConfirmation() throws {
        let apiKey = String(repeating: "a", count: 64)
        let controlKey = String(repeating: "c", count: 64)
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: apiKey
        )
        let request = try BackendClient(configuration: configuration)
            .makeCreateSwapOrderRequest(
                stationID: "PS-NIO-test",
                controlKey: controlKey
            )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://vehicle.example.com/api/v1/swap-orders")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(request.value(forHTTPHeaderField: "X-Vehicle-Control-Key") == controlKey)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["station_id", "confirmation"])
        #expect(json["station_id"] as? String == "PS-NIO-test")
        #expect(json["confirmation"] as? String == "CREATE SWAP ORDER")
    }

    @Test func everyVisibleVehicleControlEncodesItsOwnActionAndConfirmation() throws {
        let expected: [(VehicleAction, String, String)] = [
            (.unlockDoors, "unlock-doors", "UNLOCK DOORS"),
            (.unlockStart, "unlock-start", "UNLOCK AND START"),
            (.lock, "lock", "LOCK VEHICLE"),
            (.acOn, "ac-on", "START AC"),
            (.acOff, "ac-off", "STOP AC"),
            (.find, "find", "FIND VEHICLE"),
            (.findStop, "find-stop", "STOP FINDING"),
            (.guardOn, "guard-on", "ENABLE GUARD MODE"),
            (.guardOff, "guard-off", "DISABLE GUARD MODE")
        ]
        #expect(Set(expected.map(\.0)) == Set(VehicleAction.allCases))
        for (action, name, confirmation) in expected {
            let input = VehicleActionInput(action: action, temperature: 24)
            let data = try JSONEncoder().encode(input)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["action"] as? String == name)
            #expect(json["confirmation"] as? String == confirmation)
            if action == .acOn {
                #expect(json["temperature"] as? Double == 24)
            } else {
                #expect(json["temperature"] == nil)
            }
        }
    }

    @Test func guardMirrorChoiceRequiresItsOwnConfirmation() throws {
        let withMirrors = try JSONEncoder().encode(
            VehicleActionInput(action: .guardOn, expandMirrors: true)
        )
        let withChoice = try #require(JSONSerialization.jsonObject(with: withMirrors) as? [String: Any])
        #expect(withChoice["action"] as? String == "guard-on")
        #expect(withChoice["expand_mirrors"] as? Bool == true)
        #expect(withChoice["mirror_confirmation"] as? String == "EXPAND MIRRORS")

        let withoutMirrors = try JSONEncoder().encode(
            VehicleActionInput(action: .guardOn, expandMirrors: false)
        )
        let withoutChoice = try #require(JSONSerialization.jsonObject(with: withoutMirrors) as? [String: Any])
        #expect(withoutChoice["expand_mirrors"] as? Bool == false)
        #expect(withoutChoice["mirror_confirmation"] == nil)

        let unrelated = try JSONEncoder().encode(
            VehicleActionInput(action: .lock, expandMirrors: true)
        )
        let unrelatedChoice = try #require(JSONSerialization.jsonObject(with: unrelated) as? [String: Any])
        #expect(unrelatedChoice["expand_mirrors"] as? Bool == false)
    }

    @Test func vehicleActionRequestRejectsShortControlKeyBeforeNetworkUse() throws {
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: String(repeating: "a", count: 64)
        )
        #expect(throws: BackendClientError.invalidControlKey) {
            try BackendClient(configuration: configuration).makeVehicleActionRequest(
                input: VehicleActionInput(action: .lock),
                controlKey: "too-short"
            )
        }
    }

    @Test func backendStationSearchQueryIsPercentEncoded() throws {
        let key = String(repeating: "b", count: 64)
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: key
        )
        let request = BackendClient(configuration: configuration).makeRequest(
            path: "api/v1/stations?limit=200&offset=0&q=%E6%BB%A8%E6%B5%B7"
        )
        let url = try #require(request.url)
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )

        #expect(items.first(where: { $0.name == "q" })?.value == "滨海")
    }

    @Test func analyticsAndCouponRequestsUseProtectedBackendContract() throws {
        let key = String(repeating: "b", count: 64)
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: key
        )
        let client = BackendClient(configuration: configuration)
        let from = try #require(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        let to = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        let statsRequest = try client.makeEnergyStatsRequest(from: from, to: to)
        let statsURL = try #require(statsRequest.url)
        let query = try #require(URLComponents(url: statsURL, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(statsURL.path == "/api/v1/energy/stats")
        #expect(query.first(where: { $0.name == "from" })?.value == "2026-10-01T00:00:00Z")
        #expect(query.first(where: { $0.name == "to" })?.value == "2026-11-01T00:00:00Z")
        #expect(statsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")

        let couponRequest = client.makeAvailableCouponsRequest(limit: 500, offset: -3)
        let couponURL = try #require(couponRequest.url)
        let couponQuery = try #require(URLComponents(url: couponURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(couponURL.path == "/api/v1/coupons/available")
        #expect(couponQuery.first(where: { $0.name == "limit" })?.value == "100")
        #expect(couponQuery.first(where: { $0.name == "offset" })?.value == "0")
    }

    @Test func analyticsKeepsMissingEnergyDistinctAndCouponsDecodeDynamicFields() throws {
        let statsJSON = """
        {
          "from":"2026-10-01T00:00:00Z", "to":"2026-11-01T00:00:00Z",
          "swap_count":2, "swap_electricity_fee_cny_known":10.5,
          "swap_service_fee_cny_known":20, "swap_total_fee_cny_known":30.5,
          "coupon_discount_cny_known":5, "actual_paid_cny_known":25.5,
          "fee_breakdown_covered_count":1, "paid_amount_covered_count":1,
          "swap_energy_kwh_known":40, "swap_energy_covered_count":1,
          "charging_energy_kwh_estimated":null,
          "charging_energy_kwh_from_power":0, "charging_energy_kwh_from_soc":0,
          "charging_segments_from_power":0, "charging_segments_from_soc":0,
          "charging_segments_uncovered":3, "charging_sample_count":4,
          "total_energy_kwh_known":40,
          "swap_energy_share_percent_of_known":100,
          "charging_energy_share_percent_of_known":0,
          "energy_coverage_complete":false,
          "current_month_swap_count":2, "current_month_timezone":"Asia/Shanghai"
        }
        """
        let stats = try JSONDecoder().decode(EnergyStats.self, from: Data(statsJSON.utf8))
        #expect(stats.chargingEnergyKWhEstimated == nil)
        #expect(!stats.energyCoverageComplete)
        #expect(stats.chargingSegmentsUncovered == 3)
        #expect(stats.swapEnergyCoveredCount == 1)

        let couponsJSON = """
        {"amount":1,"coupons":[{
          "coupon_id":"coupon-1",
          "template":{"coupon_name":"换电服务费优惠券","coupon_desc":"限指定换电站"},
          "valid_time_desc":"有效期至 2026-12-31"
        }],"has_more":false,"limit":20,"offset":0}
        """
        let page = try JSONDecoder().decode(AvailableCouponsPage.self, from: Data(couponsJSON.utf8))
        let coupon = try #require(page.coupons.first)
        #expect(coupon.identifier == "coupon-1")
        #expect(coupon.title == "换电服务费优惠券")
        #expect(coupon.subtitle == "限指定换电站")
        #expect(coupon.validityText == "有效期至 2026-12-31")
    }

    @Test func couponGroupsPreserveQuantityAndUnknownTotals() throws {
        let json = """
        {"amount":5,"coupons":[{"title":"10元优惠券"},{"title":"5元优惠券"},{"title":"其他券"}],
         "coupon_groups":[{"count":7,"face_value_cny":10},{"count":8,"face_value_cny":5},{"count":null,"face_value_cny":null}],
         "page_coupon_count":null,"total_coupon_count":null,"has_more":true,"limit":3,"offset":0}
        """
        let page = try JSONDecoder().decode(AvailableCouponsPage.self, from: Data(json.utf8))
        #expect(page.coupons.map(\.quantity) == [7, 8, nil])
        #expect(page.coupons.map(\.faceValueCNY) == [10, 5, nil])
        #expect(page.totalCouponCount == nil)
        #expect(page.pageCouponCount == nil)
        #expect(page.hasMore)
    }

    @Test func vehicleDashboardCombinesBothBackendResponses() throws {
        let statusJSON = """
        {
          "result_code": "success",
          "server_time": 1700000000,
          "data": {
            "vehicle_id": "vehicle-test",
            "connection_status": {"connected": true},
            "exterior_status": {"mileage": 12345.6, "vehicle_state": 2},
            "special_status": {"swapping": 1},
            "soc_status": {
              "soc": 84.0,
              "remaining_range": 418.0,
              "charge_state": 1,
              "charging_current": 32.5,
              "charging_power": 11800,
              "charging_voltage": 358.0,
              "max_soc": 95,
              "max_soc_enable_on_vehl": true,
              "sample_time": 1700000002000
            }
          }
        }
        """
        let widgetJSON = """
        {
          "result_code": "success",
          "server_time": 1700000001,
          "data": {
            "status": {
              "vehicle_id": "vehicle-test",
              "soc_status": {
                "soc": 83.0,
                "remaining_range": 412.5,
                "charge_state": 1,
                "charging_current": 31.5,
                "charging_power": 11200,
                "charging_voltage": 356.0,
                "max_soc": 90,
                "max_soc_enable_on_vehl": true,
                "sample_time": 1700000001000
              },
              "door_status": {"vehicle_lock_status": 1}
            }
          }
        }
        """
        let decoder = JSONDecoder()
        let status = try decoder.decode(NIOVehicleStatusResponse.self, from: Data(statusJSON.utf8))
        let widget = try decoder.decode(NIOWidgetInfoResponse.self, from: Data(widgetJSON.utf8))
        let configuration = try BackendConfiguration(
            baseURLString: "https://vehicle.example.com",
            apiKey: String(repeating: "c", count: 64)
        )

        let dashboard = try BackendClient(configuration: configuration)
            .makeDashboard(status: status, widget: widget)
        #expect(dashboard.vehicleID == "vehicle-test")
        #expect(dashboard.isConnected)
        #expect(dashboard.isSwapping)
        #expect(dashboard.stateOfCharge == 84)
        #expect(dashboard.remainingRange == 418)
        #expect(dashboard.mileage == 12345.6)
        #expect(dashboard.chargingPower == 11800)
        #expect(dashboard.chargingVoltage == 358)
        #expect(dashboard.chargingCurrent == 32.5)
        #expect(dashboard.chargeLimitPercent == 95)
        #expect(dashboard.batterySampledAt == Date(timeIntervalSince1970: 1_700_000_002))
    }

    @Test func vehicleHistoryDecodesBackendTimestampAndFields() throws {
        let payload = """
        {
          "items": [{
            "vehicle_id": "vehicle-test",
            "sampled_at": "2026-10-09T08:30:00Z",
            "latitude": 31.2304,
            "longitude": 121.4737,
            "soc": 82,
            "remaining_range": 410.5,
            "remaining_actual_range": 365,
            "mileage": 12345.6,
            "inside_temperature": 24,
            "outside_temperature": 18.5
          }],
          "limit": 2000
        }
        """
        let page = try JSONDecoder().decode(VehicleSnapshotPage.self, from: Data(payload.utf8))
        let point = try #require(page.items.first)
        #expect(point.vehicleID == "vehicle-test")
        #expect(point.coordinate.isValid)
        #expect(point.remainingActualRange == 365)
        #expect(page.limit == 2000)
    }

    @Test func chargingSessionDecodesDedicatedBackendSamples() throws {
        let payload = """
        {
          "items": [{
            "vehicle_id": "vehicle-test",
            "sampled_at": "2026-10-09T08:30:00Z",
            "soc": 42,
            "charge_state": 1,
            "charging_current": 30,
            "charging_power": 11000,
            "charging_voltage": 360
          }]
        }
        """
        let page = try JSONDecoder().decode(
            VehicleChargingSamplePage.self,
            from: Data(payload.utf8)
        )
        let sample = try #require(page.items.first)
        #expect(sample.vehicleID == "vehicle-test")
        #expect(sample.chargeStateCode == 1)
        #expect(sample.currentAmps == 30)
        #expect(sample.powerWatts == 11_000)
        #expect(sample.voltageVolts == 360)
    }

    @Test func chargingHistoryDecodesSessionSummaries() throws {
        let payload = """
        {
          "items": [{
            "id": "1791515400000:vehicle-test",
            "vehicle_id": "vehicle-test",
            "started_at": "2026-10-09T08:30:00Z",
            "ended_at": "2026-10-09T09:12:00Z",
            "duration_seconds": 2520,
            "start_soc": 35,
            "end_soc": 80,
            "peak_power_watts": 11850,
            "sample_count": 253
          }],
          "limit": 50
        }
        """
        let page = try JSONDecoder().decode(ChargingSessionPage.self, from: Data(payload.utf8))
        let session = try #require(page.items.first)
        #expect(session.vehicleID == "vehicle-test")
        #expect(session.durationSeconds == 2_520)
        #expect(session.startSOC == 35)
        #expect(session.endSOC == 80)
        #expect(session.peakPowerWatts == 11_850)
        #expect(session.sampleCount == 253)
        #expect(page.limit == 50)
    }

    @Test func pathSimplificationTreatsNearbyDriftAsTheSamePlace() {
        let start = Date(timeIntervalSince1970: 1_700_035_200)
        let points = [
            VehicleSnapshot(vehicleID: "v", sampledAt: start, latitude: 31.2304, longitude: 121.4737),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(3_600), latitude: 31.23085, longitude: 121.4737),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(3_660), latitude: 31.2313, longitude: 121.4737),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(7_200), latitude: 31.23131, longitude: 121.47371)
        ]
        let simplified = VehiclePathBuilder.simplify(points)
        #expect(simplified.count == 2)
        #expect(simplified[1].sampledAt == points[2].sampledAt)
        #expect(VehiclePathBuilder.distanceMeters(simplified) >= VehiclePathBuilder.samePlaceRadiusMeters)
    }

    @Test func dailyPathStartsAtTheLastSampleBeforeLeavingTheInitialPlace() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_035_200)
        let points = [
            VehicleSnapshot(vehicleID: "v", sampledAt: start, latitude: 31.2304, longitude: 121.4737),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(10_000), latitude: 31.2308, longitude: 121.4737),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(10_060), latitude: 31.2320, longitude: 121.4737)
        ]

        let path = try #require(VehiclePathBuilder.buildDailyPaths(from: points, calendar: calendar).first)
        #expect(path.startTime == points[1].sampledAt)
        #expect(path.endTime == points[2].sampledAt)
    }

    @Test func sustainedStopSplitsSampledPathWithoutBridgingThePause() throws {
        let start = Date(timeIntervalSince1970: 1_700_035_200)
        let samples: [(Int, Double)] = [(0, 0), (1, 0.002), (2, 0.004), (3, 0.006),
                                        (18, 0.00601), (19, 0.008), (20, 0.010)]
        let points = samples.map { minute, offset in
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(Double(minute * 60)),
                            latitude: 31.2304, longitude: 121.4737 + offset)
        }
        let path = try #require(VehiclePathBuilder.buildDailyPaths(from: points).first)
        #expect(path.segments.count == 2)
        #expect(path.segments[0].endTime == points[3].sampledAt)
        #expect(path.segments[1].startTime == points[4].sampledAt)
        #expect(path.distanceKilometers == path.segments.reduce(0) { $0 + $1.distanceKilometers })
    }

    @Test func briefStopDoesNotSplitAndLongTelemetryGapDoes() throws {
        let start = Date(timeIntervalSince1970: 1_700_035_200)
        func point(_ minute: Int, _ offset: Double) -> VehicleSnapshot {
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(Double(minute * 60)),
                            latitude: 31.2304, longitude: 121.4737 + offset)
        }
        let briefStop = [point(0, 0), point(1, 0.002), point(10, 0.00201), point(11, 0.004)]
        #expect(VehiclePathBuilder.buildSegments(briefStop).count == 1)
        let telemetryGap = [point(0, 0), point(1, 0.002), point(36, 0.004), point(37, 0.006)]
        let segments = VehiclePathBuilder.buildSegments(telemetryGap)
        #expect(segments.count == 2)
        #expect(segments[0].endTime == telemetryGap[1].sampledAt)
        #expect(segments[1].startTime == telemetryGap[2].sampledAt)
    }

    @Test func finalParkedSamplesDoNotExtendDrivingEndTime() throws {
        let start = Date(timeIntervalSince1970: 1_700_035_200)
        let points = [
            VehicleSnapshot(vehicleID: "v", sampledAt: start, latitude: 31.2304, longitude: 121.4737),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(60), latitude: 31.2304, longitude: 121.4757),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(120), latitude: 31.2304, longitude: 121.4777),
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(1_020), latitude: 31.23041, longitude: 121.47771)
        ]
        let segment = try #require(VehiclePathBuilder.buildSegments(points).first)
        #expect(segment.endTime == points[2].sampledAt)
    }

    @Test func longSmallAreaGPSWanderIsNotDrawnAsATrip() throws {
        let start = Date(timeIntervalSince1970: 1_700_035_200)
        func point(_ minute: Int, _ offset: Double) -> VehicleSnapshot {
            VehicleSnapshot(vehicleID: "v", sampledAt: start.addingTimeInterval(Double(minute * 60)),
                            latitude: 31.2304, longitude: 121.4737 + offset)
        }
        let drift = [point(0, 0), point(10, 0.0005), point(20, 0.0011),
                     point(30, 0.0009), point(35, 0.0012)]
        #expect(VehiclePathBuilder.buildSegments(drift).isEmpty)

        let departure = drift + [point(36, 0.003), point(37, 0.005)]
        let segment = try #require(VehiclePathBuilder.buildSegments(departure).first)
        #expect(segment.startTime == drift.last?.sampledAt)
        #expect(segment.points.first == drift.last)
        #expect(VehiclePathBuilder.buildSegments(departure).count == 1)
    }

    @Test func dedicatedVehicleTripsDecodeWithoutGPSReconstruction() throws {
        let payload = """
        {
          "items": [{
            "id": "journey-1",
            "trip_id": "trip-1",
            "started_at": "2026-10-09T08:30:00Z",
            "ended_at": "2026-10-09T08:47:00Z",
            "distance_kilometers": 9,
            "duration_minutes": 17,
            "start_location": {"poi": "起点", "address": "起点道路"},
            "end_location": {"poi": "终点", "address": "终点道路"},
            "average_speed_kph": 31,
            "average_energy_consumption_kwh_per_100km": 16.8,
            "energy_consumed_kwh": 1.51,
            "maximum_speed_kph": 62,
            "odometer_kilometers": 1234.5,
            "rapid_acceleration_count": 1,
            "rapid_deceleration_count": 0,
            "rapid_swerve_count": 0,
            "is_combined": false
          }],
          "has_more": true,
          "next_query_time": 1791534600,
          "server_time": 1791535000
        }
        """
        let page = try JSONDecoder().decode(VehicleTripPage.self, from: Data(payload.utf8))
        let trip = try #require(page.items.first)
        #expect(trip.startLocation.displayName == "起点")
        #expect(trip.endLocation.displayName == "终点")
        #expect(trip.distanceKilometers == 9)
        #expect(trip.durationMinutes == 17)
        #expect(trip.averageEnergyConsumptionKWhPer100Km == 16.8)
        #expect(trip.energyConsumedKWh == 1.51)
        #expect(page.hasMore)
    }

    @Test func ongoingTripDecodesWithoutInventingLocations() throws {
        let payload = """
        {
          "items": [{
            "id": "ongoing",
            "started_at": "2026-10-13T05:43:00Z",
            "ended_at": "2026-10-13T05:53:00Z",
            "distance_kilometers": 5,
            "duration_minutes": 10,
            "start_location": {},
            "end_location": {},
            "is_combined": false
          }],
          "has_more": false
        }
        """
        let page = try JSONDecoder().decode(VehicleTripPage.self, from: Data(payload.utf8))
        let trip = try #require(page.items.first)
        #expect(!trip.startLocation.hasDisplayName)
        #expect(!trip.endLocation.hasDisplayName)
        #expect(trip.energyConsumedKWh == nil)
    }

    @Test func swapHistoryDecodesOrderBatteryAndPriceDetails() throws {
        let payload = """
        {
          "items": [{
            "id": "swap-1",
            "status": "confirmed",
            "occurred_at": "2026-10-09T09:10:00Z",
            "station_key": "PS-NIO-station-1",
            "station_name": "苏州中心蔚来换电站",
            "station_address": "苏州市工业园区",
            "order_no": "order-1",
            "order_status_name": "已完成",
            "price_amount": 12.5,
            "price_currency": "CNY",
            "price_description": "实付 ¥12.50",
            "payment_items": [{"name": "换电服务费", "amount": 12.5, "payment_type": 1}],
            "exact_energy_kwh": null,
            "estimated_energy_kwh": 55.2,
            "energy_source": "station_inventory_estimate",
            "outgoing_battery_id": "old-battery",
            "outgoing_production_date": "2021-04-08",
            "outgoing_capacity_kwh": 75,
            "outgoing_soc_percent": 18,
            "incoming_battery_id": "new-battery",
            "incoming_production_date": "2024-03-28",
            "incoming_capacity_kwh": 100,
            "incoming_soc_percent": 93,
            "battery_source": "station_inventory_delta",
            "confidence": "high"
          }],
          "limit": 100,
          "offset": 0
        }
        """
        let page = try JSONDecoder().decode(SwapEventPage.self, from: Data(payload.utf8))
        let event = try #require(page.items.first)
        #expect(event.stationName == "苏州中心蔚来换电站")
        #expect(event.outgoingBatteryID == "old-battery")
        #expect(event.incomingBatteryID == "new-battery")
        #expect(event.estimatedEnergyKWh == 55.2)
        #expect(event.priceAmount == 12.5)
        #expect(event.paymentItems.first?.name == "换电服务费")
    }

    @Test func activeServiceOrdersDecodeStationAndStatus() throws {
        let payload = """
        {
          "items": [{
            "order_no": "825393308584269288",
            "order_type": "pe_shaman_change",
            "order_status": "10",
            "order_status_name": "换电中",
            "order_created_at": "2026-10-12T05:51:21Z",
            "station_key": "PS-NIO-3606da31-f8539ae9",
            "station_name": "天津红星美凯龙滨海店 蔚来换电站",
            "station_address": null,
            "baseline_captured_at": "2026-10-12T05:51:25Z",
            "queue_number": 2,
            "target_battery_cap_level": 1,
            "vehicles_ahead": 1,
            "estimated_wait_minutes": 5,
            "estimated_wait_source": "station_queue_estimate",
            "queue_status_text": "正在排队",
            "queue_updated_at": "2026-10-12T05:53:59Z",
            "first_seen_at": "2026-10-12T05:51:21Z",
            "last_seen_at": "2026-10-12T05:54:06Z"
          }]
        }
        """

        let page = try JSONDecoder().decode(
            ActiveServiceOrderPage.self,
            from: Data(payload.utf8)
        )
        let order = try #require(page.items.first)
        #expect(order.id == "825393308584269288")
        #expect(order.orderStatusName == "换电中")
        #expect(order.stationKey == "PS-NIO-3606da31-f8539ae9")
        #expect(order.baselineCapturedAt != nil)
        #expect(order.queueNumber == 2)
        #expect(order.targetBatteryCapLevel == 1)
        #expect(order.vehiclesAhead == 1)
        #expect(order.estimatedWaitMinutes == 5)
        #expect(order.queueUpdatedAt != nil)
        let plan = try #require(SwapQueueNotificationPlanner.plan(for: order))
        #expect(plan.isImmediate)
        #expect(plan.delay == 1)
        #expect(plan.title == "下一辆快到你了")
    }

    @Test func queueNotificationSchedulesFiveMinutesBeforeEstimatedTurn() throws {
        let payload = """
        {"items":[{
          "order_no":"queue-test","order_type":"pe_shaman_change",
          "order_created_at":"2026-10-12T05:51:21Z",
          "station_name":"测试换电站","queue_number":8,"vehicles_ahead":4,
          "estimated_wait_minutes":20,
          "first_seen_at":"2026-10-12T05:51:21Z",
          "last_seen_at":"2026-10-12T05:54:06Z"
        }]}
        """
        let page = try JSONDecoder().decode(ActiveServiceOrderPage.self, from: Data(payload.utf8))
        let order = try #require(page.items.first)
        let plan = try #require(SwapQueueNotificationPlanner.plan(for: order))
        #expect(!plan.isImmediate)
        #expect(plan.delay == 15 * 60)
        #expect(plan.body.contains("前方还有 4 辆"))
    }

    @Test func dateParserPreservesFractionalSecondsAndTimeZones() async {
        let expected = Date(timeIntervalSince1970: 1_791_534_600.125)
        #expect(VehicleDateParser.parse("2026-10-09T08:30:00.125Z") == expected)
        #expect(VehicleDateParser.parse("2026-10-09T16:30:00.125+08:00") == expected)
        #expect(VehicleDateParser.parse("not-a-date") == nil)
        await withTaskGroup(of: Date?.self) { group in
            for _ in 0..<100 {
                group.addTask { VehicleDateParser.parse("2026-10-09T08:30:00.125Z") }
            }
            for await date in group { #expect(date == expected) }
        }
    }

    @Test func displayDateUsesRequestedYearMonthDayFormat() throws {
        let date = try #require(VehicleDateParser.parse("2026-10-09T20:30:00Z"))
        #expect(VehicleDateParser.displayDate(date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) == "2026/10/10")
    }

    @Test func nearestChargingSamplePreservesBoundariesAndEarlierPointOnTie() throws {
        let payload = """
        {"items":[
          {"vehicle_id":"test","sampled_at":"2026-10-09T08:30:00Z","charge_state":1},
          {"vehicle_id":"test","sampled_at":"2026-10-09T08:30:10Z","charge_state":1},
          {"vehicle_id":"test","sampled_at":"2026-10-09T08:30:30Z","charge_state":1}
        ]}
        """
        let samples = try JSONDecoder().decode(VehicleChargingSamplePage.self, from: Data(payload.utf8)).items
        let first = try #require(samples.first)
        for seconds in -10...40 {
            let date = first.sampledAt.addingTimeInterval(Double(seconds))
            let baseline = samples.min { abs($0.sampledAt.timeIntervalSince(date)) < abs($1.sampledAt.timeIntervalSince(date)) }
            #expect(ChargingSample.nearest(in: samples, to: date)?.id == baseline?.id)
        }
        #expect(ChargingSample.nearest(in: [], to: .now) == nil)
    }

    @Test @MainActor func changedBackendDoesNotJoinOrPublishTheOldRefresh() async throws {
        let fixture = try RefreshTestFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let oldRefresh = Task { await model.refresh() }
        try await fixture.scenario.waitForRequest(host: "old.fixture.invalid")
        try model.saveSettings(baseURLString: "https://new.fixture.invalid", apiKey: fixture.key, controlKey: "")
        await model.refresh()
        await oldRefresh.value

        #expect(model.dashboard?.vehicleID == "new-vehicle")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
        #expect(fixture.scenario.requestCount(host: "new.fixture.invalid") == 8)
    }

    @Test @MainActor func cancelledRefreshCallerDoesNotCancelSharedWork() async throws {
        let fixture = try RefreshTestFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let firstCaller = Task { await model.refresh() }
        try await fixture.scenario.waitForRequest(host: "old.fixture.invalid")
        firstCaller.cancel()
        await model.refresh()
        await firstCaller.value

        #expect(model.dashboard?.vehicleID == "old-vehicle")
        #expect(fixture.scenario.requestCount(host: "old.fixture.invalid") == 8)
        #expect(model.errorMessage == nil)
    }

    @Test @MainActor func failedTripRequestDoesNotDiscardSuccessfulVehicleSections() async throws {
        let fixture = try RefreshTestFixture(failTrips: true)
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.refresh()

        #expect(model.dashboard?.vehicleID == "old-vehicle")
        #expect(model.errorMessage == nil)
        #expect(model.tripsErrorMessage != nil)
        #expect(model.failureNotice?.message == model.tripsErrorMessage)
        #expect(model.historyErrorMessage == nil)
        #expect(model.chargingSessionsErrorMessage == nil)
        #expect(model.swapEventsErrorMessage == nil)
        #expect(model.activeServiceOrdersErrorMessage == nil)
    }

    @Test @MainActor func cachedDashboardAppearsBeforeNetworkThenRefreshesInPlace() async throws {
        let fixture = try RefreshTestFixture()
        defer { fixture.cleanUp() }
        let suite = "nio-dashboard-cache-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsVehicleDashboardCache(defaults: defaults)
        let baseURL = try #require(URL(string: "https://old.fixture.invalid"))
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cachedDashboard = VehicleDashboard(
            vehicleID: "cached-vehicle",
            isConnected: false,
            stateCode: 2,
            mileage: 12_345,
            isSwapping: false,
            stateOfCharge: 62,
            remainingRange: 310,
            remainingActualRange: 280,
            chargeStateCode: 0,
            chargingCurrent: nil,
            chargingPower: nil,
            chargingVoltage: nil,
            chargeLimitPercent: nil,
            batterySampledAt: cachedAt,
            lockStatusCode: 1,
            location: nil,
            locationSampledAt: nil,
            insideTemperature: 22,
            outsideTemperature: 18,
            updatedAt: cachedAt
        )
        cache.save(cachedDashboard, baseURL: baseURL, at: cachedAt)

        let model = fixture.model(dashboardCache: cache)
        #expect(model.dashboard == nil)
        model.prepareForInitialDisplay()
        #expect(model.dashboard?.vehicleID == "cached-vehicle")
        #expect(model.isShowingCachedDashboard)
        #expect(model.lastDashboardRefreshAt == cachedAt)

        await model.refresh()
        #expect(model.dashboard?.vehicleID == "old-vehicle")
        #expect(!model.isShowingCachedDashboard)
        #expect(cache.load(matching: baseURL)?.dashboard.vehicleID == "old-vehicle")
    }

    @Test @MainActor func successfulProfileSurvivesImageFailureOnFirstLoad() async throws {
        let fixture = try VehicleIdentityFixture(
            vehicleID: "vehicle-a",
            displayName: "车辆 A",
            imageReply: .httpFailure
        )
        defer { fixture.cleanUp() }
        let model = fixture.model()

        await model.refresh()

        #expect(model.vehicleProfile?.vehicleID == "vehicle-a")
        #expect(model.vehicleTitle == "车辆 A")
        #expect(model.vehicleImageData == nil)
    }

    @Test @MainActor func sameVehicleKeepsValidImageWhenARefreshImageFails() async throws {
        let fixture = try VehicleIdentityFixture(
            vehicleID: "vehicle-a",
            displayName: "车辆 A",
            imageReply: .success(fixtureImageData(seed: 1), etag: "\"a1\"")
        )
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.refresh()
        let firstImage = try #require(model.vehicleImageData)

        fixture.scenario.update(
            vehicleID: "vehicle-a",
            displayName: "车辆 A 新名称",
            imageReply: .httpFailure
        )
        await model.refresh()

        #expect(model.vehicleTitle == "车辆 A 新名称")
        #expect(model.vehicleImageData == firstImage)
    }

    @Test @MainActor func changingVehicleReplacesImageAndDoesNotSendTheOldETag() async throws {
        let fixture = try VehicleIdentityFixture(
            vehicleID: "vehicle-a",
            displayName: "车辆 A",
            imageReply: .success(fixtureImageData(seed: 1), etag: "\"a1\"")
        )
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.refresh()
        let firstImage = try #require(model.vehicleImageData)

        let secondImage = fixtureImageData(seed: 2)
        fixture.scenario.update(
            vehicleID: "vehicle-b",
            displayName: "车辆 B",
            imageReply: .success(secondImage, etag: "\"b1\"")
        )
        await model.refresh()

        #expect(model.vehicleProfile?.vehicleID == "vehicle-b")
        #expect(model.vehicleImageData == secondImage)
        #expect(model.vehicleImageData != firstImage)
        #expect(fixture.scenario.lastImageConditionalETag() == nil)
        #expect(fixture.cache.load(matching: fixture.baseURL, vehicleID: "vehicle-a") == nil)
        #expect(fixture.cache.load(matching: fixture.baseURL, vehicleID: "vehicle-b")?.data == secondImage)
    }

    @Test @MainActor func changingVehicleClearsOldImageWhenNewImageRequestFails() async throws {
        let fixture = try VehicleIdentityFixture(
            vehicleID: "vehicle-a",
            displayName: "车辆 A",
            imageReply: .success(fixtureImageData(seed: 1), etag: "\"a1\"")
        )
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.refresh()
        #expect(model.vehicleImageData != nil)

        fixture.scenario.update(
            vehicleID: "vehicle-b",
            displayName: "车辆 B",
            imageReply: .httpFailure
        )
        await model.refresh()

        #expect(model.vehicleProfile?.vehicleID == "vehicle-b")
        #expect(model.vehicleTitle == "车辆 B")
        #expect(model.vehicleImageData == nil)
        #expect(fixture.cache.load(matching: fixture.baseURL, vehicleID: "vehicle-a") == nil)
    }

    @Test @MainActor func changingVehicleClearsOldImageWhenNewImageCannotDecode() async throws {
        let fixture = try VehicleIdentityFixture(
            vehicleID: "vehicle-a",
            displayName: "车辆 A",
            imageReply: .success(fixtureImageData(seed: 1), etag: "\"a1\"")
        )
        defer { fixture.cleanUp() }
        let model = fixture.model()
        await model.refresh()

        fixture.scenario.update(
            vehicleID: "vehicle-b",
            displayName: "车辆 B",
            imageReply: .invalidImage
        )
        await model.refresh()

        #expect(model.vehicleProfile?.vehicleID == "vehicle-b")
        #expect(model.vehicleImageData == nil)
        #expect(fixture.cache.load(matching: fixture.baseURL, vehicleID: "vehicle-a") == nil)
    }

    @Test @MainActor func analyticsAndCouponsRefreshWithoutJoiningForegroundPolling() async throws {
        let fixture = try RefreshTestFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        let from = try #require(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        let to = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))

        async let stats: Void = model.refreshEnergyStats(from: from, to: to)
        async let coupons: Void = model.refreshAvailableCoupons()
        _ = await (stats, coupons)
        #expect(model.energyStats?.energyCoverageComplete == false)
        #expect(model.energyStats?.chargingEnergyKWhEstimated == nil)
        #expect(model.availableCoupons.map(\.identifier) == ["coupon-1", "coupon-2"])
        #expect(model.availableCouponCount == 3)
        #expect(model.couponsHaveMore)

        await model.refreshAvailableCoupons(reset: false)
        #expect(model.availableCoupons.map(\.identifier) == ["coupon-1", "coupon-2", "coupon-3"])
        #expect(!model.couponsHaveMore)
    }

    @Test @MainActor func changedStationHeadersStartNewRequestForSameURL() async throws {
        let transport = StationRefreshScenario()
        let model = StationViewModel(fetchStation: { try await transport.fetch($0) })
        let url = URL(string: "https://station.fixture.invalid")!
        let old = Task { await model.refresh(request: InfoRequest(url: url, headers: ["Authorization":"old"]), name: "Old") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await transport.requestCount() == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(2))
        }
        await model.refresh(request: InfoRequest(url: url, headers: ["Authorization":"new"]), name: "New")
        await old.value
        #expect(await transport.requestCount() == 2)
        #expect(model.batteries.first?.id == "new")
        #expect(model.currentRequestName == "New")
        #expect(!model.isLoading)
    }

    @Test func widgetUsesFiveMinutesOnlyForActiveVehicleStates() {
        func snapshot(state: Int?, chargeState: Int? = 0, swapping: Bool = false) -> WidgetVehicleSnapshot {
            WidgetVehicleSnapshot(
                isConnected: true, stateCode: state, isSwapping: swapping,
                stateOfCharge: 80, remainingRange: 400, remainingActualRange: 360,
                chargeStateCode: chargeState, outsideTemperature: 20, updatedAt: .now,
                station: nil, hasStationSelection: false
            )
        }

        #expect(snapshot(state: 2).preferredRefreshInterval == 15 * 60)
        #expect(snapshot(state: 1).preferredRefreshInterval == 5 * 60)
        #expect(snapshot(state: 3).preferredRefreshInterval == 5 * 60)
        #expect(snapshot(state: 4).preferredRefreshInterval == 5 * 60)
        #expect(snapshot(state: 2, chargeState: 1).preferredRefreshInterval == 5 * 60)
        #expect(snapshot(state: 2, swapping: true).preferredRefreshInterval == 5 * 60)
    }

    @Test func stationBatteryShortcutSpeaksCountAndEveryKnownProductionDate() {
        let status = NIOStationLiveStatus(
            stationID: "PS-NIO-test",
            stationName: "滨江换电站",
            available75Count: 3,
            available75Batteries: [
                .init(batteryID: "one", slotID: 1, batteryCapSeries: 3, stateOfCharge: 100, productionDate: "2025-03-30"),
                .init(batteryID: "two", slotID: 2, batteryCapSeries: 3, stateOfCharge: 96, productionDate: "2024-11-09"),
                .init(batteryID: nil, slotID: 3, batteryCapSeries: 3, stateOfCharge: 93, productionDate: nil)
            ]
        )

        let spoken = QueryStationBatteryIntent.spokenResult(
            for: status,
            requestedName: "用户输入站点"
        )

        #expect(spoken.contains("滨江换电站目前有3块可用的75千瓦时电池"))
        #expect(spoken.contains("2025年3月30日、2024年11月9日"))
        #expect(spoken.contains("另有1块电池暂时没有生产日期"))
    }

    @Test func stationBatteryShortcutExplainsWhenNoBatteryIsAvailable() {
        let status = NIOStationLiveStatus(
            stationID: "PS-NIO-test",
            stationName: "测试换电站",
            available75Count: 0,
            available75Batteries: []
        )

        let spoken = QueryStationBatteryIntent.spokenResult(for: status, requestedName: "忽略")

        #expect(spoken.contains("目前没有可用的75千瓦时电池"))
        #expect(spoken.contains("未占用"))
        #expect(spoken.contains("百分之92"))
    }

    #if DEBUG
    @Test @MainActor func designPreviewIsIndependentAndRejectsVehicleCommands() async throws {
        let model = VehicleViewModel.designPreview()
        await model.refresh()
        #expect(model.dashboard?.vehicleID == "preview-vehicle")
        #expect(model.trips.count == 3)
        #expect(model.chargingSamples.count == 120)
        #expect(try await model.fetchChargingSessionSamples(id: "preview-session").count == 120)
        #expect(try await model.fetchSwapEvent(id: "preview-swap").id == "preview-swap")
        do {
            _ = try await model.performVehicleAction(.find)
            Issue.record("Preview mode accepted a vehicle command")
        } catch {
            #expect(error as? BackendClientError == .vehicleControlFailed("设计预览不会发送车辆指令。"))
        }
    }
    #endif
}

@MainActor
private func fixtureImageData(seed: Int) -> Data {
    let color = seed == 1 ? UIColor.systemBlue : UIColor.systemOrange
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    return image.pngData()!
}

private enum VehicleImageReply: Sendable {
    case success(Data, etag: String)
    case httpFailure
    case invalidImage
}

@MainActor
private final class VehicleIdentityFixture {
    let key = "vehicle-identity-\(UUID().uuidString)"
    let service = "nio-vehicle-identity-tests-\(UUID().uuidString)"
    let suite = "nio-vehicle-identity-defaults-\(UUID().uuidString)"
    let baseURL = URL(string: "https://identity.fixture.invalid")!
    let scenario: VehicleIdentityScenario
    let settings: BackendSettingsStore
    let session: URLSession
    let cache: FileVehicleImageCache
    private let cacheRoot: URL

    init(vehicleID: String, displayName: String, imageReply: VehicleImageReply) throws {
        scenario = VehicleIdentityScenario(
            vehicleID: vehicleID,
            displayName: displayName,
            imageReply: imageReply
        )
        settings = BackendSettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
            keychainService: service
        )
        try settings.save(baseURLString: baseURL.absoluteString, apiKey: key, controlKey: "")
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = FileVehicleImageCache(
            fileURL: cacheRoot.appendingPathComponent("vehicle-image.plist")
        )
        VehicleIdentityURLProtocol.register(scenario, for: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VehicleIdentityURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func model() -> VehicleViewModel {
        VehicleViewModel(
            settingsStore: settings,
            session: session,
            vehicleImageCache: cache
        )
    }

    func cleanUp() {
        session.invalidateAndCancel()
        VehicleIdentityURLProtocol.unregister(key)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ] as CFDictionary)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}

private final class VehicleIdentityScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var vehicleID: String
    private var displayName: String
    private var imageReply: VehicleImageReply
    private var imageConditionalETags: [String?] = []

    init(vehicleID: String, displayName: String, imageReply: VehicleImageReply) {
        self.vehicleID = vehicleID
        self.displayName = displayName
        self.imageReply = imageReply
    }

    func update(vehicleID: String, displayName: String, imageReply: VehicleImageReply) {
        lock.lock()
        self.vehicleID = vehicleID
        self.displayName = displayName
        self.imageReply = imageReply
        lock.unlock()
    }

    func lastImageConditionalETag() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return imageConditionalETags.last ?? nil
    }

    func reply(for request: URLRequest) -> (Data, Int, [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        let path = request.url!.path
        if path == "/api/v1/vehicle/image" {
            imageConditionalETags.append(request.value(forHTTPHeaderField: "If-None-Match"))
            switch imageReply {
            case .success(let data, let etag):
                return (data, 200, ["Content-Type": "image/png", "ETag": etag])
            case .httpFailure:
                return (Data("upstream failure".utf8), 502, ["Content-Type": "text/plain"])
            case .invalidImage:
                return (Data("not an image".utf8), 200, ["Content-Type": "image/png"])
            }
        }
        let vehicle: [String: Any] = [
            "vehicle_id": vehicleID,
            "connection_status": ["connected": true],
            "exterior_status": ["vehicle_state": 2],
            "soc_status": ["soc": 84]
        ]
        let body: [String: Any]
        switch path {
        case "/api/v1/vehicle/profile":
            body = [
                "vehicle_id": vehicleID,
                "display_name": displayName,
                "model_type": "ET5T",
                "color": "tech_grey",
                "image_url": "https://cdn.fixture.invalid/\(vehicleID).png",
                "image_available": true,
                "image_sha256": "sha-\(vehicleID)",
                "image_fetched_at": "2026-11-13T08:00:00Z"
            ]
        case "/api/v1/vehicle/status":
            body = ["result_code": "success", "data": vehicle]
        case "/api/v1/vehicle/widget-info":
            body = ["result_code": "success", "data": ["status": vehicle]]
        default:
            body = ["items": [], "limit": 2000, "offset": 0, "has_more": false]
        }
        return (
            try! JSONSerialization.data(withJSONObject: body),
            200,
            ["Content-Type": "application/json"]
        )
    }
}

private final class VehicleIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var scenarios: [String: VehicleIdentityScenario] = [:]
    private var work: DispatchWorkItem?

    static func register(_ scenario: VehicleIdentityScenario, for key: String) {
        lock.lock()
        scenarios["Bearer \(key)"] = scenario
        lock.unlock()
    }

    static func unregister(_ key: String) {
        lock.lock()
        scenarios.removeValue(forKey: "Bearer \(key)")
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let scenario = Self.scenarios[
            request.value(forHTTPHeaderField: "Authorization") ?? ""
        ]
        Self.lock.unlock()
        guard let scenario else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (data, status, headers) = scenario.reply(for: request)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().async(execute: work)
    }

    override func stopLoading() { work?.cancel() }
}

private actor StationRefreshScenario {
    private var count = 0
    func requestCount() -> Int { count }
    func fetch(_ request: InfoRequest) async throws -> SwapStationSnapshot {
        count += 1
        let key = request.headers?["Authorization"] ?? "missing"
        if key == "old" { try await Task.sleep(for: .milliseconds(100)) }
        return SwapStationSnapshot(batteries: [BatteryModel(
            id: key, chargingProgress: 98, batteryType: "75 kWh", chargingRemainingMinutes: nil,
            isOccupied: false, manufactureDate: nil, slotID: 1
        )], feeInfo: nil)
    }
}

@MainActor
private final class RefreshTestFixture {
    let key = "fixture-\(UUID().uuidString)"
    let service = "nio-refresh-tests-\(UUID().uuidString)"
    let suite = "nio-refresh-defaults-\(UUID().uuidString)"
    let scenario: RefreshScenario
    let settings: BackendSettingsStore
    let session: URLSession

    init(failTrips: Bool = false) throws {
        scenario = RefreshScenario(failTrips: failTrips)
        settings = BackendSettingsStore(defaults: UserDefaults(suiteName: suite)!, keychainService: service)
        try settings.save(baseURLString: "https://old.fixture.invalid", apiKey: key, controlKey: "")
        RefreshURLProtocol.register(scenario, for: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func model(dashboardCache: VehicleDashboardCaching? = nil) -> VehicleViewModel {
        VehicleViewModel(
            settingsStore: settings,
            session: session,
            dashboardCache: dashboardCache
        )
    }

    func cleanUp() {
        session.invalidateAndCancel()
        RefreshURLProtocol.unregister(key)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

private final class RefreshScenario: @unchecked Sendable {
    let failTrips: Bool
    private let lock = NSLock()
    private var requests: [String] = []

    init(failTrips: Bool) { self.failTrips = failTrips }

    func reply(for request: URLRequest) -> (Data, Int, TimeInterval) {
        let host = request.url!.host!
        let path = request.url!.path
        lock.lock()
        requests.append(host)
        lock.unlock()
        let vehicleID = host.hasPrefix("old") ? "old-vehicle" : "new-vehicle"
        let status = failTrips && path.hasSuffix("/trips") ? 502 : 200
        let vehicle: [String: Any] = [
            "vehicle_id": vehicleID, "connection_status": ["connected": true],
            "exterior_status": ["vehicle_state": 2], "soc_status": ["soc": 84]
        ]
        let body: [String: Any]
        switch path {
        case "/api/v1/vehicle/status": body = ["result_code": "success", "data": vehicle]
        case "/api/v1/vehicle/widget-info": body = ["result_code": "success", "data": ["status": vehicle]]
        case "/api/v1/energy/stats":
            body = [
                "from": "2026-10-01T00:00:00Z", "to": "2026-11-01T00:00:00Z",
                "swap_count": 2, "swap_electricity_fee_cny_known": 10.5,
                "swap_service_fee_cny_known": 20.0, "swap_total_fee_cny_known": 30.5,
                "coupon_discount_cny_known": 5.0, "actual_paid_cny_known": 25.5,
                "fee_breakdown_covered_count": 1, "paid_amount_covered_count": 1,
                "swap_energy_kwh_known": 40.0, "swap_energy_covered_count": 1,
                "charging_energy_kwh_estimated": NSNull(),
                "charging_energy_kwh_from_power": 0.0, "charging_energy_kwh_from_soc": 0.0,
                "charging_segments_from_power": 0, "charging_segments_from_soc": 0,
                "charging_segments_uncovered": 3, "charging_sample_count": 4,
                "total_energy_kwh_known": 40.0,
                "swap_energy_share_percent_of_known": 100.0,
                "charging_energy_share_percent_of_known": 0.0,
                "energy_coverage_complete": false,
                "current_month_swap_count": 2, "current_month_timezone": "Asia/Shanghai"
            ]
        case "/api/v1/coupons/available":
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value ?? "0"
            if offset == "0" {
                body = [
                    "amount": 3,
                    "coupons": [
                        ["coupon_id": "coupon-1", "coupon_name": "卡券一"],
                        ["coupon_id": "coupon-2", "coupon_name": "卡券二"]
                    ],
                    "has_more": true, "limit": 20, "offset": 0
                ]
            } else {
                body = [
                    "amount": 3,
                    "coupons": [["coupon_id": "coupon-3", "coupon_name": "卡券三"]],
                    "has_more": false, "limit": 20, "offset": 2
                ]
            }
        default: body = ["items": [], "limit": 2000, "offset": 0, "has_more": false]
        }
        return (try! JSONSerialization.data(withJSONObject: body), status, host.hasPrefix("old") ? 0.15 : 0.001)
    }

    func requestCount(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0 == host }.count
    }

    func waitForRequest(host: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requestCount(host: host) == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private final class RefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var scenarios: [String: RefreshScenario] = [:]
    private var work: DispatchWorkItem?

    static func register(_ scenario: RefreshScenario, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        scenarios["Bearer \(key)"] = scenario
    }

    static func unregister(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        scenarios.removeValue(forKey: "Bearer \(key)")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let scenario = Self.scenarios[request.value(forHTTPHeaderField: "Authorization") ?? ""]
        Self.lock.unlock()
        guard let scenario else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (data, status, delay) = scenario.reply(for: request)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() { work?.cancel() }
}
