use chrono::{DateTime, TimeZone, Utc};
use md5::{Digest, Md5};
use reqwest::{Client, StatusCode, header};
use serde::Deserialize;
use serde_json::Value;
use sha2::Sha256;
use std::sync::Arc;
use thiserror::Error;
use tokio::{sync::Semaphore, task::JoinSet};
use url::Url;

use crate::config::VehicleConfig;
use crate::models::{
    StoredVehicleProfile, VehicleChargingSample, VehicleProfile, VehicleSnapshot, VehicleTrip,
    VehicleTripLocation, VehicleTripPage, VehicleTripTrack, VehicleTripTrackPoint,
};

const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
/// The journey detail track arrives at roughly one sample per 10 s; a long
/// trip can legitimately exceed a thousand points. Anything above this bound is
/// treated as a malformed response rather than stored.
const MAX_TRACK_POINTS: usize = 5_000;
const STATUS_ORIGIN: &str = "https://icar.nio.com";
const WIDGET_INFO_URL: &str = "https://app.nio.com/app/api/icar/v2/widget/info";
const SWITCH_CARS_URL: &str = "https://app.nio.com/app/api/icar/v2/switch/cars";
/// A vehicle image is a small PNG/JPEG. Anything larger is refused rather than
/// written to the database.
const MAX_IMAGE_BYTES: usize = 4 * 1024 * 1024;
const WIDGET_FUNCTIONS: &str =
    "rvs_set_doorlock,rvs_set_air_conditioner,rvs_set_tailgate,rvs_exe_findme";
const USER_AGENT: &str =
    "VehicleWidgetExtension/6.9.0 (com.do1.WeiLaiApp.NIOVehicleWidget; build:2672) Alamofire/5.9.1";
const JOURNEY_DETAIL_CONCURRENCY: usize = 4;

#[derive(Clone)]
pub struct NioVehicleClient {
    client: Client,
    config: VehicleConfig,
}

#[derive(Debug, Error)]
pub enum VehicleError {
    #[error("failed to construct NIO vehicle request")]
    InvalidUrl,
    #[error("NIO vehicle request failed")]
    Request(#[source] reqwest::Error),
    #[error("NIO vehicle endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("NIO vehicle endpoint returned invalid JSON")]
    InvalidJson(#[source] reqwest::Error),
    #[error("NIO journey endpoint returned {0}")]
    JourneyApi(String),
    #[error("NIO journey endpoint returned an invalid payload")]
    InvalidJourneyPayload,
    #[error("NIO account does not list the configured vehicle")]
    VehicleNotFound,
    #[error("vehicle image returned a non-image content type")]
    UnexpectedImageType,
    #[error("vehicle image exceeds the size limit")]
    ImageTooLarge,
    #[error("NIO journey track contains too many points: {0}")]
    TrackTooLarge(usize),
}

impl NioVehicleClient {
    pub fn vehicle_id(&self) -> &str {
        &self.config.vehicle_id
    }

    pub fn new(config: VehicleConfig) -> Result<Self, VehicleError> {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .user_agent(USER_AGENT)
            .build()
            .map_err(VehicleError::Request)?;
        Ok(Self { client, config })
    }

    pub async fn status(&self) -> Result<Value, VehicleError> {
        let raw_url = format!(
            "{STATUS_ORIGIN}/api/2/rvs/vehicle/{}/status",
            self.config.vehicle_id
        );
        let mut url = Url::parse(&raw_url).map_err(|_| VehicleError::InvalidUrl)?;
        url.query_pairs_mut()
            .append_pair("field", "offcar_mode_status")
            .append_pair("field", "special")
            .append_pair("field", "connection")
            .append_pair("field", "exterior")
            .append_pair("field", "position")
            .append_pair("field", "soc")
            .append_pair("field", "hvac")
            .append_pair("field", "door")
            .append_pair("lang", &self.config.language)
            .append_pair("app_id", &self.config.app_id)
            .append_pair("device_id", &self.config.device_id)
            .append_pair("app_ver", &self.config.app_version)
            .append_pair("region", &self.config.region);
        let url = sign_url(url, &self.config.bearer_token, Utc::now().timestamp());
        self.get(url, true).await
    }

    pub async fn widget_info(&self) -> Result<Value, VehicleError> {
        let mut url = Url::parse(WIDGET_INFO_URL).map_err(|_| VehicleError::InvalidUrl)?;
        url.query_pairs_mut()
            .append_pair("app_id", &self.config.app_id)
            .append_pair("app_ver", &self.config.app_version)
            .append_pair("lang", &self.config.language)
            .append_pair("vehicle_id", &self.config.vehicle_id)
            .append_pair("region", &self.config.region)
            .append_pair("device_id", &self.config.device_id)
            .append_pair("widget_size", "large")
            .append_pair("widget_functions", WIDGET_FUNCTIONS);
        let url = sign_url(url, &self.config.bearer_token, Utc::now().timestamp());
        self.get(url, false).await
    }

    pub async fn journeys(
        &self,
        count: u32,
        query_time: Option<i64>,
    ) -> Result<JourneyPage, VehicleError> {
        let raw_url = format!(
            "{STATUS_ORIGIN}/api/1/vehicle/{}/journey_merge/timing_journeys",
            self.config.vehicle_id
        );
        let mut url = Url::parse(&raw_url).map_err(|_| VehicleError::InvalidUrl)?;
        url.query_pairs_mut()
            .append_pair("count", &count.to_string())
            .append_pair("query_order", "-1")
            .append_pair("lang", &self.config.language)
            .append_pair("app_id", &self.config.app_id)
            .append_pair("device_id", &self.config.device_id)
            .append_pair("app_ver", &self.config.app_version)
            .append_pair("region", &self.config.region);
        let query_time = query_time.unwrap_or_else(|| Utc::now().timestamp());
        url.query_pairs_mut()
            .append_pair("query_time", &query_time.to_string());
        let url = sign_url(url, &self.config.bearer_token, Utc::now().timestamp());
        let payload = self.get(url, false).await?;
        let page = trip_page_from_payload(payload)?;
        Ok(self.enrich_journey_details(page).await)
    }

    /// Fill energy and driving details from the per-journey endpoint. The same
    /// response carries the stored GPS track, so it is returned alongside the
    /// page instead of being discarded.
    async fn enrich_journey_details(&self, mut page: VehicleTripPage) -> JourneyPage {
        let semaphore = Arc::new(Semaphore::new(JOURNEY_DETAIL_CONCURRENCY));
        let mut tasks = JoinSet::new();
        for (index, trip) in page.items.iter().enumerate() {
            let client = self.clone();
            let journey_id = trip.id.clone();
            let semaphore = semaphore.clone();
            tasks.spawn(async move {
                let Ok(_permit) = semaphore.acquire_owned().await else {
                    return (index, None);
                };
                (index, Some(client.journey_details(&journey_id).await))
            });
        }

        let mut tracks = Vec::new();
        let mut unavailable = 0usize;
        while let Some(result) = tasks.join_next().await {
            let Ok((index, Some(detail_result))) = result else {
                unavailable += 1;
                continue;
            };
            match detail_result {
                Ok(details) => {
                    let Some(trip) = page.items.get_mut(index) else {
                        unavailable += 1;
                        continue;
                    };
                    let journey_id = trip.id.clone();
                    let (energy, points) = apply_journey_details(trip, details);
                    if !energy {
                        unavailable += 1;
                    }
                    if !points.is_empty() {
                        tracks.push(VehicleTripTrack { journey_id, points });
                    }
                }
                Err(_) => unavailable += 1,
            }
        }
        if unavailable > 0 {
            tracing::debug!(
                unavailable,
                total = page.items.len(),
                "some NIO journey details did not provide energy data"
            );
        }
        JourneyPage { page, tracks }
    }

    /// Track only, for the offline backfill command. Upstream returns an empty
    /// vector for journeys without a stored trajectory.
    pub async fn journey_track(
        &self,
        journey_id: &str,
    ) -> Result<Vec<VehicleTripTrackPoint>, VehicleError> {
        Ok(self.journey_details(journey_id).await?.track)
    }

    async fn journey_details(&self, journey_id: &str) -> Result<JourneyDetails, VehicleError> {
        let raw_url = format!(
            "{STATUS_ORIGIN}/api/1/vehicle/{}/journey_merge/{journey_id}",
            self.config.vehicle_id
        );
        let mut url = Url::parse(&raw_url).map_err(|_| VehicleError::InvalidUrl)?;
        url.query_pairs_mut()
            .append_pair("lang", &self.config.language)
            .append_pair("app_id", &self.config.app_id)
            .append_pair("device_id", &self.config.device_id)
            .append_pair("app_ver", &self.config.app_version)
            .append_pair("region", &self.config.region);
        if let Some(account_id) = &self.config.account_id {
            url.query_pairs_mut().append_pair("account_id", account_id);
        }
        let url = sign_url(url, &self.config.bearer_token, Utc::now().timestamp());
        let payload = self.get(url, false).await?;
        if payload.get("result_code").and_then(Value::as_str) != Some("success") {
            return Err(VehicleError::JourneyApi(
                payload
                    .get("debug_msg")
                    .and_then(Value::as_str)
                    .unwrap_or("journey detail failed")
                    .to_owned(),
            ));
        }
        let data = payload.get("data");
        validate_track_size(data)?;
        Ok(JourneyDetails::from_data(data))
    }

    /// Every car on the account. The App shows one; this backend keeps the one
    /// whose id matches `NIO_VEHICLE_ID`.
    pub async fn switch_cars(&self) -> Result<Vec<NioCar>, VehicleError> {
        let mut url = Url::parse(SWITCH_CARS_URL).map_err(|_| VehicleError::InvalidUrl)?;
        url.query_pairs_mut()
            .append_pair("app_id", &self.config.app_id)
            .append_pair("app_ver", &self.config.app_version)
            .append_pair("region", &self.config.region)
            .append_pair("lang", &self.config.language)
            .append_pair("device_id", &self.config.device_id);
        let url = sign_url(url, &self.config.bearer_token, Utc::now().timestamp());
        let payload = self.get(url, false).await?;
        switch_cars_from_payload(payload)
    }

    /// Identity plus the cached image bytes for the configured vehicle. The
    /// image is only fetched again when upstream's URL changed (or the bytes are
    /// missing); an unchanged URL reuses the stored copy indefinitely. A failed
    /// download fails the refresh so the caller retries without mixing a new
    /// URL with old or missing bytes.
    pub async fn vehicle_profile(
        &self,
        cached: Option<&StoredVehicleProfile>,
    ) -> Result<VehicleProfile, VehicleError> {
        let cars = self.switch_cars().await?;
        let car = select_car(&cars, &self.config.vehicle_id)?;
        let image = if reuse_cached_image(cached, car.image.as_deref()) {
            None
        } else if let Some(url) = car.image.as_deref() {
            // Keep the profile update atomic with its image. If the URL changed
            // but downloading failed, returning an error leaves the old URL and
            // bytes together and lets the startup task retry later.
            Some(self.download_image(url).await?)
        } else {
            None
        };
        Ok(VehicleProfile {
            vehicle_id: self.config.vehicle_id.clone(),
            display_name: car.display_name.clone().or_else(|| {
                car.profile
                    .as_ref()
                    .and_then(|profile| profile.nick_name.clone())
            }),
            model_type: car.model_type.clone(),
            color: car
                .profile
                .as_ref()
                .and_then(|profile| profile.color.clone()),
            image_url: car.image.clone(),
            image_content_type: image.as_ref().map(|image| image.content_type.clone()),
            image_bytes: image.as_ref().map(|image| image.bytes.clone()),
            image_sha256: image.as_ref().map(|image| image.sha256.clone()),
            image_fetched_at: image.as_ref().map(|_| Utc::now()),
        })
    }

    async fn download_image(&self, url: &str) -> Result<DownloadedImage, VehicleError> {
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(VehicleError::Request)?;
        if !response.status().is_success() {
            return Err(VehicleError::HttpStatus(response.status()));
        }
        let content_type = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        if !content_type.starts_with("image/") {
            return Err(VehicleError::UnexpectedImageType);
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_IMAGE_BYTES as u64)
        {
            return Err(VehicleError::ImageTooLarge);
        }
        let bytes = response.bytes().await.map_err(VehicleError::Request)?;
        if bytes.len() > MAX_IMAGE_BYTES {
            return Err(VehicleError::ImageTooLarge);
        }
        let sha256 = format!("{:x}", Sha256::digest(&bytes));
        Ok(DownloadedImage {
            bytes: bytes.to_vec(),
            content_type,
            sha256,
        })
    }

    async fn get(&self, url: Url, widget_status_headers: bool) -> Result<Value, VehicleError> {
        let mut request = self
            .client
            .get(url)
            .bearer_auth(&self.config.bearer_token)
            .header(header::ACCEPT, "application/json,text/json,text/plain")
            .header(header::ACCEPT_LANGUAGE, "zh-CN,zh-Hans;q=0.9");
        if widget_status_headers {
            request = request
                .header("widget_family", "accessoryCircular")
                .header("widget_identifier", "widget.small.watch.nio.guardian");
        }
        let response = request.send().await.map_err(VehicleError::Request)?;
        if !response.status().is_success() {
            return Err(VehicleError::HttpStatus(response.status()));
        }
        response.json().await.map_err(VehicleError::InvalidJson)
    }
}

/// One upstream page of journeys plus the tracks returned by the per-journey
/// detail calls that enrich it. The page itself stays exactly as documented by
/// the trips endpoint.
pub struct JourneyPage {
    pub page: VehicleTripPage,
    pub tracks: Vec<VehicleTripTrack>,
}

#[derive(Debug, Deserialize)]
struct NioSwitchCarsResponse {
    result_code: String,
    data: Option<NioSwitchCarsData>,
    debug_msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NioSwitchCarsData {
    #[serde(default)]
    cars: Vec<NioCar>,
}

/// One car in the account's switch/cars list.
#[derive(Clone, Debug, Deserialize)]
pub struct NioCar {
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub model_type: Option<String>,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default, rename = "vehicle_profile")]
    pub profile: Option<NioCarProfile>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct NioCarProfile {
    #[serde(default)]
    pub vehicle_id: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub nick_name: Option<String>,
}

struct DownloadedImage {
    bytes: Vec<u8>,
    content_type: String,
    sha256: String,
}

fn switch_cars_from_payload(payload: Value) -> Result<Vec<NioCar>, VehicleError> {
    let response: NioSwitchCarsResponse = serde_json::from_value(payload).map_err(|error| {
        tracing::warn!(%error, "invalid NIO switch/cars response shape");
        VehicleError::InvalidJourneyPayload
    })?;
    if response.result_code != "success" {
        return Err(VehicleError::JourneyApi(
            response.debug_msg.unwrap_or(response.result_code),
        ));
    }
    Ok(response.data.map(|data| data.cars).unwrap_or_default())
}

/// The image is keyed by its upstream URL: as long as it does not change and the
/// bytes are still stored, there is nothing to download.
fn reuse_cached_image(cached: Option<&StoredVehicleProfile>, image_url: Option<&str>) -> bool {
    let (Some(cached), Some(url)) = (cached, image_url) else {
        return false;
    };
    cached.image_available && cached.image_url.as_deref() == Some(url)
}

/// Pick the configured vehicle. A single-car account is unambiguous even when
/// the response omits `vehicle_profile.vehicle_id`; anything else must match.
fn select_car<'a>(cars: &'a [NioCar], vehicle_id: &str) -> Result<&'a NioCar, VehicleError> {
    if let Some(car) = cars.iter().find(|car| {
        car.profile
            .as_ref()
            .and_then(|profile| profile.vehicle_id.as_deref())
            == Some(vehicle_id)
    }) {
        return Ok(car);
    }
    match cars {
        [only] => Ok(only),
        _ => Err(VehicleError::VehicleNotFound),
    }
}

#[derive(Debug, Deserialize)]
struct NioJourneyResponse {
    result_code: String,
    server_time: Option<i64>,
    data: Option<NioJourneyData>,
    debug_msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NioJourneyData {
    #[serde(default)]
    detail: Vec<NioJourney>,
    #[serde(default)]
    has_more: bool,
}

#[derive(Debug, Deserialize)]
struct NioJourney {
    journey_id: String,
    trip_id: Option<String>,
    start_time: i64,
    end_time: i64,
    distance: f64,
    journey_duration_by_minutes: f64,
    start_location: Option<NioJourneyLocation>,
    end_location: Option<NioJourneyLocation>,
    avg_speed: Option<f64>,
    max_speed: Option<f64>,
    trip_odometer: Option<f64>,
    rapid_acceleration: Option<u32>,
    rapid_deceleration: Option<u32>,
    rapid_swerve: Option<u32>,
    #[serde(default)]
    is_comb: bool,
}

#[derive(Debug, Default, Deserialize)]
struct NioJourneyLocation {
    address: Option<String>,
    poi: Option<String>,
    road_name: Option<String>,
    town: Option<String>,
    district: Option<String>,
    city: Option<String>,
    province: Option<String>,
    poi_latitude: Option<f64>,
    poi_longitude: Option<f64>,
}

#[derive(Default)]
struct JourneyDetails {
    energy_kwh: Option<f64>,
    start_odo: Option<f64>,
    end_odo: Option<f64>,
    max_speed: Option<f64>,
    trip_odometer: Option<f64>,
    rapid_acceleration: Option<u32>,
    rapid_deceleration: Option<u32>,
    rapid_swerve: Option<u32>,
    track: Vec<VehicleTripTrackPoint>,
}

impl JourneyDetails {
    fn from_data(data: Option<&Value>) -> Self {
        let number = |key| {
            data.and_then(|data| data.get(key))
                .and_then(value_as_f64)
                .filter(|value| value.is_finite() && *value >= 0.0)
        };
        let count = |key| data.and_then(|data| data.get(key)).and_then(value_as_u32);
        Self {
            energy_kwh: number("trip_eng"),
            start_odo: number("start_odo"),
            end_odo: number("end_odo"),
            max_speed: number("max_speed"),
            trip_odometer: number("trip_odometer"),
            rapid_acceleration: count("rapid_acceleration"),
            rapid_deceleration: count("rapid_deceleration"),
            rapid_swerve: count("rapid_swerve"),
            track: track_points(data),
        }
    }
}

/// The journey detail `track` is a plain array of GPS samples. Points with
/// unusable coordinates or timestamps are dropped instead of being guessed, and
/// the remainder is ordered by sample time so the stored `seq` is chronological.
fn track_points(data: Option<&Value>) -> Vec<VehicleTripTrackPoint> {
    let items = data
        .and_then(|data| data.get("track"))
        .and_then(Value::as_array);
    let Some(items) = items else {
        return Vec::new();
    };
    let mut points = items
        .iter()
        .filter_map(|item| {
            let latitude = item.get("latitude").and_then(value_as_f64)?;
            let longitude = item.get("longitude").and_then(value_as_f64)?;
            if !valid_gps(latitude, longitude) {
                return None;
            }
            let sampled_at = timestamp_to_datetime(item.get("timestamp").and_then(value_as_i64)?)?;
            Some(VehicleTripTrackPoint {
                sampled_at,
                latitude,
                longitude,
                speed_kph: item
                    .get("speed")
                    .and_then(value_as_f64)
                    .filter(|value| value.is_finite() && *value >= 0.0),
                power_consumption: item
                    .get("power_consumption")
                    .and_then(value_as_f64)
                    .filter(|value| value.is_finite()),
                np_status: item.get("np_status").and_then(value_as_i64),
            })
        })
        .collect::<Vec<_>>();
    points.sort_by_key(|point| point.sampled_at);
    points
}

fn validate_track_size(data: Option<&Value>) -> Result<(), VehicleError> {
    if let Some(point_count) = data
        .and_then(|data| data.get("track"))
        .and_then(Value::as_array)
        .map(Vec::len)
        && point_count > MAX_TRACK_POINTS
    {
        return Err(VehicleError::TrackTooLarge(point_count));
    }
    Ok(())
}

fn trip_page_from_payload(payload: Value) -> Result<VehicleTripPage, VehicleError> {
    let response_shape = journey_response_shape(&payload);
    let response: NioJourneyResponse = serde_json::from_value(payload).map_err(|error| {
        tracing::warn!(
            %error,
            response_shape = %response_shape,
            "invalid NIO journey response shape"
        );
        VehicleError::InvalidJourneyPayload
    })?;
    if response.result_code != "success" {
        return Err(VehicleError::JourneyApi(
            response.debug_msg.unwrap_or(response.result_code),
        ));
    }
    let data = response.data.ok_or(VehicleError::InvalidJourneyPayload)?;
    let items = data
        .detail
        .into_iter()
        .map(|item| {
            let started_at = timestamp_to_datetime(item.start_time)
                .ok_or(VehicleError::InvalidJourneyPayload)?;
            let ended_at =
                timestamp_to_datetime(item.end_time).ok_or(VehicleError::InvalidJourneyPayload)?;
            let duration_minutes = if item.journey_duration_by_minutes.is_finite()
                && item.journey_duration_by_minutes >= 0.0
            {
                item.journey_duration_by_minutes
                    .round()
                    .min(u32::MAX as f64) as u32
            } else {
                return Err(VehicleError::InvalidJourneyPayload);
            };
            Ok(VehicleTrip {
                id: item.journey_id,
                trip_id: item.trip_id,
                started_at,
                ended_at,
                distance_kilometers: item.distance,
                duration_minutes,
                start_location: item.start_location.unwrap_or_default().into(),
                end_location: item.end_location.unwrap_or_default().into(),
                average_speed_kph: item.avg_speed,
                average_energy_consumption_kwh_per_100km: None,
                energy_consumed_kwh: None,
                maximum_speed_kph: item.max_speed,
                odometer_kilometers: item.trip_odometer,
                rapid_acceleration_count: item.rapid_acceleration,
                rapid_deceleration_count: item.rapid_deceleration,
                rapid_swerve_count: item.rapid_swerve,
                is_combined: item.is_comb,
            })
        })
        .collect::<Result<Vec<_>, VehicleError>>()?;
    let next_query_time = items.last().map(|item| item.started_at.timestamp());
    Ok(VehicleTripPage {
        items,
        has_more: data.has_more,
        next_query_time,
        server_time: response.server_time,
    })
}

fn journey_response_shape(payload: &Value) -> Value {
    const MAX_DETAIL_ITEMS: usize = 25;

    fn value_kind(value: &Value) -> &'static str {
        match value {
            Value::Null => "null",
            Value::Bool(_) => "boolean",
            Value::Number(_) => "number",
            Value::String(_) => "string",
            Value::Array(_) => "array",
            Value::Object(_) => "object",
        }
    }

    fn object_shape(value: &Value) -> Value {
        value.as_object().map_or(Value::Null, |object| {
            Value::Object(
                object
                    .iter()
                    .map(|(key, value)| (key.clone(), Value::String(value_kind(value).to_owned())))
                    .collect(),
            )
        })
    }

    let detail = payload
        .get("data")
        .and_then(|data| data.get("detail"))
        .and_then(Value::as_array);
    let detail_shapes = detail
        .into_iter()
        .flat_map(|items| items.iter())
        .take(MAX_DETAIL_ITEMS)
        .enumerate()
        .map(|(index, item)| {
            serde_json::json!({
                "index": index,
                "type": value_kind(item),
                "fields": object_shape(item),
            })
        })
        .collect::<Vec<_>>();
    let detail_count = detail.map_or(0, Vec::len);

    serde_json::json!({
        "top_level": object_shape(payload),
        "data": object_shape(payload.get("data").unwrap_or(&Value::Null)),
        "detail_count": detail_count,
        "detail_items": detail_shapes,
        "detail_truncated": detail_count > MAX_DETAIL_ITEMS,
    })
}

fn apply_journey_energy(trip: &mut VehicleTrip, energy_kwh: f64) {
    trip.energy_consumed_kwh = Some(energy_kwh);
    trip.average_energy_consumption_kwh_per_100km =
        (trip.distance_kilometers > 0.0).then(|| energy_kwh / trip.distance_kilometers * 100.0);
}

fn apply_journey_details(
    trip: &mut VehicleTrip,
    details: JourneyDetails,
) -> (bool, Vec<VehicleTripTrackPoint>) {
    // Preserve list values; only fill gaps from the detail response.
    trip.maximum_speed_kph = trip.maximum_speed_kph.or(details.max_speed);
    trip.odometer_kilometers = trip
        .odometer_kilometers
        .or(details.trip_odometer)
        .or(details.end_odo);
    // The list can report a provisional zero even when the detail has events.
    trip.rapid_acceleration_count = details.rapid_acceleration.or(trip.rapid_acceleration_count);
    trip.rapid_deceleration_count = details.rapid_deceleration.or(trip.rapid_deceleration_count);
    trip.rapid_swerve_count = details.rapid_swerve.or(trip.rapid_swerve_count);
    if let Some(distance) = precise_distance_from_odometers(
        trip.distance_kilometers,
        details.start_odo,
        details.end_odo,
    ) {
        trip.distance_kilometers = distance;
    }
    if let Some(energy_kwh) = details
        .energy_kwh
        .filter(|energy| energy.is_finite() && *energy >= 0.0)
    {
        apply_journey_energy(trip, energy_kwh);
        (true, details.track)
    } else {
        (false, details.track)
    }
}

fn precise_distance_from_odometers(
    listed_distance_km: f64,
    start_odo: Option<f64>,
    end_odo: Option<f64>,
) -> Option<f64> {
    // The journey list/detail `distance` is an integer km value. Detail odometers
    // retain decimals; use their difference only when it agrees with that integer.
    if !listed_distance_km.is_finite()
        || listed_distance_km < 0.0
        || listed_distance_km.fract() != 0.0
    {
        return None;
    }
    let start = start_odo?;
    let end = end_odo?;
    if !start.is_finite() || !end.is_finite() || start < 0.0 || end <= start {
        return None;
    }
    let distance = end - start;
    (distance.is_finite() && distance >= listed_distance_km && distance < listed_distance_km + 1.0)
        .then_some(distance)
}

impl From<NioJourneyLocation> for VehicleTripLocation {
    fn from(value: NioJourneyLocation) -> Self {
        Self {
            address: value.address,
            poi: value.poi,
            road_name: value.road_name,
            town: value.town,
            district: value.district,
            city: value.city,
            province: value.province,
            latitude: value.poi_latitude,
            longitude: value.poi_longitude,
        }
    }
}

pub fn snapshot_from_status(payload: &Value) -> Option<VehicleSnapshot> {
    let data = payload.get("data")?;
    let status = data.get("status").unwrap_or(data);
    let position = status.get("position_status")?;
    let latitude = value_as_f64(position.get("latitude")?)?;
    let longitude = value_as_f64(position.get("longitude")?)?;
    if !valid_gps(latitude, longitude) {
        return None;
    }

    let soc = status.get("soc_status");
    let exterior = status.get("exterior_status");
    let hvac = status.get("hvac_status");
    let timestamp = value_as_i64(position.get("sample_time")?)
        .or_else(|| soc.and_then(|value| value_as_i64(value.get("sample_time")?)))?;
    let sampled_at = timestamp_to_datetime(timestamp)?;
    let vehicle_id = status
        .get("vehicle_id")
        .or_else(|| data.get("vehicle_id"))?
        .as_str()?
        .to_owned();

    Some(VehicleSnapshot {
        vehicle_id,
        sampled_at,
        latitude,
        longitude,
        soc: soc
            .and_then(|value| value.get("soc"))
            .and_then(value_as_f64),
        remaining_range: soc
            .and_then(|value| value.get("remaining_range"))
            .and_then(value_as_f64),
        remaining_actual_range: soc
            .and_then(|value| value.get("remaining_actual_range"))
            .and_then(value_as_f64),
        mileage: exterior
            .and_then(|value| value.get("mileage"))
            .and_then(value_as_f64),
        inside_temperature: hvac
            .and_then(|value| value.get("temperature"))
            .and_then(value_as_f64),
        outside_temperature: hvac
            .and_then(|value| value.get("outside_temperature"))
            .and_then(value_as_f64),
    })
}

pub fn charging_sample_from_status(payload: &Value) -> Option<VehicleChargingSample> {
    let data = payload.get("data")?;
    let status = data.get("status").unwrap_or(data);
    let soc = status.get("soc_status")?;
    let vehicle_id = status
        .get("vehicle_id")
        .or_else(|| data.get("vehicle_id"))?
        .as_str()?
        .to_owned();
    let charge_state = soc.get("charge_state").and_then(value_as_i64)?;
    let sampled_at = timestamp_to_datetime(value_as_i64(soc.get("sample_time")?)?)?;
    Some(VehicleChargingSample {
        vehicle_id,
        sampled_at,
        soc: soc.get("soc").and_then(value_as_f64),
        charge_state,
        charging_current: soc.get("charging_current").and_then(value_as_f64),
        charging_power: soc.get("charging_power").and_then(value_as_f64),
        charging_voltage: soc.get("charging_voltage").and_then(value_as_f64),
    })
}

fn valid_gps(latitude: f64, longitude: f64) -> bool {
    latitude.is_finite()
        && longitude.is_finite()
        && latitude.abs() <= 90.0
        && longitude.abs() <= 180.0
        && !(latitude.abs() < 0.01 && longitude.abs() < 0.01)
}

fn value_as_f64(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
}

fn value_as_u32(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
}

fn value_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|value| i64::try_from(value).ok()))
        .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
}

fn timestamp_to_datetime(timestamp: i64) -> Option<DateTime<Utc>> {
    let millis = if timestamp.abs() < 10_000_000_000 {
        timestamp.checked_mul(1_000)?
    } else {
        timestamp
    };
    Utc.timestamp_millis_opt(millis).single()
}

pub fn swapping_state(payload: &Value) -> Option<bool> {
    let value = &payload["data"]["special_status"]["swapping"];
    value
        .as_bool()
        .or_else(|| value.as_i64().map(|value| value != 0))
        .or_else(|| {
            value
                .as_str()
                .map(|value| matches!(value.to_ascii_lowercase().as_str(), "true" | "1" | "yes"))
        })
}

pub fn vehicle_locked(payload: &Value) -> Option<bool> {
    let data = payload.get("data")?;
    let status = data.get("status").unwrap_or(data);
    match status
        .get("door_status")?
        .get("vehicle_lock_status")?
        .as_i64()?
    {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

pub fn charging_state(payload: &Value) -> Option<bool> {
    let data = payload.get("data")?;
    let status = data.get("status").unwrap_or(data);
    value_as_i64(status.get("soc_status")?.get("charge_state")?).map(|state| state == 1)
}

pub(crate) fn sign_url(mut url: Url, bearer_token: &str, timestamp: i64) -> Url {
    let mut pairs = url
        .query_pairs()
        .filter(|(name, _)| {
            !name.eq_ignore_ascii_case("sign") && !name.eq_ignore_ascii_case("timestamp")
        })
        .map(|(name, value)| (name.into_owned(), value.into_owned()))
        .collect::<Vec<_>>();
    pairs.push(("timestamp".to_owned(), timestamp.to_string()));

    let mut canonical_pairs = pairs.clone();
    canonical_pairs.sort_by(|left, right| left.0.cmp(&right.0).then(left.1.cmp(&right.1)));
    let canonical_query = canonical_pairs
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("&");
    let sign_text = format!(
        "GET{}?{}{}Bearer {}",
        url.path(),
        canonical_query,
        SIGNING_SALT,
        bearer_token
    );
    let sign = format!("{:x}", Md5::digest(sign_text.as_bytes()));

    url.query_pairs_mut()
        .clear()
        .extend_pairs(&pairs)
        .append_pair("sign", &sign);
    url
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signing_sorts_repeated_query_values() {
        let mut url = Url::parse("https://icar.nio.com/example").unwrap();
        url.query_pairs_mut()
            .append_pair("field", "special")
            .append_pair("field", "connection")
            .append_pair("region", "cn");
        let signed = sign_url(url, "test-token", 1_700_000_000);
        let sign = signed
            .query_pairs()
            .find(|(name, _)| name == "sign")
            .unwrap()
            .1
            .into_owned();
        assert_eq!(sign, "3e94fd040a5542f97f713fdba331960c");
    }

    #[test]
    fn parses_numeric_and_boolean_swapping_states() {
        assert_eq!(
            swapping_state(&serde_json::json!({"data":{"special_status":{"swapping":1}}})),
            Some(true)
        );
        assert_eq!(
            swapping_state(&serde_json::json!({"data":{"special_status":{"swapping":false}}})),
            Some(false)
        );
        assert_eq!(swapping_state(&serde_json::json!({"data":{}})), None);
    }

    #[test]
    fn parses_vehicle_lock_state_from_rvs_status() {
        assert_eq!(
            vehicle_locked(&serde_json::json!({"data":{"door_status":{"vehicle_lock_status":0}}})),
            Some(false)
        );
        assert_eq!(
            vehicle_locked(&serde_json::json!({"data":{"door_status":{"vehicle_lock_status":1}}})),
            Some(true)
        );
        assert_eq!(
            vehicle_locked(&serde_json::json!({"data":{"door_status":{"vehicle_lock_status":2}}})),
            None
        );
        assert_eq!(vehicle_locked(&serde_json::json!({"data":{}})), None);
    }

    #[test]
    fn parses_flat_rvs_vehicle_snapshot_and_rejects_zero_gps() {
        let payload = serde_json::json!({
            "data": {
                "vehicle_id": "vehicle-1",
                "position_status": {"latitude": 31.2304, "longitude": 121.4737, "sample_time": 1_700_000_000_000_i64},
                "soc_status": {
                    "soc": 82,
                    "remaining_range": 410.5,
                    "remaining_actual_range": 365,
                    "charge_state": 1,
                    "charging_current": 32.5,
                    "charging_power": 11800,
                    "charging_voltage": 358,
                    "sample_time": 1_700_000_001_000_i64
                },
                "exterior_status": {"mileage": 12345.6},
                "hvac_status": {"temperature": 24, "outside_temperature": 18.5}
            }
        });
        let snapshot = snapshot_from_status(&payload).unwrap();
        assert_eq!(snapshot.vehicle_id, "vehicle-1");
        assert_eq!(snapshot.soc, Some(82.0));
        assert_eq!(snapshot.remaining_actual_range, Some(365.0));
        assert_eq!(snapshot.sampled_at.timestamp(), 1_700_000_000);
        assert_eq!(snapshot.latitude, 31.2304);

        let charging = charging_sample_from_status(&payload).unwrap();
        assert_eq!(charging.charge_state, 1);
        assert_eq!(charging.soc, Some(82.0));
        assert_eq!(charging.charging_current, Some(32.5));
        assert_eq!(charging.charging_power, Some(11_800.0));
        assert_eq!(charging.charging_voltage, Some(358.0));
        assert_eq!(charging.sampled_at.timestamp(), 1_700_000_001);

        let invalid = serde_json::json!({
            "data": {"vehicle_id": "vehicle-1", "position_status": {"latitude": 0, "longitude": 0, "sample_time": 1_700_000_000}}
        });
        assert!(snapshot_from_status(&invalid).is_none());
    }

    #[test]
    fn normalizes_dedicated_journey_payload() {
        let page = trip_page_from_payload(serde_json::json!({
            "result_code": "success",
            "server_time": 1_700_000_500,
            "data": {
                "has_more": true,
                "note_sum": 0,
                "detail": [{
                    "journey_id": "journey-1",
                    "trip_id": "trip-1",
                    "start_time": 1_700_000_000,
                    "end_time": 1_700_000_600,
                    "distance": 5,
                    "journey_duration_by_minutes": 10,
                    "avg_speed": 30,
                    "max_speed": 52,
                    "trip_odometer": 1234.5,
                    "rapid_acceleration": 1,
                    "rapid_deceleration": 2,
                    "rapid_swerve": 0,
                    "is_comb": false,
                    "start_location": {"address": "起点", "poi": "A", "poi_latitude": 31.2, "poi_longitude": 121.4},
                    "end_location": {"address": "终点", "poi": "B", "poi_latitude": 31.3, "poi_longitude": 121.5}
                }]
            }
        }))
        .unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].distance_kilometers, 5.0);
        assert_eq!(page.items[0].duration_minutes, 10);
        assert_eq!(page.items[0].average_energy_consumption_kwh_per_100km, None);
        assert_eq!(page.items[0].energy_consumed_kwh, None);
        assert_eq!(page.items[0].start_location.poi.as_deref(), Some("A"));
        let item = serde_json::to_value(&page.items[0]).unwrap();
        assert_eq!(item["maximum_speed_kph"], 52.0);
        assert_eq!(item["odometer_kilometers"], 1234.5);
        assert_eq!(item["rapid_acceleration_count"], 1);
        assert_eq!(item["rapid_deceleration_count"], 2);
        assert_eq!(item["rapid_swerve_count"], 0);
        assert_eq!(page.next_query_time, Some(1_700_000_000));
        assert!(page.has_more);
    }

    #[test]
    fn ongoing_journey_without_locations_does_not_fail_the_page() {
        let page = trip_page_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {
                "has_more": false,
                "detail": [
                    {
                        "journey_id": "ongoing",
                        "start_time": 1_700_000_000,
                        "end_time": 1_700_000_600,
                        "distance": 5.0,
                        "journey_duration_by_minutes": 10.0
                    },
                    {
                        "journey_id": "completed",
                        "start_time": 1_699_999_000,
                        "end_time": 1_699_999_600,
                        "distance": 8.0,
                        "journey_duration_by_minutes": 10.0,
                        "start_location": {"poi": "起点"},
                        "end_location": {"poi": "终点"}
                    }
                ]
            }
        }))
        .unwrap();

        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].id, "ongoing");
        assert_eq!(page.items[0].start_location.poi, None);
        assert_eq!(page.items[0].end_location.poi, None);
        assert_eq!(page.items[0].energy_consumed_kwh, None);
        let item = serde_json::to_value(&page.items[0]).unwrap();
        for field in [
            "maximum_speed_kph",
            "odometer_kilometers",
            "rapid_acceleration_count",
            "rapid_deceleration_count",
            "rapid_swerve_count",
        ] {
            assert!(item.get(field).unwrap().is_null());
        }
        assert_eq!(page.items[1].end_location.poi.as_deref(), Some("终点"));
        assert_eq!(page.next_query_time, Some(1_699_999_000));
    }

    #[test]
    fn ongoing_journey_with_null_locations_is_also_supported() {
        let page = trip_page_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {
                "detail": [{
                    "journey_id": "ongoing",
                    "start_time": 1_700_000_000,
                    "end_time": 1_700_000_600,
                    "distance": 5.0,
                    "journey_duration_by_minutes": 10.0,
                    "start_location": null,
                    "end_location": null
                }]
            }
        }))
        .unwrap();

        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].start_location.address, None);
        assert_eq!(page.items[0].end_location.address, None);
    }

    #[test]
    fn journey_error_shape_reports_null_fields_without_logging_values() {
        let payload = serde_json::json!({
            "result_code": "success",
            "data": {
                "has_more": false,
                "detail": [{
                    "journey_id": "sensitive-journey-id",
                    "start_location": {"address": "sensitive-start-address"},
                    "end_location": null,
                    "distance": 12.5
                }]
            }
        });

        let shape = journey_response_shape(&payload);
        assert_eq!(shape["detail_count"], 1);
        assert_eq!(shape["detail_items"][0]["fields"]["journey_id"], "string");
        assert_eq!(
            shape["detail_items"][0]["fields"]["start_location"],
            "object"
        );
        assert_eq!(shape["detail_items"][0]["fields"]["end_location"], "null");
        assert_eq!(shape["detail_items"][0]["fields"]["distance"], "number");
        let serialized = shape.to_string();
        assert!(!serialized.contains("sensitive-journey-id"));
        assert!(!serialized.contains("sensitive-start-address"));
    }

    #[test]
    fn applies_journey_detail_energy_and_calculates_average() {
        let mut trip = trip_page_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {
                "detail": [{
                    "journey_id": "journey-1",
                    "start_time": 1_700_000_000,
                    "end_time": 1_700_001_200,
                    "distance": 20,
                    "journey_duration_by_minutes": 20,
                    "start_location": {},
                    "end_location": {}
                }]
            }
        }))
        .unwrap()
        .items
        .remove(0);

        apply_journey_energy(&mut trip, 3.36);

        assert_eq!(trip.energy_consumed_kwh, Some(3.36));
        let average = trip
            .average_energy_consumption_kwh_per_100km
            .expect("positive-distance trip should have an average");
        assert!((average - 16.8).abs() < 1e-12);
    }

    #[test]
    fn switch_cars_parses_the_image_and_picks_the_configured_vehicle() {
        let cars = switch_cars_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {"cars": [
                {"display_name": "我的ET5T", "model_type": "ET5T",
                 "image": "https://cdn-app.nio.com/a.png",
                 "vehicle_profile": {"vehicle_id": "v1", "color": "tech_grey", "nick_name": "昵称"}},
                {"display_name": "另一辆", "model_type": "ES6",
                 "image": "https://cdn-app.nio.com/b.png",
                 "vehicle_profile": {"vehicle_id": "v2", "color": "black"}}
            ]}
        }))
        .unwrap();
        assert_eq!(cars.len(), 2);
        let car = select_car(&cars, "v2").unwrap();
        assert_eq!(car.model_type.as_deref(), Some("ES6"));
        assert_eq!(car.image.as_deref(), Some("https://cdn-app.nio.com/b.png"));
        // An account with several cars must never be guessed.
        assert!(select_car(&cars, "v3").is_err());
        assert_eq!(
            cars[0].profile.as_ref().unwrap().color.as_deref(),
            Some("tech_grey")
        );
    }

    #[test]
    fn the_cached_image_is_reused_only_while_the_url_is_unchanged() {
        let cached = StoredVehicleProfile {
            vehicle_id: "v1".to_owned(),
            display_name: None,
            model_type: None,
            color: None,
            image_url: Some("https://cdn/a.png".to_owned()),
            image_available: true,
            image_sha256: Some("sha".to_owned()),
            image_fetched_at: None,
        };
        assert!(reuse_cached_image(Some(&cached), Some("https://cdn/a.png")));
        // A new URL means new bytes.
        assert!(!reuse_cached_image(
            Some(&cached),
            Some("https://cdn/b.png")
        ));
        // No bytes stored yet, so a failed earlier download is retried.
        let empty = StoredVehicleProfile {
            image_available: false,
            ..cached.clone()
        };
        assert!(!reuse_cached_image(Some(&empty), Some("https://cdn/a.png")));
        assert!(!reuse_cached_image(None, Some("https://cdn/a.png")));
        // Upstream no longer reports an image; there is nothing to keep.
        assert!(!reuse_cached_image(Some(&cached), None));
    }

    #[test]
    fn single_car_account_is_selected_without_a_matching_id() {
        let cars = switch_cars_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {"cars": [{"image": "https://cdn-app.nio.com/only.png"}]}
        }))
        .unwrap();
        assert_eq!(
            select_car(&cars, "whatever").unwrap().image.as_deref(),
            Some("https://cdn-app.nio.com/only.png")
        );
    }

    #[test]
    fn switch_cars_reports_an_upstream_failure_instead_of_an_empty_list() {
        let error = switch_cars_from_payload(serde_json::json!({
            "result_code": "failed",
            "debug_msg": "token expired"
        }));
        assert!(
            matches!(error, Err(VehicleError::JourneyApi(message)) if message == "token expired")
        );
    }

    #[test]
    fn journey_detail_track_keeps_valid_points_in_time_order() {
        let details = JourneyDetails::from_data(Some(&serde_json::json!({
            "trip_eng": 4.2,
            "track": [
                {"longitude": 117.766, "latitude": 39.123, "timestamp": 1794288480,
                 "speed": 12.5, "power_consumption": 3, "np_status": 0},
                {"longitude": 117.760, "latitude": 39.120, "timestamp": 1794288460,
                 "speed": 0.0, "power_consumption": -2, "np_status": 1},
                {"longitude": 0.0, "latitude": 0.0, "timestamp": 1794288470, "speed": 1.0},
                {"longitude": 117.75, "latitude": 39.11}
            ]
        })));
        assert_eq!(details.energy_kwh, Some(4.2));
        // Null-island and timestamp-less samples are dropped, not guessed.
        assert_eq!(details.track.len(), 2);
        assert_eq!(details.track[0].sampled_at.timestamp(), 1794288460);
        assert_eq!(details.track[1].sampled_at.timestamp(), 1794288480);
        assert_eq!(details.track[0].power_consumption, Some(-2.0));
        assert_eq!(details.track[1].speed_kph, Some(12.5));
        assert_eq!(details.track[1].np_status, Some(0));
    }

    #[test]
    fn journey_detail_without_track_produces_no_points() {
        let details = JourneyDetails::from_data(Some(&serde_json::json!({"trip_eng": 1.0})));
        assert!(details.track.is_empty());
        assert!(JourneyDetails::from_data(None).track.is_empty());
    }

    #[test]
    fn oversized_journey_track_is_rejected_instead_of_truncated() {
        let points = (0..=MAX_TRACK_POINTS)
            .map(|index| {
                serde_json::json!({
                    "longitude": 117.0,
                    "latitude": 39.0,
                    "timestamp": 1_700_000_000_i64 + index as i64
                })
            })
            .collect::<Vec<_>>();
        let data = serde_json::json!({"track": points});
        assert!(matches!(
            validate_track_size(Some(&data)),
            Err(VehicleError::TrackTooLarge(count)) if count == MAX_TRACK_POINTS + 1
        ));
    }

    #[test]
    fn detail_odometers_restore_short_trip_decimals_without_guessing() {
        let short = precise_distance_from_odometers(0.0, Some(12_345.1), Some(12_346.0))
            .expect("consistent odometers should restore a short trip");
        assert!((short - 0.9).abs() < 1e-9);
        let longer = precise_distance_from_odometers(19.0, Some(12_300.0), Some(12_319.9))
            .expect("consistent odometers should retain decimals");
        assert!((longer - 19.9).abs() < 1e-9);

        assert_eq!(
            precise_distance_from_odometers(0.0, None, Some(12_346.0)),
            None
        );
        assert_eq!(
            precise_distance_from_odometers(0.0, Some(12_346.0), Some(12_345.1)),
            None
        );
        assert_eq!(
            precise_distance_from_odometers(0.0, Some(12_345.0), Some(12_346.3)),
            None
        );
        assert_eq!(
            precise_distance_from_odometers(0.5, Some(12_345.0), Some(12_345.8)),
            None
        );
        assert_eq!(
            precise_distance_from_odometers(0.0, Some(f64::NAN), Some(12_345.8)),
            None
        );
    }

    #[test]
    fn applies_precise_short_trip_distance_before_energy_average() {
        let mut trip = trip_page_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {"detail": [{
                "journey_id": "short-trip",
                "start_time": 1_700_000_000,
                "end_time": 1_700_000_600,
                "distance": 0,
                "journey_duration_by_minutes": 10
            }]}
        }))
        .unwrap()
        .items
        .remove(0);

        assert!(
            apply_journey_details(
                &mut trip,
                JourneyDetails {
                    energy_kwh: Some(0.18),
                    start_odo: Some(12_345.1),
                    end_odo: Some(12_346.0),
                    ..Default::default()
                }
            )
            .0
        );
        assert!((trip.distance_kilometers - 0.9).abs() < 1e-9);
        assert_eq!(trip.energy_consumed_kwh, Some(0.18));
        assert!((trip.average_energy_consumption_kwh_per_100km.unwrap() - 20.0).abs() < 1e-9);
    }

    #[test]
    fn journey_detail_overrides_provisional_list_event_counts() {
        let mut trip = trip_page_from_payload(serde_json::json!({
            "result_code": "success",
            "data": {"detail": [{
                "journey_id": "journey-1",
                "start_time": 1_700_000_000,
                "end_time": 1_700_000_600,
                "distance": 5,
                "journey_duration_by_minutes": 10,
                "max_speed": 52,
                "rapid_acceleration": 0
            }]}
        }))
        .unwrap()
        .items
        .remove(0);
        let data = serde_json::json!({
            "max_speed": 80,
            "end_odo": "1234.5",
            "rapid_acceleration": 3,
            "rapid_deceleration": "2",
            "rapid_swerve": 0
        });

        assert!(!apply_journey_details(&mut trip, JourneyDetails::from_data(Some(&data))).0);
        let item = serde_json::to_value(&trip).unwrap();
        assert_eq!(item["maximum_speed_kph"], 52.0);
        assert_eq!(item["odometer_kilometers"], 1234.5);
        assert_eq!(item["rapid_acceleration_count"], 3);
        assert_eq!(item["rapid_deceleration_count"], 2);
        assert_eq!(item["rapid_swerve_count"], 0);
    }

    #[test]
    fn journey_detail_rejects_invalid_metrics_and_prefers_explicit_odometer() {
        let data = serde_json::json!({
            "max_speed": "NaN",
            "trip_odometer": 1234.5,
            "end_odo": 1235.0,
            "rapid_acceleration": -1,
            "rapid_deceleration": 4294967296_u64,
            "rapid_swerve": "not a count"
        });
        let details = JourneyDetails::from_data(Some(&data));
        assert_eq!(details.max_speed, None);
        assert_eq!(details.trip_odometer.or(details.end_odo), Some(1234.5));
        assert_eq!(details.rapid_acceleration, None);
        assert_eq!(details.rapid_deceleration, None);
        assert_eq!(details.rapid_swerve, None);
    }
}
