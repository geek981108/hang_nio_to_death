//! Explicit one-call NIO swap ordering.
//!
//! The API handler resolves the station coordinates from the encrypted station
//! detail endpoint. This client then performs `/swap/scan` followed by exactly
//! one `POST /swap`. No upstream request is retried.
//!
//! Request shapes follow the domestic 6.9.6 flow (`nioapp-powerswap-cn` H5
//! `startSwapping`): the scan carries `spot_id` and `vehicle_id`; the create
//! carries `action`/`service_type` (empty for a plain swap), `scene`, and the
//! fixed `model_type_year=G1.2`.

use std::{env, sync::Arc, time::Duration};

use aes::Aes128;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use chrono::Utc;
use md5::{Digest as _, Md5};
use reqwest::{Client, StatusCode, redirect::Policy};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;

use crate::{config::VehicleConfig, provider::StationCoordinates};

type Aes128CbcDec = cbc::Decryptor<Aes128>;

const APP_ORIGIN: &str = "https://app.nio.com";
const SCAN_PATH: &str = "/app/api/pe/v1/swap/scan";
const CREATE_PATH: &str = "/app/api/pe/v1/swap";
const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
const RESPONSE_KEY: &[u8; 16] = b"kc1$[41_fpqxeg70";
const RESPONSE_IV: &[u8; 16] = b"g3QNdti5qCEoFVCj";
/// Popup configuration key the app sends as `scene` on a plain swap start.
const CREATE_SCENE: &str = "swap_pop_ups";

#[derive(Clone)]
pub struct SwapOrderRuntime {
    client: Arc<SwapOrderClient>,
}

struct SwapOrderClient {
    profile: VehicleConfig,
    model_type: String,
    target_battery_cap_level: u8,
    http: Client,
    gate: Mutex<()>,
}

#[derive(Debug, thiserror::Error)]
pub enum SwapOrderError {
    #[error("invalid swap-order input: {0}")]
    InvalidInput(&'static str),
    #[error("swap-order configuration is invalid: {0}")]
    InvalidConfig(&'static str),
    #[error("failed to construct NIO swap-order request")]
    InvalidUrl,
    #[error("NIO swap-order request failed")]
    Request(#[source] reqwest::Error),
    #[error("NIO swap-order endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("NIO swap-order endpoint returned invalid JSON")]
    InvalidJson(#[source] reqwest::Error),
    #[error("NIO swap-order response was invalid")]
    InvalidResponse,
    #[error("NIO swap-order request was rejected: {0}")]
    Rejected(String),
    #[error("NIO swap-order response decryption failed")]
    Decryption,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateSwapOrderInput {
    pub station_id: String,
    pub confirmation: String,
}

#[derive(Debug, Serialize)]
pub struct CreateSwapOrderOutcome {
    pub station_id: String,
    pub latitude: f64,
    pub longitude: f64,
    pub scan_request_id: Option<String>,
    pub request_id: Option<String>,
    pub server_time: Option<i64>,
    pub order_id: String,
    pub requested_battery_cap_level: u8,
    pub battery_cap_level: Option<u8>,
    pub target_battery_cap_level: Option<u8>,
    pub ps_resource_model: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Envelope {
    result_code: String,
    #[serde(default)]
    data: Value,
    #[serde(default)]
    encrypt_type: u8,
    request_id: Option<String>,
    server_time: Option<i64>,
    display_msg: Option<String>,
    debug_msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateData {
    order_id: String,
    battery_cap_level: Option<u8>,
    target_battery_cap_level: Option<u8>,
    ps_resource_model: Option<String>,
}

impl SwapOrderRuntime {
    /// A vehicle session prepares the upstream client. HTTP authorization is
    /// intentionally shared with the existing vehicle-control runtime.
    pub fn from_env(profile: Option<VehicleConfig>) -> Result<Option<Self>, SwapOrderError> {
        let Some(profile) = profile else {
            return Ok(None);
        };
        let model_type = nonempty_env("NIO_SWAP_MODEL_TYPE").unwrap_or_else(|| "ET5T".to_owned());
        if !valid_model_component(&model_type) {
            return Err(SwapOrderError::InvalidConfig(
                "swap vehicle model contains unsupported characters",
            ));
        }
        let target_battery_cap_level = nonempty_env("NIO_SWAP_TARGET_BATTERY_CAP_LEVEL")
            .unwrap_or_else(|| "1".to_owned())
            .parse::<u8>()
            .map_err(|_| {
                SwapOrderError::InvalidConfig("target battery capacity level must be 1 or 2")
            })?;
        if !matches!(target_battery_cap_level, 1 | 2) {
            return Err(SwapOrderError::InvalidConfig(
                "target battery capacity level must be 1 or 2",
            ));
        }
        let http = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(format!(
                "NextevCar/{} (independent Rust swap-order client)",
                profile.app_version
            ))
            .build()
            .map_err(SwapOrderError::Request)?;
        Ok(Some(Self {
            client: Arc::new(SwapOrderClient {
                profile,
                model_type,
                target_battery_cap_level,
                http,
                gate: Mutex::new(()),
            }),
        }))
    }

    pub async fn create(
        &self,
        input: CreateSwapOrderInput,
        coordinates: StationCoordinates,
    ) -> Result<CreateSwapOrderOutcome, SwapOrderError> {
        self.client.create(input, coordinates).await
    }
}

impl SwapOrderClient {
    async fn create(
        &self,
        input: CreateSwapOrderInput,
        coordinates: StationCoordinates,
    ) -> Result<CreateSwapOrderOutcome, SwapOrderError> {
        if input.confirmation != "CREATE SWAP ORDER" {
            return Err(SwapOrderError::InvalidInput(
                "typed confirmation must be CREATE SWAP ORDER",
            ));
        }
        validate_station_id(&input.station_id)?;
        validate_coordinates(coordinates)?;

        let station_id = input.station_id;
        let _guard = self.gate.lock().await;

        let scan_form = build_scan_form(&station_id, &self.profile.vehicle_id);
        let scan_envelope = self.post_form_once(SCAN_PATH, &scan_form).await?;
        let _scan_data = decode_data(&scan_envelope)?;

        let create_form = build_create_form(
            &station_id,
            &self.profile.vehicle_id,
            coordinates,
            &self.model_type,
            self.target_battery_cap_level,
        );
        let envelope = self.post_form_once(CREATE_PATH, &create_form).await?;
        let request_id = envelope.request_id.clone();
        let server_time = envelope.server_time;
        let data: CreateData = serde_json::from_value(decode_data(&envelope)?)
            .map_err(|_| SwapOrderError::InvalidResponse)?;
        validate_order_id(&data.order_id)?;
        Ok(CreateSwapOrderOutcome {
            station_id,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            scan_request_id: scan_envelope.request_id,
            request_id,
            server_time,
            order_id: data.order_id,
            requested_battery_cap_level: self.target_battery_cap_level,
            battery_cap_level: data.battery_cap_level,
            target_battery_cap_level: data.target_battery_cap_level,
            ps_resource_model: data.ps_resource_model,
        })
    }

    async fn post_form_once(
        &self,
        path: &str,
        form: &[(String, String)],
    ) -> Result<Envelope, SwapOrderError> {
        let query = common_query(&self.profile, Utc::now().timestamp());
        let url = signed_url(path, "POST", query, form, &self.profile.bearer_token)?;
        let response = self
            .http
            .post(url)
            .bearer_auth(&self.profile.bearer_token)
            .header("accept", "application/json,text/json,text/plain")
            .header("accept-language", "zh-CN,zh-Hans;q=0.9")
            .header(
                "x-request-session-id",
                Uuid::new_v4().to_string().to_uppercase(),
            )
            .form(form)
            .send()
            .await
            .map_err(SwapOrderError::Request)?;
        read_envelope(response).await
    }
}

async fn read_envelope(response: reqwest::Response) -> Result<Envelope, SwapOrderError> {
    if !response.status().is_success() {
        return Err(SwapOrderError::HttpStatus(response.status()));
    }
    let envelope = response
        .json::<Envelope>()
        .await
        .map_err(SwapOrderError::InvalidJson)?;
    if envelope.result_code != "success" {
        return Err(SwapOrderError::Rejected(
            envelope
                .display_msg
                .or(envelope.debug_msg)
                .unwrap_or(envelope.result_code),
        ));
    }
    Ok(envelope)
}

fn decode_data(envelope: &Envelope) -> Result<Value, SwapOrderError> {
    match envelope.encrypt_type {
        0 => Ok(envelope.data.clone()),
        1 => {
            let encoded = envelope
                .data
                .as_str()
                .ok_or(SwapOrderError::InvalidResponse)?;
            let ciphertext = BASE64
                .decode(encoded)
                .map_err(|_| SwapOrderError::Decryption)?;
            let plaintext = Aes128CbcDec::new(RESPONSE_KEY.into(), RESPONSE_IV.into())
                .decrypt_padded_vec_mut::<Pkcs7>(&ciphertext)
                .map_err(|_| SwapOrderError::Decryption)?;
            serde_json::from_slice(&plaintext).map_err(|_| SwapOrderError::InvalidResponse)
        }
        _ => Err(SwapOrderError::InvalidResponse),
    }
}

/// `/swap/scan` form, in the app's field order: `spot_id`, optional `content`,
/// `vehicle_id`.
fn build_scan_form(station_id: &str, vehicle_id: &str) -> Vec<(String, String)> {
    vec![
        ("spot_id".to_owned(), station_id.to_owned()),
        ("vehicle_id".to_owned(), vehicle_id.to_owned()),
    ]
}

/// `POST /swap` form aligned with the app's `startSwapping`.
///
/// `action` and `service_type` are empty strings for a plain swap; the app only
/// fills them from `cross_swap_info_list` for a cross-level battery selection.
/// `scene` names the popup configuration; `model_type_year` is fixed to G1.2.
fn build_create_form(
    station_id: &str,
    vehicle_id: &str,
    coordinates: StationCoordinates,
    model_type: &str,
    target_battery_cap_level: u8,
) -> Vec<(String, String)> {
    vec![
        ("action".to_owned(), String::new()),
        ("service_type".to_owned(), String::new()),
        ("vehicleId".to_owned(), vehicle_id.to_owned()),
        ("swapId".to_owned(), station_id.to_owned()),
        ("latitude".to_owned(), coordinates.latitude.to_string()),
        ("longitude".to_owned(), coordinates.longitude.to_string()),
        (
            "target_battery_cap_level".to_owned(),
            target_battery_cap_level.to_string(),
        ),
        ("model_type".to_owned(), model_type.to_owned()),
        ("scene".to_owned(), CREATE_SCENE.to_owned()),
        ("model_type_year".to_owned(), "G1.2".to_owned()),
    ]
}

fn common_query(profile: &VehicleConfig, timestamp: i64) -> Vec<(String, String)> {
    vec![
        ("app_id".to_owned(), profile.app_id.clone()),
        ("region".to_owned(), profile.region.clone()),
        ("lang".to_owned(), profile.language.clone()),
        ("app_ver".to_owned(), profile.app_version.clone()),
        ("timestamp".to_owned(), timestamp.to_string()),
        ("device_id".to_owned(), profile.device_id.clone()),
    ]
}

fn signed_url(
    path: &str,
    method: &str,
    query: Vec<(String, String)>,
    form: &[(String, String)],
    bearer_token: &str,
) -> Result<Url, SwapOrderError> {
    if !path.starts_with('/') || path.contains('?') || path.contains('#') {
        return Err(SwapOrderError::InvalidUrl);
    }
    let encoded_query = query
        .iter()
        .map(|(name, value)| {
            let mut serializer = url::form_urlencoded::Serializer::new(String::new());
            serializer.append_pair(name, value).finish()
        })
        .collect::<Vec<_>>();
    let mut canonical = encoded_query.clone();
    canonical.extend(
        form.iter()
            .filter(|(name, _)| !name.is_empty())
            .map(|(name, value)| format!("{name}={value}")),
    );
    canonical.sort();
    let material = format!(
        "{}{}?{}{}Bearer {}",
        method.to_uppercase(),
        path,
        canonical.join("&"),
        SIGNING_SALT,
        bearer_token
    );
    let signature = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url = Url::parse(APP_ORIGIN).map_err(|_| SwapOrderError::InvalidUrl)?;
    url.set_path(path);
    url.query_pairs_mut()
        .extend_pairs(query)
        .append_pair("sign", &signature);
    Ok(url)
}

fn validate_station_id(value: &str) -> Result<(), SwapOrderError> {
    if !(value.starts_with("PS-NIO-")
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')))
    {
        return Err(SwapOrderError::InvalidInput("station ID is invalid"));
    }
    Ok(())
}

fn validate_coordinates(value: StationCoordinates) -> Result<(), SwapOrderError> {
    if !value.latitude.is_finite()
        || !value.longitude.is_finite()
        || !(-90.0..=90.0).contains(&value.latitude)
        || !(-180.0..=180.0).contains(&value.longitude)
    {
        return Err(SwapOrderError::InvalidInput(
            "resolved station coordinates are invalid",
        ));
    }
    Ok(())
}

fn validate_order_id(value: &str) -> Result<(), SwapOrderError> {
    if value.is_empty() || value.len() > 128 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(SwapOrderError::InvalidInput("order ID is invalid"));
    }
    Ok(())
}

fn valid_model_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

fn nonempty_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile() -> VehicleConfig {
        VehicleConfig {
            bearer_token: "test-token".to_owned(),
            account_id: None,
            vehicle_id: "vehicle-1".to_owned(),
            device_id: "0123456789abcdef0123456789abcdef".to_owned(),
            app_id: "10002".to_owned(),
            app_version: "6.9.0".to_owned(),
            region: "cn".to_owned(),
            language: "zh_cn".to_owned(),
            vin_code: None,
        }
    }

    #[test]
    fn signing_covers_form_fields_and_bearer_token() {
        let profile = profile();
        let query = common_query(&profile, 1_792_057_271);
        let form = vec![
            ("latitude".to_owned(), "39.904213".to_owned()),
            ("longitude".to_owned(), "116.407423".to_owned()),
            ("model_type".to_owned(), "ET5T".to_owned()),
            ("model_type_year".to_owned(), "G1.2".to_owned()),
            ("swapId".to_owned(), "PS-NIO-3606da31-f8539ae9".to_owned()),
            ("target_battery_cap_level".to_owned(), "1".to_owned()),
            ("vehicleId".to_owned(), "vehicle-1".to_owned()),
        ];
        let first = signed_url(CREATE_PATH, "POST", query.clone(), &form, "test-token").unwrap();
        let mut changed = form.clone();
        changed[0].1 = "39.0".to_owned();
        let second = signed_url(CREATE_PATH, "POST", query, &changed, "test-token").unwrap();
        let signature = |url: &Url| {
            url.query_pairs()
                .find(|(name, _)| name == "sign")
                .map(|(_, value)| value.into_owned())
                .unwrap()
        };
        assert_ne!(signature(&first), signature(&second));
    }

    #[test]
    fn input_accepts_only_station_and_confirmation() {
        let input: CreateSwapOrderInput = serde_json::from_value(serde_json::json!({
            "station_id": "PS-NIO-test",
            "confirmation": "CREATE SWAP ORDER"
        }))
        .unwrap();
        assert!(validate_station_id(&input.station_id).is_ok());
        assert!(
            serde_json::from_value::<CreateSwapOrderInput>(serde_json::json!({
                "station_id": "PS-NIO-test",
                "confirmation": "CREATE SWAP ORDER",
                "latitude": 39.0
            }))
            .is_err()
        );
    }

    #[test]
    fn input_rejects_removed_scan_content() {
        assert!(
            serde_json::from_value::<CreateSwapOrderInput>(serde_json::json!({
                "station_id": "PS-NIO-test",
                "confirmation": "CREATE SWAP ORDER",
                "scan_content": "https://app.nio.com/ps/PS-NIO-test"
            }))
            .is_err()
        );
    }

    #[test]
    fn scan_form_contains_only_station_and_vehicle() {
        assert_eq!(
            build_scan_form("PS-1", "vehicle-1"),
            vec![
                ("spot_id".to_owned(), "PS-1".to_owned()),
                ("vehicle_id".to_owned(), "vehicle-1".to_owned()),
            ]
        );
    }

    #[test]
    fn create_form_matches_app_field_set() {
        let form = build_create_form(
            "PS-1",
            "vehicle-1",
            StationCoordinates {
                latitude: 39.904213,
                longitude: 116.407423,
            },
            "ET5T",
            1,
        );
        let names: Vec<&str> = form.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(
            names,
            vec![
                "action",
                "service_type",
                "vehicleId",
                "swapId",
                "latitude",
                "longitude",
                "target_battery_cap_level",
                "model_type",
                "scene",
                "model_type_year",
            ]
        );
        let value = |key: &str| {
            form.iter()
                .find(|(name, _)| name == key)
                .map(|(_, value)| value.as_str())
        };
        assert_eq!(value("action"), Some(""));
        assert_eq!(value("service_type"), Some(""));
        assert_eq!(value("scene"), Some(CREATE_SCENE));
        assert_eq!(value("model_type_year"), Some("G1.2"));
        assert_eq!(value("swapId"), Some("PS-1"));
        assert_eq!(value("latitude"), Some("39.904213"));
        assert_eq!(value("longitude"), Some("116.407423"));
    }

    #[test]
    fn create_form_keeps_fixed_model_type_year() {
        let form = build_create_form(
            "PS-1",
            "vehicle-1",
            StationCoordinates {
                latitude: 39.0,
                longitude: 117.0,
            },
            "ET5T",
            2,
        );
        assert!(form.contains(&("model_type_year".to_owned(), "G1.2".to_owned())));
        assert_eq!(form.len(), 10);
    }

    #[test]
    fn rejects_invalid_resolved_coordinates() {
        assert!(
            validate_coordinates(StationCoordinates {
                latitude: 39.904213,
                longitude: 116.407423,
            })
            .is_ok()
        );
        assert!(
            validate_coordinates(StationCoordinates {
                latitude: 91.0,
                longitude: 116.407423,
            })
            .is_err()
        );
    }

    #[test]
    fn decrypts_encrypted_scan_data() {
        use cbc::cipher::BlockEncryptMut;
        type Aes128CbcEnc = cbc::Encryptor<Aes128>;

        let plaintext = br#"{"status":"ready"}"#;
        let ciphertext = Aes128CbcEnc::new(RESPONSE_KEY.into(), RESPONSE_IV.into())
            .encrypt_padded_vec_mut::<Pkcs7>(plaintext);
        let envelope = Envelope {
            result_code: "success".to_owned(),
            data: Value::String(BASE64.encode(ciphertext)),
            encrypt_type: 1,
            request_id: None,
            server_time: None,
            display_msg: None,
            debug_msg: None,
        };
        assert_eq!(decode_data(&envelope).unwrap()["status"], "ready");
    }

    #[test]
    fn create_response_keeps_initial_capacity_values_exact() {
        let envelope: Envelope = serde_json::from_value(serde_json::json!({
            "result_code": "success",
            "encrypt_type": 0,
            "request_id": "request-1",
            "server_time": 1792057575415_i64,
            "data": {
                "order_id": "825393300000000001",
                "battery_cap_level": 0,
                "target_battery_cap_level": 0,
                "ps_resource_model": "Power Swap2"
            }
        }))
        .unwrap();
        let data: CreateData = serde_json::from_value(decode_data(&envelope).unwrap()).unwrap();
        assert_eq!(data.order_id, "825393300000000001");
        assert_eq!(data.battery_cap_level, Some(0));
        assert_eq!(data.target_battery_cap_level, Some(0));
    }
}
