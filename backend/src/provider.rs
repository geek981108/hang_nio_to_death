use std::collections::HashMap;

use aes::Aes128;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use chrono::{DateTime, NaiveDate, Utc};
use md5::{Digest, Md5};
use reqwest::{
    Client,
    header::{HeaderMap, HeaderName, HeaderValue},
};
use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;
use url::Url;

use crate::{
    config::StationConfig,
    models::{
        BatteryObservation, StationBatteryReadiness, StationFeeItem, StationFeePeriod,
        StationLiveQueue, StationQueueStatus, StationSnapshot,
    },
};

type Aes128CbcDec = cbc::Decryptor<Aes128>;

const SUPPORTED_HOST: &str = "app.nio.com";
const SUPPORTED_PATH_PREFIX: &str = "/nio/app/bff/map/resources/v1/swap/";
const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
// Protocol constants used by the upstream encrypted response, not account credentials.
const RESPONSE_KEY: &[u8; 16] = b"kc1$[41_fpqxeg70";
const RESPONSE_IV: &[u8; 16] = b"g3QNdti5qCEoFVCj";

#[derive(Clone)]
pub struct NioStationProvider {
    client: Client,
    config: StationConfig,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StationCoordinates {
    pub latitude: f64,
    pub longitude: f64,
}

pub struct StationLiveDetails {
    pub captured_at: DateTime<Utc>,
    pub current_fees: Vec<StationFeeItem>,
    pub fee_periods: Vec<StationFeePeriod>,
    pub fee_notices: Vec<String>,
    pub fee_timezone: Option<String>,
    pub queue: StationLiveQueue,
    pub battery_readiness: Vec<StationBatteryReadiness>,
}

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("invalid station URL: {0}")]
    InvalidUrl(String),
    #[error("station endpoint must use HTTPS")]
    InsecureUrl,
    #[error("supported NIO endpoint requires a valid Authorization: Bearer header")]
    MissingAuthorization,
    #[error("invalid request header {name}: {message}")]
    InvalidHeader { name: String, message: String },
    #[error("station request failed: {0}")]
    Request(#[source] reqwest::Error),
    #[error("station returned HTTP {0}")]
    HttpStatus(reqwest::StatusCode),
    #[error("station response envelope is invalid: {0}")]
    InvalidEnvelope(String),
    #[error("station response cannot be decrypted")]
    Decryption,
    #[error("decrypted station payload is invalid: {0}")]
    InvalidPayload(String),
}

#[derive(Deserialize)]
struct EncryptedEnvelope {
    data: String,
}

impl From<reqwest::Error> for ProviderError {
    fn from(error: reqwest::Error) -> Self {
        // URLs may contain signed query parameters or custom credentials.
        // Keep the diagnostic source while excluding URLs from logs/errors.
        Self::Request(error.without_url())
    }
}

impl NioStationProvider {
    pub fn new(config: StationConfig) -> Result<Self, ProviderError> {
        let mut default_headers = HeaderMap::new();
        for (name, value) in &config.headers {
            let header_name = name.parse::<HeaderName>().map_err(
                |error: reqwest::header::InvalidHeaderName| ProviderError::InvalidHeader {
                    name: name.clone(),
                    message: error.to_string(),
                },
            )?;
            let header_value = value.parse::<HeaderValue>().map_err(
                |error: reqwest::header::InvalidHeaderValue| ProviderError::InvalidHeader {
                    name: name.clone(),
                    message: error.to_string(),
                },
            )?;
            default_headers.insert(header_name, header_value);
        }
        let client = Client::builder()
            .default_headers(default_headers)
            .timeout(std::time::Duration::from_secs(20))
            .user_agent("nio-swap-history-backend/0.1")
            .build()?;
        Ok(Self { client, config })
    }

    pub fn station_key(&self) -> &str {
        &self.config.key
    }

    pub fn station_name(&self) -> &str {
        &self.config.name
    }

    /// Reuse the HTTP connection pool for a station selected from the same
    /// credential template. No response is cached; each fetch still signs a
    /// fresh request and obtains current inventory and fees.
    pub fn retarget(&self, key: String, name: String, url: String) -> Self {
        Self {
            client: self.client.clone(),
            config: StationConfig {
                key,
                name,
                url,
                headers: self.config.headers.clone(),
            },
        }
    }

    pub async fn fetch(&self) -> Result<StationSnapshot, ProviderError> {
        let payload = self.fetch_payload().await?;

        Ok(StationSnapshot {
            station_key: self.config.key.clone(),
            station_name: self.config.name.clone(),
            address: parse_address(&payload),
            captured_at: Utc::now(),
            batteries: parse_batteries(&payload),
            current_fees: parse_current_fees(&payload),
        })
    }

    /// A single read-only station request for current and future fee periods,
    /// queue observations, and upstream battery charging estimates.
    pub async fn fetch_live_details(&self) -> Result<StationLiveDetails, ProviderError> {
        let payload = self.fetch_payload().await?;
        Ok(parse_live_details(&payload, Utc::now()))
    }

    pub async fn fetch_coordinates(&self) -> Result<StationCoordinates, ProviderError> {
        let payload = self.fetch_payload().await?;
        parse_coordinates(&payload)
    }

    /// One station fetch that yields both the geographic anchor and the short
    /// address/POI name used to fill the station directory.
    pub async fn fetch_identity(
        &self,
    ) -> Result<(StationCoordinates, Option<String>), ProviderError> {
        let payload = self.fetch_payload().await?;
        Ok((parse_coordinates(&payload)?, parse_address(&payload)))
    }

    pub async fn fetch_queue_status(
        &self,
        target_battery_cap_level: Option<u32>,
    ) -> Result<StationQueueStatus, ProviderError> {
        let payload = self.fetch_payload().await?;
        Ok(parse_queue_status(&payload, target_battery_cap_level))
    }

    async fn fetch_payload(&self) -> Result<Value, ProviderError> {
        let url = signed_url_if_supported(
            &self.config.url,
            &self.config.headers,
            Utc::now().timestamp(),
        )?;
        let response = self.client.get(url).send().await?;
        let status = response.status();
        if !status.is_success() {
            return Err(ProviderError::HttpStatus(status));
        }
        let envelope = response
            .json::<EncryptedEnvelope>()
            .await
            .map_err(|error| ProviderError::InvalidEnvelope(error.to_string()))?;
        let decrypted = decrypt_payload(&envelope.data)?;
        let payload: Value = serde_json::from_slice(&decrypted)
            .map_err(|error| ProviderError::InvalidPayload(error.to_string()))?;

        Ok(payload)
    }
}

fn parse_queue_status(
    payload: &Value,
    target_battery_cap_level: Option<u32>,
) -> StationQueueStatus {
    let matching_group = target_battery_cap_level.and_then(|target| {
        payload
            .pointer("/battery/battery_cap_level_sort_list")
            .and_then(Value::as_array)
            .and_then(|groups| {
                groups
                    .iter()
                    .find(|group| u32_value(&group["battery_cap_level"]) == Some(target))
            })
    });
    let source = matching_group.unwrap_or(payload);
    StationQueueStatus {
        vehicles_ahead: u32_value(&source["wait_in_line"])
            .or_else(|| u32_value(&payload["wait_in_line"])),
        waiting_description: string_value(&source["waiting_desc"])
            .or_else(|| string_value(&payload["wait_in_line_desc"])),
        navigation_count: u32_value(&source["nav_count"])
            .or_else(|| u32_value(&payload["nav_count"])),
    }
}

fn parse_address(payload: &Value) -> Option<String> {
    string_value(&payload["address"])
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn parse_coordinates(payload: &Value) -> Result<StationCoordinates, ProviderError> {
    let location = payload
        .get("location")
        .and_then(Value::as_str)
        .ok_or_else(|| ProviderError::InvalidPayload("missing station location".to_owned()))?;
    let (longitude, latitude) = location
        .split_once(',')
        .ok_or_else(|| ProviderError::InvalidPayload("invalid station location".to_owned()))?;
    let longitude = longitude
        .trim()
        .parse::<f64>()
        .map_err(|_| ProviderError::InvalidPayload("invalid station longitude".to_owned()))?;
    let latitude = latitude
        .trim()
        .parse::<f64>()
        .map_err(|_| ProviderError::InvalidPayload("invalid station latitude".to_owned()))?;
    if !longitude.is_finite()
        || !latitude.is_finite()
        || !(-180.0..=180.0).contains(&longitude)
        || !(-90.0..=90.0).contains(&latitude)
    {
        return Err(ProviderError::InvalidPayload(
            "station location is out of range".to_owned(),
        ));
    }
    Ok(StationCoordinates {
        latitude,
        longitude,
    })
}

fn parse_fee_item(value: &Value) -> Option<StationFeeItem> {
    let name = string_value(&value["name"])?;
    let normalized_name = name.trim().replace(' ', "").to_ascii_lowercase();
    let fee = string_value(&value["fee"])?;
    Some(StationFeeItem {
        fee_type: string_value(&value["type"]),
        is_total: value["type"]
            .as_str()
            .is_some_and(|value| value.to_ascii_lowercase().contains("total_fee"))
            || matches!(
                normalized_name.as_str(),
                "合计" | "总计" | "总费用" | "total" | "totalfee"
            ),
        name,
        fee,
        unit: string_value(&value["unit"]).unwrap_or_default(),
        currency: string_value(&value["currency"]).unwrap_or_else(|| "¥".to_owned()),
    })
}

fn parse_current_fees(payload: &Value) -> Vec<StationFeeItem> {
    payload["fee_info"]["current_fee"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(parse_fee_item)
        .collect()
}

fn parse_live_details(payload: &Value, captured_at: DateTime<Utc>) -> StationLiveDetails {
    let fee_info = &payload["fee_info"];
    let fee_periods = fee_info["detail"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|period| {
            let time_period = string_value(&period["time_period"])?;
            if time_period.trim().is_empty() {
                return None;
            }
            let fees = period["fee"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(parse_fee_item)
                .collect::<Vec<_>>();
            (!fees.is_empty()).then_some(StationFeePeriod { time_period, fees })
        })
        .collect();
    let fee_notices = fee_info["fee_special_desc_array"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect();
    let upstream_queue = parse_queue_status(payload, None);
    StationLiveDetails {
        captured_at,
        current_fees: parse_current_fees(payload),
        fee_periods,
        fee_notices,
        fee_timezone: string_value(&fee_info["timezone"])
            .or_else(|| string_value(&fee_info["time_zone"])),
        queue: StationLiveQueue {
            vehicles_ahead: upstream_queue.vehicles_ahead,
            waiting_description: upstream_queue.waiting_description,
            navigation_count: upstream_queue.navigation_count,
            // This station detail payload has no verified wait-duration or
            // upstream update timestamp field. Active orders expose their own.
            estimated_wait_minutes: None,
            upstream_updated_at: None,
            observed_at: captured_at,
        },
        battery_readiness: parse_battery_readiness(payload, captured_at),
    }
}

fn signed_url_if_supported(
    raw_url: &str,
    headers: &HashMap<String, String>,
    timestamp: i64,
) -> Result<Url, ProviderError> {
    let mut url =
        Url::parse(raw_url).map_err(|error| ProviderError::InvalidUrl(error.to_string()))?;
    if url.scheme() != "https" {
        return Err(ProviderError::InsecureUrl);
    }
    if url.host_str().map(str::to_ascii_lowercase).as_deref() != Some(SUPPORTED_HOST)
        || !url.path().starts_with(SUPPORTED_PATH_PREFIX)
    {
        return Ok(url);
    }

    let authorization = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("authorization"))
        .map(|(_, value)| value.trim())
        .ok_or(ProviderError::MissingAuthorization)?;
    let mut auth_parts = authorization.splitn(2, char::is_whitespace);
    let scheme = auth_parts.next().unwrap_or_default();
    let token = auth_parts
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(ProviderError::MissingAuthorization)?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return Err(ProviderError::MissingAuthorization);
    }
    let normalized_authorization = format!("Bearer {token}");

    let mut pairs: Vec<(usize, String, String)> = url
        .query_pairs()
        .enumerate()
        .filter(|(_, (name, _))| {
            !name.eq_ignore_ascii_case("sign") && !name.eq_ignore_ascii_case("timestamp")
        })
        .map(|(index, (name, value))| (index, name.into_owned(), value.into_owned()))
        .collect();
    let next_index = pairs.len();
    pairs.push((next_index, "timestamp".to_owned(), timestamp.to_string()));

    let mut canonical_pairs = pairs.clone();
    canonical_pairs.sort_by(|left, right| {
        left.1
            .cmp(&right.1)
            .then(left.2.cmp(&right.2))
            .then(left.0.cmp(&right.0))
    });
    let canonical_query = canonical_pairs
        .iter()
        .map(|(_, name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("&");
    let sign_text = format!(
        "GET{}?{}{}{}",
        url.path(),
        canonical_query,
        SIGNING_SALT,
        normalized_authorization
    );
    let sign = format!("{:x}", Md5::digest(sign_text.as_bytes()));

    url.query_pairs_mut()
        .clear()
        .extend_pairs(pairs.iter().map(|(_, name, value)| (name, value)))
        .append_pair("sign", &sign);
    Ok(url)
}

pub(crate) fn decrypt_payload(ciphertext_base64: &str) -> Result<Vec<u8>, ProviderError> {
    let ciphertext = BASE64
        .decode(ciphertext_base64)
        .map_err(|_| ProviderError::Decryption)?;
    Aes128CbcDec::new(RESPONSE_KEY.into(), RESPONSE_IV.into())
        .decrypt_padded_vec_mut::<Pkcs7>(&ciphertext)
        .map_err(|_| ProviderError::Decryption)
}

fn battery_values(payload: &Value) -> Vec<&Value> {
    let battery = &payload["battery"];
    if let Some(groups) = battery["battery_cap_level_sort_list"].as_array() {
        groups
            .iter()
            .filter_map(|group| group["battery_list"].as_array())
            .flat_map(|items| items.iter())
            .collect()
    } else {
        battery["battery_list"]
            .as_array()
            .map(|items| items.iter().collect())
            .unwrap_or_default()
    }
}

fn parse_batteries(payload: &Value) -> Vec<BatteryObservation> {
    let mut batteries = battery_values(payload)
        .into_iter()
        .filter_map(|value| {
            let battery_id = string_value(&value["battery_id"])?;
            if battery_id.is_empty() {
                return None;
            }
            let description =
                string_value(&value["lower_case_desc"]).map(|value| value.replace(['(', ')'], ""));
            let capacity_kwh = capacity_from_value(value, &battery_id, description.as_deref());
            Some(BatteryObservation {
                production_date: production_date_from_id(&battery_id),
                battery_id,
                slot_id: i64_value(&value["slot_id"]),
                battery_type: description,
                capacity_kwh,
                soc_percent: f64_value(&value["progress"]).map(|value| value.clamp(0.0, 100.0)),
                occupied: bool_value(&value["battery_occupied"]).unwrap_or(false),
            })
        })
        .collect::<Vec<_>>();
    batteries.sort_by_key(|battery| battery.slot_id.unwrap_or(i64::MAX));
    batteries
}

fn parse_battery_readiness(
    payload: &Value,
    captured_at: DateTime<Utc>,
) -> Vec<StationBatteryReadiness> {
    let mut batteries = battery_values(payload)
        .into_iter()
        .map(|value| {
            let description =
                string_value(&value["charging_time_desc"]).filter(|value| !value.trim().is_empty());
            // The upstream field is documented in the App as minutes. Only
            // numeric representations are converted; prose remains raw text.
            let minutes = value["charging_time_desc"]
                .as_u64()
                .and_then(|value| u32::try_from(value).ok())
                .or_else(|| {
                    value["charging_time_desc"]
                        .as_str()
                        .and_then(|value| value.trim().parse::<u32>().ok())
                })
                .filter(|value| (1..=1440).contains(value));
            StationBatteryReadiness {
                slot_id: i64_value(&value["slot_id"]),
                battery_cap_series: i64_value(&value["battery_cap_series"]),
                capacity_kwh: capacity_from_value(
                    value,
                    &string_value(&value["battery_id"]).unwrap_or_default(),
                    value["lower_case_desc"].as_str(),
                ),
                progress_percent: f64_value(&value["progress"])
                    .filter(|value| value.is_finite() && (0.0..=100.0).contains(value)),
                battery_occupied: bool_value(&value["battery_occupied"]),
                charging_time_description: description,
                charging_remaining_minutes: minutes,
                estimated_charge_complete_at: minutes
                    .map(|minutes| captured_at + chrono::Duration::minutes(i64::from(minutes))),
                battery_id: Some(&value["battery_id"])
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                production_date: production_date_from_id(
                    &string_value(&value["battery_id"]).unwrap_or_default(),
                ),
            }
        })
        .collect::<Vec<_>>();
    batteries.sort_by_key(|battery| battery.slot_id.unwrap_or(i64::MAX));
    batteries
}

pub(crate) fn production_date_from_id(battery_id: &str) -> Option<NaiveDate> {
    let bytes = battery_id.as_bytes();
    if bytes.len() < 15 || !bytes[10..15].iter().all(u8::is_ascii_digit) {
        return None;
    }
    let ordinal = std::str::from_utf8(&bytes[10..13])
        .ok()?
        .parse::<u32>()
        .ok()?;
    let year = 2000
        + std::str::from_utf8(&bytes[13..15])
            .ok()?
            .parse::<i32>()
            .ok()?;
    NaiveDate::from_yo_opt(year, ordinal)
}

fn capacity_from(battery_id: &str, description: Option<&str>) -> Option<f64> {
    let description = description.unwrap_or_default();
    if description.contains("150") {
        return Some(150.0);
    }
    if description.contains("100") {
        return Some(100.0);
    }
    if description.contains("75") {
        return Some(if battery_id.starts_with("P007") {
            70.0
        } else {
            75.0
        });
    }
    if description.contains("70") {
        return Some(70.0);
    }
    None
}

fn capacity_from_value(value: &Value, battery_id: &str, description: Option<&str>) -> Option<f64> {
    capacity_from_series(&value["battery_cap_series"])
        .or_else(|| capacity_from(battery_id, description))
}

fn capacity_from_series(value: &Value) -> Option<f64> {
    match i64_value(value)? {
        0 => Some(70.0),
        3 => Some(75.0),
        2 => Some(100.0),
        _ => None,
    }
}

fn string_value(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn f64_value(value: &Value) -> Option<f64> {
    value.as_f64().or_else(|| value.as_str()?.parse().ok())
}

fn i64_value(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|value| value as i64))
        .or_else(|| {
            value
                .as_str()?
                .chars()
                .filter(|character| character.is_ascii_digit() || *character == '-')
                .collect::<String>()
                .parse()
                .ok()
        })
}

fn u32_value(value: &Value) -> Option<u32> {
    i64_value(value).and_then(|value| u32::try_from(value).ok())
}

fn bool_value(value: &Value) -> Option<bool> {
    value
        .as_bool()
        .or_else(|| value.as_i64().map(|value| value != 0))
        .or_else(|| {
            value
                .as_str()
                .map(|value| matches!(value.to_ascii_lowercase().as_str(), "true" | "1" | "yes"))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD as TEST_BASE64;
    use cbc::cipher::BlockEncryptMut;
    use chrono::Datelike;

    type Aes128CbcEnc = cbc::Encryptor<Aes128>;

    #[test]
    fn production_code_is_year_and_ordinal_day() {
        let date = production_date_from_id("012345678900920-rest").unwrap();
        assert_eq!(date.to_string(), "2020-01-09");
        assert_eq!(date.ordinal(), 9);
    }

    #[test]
    fn rejects_impossible_ordinal_day() {
        assert!(production_date_from_id("012345678936724-rest").is_none());
    }

    #[test]
    fn signing_replaces_stale_values_and_is_deterministic() {
        let headers = HashMap::from([("Authorization".to_owned(), "Bearer token".to_owned())]);
        let url = signed_url_if_supported(
            "https://app.nio.com/nio/app/bff/map/resources/v1/swap/detail?z=2&sign=old&a=1&timestamp=0",
            &headers,
            1_700_000_000,
        ).unwrap();
        let pairs = url.query_pairs().collect::<HashMap<_, _>>();
        assert_eq!(
            pairs.get("timestamp").map(|value| value.as_ref()),
            Some("1700000000")
        );
        assert_ne!(pairs.get("sign").map(|value| value.as_ref()), Some("old"));
        assert_eq!(
            pairs.get("sign").map(|value| value.as_ref()),
            Some("3601421c22cb77292759bcda60ba3653")
        );
    }

    #[test]
    fn decrypts_protocol_envelope_data() {
        let plaintext = br#"{"battery":{"battery_list":[]}}"#;
        let ciphertext = Aes128CbcEnc::new(RESPONSE_KEY.into(), RESPONSE_IV.into())
            .encrypt_padded_vec_mut::<Pkcs7>(plaintext);
        let encoded = TEST_BASE64.encode(ciphertext);
        assert_eq!(decrypt_payload(&encoded).unwrap(), plaintext);
    }

    #[test]
    fn parses_station_location_as_longitude_then_latitude() {
        let coordinates = parse_coordinates(&serde_json::json!({
            "location": "116.407423,39.904213"
        }))
        .unwrap();
        assert_eq!(coordinates.longitude, 116.407423);
        assert_eq!(coordinates.latitude, 39.904213);
    }

    #[test]
    fn rejects_missing_or_out_of_range_station_location() {
        assert!(parse_coordinates(&serde_json::json!({})).is_err());
        assert!(parse_coordinates(&serde_json::json!({"location":"181,39"})).is_err());
        assert!(parse_coordinates(&serde_json::json!({"location":"117,91"})).is_err());
    }

    #[test]
    fn parses_station_address_and_ignores_blanks() {
        assert_eq!(
            parse_address(&serde_json::json!({"address": " 红星美凯龙(云山道店) "})).as_deref(),
            Some("红星美凯龙(云山道店)")
        );
        assert_eq!(parse_address(&serde_json::json!({"address": "   "})), None);
        assert_eq!(parse_address(&serde_json::json!({})), None);
    }

    #[test]
    fn parses_queue_for_requested_battery_level() {
        let payload = serde_json::json!({
            "wait_in_line": 3,
            "estimated_wait_in_line": 4,
            "battery": {
                "battery_cap_level_sort_list": [
                    {"battery_cap_level": 1, "wait_in_line": 1, "waiting_desc": "正在排队", "nav_count": 2},
                    {"battery_cap_level": 2, "wait_in_line": 0, "waiting_desc": "无需排队", "nav_count": 0}
                ]
            }
        });
        let queue = parse_queue_status(&payload, Some(1));
        assert_eq!(queue.vehicles_ahead, Some(1));
        assert_eq!(queue.waiting_description.as_deref(), Some("正在排队"));
        assert_eq!(queue.navigation_count, Some(2));
    }

    #[test]
    #[ignore = "requires NIO_STATION_FIXTURE to point to an encrypted response envelope"]
    fn parses_external_encrypted_fixture_when_provided() {
        let path = std::env::var("NIO_STATION_FIXTURE")
            .expect("set NIO_STATION_FIXTURE to the encrypted response JSON file");
        let raw = std::fs::read(path).expect("read station response fixture");
        let envelope: EncryptedEnvelope =
            serde_json::from_slice(&raw).expect("parse station response envelope");
        let decrypted = decrypt_payload(&envelope.data).expect("decrypt station response");
        let payload: Value = serde_json::from_slice(&decrypted).expect("parse decrypted JSON");
        let details = parse_live_details(&payload, Utc::now());
        assert!(
            !details.battery_readiness.is_empty(),
            "real station response should contain battery readiness entries"
        );
        assert!(
            details
                .battery_readiness
                .iter()
                .any(|battery| battery.capacity_kwh.is_some()),
            "real station response should contain a recognized battery series"
        );
        let identified_count = details
            .battery_readiness
            .iter()
            .filter(|battery| battery.battery_id.is_some())
            .count();
        eprintln!(
            "validated {} batteries; {} still include upstream IDs",
            details.battery_readiness.len(),
            identified_count
        );
    }

    #[test]
    fn parses_grouped_batteries_and_real_date() {
        let payload = serde_json::json!({
            "battery": {"battery_cap_level_sort_list": [{"battery_list": [{
                "battery_id": "ABCDEFGHIJ05621-extra",
                "slot_id": "2",
                "progress": "93.5",
                "lower_case_desc": "(100 kWh)",
                "battery_occupied": 0
            }]}]}
        });
        let batteries = parse_batteries(&payload);
        assert_eq!(batteries.len(), 1);
        assert_eq!(
            batteries[0].production_date.unwrap().to_string(),
            "2021-02-25"
        );
        assert_eq!(batteries[0].capacity_kwh, Some(100.0));
    }

    #[test]
    fn parses_current_station_price() {
        let payload = serde_json::json!({
            "fee_info": {"current_fee": [
                {"type": "service_fee", "name": "服务费", "fee": "0.60", "unit": "元/度", "currency": "¥"},
                {"type": "total_fee", "name": "合计", "fee": "1.35", "unit": "元/度", "currency": "¥"}
            ]}
        });
        let fees = parse_current_fees(&payload);
        assert_eq!(fees.len(), 2);
        assert_eq!(fees[1].fee, "1.35");
        assert!(fees[1].is_total);
    }

    #[test]
    fn live_details_preserve_all_fee_periods_and_unknown_queue_fields() {
        let payload = serde_json::json!({
            "fee_info": {
                "current_fee": [{"type":"total_fee","name":"合计","fee":"1.35","unit":"元/度","currency":"¥"}],
                "detail": [
                    {"time_period":"00:00-08:00","fee":[
                        {"type":"electricity_fee","name":"电费","fee":"0.42","unit":"元/度","currency":"¥"},
                        {"type":"service_fee","name":"服务费","fee":"0.60","unit":"元/度","currency":"¥"}
                    ]},
                    {"time_period":"08:00-24:00","fee":[
                        {"type":"electricity_fee","name":"电费","fee":"0.75","unit":"元/度","currency":"¥"},
                        {"type":"service_fee","name":"服务费","fee":"0.60","unit":"元/度","currency":"¥"}
                    ]}
                ],
                "fee_special_desc_array": ["只适用于现场公示的计费规则"]
            },
            "wait_in_line": 3,
            "battery": {"battery_list": [
                {"battery_id":"P007XXXXXXXXXXXX", "slot_id": 2, "progress":"89", "lower_case_desc":"(75 kWh)",
                 "charging_time_desc":"25", "battery_occupied":1},
                {"battery_id":"OTHERXXXXXXXXXXXX", "slot_id": 4, "progress":"80", "lower_case_desc":"(100 kWh)",
                 "charging_time_desc":"约1小时20分钟", "battery_occupied":0}
            ]}
        });
        let at = DateTime::parse_from_rfc3339("2026-10-30T08:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let detail = parse_live_details(&payload, at);
        assert_eq!(detail.fee_periods.len(), 2);
        assert_eq!(
            detail.fee_periods[1].fees[1].fee_type.as_deref(),
            Some("service_fee")
        );
        assert_eq!(detail.fee_periods[1].fees[0].unit, "元/度");
        assert_eq!(detail.fee_notices, vec!["只适用于现场公示的计费规则"]);
        assert_eq!(detail.fee_timezone, None);
        assert_eq!(detail.queue.vehicles_ahead, Some(3));
        assert_eq!(detail.queue.estimated_wait_minutes, None);
        assert_eq!(detail.queue.upstream_updated_at, None);
        assert_eq!(detail.queue.observed_at, at);
        assert_eq!(detail.battery_readiness.len(), 2);
        assert_eq!(
            detail.battery_readiness[0].charging_remaining_minutes,
            Some(25)
        );
        assert_eq!(
            detail.battery_readiness[0].estimated_charge_complete_at,
            Some(at + chrono::Duration::minutes(25))
        );
        assert_eq!(detail.battery_readiness[1].charging_remaining_minutes, None);
        assert_eq!(
            detail.battery_readiness[1].estimated_charge_complete_at,
            None
        );
        let serialized = serde_json::to_value(&detail.battery_readiness).unwrap();
        assert!(!serialized.to_string().contains("P007"));
        assert!(!serialized.to_string().contains("battery_id"));
    }

    #[test]
    fn derives_capacity_from_series_when_upstream_omits_battery_id() {
        let payload = serde_json::json!({
            "battery": {"battery_cap_level_sort_list": [{"battery_list": [
                {"battery_cap_series":0,"slot_id":2,"progress":100,"lower_case_desc":"(70/75kWh)","battery_occupied":false,"charging_time_desc":"可用"},
                {"battery_cap_series":3,"slot_id":12,"progress":100,"lower_case_desc":"(70/75kWh)","battery_occupied":false,"charging_time_desc":"可用"},
                {"battery_cap_series":2,"slot_id":10,"progress":100,"lower_case_desc":"(400V 100kWh)","battery_occupied":false,"charging_time_desc":"可用"}
            ]}]}
        });
        let at = DateTime::parse_from_rfc3339("2026-11-13T06:23:59Z")
            .unwrap()
            .with_timezone(&Utc);
        let details = parse_live_details(&payload, at);
        assert!(
            parse_batteries(&payload).is_empty(),
            "no synthetic battery IDs"
        );
        assert_eq!(details.battery_readiness.len(), 3);
        for (series, capacity) in [(0, 70.0), (3, 75.0), (2, 100.0)] {
            let battery = details
                .battery_readiness
                .iter()
                .find(|battery| battery.battery_cap_series == Some(series))
                .unwrap();
            assert_eq!(battery.capacity_kwh, Some(capacity));
            assert_eq!(battery.battery_id, None);
        }
    }
}
