//! Read-only NIO CN map around/recall lookup for power-swap stations.
//! Request shape was checked against the 2026-10-30 CN capture. The capture's
//! account credentials and coordinates are never stored or replayed.

use std::{collections::BTreeMap, env, sync::Arc, time::Duration};

use chrono::{DateTime, Utc};
use md5::{Digest as _, Md5};
use reqwest::{Client, StatusCode, redirect::Policy};
use serde::Serialize;
use serde_json::{Value, json};
use url::Url;

use crate::{
    config::VehicleConfig,
    provider::decrypt_payload,
    route_estimate::{straight_line_km, valid_coordinate},
};

const APP_ORIGIN: &str = "https://app.nio.com";
const AROUND_PATH: &str = "/app/api/pe/map/resources/v1/scene/around/recall";
const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
const CAPTURED_ZOOM_LEVEL: u8 = 14;
const CAPTURED_SCREEN_RATIO: f64 = 1.4586666666666666;

#[derive(Clone)]
pub struct NioNearbyStationClient {
    profile: Arc<VehicleConfig>,
    model_type: String,
    http: Client,
}

#[derive(Debug, thiserror::Error)]
pub enum NearbyError {
    #[error("invalid coordinates")]
    InvalidCoordinates,
    #[error("invalid configured vehicle model")]
    InvalidModel,
    #[error("failed to construct NIO nearby-station request")]
    InvalidUrl,
    #[error("NIO nearby-station request failed")]
    Request(#[source] reqwest::Error),
    #[error("NIO nearby-station endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("NIO nearby-station response was invalid")]
    InvalidResponse,
    #[error("NIO nearby-station request was rejected: {0}")]
    Rejected(String),
}

#[derive(Debug, Serialize)]
pub struct NearbyStation {
    pub station_id: String,
    pub name: Option<String>,
    pub latitude: f64,
    pub longitude: f64,
    pub straight_line_distance_km: f64,
}

#[derive(Debug, Serialize)]
pub struct NearbyStationResult {
    pub source: &'static str,
    pub fetched_at: DateTime<Utc>,
    pub viewport_zoom_level: u8,
    pub viewport_screen_ratio: f64,
    pub coverage: &'static str,
    pub stations: Vec<NearbyStation>,
}

impl NioNearbyStationClient {
    pub fn new(profile: VehicleConfig) -> Result<Self, NearbyError> {
        let model_type = env::var("NIO_SWAP_MODEL_TYPE").unwrap_or_else(|_| "ET5T".to_owned());
        if model_type.is_empty()
            || model_type.len() > 40
            || !model_type
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        {
            return Err(NearbyError::InvalidModel);
        }
        let http = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(format!("NextevCar/{}", profile.app_version))
            .build()
            .map_err(|error| NearbyError::Request(error.without_url()))?;
        Ok(Self {
            profile: Arc::new(profile),
            model_type,
            http,
        })
    }

    pub async fn search(
        &self,
        latitude: f64,
        longitude: f64,
    ) -> Result<NearbyStationResult, NearbyError> {
        if !valid_coordinate(latitude, longitude) {
            return Err(NearbyError::InvalidCoordinates);
        }
        let body = request_body(&self.profile, &self.model_type, latitude, longitude);
        let body = serde_json::to_string(&body).map_err(|_| NearbyError::InvalidResponse)?;
        let query = vec![
            ("app_id".to_owned(), self.profile.app_id.clone()),
            ("region".to_owned(), self.profile.region.clone()),
            (
                "lang".to_owned(),
                self.profile.language.replace('-', "_").to_ascii_lowercase(),
            ),
            ("app_ver".to_owned(), self.profile.app_version.clone()),
            ("timestamp".to_owned(), Utc::now().timestamp().to_string()),
            ("device_id".to_owned(), self.profile.device_id.clone()),
            ("scene".to_owned(), "resource".to_owned()),
            ("biz_type".to_owned(), "around_detail".to_owned()),
            ("scene_info".to_owned(), "auto".to_owned()),
        ];
        let url = signed_url(&query, &body, &self.profile.bearer_token)?;
        let response = self
            .http
            .post(url)
            .bearer_auth(&self.profile.bearer_token)
            .header("accept", "application/json,text/json,text/plain")
            .header("accept-encoding", "identity")
            .header("content-type", "application/json")
            .body(body)
            .send()
            .await
            .map_err(|error| NearbyError::Request(error.without_url()))?;
        if !response.status().is_success() {
            return Err(NearbyError::HttpStatus(response.status()));
        }
        let envelope: Value = response
            .json()
            .await
            .map_err(|_| NearbyError::InvalidResponse)?;
        let code = envelope
            .get("result_code")
            .and_then(Value::as_str)
            .ok_or(NearbyError::InvalidResponse)?;
        if code != "success" && code != "0" {
            return Err(NearbyError::Rejected(code.to_owned()));
        }
        let data = match envelope.get("encrypt_type").and_then(Value::as_u64) {
            Some(1) => {
                let encoded = envelope
                    .get("data")
                    .and_then(Value::as_str)
                    .ok_or(NearbyError::InvalidResponse)?;
                let plain = decrypt_payload(encoded).map_err(|_| NearbyError::InvalidResponse)?;
                serde_json::from_slice(&plain).map_err(|_| NearbyError::InvalidResponse)?
            }
            Some(0) | None => envelope
                .get("data")
                .cloned()
                .ok_or(NearbyError::InvalidResponse)?,
            _ => return Err(NearbyError::InvalidResponse),
        };
        let fetched_at = Utc::now();
        Ok(parse_result(&data, latitude, longitude, fetched_at))
    }
}

fn request_body(profile: &VehicleConfig, model_type: &str, latitude: f64, longitude: f64) -> Value {
    json!({
        "latitude": latitude,
        "longitude": longitude,
        "recall_latitude": latitude,
        "recall_longitude": longitude,
        "zoom_level": CAPTURED_ZOOM_LEVEL,
        "screen_ratio": CAPTURED_SCREEN_RATIO,
        "with_recall": true,
        "filter": {"resource_types": "PS"},
        "vehicle_info": {
            "vehicle_id": profile.vehicle_id,
            "model_type": model_type,
            "model_type_year": "G1.2",
            "vehicle_latitude": latitude,
            "vehicle_longitude": longitude
        }
    })
}

fn signed_url(
    query: &[(String, String)],
    body: &str,
    bearer_token: &str,
) -> Result<Url, NearbyError> {
    let mut canonical = query
        .iter()
        .map(|(name, value)| {
            let mut serializer = url::form_urlencoded::Serializer::new(String::new());
            serializer.append_pair(name, value).finish()
        })
        .collect::<Vec<_>>();
    canonical.push(format!("jsonBody={body}"));
    canonical.sort();
    let material = format!(
        "POST{AROUND_PATH}?{}{}Bearer {bearer_token}",
        canonical.join("&"),
        SIGNING_SALT
    );
    let signature = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url = Url::parse(APP_ORIGIN).map_err(|_| NearbyError::InvalidUrl)?;
    url.set_path(AROUND_PATH);
    url.query_pairs_mut()
        .extend_pairs(query.iter().map(|(name, value)| (name, value)))
        .append_pair("sign", &signature);
    Ok(url)
}

fn parse_result(
    data: &Value,
    latitude: f64,
    longitude: f64,
    fetched_at: DateTime<Utc>,
) -> NearbyStationResult {
    let mut names = BTreeMap::<String, String>::new();
    for module in data
        .pointer("/recall_result/content_modules")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(detail) = module
            .get("module_data")
            .and_then(Value::as_str)
            .and_then(|text| serde_json::from_str::<Value>(text).ok())
        else {
            continue;
        };
        if detail.pointer("/detail/sub_type").and_then(Value::as_str) != Some("PowerSwap") {
            continue;
        }
        if let (Some(id), Some(name)) = (
            detail.pointer("/detail/id").and_then(Value::as_str),
            detail.pointer("/detail/name").and_then(Value::as_str),
        ) {
            names.insert(id.to_owned(), name.to_owned());
        }
    }
    let mut stations = BTreeMap::<String, NearbyStation>::new();
    for pin in ["map_pins", "open_pin_list"].into_iter().flat_map(|key| {
        data.get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
    }) {
        let (Some(id), Some(station_latitude), Some(station_longitude)) = (
            pin.get("id").and_then(Value::as_str),
            pin.get("latitude").and_then(Value::as_f64),
            pin.get("longitude").and_then(Value::as_f64),
        ) else {
            continue;
        };
        if pin.get("sub_type").and_then(Value::as_str) != Some("PowerSwap")
            || !id.starts_with("PS-NIO-")
            || !valid_coordinate(station_latitude, station_longitude)
        {
            continue;
        }
        let distance = straight_line_km(latitude, longitude, station_latitude, station_longitude);
        stations
            .entry(id.to_owned())
            .or_insert_with(|| NearbyStation {
                station_id: id.to_owned(),
                name: names.get(id).cloned(),
                latitude: station_latitude,
                longitude: station_longitude,
                straight_line_distance_km: (distance * 10.0).round() / 10.0,
            });
    }
    let mut stations = stations.into_values().collect::<Vec<_>>();
    stations.sort_by(|a, b| {
        a.straight_line_distance_km
            .total_cmp(&b.straight_line_distance_km)
            .then(a.station_id.cmp(&b.station_id))
    });
    NearbyStationResult {
        source: "nio_cn_around_recall",
        fetched_at,
        viewport_zoom_level: CAPTURED_ZOOM_LEVEL,
        viewport_screen_ratio: CAPTURED_SCREEN_RATIO,
        coverage: "upstream_viewport_results_not_a_radius_complete_list",
        stations,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_and_deduplicates_power_swap_pins_without_echoing_center() {
        let data = json!({
            "map_pins": [
                {"id":"PS-NIO-1","sub_type":"PowerSwap","latitude":31.1,"longitude":121.0},
                {"id":"CS-2","sub_type":"ChargeStation","latitude":31.0,"longitude":121.0}
            ],
            "open_pin_list": [
                {"id":"PS-NIO-1","sub_type":"PowerSwap","latitude":31.1,"longitude":121.0},
                {"id":"PS-NIO-3","sub_type":"PowerSwap","latitude":31.2,"longitude":121.0},
                {"id":"PS-NIO-bad","sub_type":"PowerSwap","latitude":99.0,"longitude":121.0}
            ],
            "recall_result":{"content_modules":[
                {"module_data": r#"{"detail":{"id":"PS-NIO-1","name":"测试站","sub_type":"PowerSwap"}}"#}
            ]}
        });
        let result = parse_result(&data, 31.0, 121.0, Utc::now());
        assert_eq!(result.stations.len(), 2);
        assert_eq!(result.stations[0].name.as_deref(), Some("测试站"));
        assert!(result.stations[0].straight_line_distance_km > 11.0);
        let wire = serde_json::to_value(result).unwrap();
        assert!(wire.get("latitude").is_none());
        assert!(wire.get("longitude").is_none());
        assert_eq!(
            wire["coverage"],
            "upstream_viewport_results_not_a_radius_complete_list"
        );
    }
}
