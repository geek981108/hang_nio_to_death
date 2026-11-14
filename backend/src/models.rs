use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct BatteryObservation {
    pub battery_id: String,
    pub slot_id: Option<i64>,
    pub battery_type: Option<String>,
    pub capacity_kwh: Option<f64>,
    pub soc_percent: Option<f64>,
    pub occupied: bool,
    pub production_date: Option<NaiveDate>,
}

#[derive(Clone, Debug)]
pub struct StationSnapshot {
    pub station_key: String,
    pub station_name: String,
    /// Short address/POI name from the station detail payload. It is not stored
    /// in the snapshot tables; the poller only uses it to refresh the station
    /// directory so completed orders can show an address.
    pub address: Option<String>,
    pub captured_at: DateTime<Utc>,
    pub batteries: Vec<BatteryObservation>,
    pub current_fees: Vec<StationFeeItem>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StationQueueStatus {
    pub vehicles_ahead: Option<u32>,
    pub waiting_description: Option<String>,
    pub navigation_count: Option<u32>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StationFeeItem {
    pub fee_type: Option<String>,
    pub name: String,
    pub fee: String,
    pub unit: String,
    pub currency: String,
    pub is_total: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StationFeePeriod {
    /// Raw station-local time label supplied by NIO, such as 07:00-10:00.
    pub time_period: String,
    pub fees: Vec<StationFeeItem>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StationBatteryReadiness {
    pub slot_id: Option<i64>,
    /// Upstream battery family code. Current observed mapping: 0=70 kWh,
    /// 3=75 kWh and 2=400 V 100 kWh.
    pub battery_cap_series: Option<i64>,
    pub capacity_kwh: Option<f64>,
    pub progress_percent: Option<f64>,
    pub battery_occupied: Option<bool>,
    pub charging_time_description: Option<String>,
    pub charging_remaining_minutes: Option<u32>,
    /// Derived from the upstream minute estimate; not a guaranteed swap-ready time.
    pub estimated_charge_complete_at: Option<DateTime<Utc>>,
    /// Internal only; the live-status API deliberately does not expose battery IDs.
    #[serde(skip_serializing)]
    pub battery_id: Option<String>,
    pub production_date: Option<NaiveDate>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StationAvailableBattery {
    /// Upstream stopped returning this field in the station payload. Keep it
    /// optional for compatibility with older responses.
    pub battery_id: Option<String>,
    pub slot_id: Option<i64>,
    pub battery_cap_series: Option<i64>,
    pub capacity_kwh: Option<f64>,
    pub soc_percent: Option<f64>,
    pub occupied: bool,
    pub production_date: Option<NaiveDate>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StationLiveQueue {
    pub vehicles_ahead: Option<u32>,
    pub waiting_description: Option<String>,
    pub navigation_count: Option<u32>,
    pub estimated_wait_minutes: Option<u32>,
    pub upstream_updated_at: Option<DateTime<Utc>>,
    pub observed_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct StationLiveStatus {
    pub station_id: String,
    pub station_name: String,
    pub captured_at: DateTime<Utc>,
    pub current_fees: Vec<StationFeeItem>,
    pub fee_periods: Vec<StationFeePeriod>,
    pub fee_notices: Vec<String>,
    /// None when the upstream payload does not explicitly identify a timezone.
    pub fee_timezone: Option<String>,
    pub queue: StationLiveQueue,
    pub battery_readiness: Vec<StationBatteryReadiness>,
    pub available_75_count: usize,
    pub available_75_batteries: Vec<StationAvailableBattery>,
}

/// Live status of the swap station nearest to the vehicle's reported position.
/// Same payload as `StationLiveStatus`, plus the straight-line distance from
/// the vehicle; the vehicle coordinates themselves are not returned.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct NearestStationLive {
    pub station_id: String,
    pub station_name: String,
    pub straight_line_distance_km: f64,
    pub captured_at: DateTime<Utc>,
    pub current_fees: Vec<StationFeeItem>,
    pub fee_periods: Vec<StationFeePeriod>,
    pub fee_notices: Vec<String>,
    pub fee_timezone: Option<String>,
    pub queue: StationLiveQueue,
    pub battery_readiness: Vec<StationBatteryReadiness>,
    pub available_75_count: usize,
    pub available_75_batteries: Vec<StationAvailableBattery>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ObservedSwapStation {
    pub station_id: String,
    pub station_name: String,
    pub station_address: Option<String>,
    pub operator_id: Option<String>,
    pub operator_name: Option<String>,
    pub source_order_no: String,
    pub observed_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct SwapStation {
    pub station_id: String,
    pub station_name: String,
    pub station_address: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub operator_id: Option<String>,
    pub operator_name: Option<String>,
    pub source_order_no: Option<String>,
    pub first_seen_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct SwapStationPage {
    pub items: Vec<SwapStation>,
    pub limit: u32,
    pub offset: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ImportedBattery {
    pub battery_id: Option<String>,
    pub production_date: Option<NaiveDate>,
    pub capacity_kwh: Option<f64>,
    pub soc_percent: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ImportedOrder {
    pub order_no: String,
    pub occurred_at: DateTime<Utc>,
    pub station_key: Option<String>,
    pub station_name: Option<String>,
    pub station_address: Option<String>,
    pub order_status_name: Option<String>,
    pub price_amount: Option<f64>,
    pub price_currency: Option<String>,
    pub price_description: Option<String>,
    #[serde(default)]
    pub payment_items: Vec<SwapPaymentItem>,
    pub energy_kwh: Option<f64>,
    pub outgoing_battery: Option<ImportedBattery>,
    pub incoming_battery: Option<ImportedBattery>,
    #[serde(default)]
    pub raw_payload: Option<serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct SwapPaymentItem {
    pub name: String,
    pub amount: f64,
    #[serde(default)]
    pub payment_type: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ObservedServiceOrder {
    pub order_no: String,
    pub order_type: String,
    pub order_status: Option<String>,
    pub order_status_name: Option<String>,
    pub created_at: DateTime<Utc>,
    pub vehicle_id: Option<String>,
    pub vin_code: Option<String>,
    pub station_key: Option<String>,
    pub station_name: Option<String>,
    pub station_address: Option<String>,
    pub raw_payload: serde_json::Value,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ObservedServiceOrderQueue {
    pub order_no: String,
    pub queue_number: Option<u32>,
    pub target_battery_cap_level: Option<u32>,
    pub vehicles_ahead: Option<u32>,
    pub estimated_wait_minutes: Option<u32>,
    pub estimated_wait_source: Option<String>,
    pub queue_status_text: Option<String>,
    pub observed_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct ActiveServiceOrder {
    pub order_no: String,
    pub order_type: String,
    pub order_status: Option<String>,
    pub order_status_name: Option<String>,
    pub order_created_at: DateTime<Utc>,
    pub station_key: Option<String>,
    pub station_name: Option<String>,
    pub station_address: Option<String>,
    pub baseline_captured_at: Option<DateTime<Utc>>,
    pub queue_number: Option<u32>,
    pub target_battery_cap_level: Option<u32>,
    pub vehicles_ahead: Option<u32>,
    pub estimated_wait_minutes: Option<u32>,
    pub estimated_wait_source: Option<String>,
    pub queue_status_text: Option<String>,
    pub queue_updated_at: Option<DateTime<Utc>>,
    pub first_seen_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct ActiveServiceOrderPage {
    pub items: Vec<ActiveServiceOrder>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SwapEvent {
    pub id: String,
    pub status: String,
    pub occurred_at: DateTime<Utc>,
    pub station_key: Option<String>,
    pub station_name: Option<String>,
    pub station_address: Option<String>,
    pub order_no: Option<String>,
    pub order_status_name: Option<String>,
    pub price_amount: Option<f64>,
    pub price_currency: Option<String>,
    pub price_description: Option<String>,
    pub payment_items: Vec<SwapPaymentItem>,
    pub exact_energy_kwh: Option<f64>,
    pub estimated_energy_kwh: Option<f64>,
    pub energy_source: String,
    pub outgoing_battery_id: Option<String>,
    pub outgoing_production_date: Option<NaiveDate>,
    pub outgoing_capacity_kwh: Option<f64>,
    pub outgoing_soc_percent: Option<f64>,
    pub incoming_battery_id: Option<String>,
    pub incoming_production_date: Option<NaiveDate>,
    pub incoming_capacity_kwh: Option<f64>,
    pub incoming_soc_percent: Option<f64>,
    pub battery_source: String,
    pub confidence: String,
    pub evidence: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct SwapEventPage {
    pub items: Vec<SwapEvent>,
    pub limit: u32,
    pub offset: u32,
}

#[derive(Clone, Debug, Serialize)]
pub struct PollOutcome {
    pub outcome: String,
    pub snapshot_id: Option<String>,
    pub candidate_event_id: Option<String>,
    pub battery_count: Option<usize>,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct ServiceStatus {
    pub station_configured: bool,
    pub vehicle_configured: bool,
    pub service_order_configured: bool,
    pub station_template_configured: bool,
    pub poll_interval_seconds: u64,
    pub service_order_poll_interval_seconds: u64,
    pub poll_in_progress: bool,
    pub last_poll: Option<PollRunSummary>,
    pub snapshot_count: i64,
    pub candidate_count: i64,
    pub confirmed_count: i64,
    pub observed_service_order_count: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct PollRunSummary {
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
    pub outcome: String,
    pub snapshot_id: Option<String>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct VehicleSnapshot {
    pub vehicle_id: String,
    pub sampled_at: DateTime<Utc>,
    pub latitude: f64,
    pub longitude: f64,
    pub soc: Option<f64>,
    pub remaining_range: Option<f64>,
    pub remaining_actual_range: Option<f64>,
    pub mileage: Option<f64>,
    pub inside_temperature: Option<f64>,
    pub outside_temperature: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct VehicleSnapshotPage {
    pub items: Vec<VehicleSnapshot>,
    pub limit: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct VehicleChargingSample {
    pub vehicle_id: String,
    pub sampled_at: DateTime<Utc>,
    pub soc: Option<f64>,
    pub charge_state: i64,
    pub charging_current: Option<f64>,
    pub charging_power: Option<f64>,
    pub charging_voltage: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct VehicleChargingSamplePage {
    pub items: Vec<VehicleChargingSample>,
    pub energy_kwh: Option<f64>,
    pub energy_finalized: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct VehicleChargingSession {
    pub id: String,
    pub vehicle_id: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub duration_seconds: i64,
    pub start_soc: Option<f64>,
    pub end_soc: Option<f64>,
    pub peak_power_watts: Option<f64>,
    pub energy_kwh: Option<f64>,
    pub sample_count: usize,
}

#[derive(Debug, Serialize)]
pub struct VehicleChargingSessionPage {
    pub items: Vec<VehicleChargingSession>,
    pub limit: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct VehicleTripLocation {
    pub address: Option<String>,
    pub poi: Option<String>,
    pub road_name: Option<String>,
    pub town: Option<String>,
    pub district: Option<String>,
    pub city: Option<String>,
    pub province: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct VehicleTrip {
    pub id: String,
    pub trip_id: Option<String>,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub distance_kilometers: f64,
    pub duration_minutes: u32,
    pub start_location: VehicleTripLocation,
    pub end_location: VehicleTripLocation,
    pub average_speed_kph: Option<f64>,
    pub average_energy_consumption_kwh_per_100km: Option<f64>,
    pub energy_consumed_kwh: Option<f64>,
    pub maximum_speed_kph: Option<f64>,
    pub odometer_kilometers: Option<f64>,
    pub rapid_acceleration_count: Option<u32>,
    pub rapid_deceleration_count: Option<u32>,
    pub rapid_swerve_count: Option<u32>,
    pub is_combined: bool,
}

#[derive(Debug, Serialize)]
pub struct VehicleTripPage {
    pub items: Vec<VehicleTrip>,
    pub has_more: bool,
    pub next_query_time: Option<i64>,
    pub server_time: Option<i64>,
}

/// One GPS sample of an upstream journey track. Values are exactly what the
/// journey detail returned; no interpolation or smoothing is applied.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub struct VehicleTripTrackPoint {
    pub sampled_at: DateTime<Utc>,
    pub latitude: f64,
    pub longitude: f64,
    pub speed_kph: Option<f64>,
    pub power_consumption: Option<f64>,
    pub np_status: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct VehicleTripTrack {
    pub journey_id: String,
    pub points: Vec<VehicleTripTrackPoint>,
}

/// Vehicle identity and cached image for one tenant. This is the write shape:
/// the bytes travel with it so one upsert stores metadata and image together.
#[derive(Clone, Debug)]
pub struct VehicleProfile {
    pub vehicle_id: String,
    pub display_name: Option<String>,
    pub model_type: Option<String>,
    pub color: Option<String>,
    pub image_url: Option<String>,
    pub image_content_type: Option<String>,
    pub image_bytes: Option<Vec<u8>>,
    pub image_sha256: Option<String>,
    pub image_fetched_at: Option<DateTime<Utc>>,
}

/// Read shape: the image bytes are deliberately not selected, only whether they
/// exist, so a profile read never drags the image through JSON.
#[derive(Clone, Debug, Deserialize)]
pub struct StoredVehicleProfile {
    pub vehicle_id: String,
    pub display_name: Option<String>,
    pub model_type: Option<String>,
    pub color: Option<String>,
    pub image_url: Option<String>,
    pub image_available: bool,
    pub image_sha256: Option<String>,
    pub image_fetched_at: Option<DateTime<Utc>>,
}

/// Cached image as served: content type plus the digest used for ETag
/// revalidation.
pub struct CachedVehicleImage {
    pub content_type: String,
    pub sha256: Option<String>,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Serialize)]
pub struct VehicleProfileResponse {
    pub vehicle_id: String,
    pub display_name: Option<String>,
    pub model_type: Option<String>,
    pub color: Option<String>,
    pub image_url: Option<String>,
    /// The App can fetch the cached bytes from the image endpoint when true.
    pub image_available: bool,
    pub image_sha256: Option<String>,
    pub image_fetched_at: Option<DateTime<Utc>>,
}

impl From<StoredVehicleProfile> for VehicleProfileResponse {
    fn from(profile: StoredVehicleProfile) -> Self {
        Self {
            vehicle_id: profile.vehicle_id,
            display_name: profile.display_name,
            model_type: profile.model_type,
            color: profile.color,
            image_url: profile.image_url,
            image_available: profile.image_available,
            image_sha256: profile.image_sha256,
            image_fetched_at: profile.image_fetched_at,
        }
    }
}
