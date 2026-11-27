use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex, RwLock},
    time::{Duration, Instant},
};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD as BASE64_STANDARD, URL_SAFE_NO_PAD as BASE64_URL},
};
use chrono::{DateTime, Utc};
use reqwest::StatusCode;
use ring::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair},
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::{
    config::ApnsConfig,
    models::{ActiveServiceOrder, VehicleSnapshot},
    store::Store,
    vehicle::{charging_sample_from_status, snapshot_from_status, swapping_state},
};

/// Seconds between Unix epoch (1970-01-01) and Apple's NSDate reference date (2001-01-01).
pub const APPLE_REFERENCE_DATE_OFFSET_SECONDS: i64 = 978_307_200;
const JWT_TTL_SECONDS: i64 = 45 * 60;
const START_COOLDOWN: Duration = Duration::from_secs(180);
const CHARGING_UPDATE_MIN_INTERVAL: Duration = Duration::from_secs(10);
const STALE_AFTER_SECONDS: i64 = 20 * 60;
const APNS_ATTRIBUTES_TYPE: &str = "NIOVehicleLiveActivityAttributes";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApnsEnvironment {
    Production,
    Sandbox,
}

impl ApnsEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Production => "production",
            Self::Sandbox => "sandbox",
        }
    }

    pub fn host(self) -> &'static str {
        match self {
            Self::Production => "api.push.apple.com",
            Self::Sandbox => "api.sandbox.push.apple.com",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "production" | "prod" | "release" => Some(Self::Production),
            "sandbox" | "development" | "dev" | "debug" => Some(Self::Sandbox),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiveActivityTokenKind {
    PushToStart,
    ActivityUpdate,
}

impl LiveActivityTokenKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PushToStart => "push_to_start",
            Self::ActivityUpdate => "activity_update",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LiveActivityMode {
    #[serde(rename = "swapQueue")]
    SwapQueue,
    #[serde(rename = "charging")]
    Charging,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LiveActivityTokenRegistration {
    pub device_id: String,
    pub token_kind: LiveActivityTokenKind,
    pub push_token: String,
    #[serde(default)]
    pub activity_id: Option<String>,
    #[serde(default)]
    pub session_key: Option<String>,
    #[serde(default)]
    pub activity_mode: Option<String>,
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default, alias = "environment")]
    pub apns_environment: Option<ApnsEnvironment>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LiveActivityTokenDeleteInput {
    pub device_id: String,
    #[serde(default)]
    pub token_kind: Option<LiveActivityTokenKind>,
    #[serde(default)]
    pub activity_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct LiveActivityTokenResponse {
    pub registered: bool,
    pub apns_configured: bool,
    pub token_kind: LiveActivityTokenKind,
    pub apns_environment: ApnsEnvironment,
}

fn default_sim_mode() -> LiveActivityMode {
    LiveActivityMode::Charging
}

fn default_sim_interval_seconds() -> u64 {
    5
}

fn default_sim_steps() -> u32 {
    6
}

#[derive(Clone, Debug, Deserialize)]
pub struct LiveActivitySimulationRequest {
    #[serde(default = "default_sim_mode")]
    pub mode: LiveActivityMode,
    #[serde(default = "default_sim_interval_seconds")]
    pub interval_seconds: u64,
    #[serde(default = "default_sim_steps")]
    pub steps: u32,
    #[serde(default)]
    pub device_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct LiveActivitySimulationStopInput {
    #[serde(default)]
    pub device_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct LiveActivitySimulationSnapshot {
    pub running: bool,
    pub simulation_id: Option<String>,
    pub mode: Option<LiveActivityMode>,
    pub session_key: Option<String>,
    pub current_step: u32,
    pub total_steps: u32,
    pub interval_seconds: u64,
    pub started_at: Option<DateTime<Utc>>,
    pub last_event: Option<String>,
    pub last_delivered_count: usize,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct LiveActivitySimulationOutcome {
    pub started: bool,
    pub simulation_id: String,
    pub mode: LiveActivityMode,
    pub session_key: String,
    pub interval_seconds: u64,
    pub total_steps: u32,
    pub start_tokens_targeted: usize,
    pub start_delivered: usize,
    pub update_tokens_targeted: usize,
    pub update_delivered: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct LiveActivitySimulationStopOutcome {
    pub stopped: bool,
    pub ended_tokens: usize,
    pub end_delivered: usize,
}

#[derive(Debug, Error)]
pub enum SimulationError {
    #[error("APNs push is not configured on this server")]
    ApnsNotConfigured,
    #[error("no active Live Activity push tokens registered for this target")]
    NoRegisteredTokens,
    #[error(transparent)]
    Store(#[from] crate::store::StoreError),
}

#[derive(Clone, Debug, Serialize)]
pub struct LiveActivityPushStatus {
    pub apns_configured: bool,
    pub bundle_id: Option<String>,
    pub default_environment: Option<ApnsEnvironment>,
    pub push_to_start_token_count: usize,
    pub activity_update_token_count: usize,
    pub active_session_key: Option<String>,
    pub active_mode: Option<LiveActivityMode>,
    pub last_push_at: Option<DateTime<Utc>>,
    pub simulation: Option<LiveActivitySimulationSnapshot>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveActivityTokenRecord {
    pub token_id: String,
    pub device_id: String,
    pub token_kind: String,
    pub push_token: String,
    pub activity_id: Option<String>,
    pub session_key: Option<String>,
    pub activity_mode: Option<String>,
    pub bundle_id: String,
    pub apns_environment: String,
    pub updated_at: DateTime<Utc>,
    pub last_pushed_at: Option<DateTime<Utc>>,
}

impl LiveActivityTokenRecord {
    pub fn environment(&self, fallback: ApnsEnvironment) -> ApnsEnvironment {
        ApnsEnvironment::parse(&self.apns_environment).unwrap_or(fallback)
    }
}

/// Exact camelCase match for Swift `NIOVehicleLiveActivityAttributes`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveActivityAttributes {
    pub session_key: String,
    pub vehicle_name: String,
}

/// Exact camelCase match for Swift `NIOVehicleLiveActivityAttributes.ContentState`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveActivityContentState {
    pub mode: LiveActivityMode,
    pub title: String,
    pub subtitle: Option<String>,
    /// Seconds since Apple reference date (2001-01-01T00:00:00Z), matching Swift `JSONDecoder` default.
    pub updated_at: f64,
    pub order_no: Option<String>,
    pub queue_number: Option<i64>,
    pub vehicles_ahead: Option<i64>,
    pub estimated_wait_minutes: Option<i64>,
    pub state_of_charge: Option<f64>,
    pub charge_limit_percent: Option<f64>,
    #[serde(rename = "chargingPowerKW")]
    pub charging_power_kw: Option<f64>,
    pub remaining_range_km: Option<f64>,
    #[serde(rename = "chargedEnergyKWh")]
    pub charged_energy_kwh: Option<f64>,
}

impl LiveActivityContentState {
    /// Returns true if all user-visible fields changed meaningfully enough to warrant an APNs update.
    pub fn differs_meaningfully_from(&self, other: &Self) -> bool {
        if self.mode != other.mode
            || self.title != other.title
            || self.subtitle != other.subtitle
            || self.order_no != other.order_no
            || self.queue_number != other.queue_number
            || self.vehicles_ahead != other.vehicles_ahead
            || self.estimated_wait_minutes != other.estimated_wait_minutes
        {
            return true;
        }
        opt_f64_differs(self.state_of_charge, other.state_of_charge, 0.5)
            || opt_f64_differs(self.charge_limit_percent, other.charge_limit_percent, 0.5)
            || opt_f64_differs(self.charging_power_kw, other.charging_power_kw, 0.5)
            || opt_f64_differs(self.remaining_range_km, other.remaining_range_km, 1.0)
            || opt_f64_differs(self.charged_energy_kwh, other.charged_energy_kwh, 0.09)
    }
}

fn opt_f64_differs(a: Option<f64>, b: Option<f64>, threshold: f64) -> bool {
    match (a, b) {
        (None, None) => false,
        (Some(x), Some(y)) => (x - y).abs() >= threshold,
        _ => true,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct LiveActivityPlan {
    pub session_key: String,
    pub vehicle_name: String,
    pub state: LiveActivityContentState,
    pub alert_title: String,
    pub alert_body: String,
}

#[derive(Debug, Error)]
pub enum ApnsError {
    #[error("invalid APNs .p8 private key: {0}")]
    InvalidPrivateKey(String),
    #[error("failed to initialize APNs HTTP/2 client: {0}")]
    ClientInit(#[source] reqwest::Error),
    #[error("failed to sign APNs JWT")]
    SigningFailed,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ApnsDeliveryOutcome {
    Delivered,
    InvalidToken(String),
    ExpiredProviderToken,
    Failed { status: u16, reason: String },
}

pub struct ApnsClient {
    http: reqwest::Client,
    team_id: String,
    key_id: String,
    pub bundle_id: String,
    pub default_environment: ApnsEnvironment,
    key_pair: EcdsaKeyPair,
    rng: SystemRandom,
    cached_jwt: RwLock<Option<(i64, String)>>,
}

impl ApnsClient {
    pub fn new(config: &ApnsConfig) -> Result<Self, ApnsError> {
        let der = decode_p8_pkcs8_der(&config.private_key_pem)?;
        let rng = SystemRandom::new();
        let key_pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &rng)
            .map_err(|_| {
                ApnsError::InvalidPrivateKey("expected PKCS#8 P-256 EC private key".to_owned())
            })?;
        let http = reqwest::Client::builder()
            .https_only(true)
            .http2_adaptive_window(true)
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(ApnsError::ClientInit)?;
        Ok(Self {
            http,
            team_id: config.team_id.clone(),
            key_id: config.key_id.clone(),
            bundle_id: config.bundle_id.clone(),
            default_environment: config.default_environment,
            key_pair,
            rng,
            cached_jwt: RwLock::new(None),
        })
    }

    pub fn bearer_jwt(&self, now_unix: i64) -> Result<String, ApnsError> {
        {
            let guard = self
                .cached_jwt
                .read()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some((issued_at, token)) = guard.as_ref()
                && now_unix.saturating_sub(*issued_at) < JWT_TTL_SECONDS
            {
                return Ok(token.clone());
            }
        }
        let jwt = self.sign_jwt(now_unix)?;
        *self
            .cached_jwt
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some((now_unix, jwt.clone()));
        Ok(jwt)
    }

    pub fn invalidate_cached_jwt(&self) {
        *self
            .cached_jwt
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }

    fn sign_jwt(&self, issued_at: i64) -> Result<String, ApnsError> {
        let header = serde_json::json!({
            "alg": "ES256",
            "kid": self.key_id,
        });
        let claims = serde_json::json!({
            "iss": self.team_id,
            "iat": issued_at,
        });
        let header_b64 = BASE64_URL.encode(header.to_string().as_bytes());
        let claims_b64 = BASE64_URL.encode(claims.to_string().as_bytes());
        let signing_input = format!("{header_b64}.{claims_b64}");
        let signature = self
            .key_pair
            .sign(&self.rng, signing_input.as_bytes())
            .map_err(|_| ApnsError::SigningFailed)?;
        let sig_b64 = BASE64_URL.encode(signature.as_ref());
        Ok(format!("{signing_input}.{sig_b64}"))
    }

    pub async fn send_payload(
        &self,
        environment: ApnsEnvironment,
        bundle_id: &str,
        push_token: &str,
        priority: u8,
        expiration_unix: i64,
        body: &serde_json::Value,
    ) -> ApnsDeliveryOutcome {
        let now_unix = Utc::now().timestamp();
        let jwt = match self.bearer_jwt(now_unix) {
            Ok(jwt) => jwt,
            Err(error) => {
                return ApnsDeliveryOutcome::Failed {
                    status: 0,
                    reason: error.to_string(),
                };
            }
        };
        let topic = format!("{bundle_id}.push-type.liveactivity");
        let url = format!("https://{}/3/device/{}", environment.host(), push_token);
        let response = self
            .http
            .post(&url)
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", topic)
            .header("apns-push-type", "liveactivity")
            .header("apns-priority", priority.to_string())
            .header("apns-expiration", expiration_unix.max(0).to_string())
            .json(body)
            .send()
            .await;

        let response = match response {
            Ok(resp) => resp,
            Err(error) => {
                return ApnsDeliveryOutcome::Failed {
                    status: 0,
                    reason: error.to_string(),
                };
            }
        };

        let status = response.status();
        if status == StatusCode::OK {
            return ApnsDeliveryOutcome::Delivered;
        }
        let reason = response
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|v| v.get("reason").and_then(serde_json::Value::as_str).map(str::to_owned))
            .unwrap_or_else(|| status.to_string());
        classify_apns_error(status.as_u16(), &reason)
    }
}

pub fn classify_apns_error(status: u16, reason: &str) -> ApnsDeliveryOutcome {
    if status == 410
        || matches!(
            reason,
            "BadDeviceToken" | "Unregistered" | "DeviceTokenNotForTopic"
        )
    {
        return ApnsDeliveryOutcome::InvalidToken(reason.to_owned());
    }
    if status == 403 && reason == "ExpiredProviderToken" {
        return ApnsDeliveryOutcome::ExpiredProviderToken;
    }
    ApnsDeliveryOutcome::Failed {
        status,
        reason: reason.to_owned(),
    }
}

pub fn decode_p8_pkcs8_der(raw: &str) -> Result<Vec<u8>, ApnsError> {
    let normalized = raw.trim().replace("\\n", "\n");
    let pem_text = if normalized.contains("BEGIN PRIVATE KEY") {
        normalized
    } else if let Ok(decoded_bytes) = BASE64_STANDARD.decode(
        normalized
            .chars()
            .filter(|ch| !ch.is_whitespace())
            .collect::<String>(),
    ) {
        if let Ok(as_utf8) = String::from_utf8(decoded_bytes.clone())
            && as_utf8.contains("BEGIN PRIVATE KEY")
        {
            as_utf8
        } else {
            return Ok(decoded_bytes);
        }
    } else {
        return Err(ApnsError::InvalidPrivateKey(
            "expected PEM or base64-encoded PKCS#8 .p8 key".to_owned(),
        ));
    };

    let b64_body: String = pem_text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("-----"))
        .collect();
    if b64_body.is_empty() {
        return Err(ApnsError::InvalidPrivateKey(
            "PEM private key body is empty".to_owned(),
        ));
    }
    BASE64_STANDARD
        .decode(b64_body)
        .map_err(|error| ApnsError::InvalidPrivateKey(error.to_string()))
}

pub fn apple_reference_timestamp(now: DateTime<Utc>) -> f64 {
    (now.timestamp() - APPLE_REFERENCE_DATE_OFFSET_SECONDS) as f64
}

pub fn build_start_payload(plan: &LiveActivityPlan, now: DateTime<Utc>) -> serde_json::Value {
    let ts = now.timestamp();
    let attributes = LiveActivityAttributes {
        session_key: plan.session_key.clone(),
        vehicle_name: plan.vehicle_name.clone(),
    };
    serde_json::json!({
        "aps": {
            "timestamp": ts,
            "event": "start",
            "attributes-type": APNS_ATTRIBUTES_TYPE,
            "attributes": attributes,
            "content-state": plan.state,
            "stale-date": ts + STALE_AFTER_SECONDS,
            "alert": {
                "title": plan.alert_title,
                "body": plan.alert_body,
            }
        }
    })
}

pub fn build_update_payload(
    state: &LiveActivityContentState,
    now: DateTime<Utc>,
) -> serde_json::Value {
    let ts = now.timestamp();
    serde_json::json!({
        "aps": {
            "timestamp": ts,
            "event": "update",
            "content-state": state,
            "stale-date": ts + STALE_AFTER_SECONDS,
        }
    })
}

pub fn build_end_payload(
    state: &LiveActivityContentState,
    now: DateTime<Utc>,
) -> serde_json::Value {
    let ts = now.timestamp();
    serde_json::json!({
        "aps": {
            "timestamp": ts,
            "event": "end",
            "dismissal-date": ts,
            "content-state": state,
        }
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct LiveVehicleObservation {
    pub vehicle_id: String,
    pub soc: Option<f64>,
    pub remaining_range: Option<f64>,
    pub remaining_actual_range: Option<f64>,
    pub charge_state: Option<i64>,
    pub charging_power_watts: Option<f64>,
    pub charge_limit_percent: Option<f64>,
    pub swapping: Option<bool>,
}

impl LiveVehicleObservation {
    pub fn from_status_payload(payload: &serde_json::Value) -> Option<Self> {
        let snapshot = snapshot_from_status(payload);
        let sample = charging_sample_from_status(payload);
        let swapping = swapping_state(payload);

        let data = payload.get("data");
        let status = data.and_then(|d| d.get("status")).or(data);
        let soc_status = status.and_then(|s| s.get("soc_status"));
        let vehicle_id = snapshot
            .as_ref()
            .map(|s| s.vehicle_id.clone())
            .or_else(|| sample.as_ref().map(|s| s.vehicle_id.clone()))
            .or_else(|| {
                data.and_then(|d| d.get("vehicle_id"))
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
            })?;

        let json_f64 = |obj: Option<&serde_json::Value>, key: &str| -> Option<f64> {
            let v = obj?.get(key)?;
            v.as_f64()
                .or_else(|| v.as_str().and_then(|s| s.trim().parse::<f64>().ok()))
                .filter(|n| n.is_finite())
        };
        let max_soc_enabled = soc_status
            .and_then(|s| s.get("max_soc_status").or_else(|| s.get("max_soc_enable")))
            .and_then(|v| {
                v.as_bool()
                    .or_else(|| v.as_i64().map(|n| n == 1))
                    .or_else(|| v.as_str().map(|s| s == "1" || s.eq_ignore_ascii_case("true")))
            });
        let charge_limit_percent = if max_soc_enabled == Some(false) {
            None
        } else {
            json_f64(soc_status, "max_soc").filter(|v| (1.0..=100.0).contains(v))
        };

        Some(Self {
            vehicle_id,
            soc: snapshot
                .as_ref()
                .and_then(|s| s.soc)
                .or_else(|| sample.as_ref().and_then(|s| s.soc))
                .or_else(|| json_f64(soc_status, "soc")),
            remaining_range: snapshot
                .as_ref()
                .and_then(|s| s.remaining_range)
                .or_else(|| json_f64(soc_status, "remaining_range")),
            remaining_actual_range: snapshot
                .as_ref()
                .and_then(|s| s.remaining_actual_range)
                .or_else(|| json_f64(soc_status, "remaining_actual_range")),
            charge_state: sample.as_ref().map(|s| s.charge_state).or_else(|| {
                soc_status
                    .and_then(|s| s.get("chrg_state"))
                    .and_then(serde_json::Value::as_i64)
            }),
            charging_power_watts: sample
                .as_ref()
                .and_then(|s| s.charging_power)
                .or_else(|| json_f64(soc_status, "chrg_pwr")),
            charge_limit_percent,
            swapping,
        })
    }

    pub fn from_snapshot(snapshot: &VehicleSnapshot) -> Self {
        Self {
            vehicle_id: snapshot.vehicle_id.clone(),
            soc: snapshot.soc,
            remaining_range: snapshot.remaining_range,
            remaining_actual_range: snapshot.remaining_actual_range,
            charge_state: None,
            charging_power_watts: None,
            charge_limit_percent: None,
            swapping: None,
        }
    }
}

pub fn plan_live_activity(
    observation: Option<&LiveVehicleObservation>,
    active_orders: &[ActiveServiceOrder],
    live_charging_energy_kwh: Option<f64>,
    vehicle_name: &str,
    now: DateTime<Utc>,
) -> Option<LiveActivityPlan> {
    let updated_at = apple_reference_timestamp(now);
    let remaining_range = observation
        .and_then(|s| s.remaining_actual_range.or(s.remaining_range))
        .filter(|v| v.is_finite() && *v >= 0.0);

    if let Some(order) = active_orders.first() {
        let title =
            non_empty(order.station_name.as_deref()).unwrap_or_else(|| "蔚来换电站".to_owned());
        let subtitle = non_empty(order.queue_status_text.as_deref())
            .or_else(|| non_empty(order.order_status_name.as_deref()))
            .unwrap_or_else(|| "换电排队中".to_owned());
        let alert_body = match (order.vehicles_ahead, order.estimated_wait_minutes) {
            (Some(0), _) => format!("{title} · 已到你换电"),
            (Some(ahead), Some(wait)) if wait > 0 => {
                format!("{title} · 前方 {ahead} 辆 · 预计约 {wait} 分钟")
            }
            (Some(ahead), _) => format!("{title} · 前方 {ahead} 辆"),
            _ => format!("{title} · {subtitle}"),
        };
        return Some(LiveActivityPlan {
            session_key: format!("swap:{}", order.order_no),
            vehicle_name: vehicle_name.to_owned(),
            alert_title: "换电排队已开始".to_owned(),
            alert_body,
            state: LiveActivityContentState {
                mode: LiveActivityMode::SwapQueue,
                title,
                subtitle: Some(subtitle),
                updated_at,
                order_no: Some(order.order_no.clone()),
                queue_number: order.queue_number.map(i64::from),
                vehicles_ahead: order.vehicles_ahead.map(i64::from),
                estimated_wait_minutes: order.estimated_wait_minutes.map(i64::from),
                state_of_charge: observation.and_then(|s| s.soc),
                charge_limit_percent: None,
                charging_power_kw: None,
                remaining_range_km: remaining_range,
                charged_energy_kwh: None,
            },
        });
    }

    if let Some(observation) = observation
        && observation.swapping == Some(true)
    {
        return Some(LiveActivityPlan {
            session_key: format!("swap-active:{}", observation.vehicle_id),
            vehicle_name: vehicle_name.to_owned(),
            alert_title: "车辆正在换电".to_owned(),
            alert_body: "换电站正在为车辆更换电池".to_owned(),
            state: LiveActivityContentState {
                mode: LiveActivityMode::SwapQueue,
                title: "正在换电".to_owned(),
                subtitle: Some("换电站正在为车辆更换电池".to_owned()),
                updated_at,
                order_no: None,
                queue_number: None,
                vehicles_ahead: Some(0),
                estimated_wait_minutes: None,
                state_of_charge: observation.soc,
                charge_limit_percent: None,
                charging_power_kw: None,
                remaining_range_km: remaining_range,
                charged_energy_kwh: None,
            },
        });
    }

    if let Some(observation) = observation
        && observation.charge_state == Some(1)
    {
        let power_kw = observation
            .charging_power_watts
            .filter(|w| w.is_finite() && *w > 0.0)
            .map(|w| (w / 100.0).round() / 10.0);
        let subtitle = match observation.charge_limit_percent.filter(|v| v.is_finite()) {
            Some(limit) => format!("充电中 · 上限 {}%", limit.round() as i64),
            None => "车辆充电中".to_owned(),
        };
        let soc_text = observation
            .soc
            .map(|s| format!("{}%", s.round() as i64))
            .unwrap_or_else(|| "--%".to_owned());
        let alert_body = match power_kw {
            Some(kw) => format!("{vehicle_name} 当前电量 {soc_text} · 功率 {kw:.1} kW"),
            None => format!("{vehicle_name} 当前电量 {soc_text}"),
        };
        return Some(LiveActivityPlan {
            session_key: format!("charging:{}", observation.vehicle_id),
            vehicle_name: vehicle_name.to_owned(),
            alert_title: "车辆已开始充电".to_owned(),
            alert_body,
            state: LiveActivityContentState {
                mode: LiveActivityMode::Charging,
                title: "正在充电".to_owned(),
                subtitle: Some(subtitle),
                updated_at,
                order_no: None,
                queue_number: None,
                vehicles_ahead: None,
                estimated_wait_minutes: None,
                state_of_charge: observation.soc,
                charge_limit_percent: observation.charge_limit_percent,
                charging_power_kw: power_kw,
                remaining_range_km: remaining_range,
                charged_energy_kwh: live_charging_energy_kwh
                    .filter(|v| v.is_finite() && *v > 0.0)
                    .map(|v| (v * 100.0).round() / 100.0),
            },
        });
    }

    None
}

fn non_empty(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

struct ActiveSimulation {
    id: String,
    running: bool,
    mode: LiveActivityMode,
    session_key: String,
    current_step: u32,
    total_steps: u32,
    interval_seconds: u64,
    started_at: DateTime<Utc>,
    last_event: Option<String>,
    last_delivered_count: usize,
    last_error: Option<String>,
    last_state: Option<LiveActivityContentState>,
    task_handle: Option<tokio::task::JoinHandle<()>>,
}

impl ActiveSimulation {
    fn snapshot(&self) -> LiveActivitySimulationSnapshot {
        LiveActivitySimulationSnapshot {
            running: self.running,
            simulation_id: Some(self.id.clone()),
            mode: Some(self.mode),
            session_key: Some(self.session_key.clone()),
            current_step: self.current_step,
            total_steps: self.total_steps,
            interval_seconds: self.interval_seconds,
            started_at: Some(self.started_at),
            last_event: self.last_event.clone(),
            last_delivered_count: self.last_delivered_count,
            last_error: self.last_error.clone(),
        }
    }
}

pub fn build_simulation_plan(
    mode: LiveActivityMode,
    session_key: &str,
    vehicle_name: &str,
    step: u32,
    total_steps: u32,
    now: DateTime<Utc>,
) -> LiveActivityPlan {
    let updated_at = apple_reference_timestamp(now);
    let total_display = total_steps.saturating_add(1);
    let step_display = step.saturating_add(1).min(total_display);
    match mode {
        LiveActivityMode::Charging => {
            let soc = (52.0 + (step as f64) * 5.0).min(90.0);
            let energy_kwh = ((2.4 + (step as f64) * 2.35) * 100.0).round() / 100.0;
            let power_kw = ((82.4 - (step as f64) * 6.8).max(28.0) * 10.0).round() / 10.0;
            let remaining_km = (236.0 + (step as f64) * 22.0).min(410.0);
            let subtitle = format!("模拟推送 {step_display}/{total_display} · 上限 90%");
            LiveActivityPlan {
                session_key: session_key.to_owned(),
                vehicle_name: vehicle_name.to_owned(),
                alert_title: "模拟推送：车辆已开始充电".to_owned(),
                alert_body: format!(
                    "{vehicle_name} 当前电量 {:.0}% · 功率 {power_kw:.1} kW · +{energy_kwh:.1} kWh",
                    soc
                ),
                state: LiveActivityContentState {
                    mode: LiveActivityMode::Charging,
                    title: "正在充电（模拟）".to_owned(),
                    subtitle: Some(subtitle),
                    updated_at,
                    order_no: None,
                    queue_number: None,
                    vehicles_ahead: None,
                    estimated_wait_minutes: None,
                    state_of_charge: Some(soc),
                    charge_limit_percent: Some(90.0),
                    charging_power_kw: Some(power_kw),
                    remaining_range_km: Some(remaining_km),
                    charged_energy_kwh: Some(energy_kwh),
                },
            }
        }
        LiveActivityMode::SwapQueue => {
            let initial_ahead = total_steps.min(4) as i64;
            let ahead = (initial_ahead - step as i64).max(0);
            let wait_minutes = ahead * 4;
            let subtitle = if ahead == 0 {
                format!("模拟推送 {step_display}/{total_display} · 已到你换电，请驶入车位")
            } else {
                format!(
                    "模拟推送 {step_display}/{total_display} · 前方 {ahead} 辆 · 约 {wait_minutes} 分钟"
                )
            };
            let alert_body = if ahead == 0 {
                "已到你换电，请准备驶入换电车位（模拟推送）".to_owned()
            } else {
                format!("前方 {ahead} 辆 · 预计等待 {wait_minutes} 分钟（模拟推送）")
            };
            LiveActivityPlan {
                session_key: session_key.to_owned(),
                vehicle_name: vehicle_name.to_owned(),
                alert_title: "模拟推送：换电排队中".to_owned(),
                alert_body,
                state: LiveActivityContentState {
                    mode: LiveActivityMode::SwapQueue,
                    title: "天津滨海万达换电站（模拟）".to_owned(),
                    subtitle: Some(subtitle),
                    updated_at,
                    order_no: Some("SIM-SWAP-001".to_owned()),
                    queue_number: Some(5),
                    vehicles_ahead: Some(ahead),
                    estimated_wait_minutes: Some(wait_minutes),
                    state_of_charge: Some(24.0),
                    charge_limit_percent: None,
                    charging_power_kw: None,
                    remaining_range_km: Some(104.0),
                    charged_energy_kwh: None,
                },
            }
        }
    }
}

#[derive(Default)]
struct CoordinatorState {
    active_session_key: Option<String>,
    active_mode: Option<LiveActivityMode>,
    last_pushed_state: Option<LiveActivityContentState>,
    last_update_sent_at: Option<Instant>,
    last_push_at: Option<DateTime<Utc>>,
    /// Maps `(device_id, session_key)` -> when `event: "start"` was last sent so we don't spam starts.
    start_sent_at: HashMap<(String, String), Instant>,
    simulation: Option<ActiveSimulation>,
}

pub struct LiveActivityCoordinator {
    store: Store,
    apns: Option<Arc<ApnsClient>>,
    state: Mutex<CoordinatorState>,
}

impl LiveActivityCoordinator {
    pub fn new(store: Store, apns: Option<Arc<ApnsClient>>) -> Self {
        Self {
            store,
            apns,
            state: Mutex::new(CoordinatorState::default()),
        }
    }

    pub fn is_apns_configured(&self) -> bool {
        self.apns.is_some()
    }

    pub fn default_bundle_id(&self) -> String {
        self.apns
            .as_ref()
            .map(|c| c.bundle_id.clone())
            .unwrap_or_else(|| "com.shuto.happyvalley".to_owned())
    }

    pub fn default_environment(&self) -> ApnsEnvironment {
        self.apns
            .as_ref()
            .map(|c| c.default_environment)
            .unwrap_or(ApnsEnvironment::Production)
    }

    pub async fn status(&self) -> Result<LiveActivityPushStatus, crate::store::StoreError> {
        let start_tokens = self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::PushToStart.as_str()))
            .await?;
        let update_tokens = self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::ActivityUpdate.as_str()))
            .await?;
        let guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        Ok(LiveActivityPushStatus {
            apns_configured: self.apns.is_some(),
            bundle_id: self.apns.as_ref().map(|c| c.bundle_id.clone()),
            default_environment: self.apns.as_ref().map(|c| c.default_environment),
            push_to_start_token_count: start_tokens.len(),
            activity_update_token_count: update_tokens.len(),
            active_session_key: guard.active_session_key.clone(),
            active_mode: guard.active_mode,
            last_push_at: guard.last_push_at,
            simulation: guard.simulation.as_ref().map(ActiveSimulation::snapshot),
        })
    }

    fn is_simulation_running(&self) -> bool {
        let guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.simulation.as_ref().is_some_and(|sim| sim.running)
    }

    fn is_simulation_current(&self, sim_id: &str) -> bool {
        let guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard
            .simulation
            .as_ref()
            .is_some_and(|sim| sim.running && sim.id == sim_id)
    }

    /// Starts an interactive backend APNs push simulation that immediately sends `event: "start"`
    /// to registered `push_to_start` tokens and then periodically pushes `event: "update"` frames
    /// to newly-registered `activity_update` tokens before cleanly sending `event: "end"`.
    pub async fn start_simulation(
        self: &Arc<Self>,
        req: LiveActivitySimulationRequest,
    ) -> Result<LiveActivitySimulationOutcome, SimulationError> {
        let Some(apns) = self.apns.as_ref() else {
            return Err(SimulationError::ApnsNotConfigured);
        };

        let interval_seconds = req.interval_seconds.clamp(3, 30);
        let total_steps = req.steps.clamp(1, 20);
        let target_device_id = req
            .device_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        let all_start_tokens = self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::PushToStart.as_str()))
            .await?;
        let all_update_tokens = self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::ActivityUpdate.as_str()))
            .await?;

        let filter_device = |token: &LiveActivityTokenRecord| {
            target_device_id
                .as_deref()
                .is_none_or(|id| token.device_id == id)
        };
        let start_tokens: Vec<LiveActivityTokenRecord> =
            all_start_tokens.into_iter().filter(filter_device).collect();
        let existing_update_tokens: Vec<LiveActivityTokenRecord> =
            all_update_tokens.into_iter().filter(filter_device).collect();

        if start_tokens.is_empty() && existing_update_tokens.is_empty() {
            return Err(SimulationError::NoRegisteredTokens);
        }

        // Abort any previous running simulation task before starting a fresh one.
        let previous_handle = {
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard
                .simulation
                .as_mut()
                .and_then(|sim| sim.task_handle.take())
        };
        if let Some(handle) = previous_handle {
            handle.abort();
        }

        let vehicle_name = self
            .store
            .latest_vehicle_profile()
            .await
            .ok()
            .flatten()
            .and_then(|p| p.display_name)
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| "我的蔚来".to_owned());

        let sim_id = Uuid::new_v4().simple().to_string();
        let mode_slug = match req.mode {
            LiveActivityMode::Charging => "charging",
            LiveActivityMode::SwapQueue => "swap",
        };
        let session_key = format!("sim:{mode_slug}:{}", &sim_id[..8]);
        let now = Utc::now();
        let initial_plan =
            build_simulation_plan(req.mode, &session_key, &vehicle_name, 0, total_steps, now);

        // End stale simulation update tokens if we have push-to-start tokens to cleanly start a new one.
        let mut update_tokens_targeted = 0usize;
        let mut update_delivered = 0usize;
        if !start_tokens.is_empty() {
            let end_body = build_end_payload(&initial_plan.state, now);
            for stale in &existing_update_tokens {
                if stale
                    .session_key
                    .as_deref()
                    .is_some_and(|key| key.starts_with("sim:"))
                {
                    let _ = self
                        .deliver_and_handle(apns, stale, "end", 10, 0, &end_body)
                        .await;
                    let _ = self.store.invalidate_live_activity_token(&stale.token_id).await;
                }
            }
        } else {
            // No push-to-start token available (e.g. local activity already open); drive updates directly.
            let update_body = build_update_payload(&initial_plan.state, now);
            let exp = now.timestamp() + 300;
            update_tokens_targeted = existing_update_tokens.len();
            for token in &existing_update_tokens {
                if self
                    .deliver_and_handle(apns, token, "update", 10, exp, &update_body)
                    .await
                {
                    update_delivered += 1;
                }
            }
        }

        let start_tokens_targeted = start_tokens.len();
        let mut start_delivered = 0usize;
        if !start_tokens.is_empty() {
            let start_body = build_start_payload(&initial_plan, now);
            let exp = now.timestamp() + 300;
            for token in &start_tokens {
                if self
                    .deliver_and_handle(apns, token, "start", 10, exp, &start_body)
                    .await
                {
                    start_delivered += 1;
                }
            }
        }

        let delivered_initial = start_delivered + update_delivered;
        let initial_event = if start_tokens_targeted > 0 {
            "start"
        } else {
            "update"
        };
        let initial_error = if delivered_initial == 0 {
            Some("初始 APNs 推送未被 Apple 接受，请检查服务端日志与设备沙盒/生产环境是否匹配".to_owned())
        } else {
            None
        };

        {
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard.active_session_key = Some(session_key.clone());
            guard.active_mode = Some(req.mode);
            guard.last_pushed_state = Some(initial_plan.state.clone());
            if delivered_initial > 0 {
                guard.last_push_at = Some(now);
            }
            guard.simulation = Some(ActiveSimulation {
                id: sim_id.clone(),
                running: true,
                mode: req.mode,
                session_key: session_key.clone(),
                current_step: 0,
                total_steps,
                interval_seconds,
                started_at: now,
                last_event: Some(initial_event.to_owned()),
                last_delivered_count: delivered_initial,
                last_error: initial_error,
                last_state: Some(initial_plan.state.clone()),
                task_handle: None,
            });
        }

        let coordinator = Arc::clone(self);
        let bg_sim_id = sim_id.clone();
        let bg_session_key = session_key.clone();
        let bg_mode = req.mode;
        let handle = tokio::spawn(async move {
            coordinator
                .run_simulation_loop(
                    bg_sim_id,
                    bg_mode,
                    bg_session_key,
                    vehicle_name,
                    total_steps,
                    interval_seconds,
                    target_device_id,
                )
                .await;
        });

        {
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(sim) = guard.simulation.as_mut()
                && sim.id == sim_id
            {
                sim.task_handle = Some(handle);
            }
        }

        Ok(LiveActivitySimulationOutcome {
            started: true,
            simulation_id: sim_id,
            mode: req.mode,
            session_key,
            interval_seconds,
            total_steps,
            start_tokens_targeted,
            start_delivered,
            update_tokens_targeted,
            update_delivered,
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_simulation_loop(
        self: Arc<Self>,
        sim_id: String,
        mode: LiveActivityMode,
        session_key: String,
        vehicle_name: String,
        total_steps: u32,
        interval_seconds: u64,
        target_device_id: Option<String>,
    ) {
        let Some(apns) = self.apns.as_ref() else {
            return;
        };

        for step in 1..=total_steps {
            tokio::time::sleep(Duration::from_secs(interval_seconds)).await;
            if !self.is_simulation_current(&sim_id) {
                return;
            }
            let now = Utc::now();
            let plan =
                build_simulation_plan(mode, &session_key, &vehicle_name, step, total_steps, now);
            let update_tokens = self
                .matching_simulation_update_tokens(&session_key, target_device_id.as_deref())
                .await;
            let update_body = build_update_payload(&plan.state, now);
            let exp = now.timestamp() + 300;
            let mut delivered = 0usize;
            for token in &update_tokens {
                if self
                    .deliver_and_handle(apns, token, "update", 10, exp, &update_body)
                    .await
                {
                    delivered += 1;
                }
            }
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(sim) = guard.simulation.as_mut()
                && sim.id == sim_id
            {
                sim.current_step = step;
                sim.last_event = Some("update".to_owned());
                sim.last_delivered_count = delivered;
                sim.last_state = Some(plan.state.clone());
                sim.last_error = if update_tokens.is_empty() {
                    Some("等待 iPhone 上报活动更新令牌（请确认 App 已收到实时活动并允许推送）".to_owned())
                } else if delivered == 0 {
                    Some("update 推送未投递成功，请查看后端日志".to_owned())
                } else {
                    None
                };
            }
            guard.last_pushed_state = Some(plan.state);
            if delivered > 0 {
                guard.last_push_at = Some(now);
            }
        }

        // Hold the final step briefly, then send APNs `event: "end"` so the test finishes cleanly.
        tokio::time::sleep(Duration::from_secs(interval_seconds)).await;
        if !self.is_simulation_current(&sim_id) {
            return;
        }
        let now = Utc::now();
        let final_state = {
            let guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard
                .simulation
                .as_ref()
                .and_then(|sim| sim.last_state.clone())
        }
        .unwrap_or_else(|| {
            build_simulation_plan(mode, &session_key, &vehicle_name, total_steps, total_steps, now)
                .state
        });
        let update_tokens = self
            .matching_simulation_update_tokens(&session_key, target_device_id.as_deref())
            .await;
        let end_body = build_end_payload(&final_state, now);
        let mut delivered = 0usize;
        for token in &update_tokens {
            if self
                .deliver_and_handle(apns, token, "end", 10, 0, &end_body)
                .await
            {
                delivered += 1;
            }
            let _ = self.store.invalidate_live_activity_token(&token.token_id).await;
        }
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(sim) = guard.simulation.as_mut()
            && sim.id == sim_id
        {
            sim.running = false;
            sim.last_event = Some("end".to_owned());
            sim.last_delivered_count = delivered;
            sim.task_handle = None;
        }
        guard.active_session_key = None;
        guard.active_mode = None;
        if delivered > 0 {
            guard.last_push_at = Some(now);
        }
    }

    async fn matching_simulation_update_tokens(
        &self,
        session_key: &str,
        target_device_id: Option<&str>,
    ) -> Vec<LiveActivityTokenRecord> {
        let all = match self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::ActivityUpdate.as_str()))
            .await
        {
            Ok(tokens) => tokens,
            Err(error) => {
                warn!(%error, "failed to load update tokens during simulation");
                return Vec::new();
            }
        };
        let filtered: Vec<LiveActivityTokenRecord> = all
            .into_iter()
            .filter(|t| target_device_id.is_none_or(|id| t.device_id == id))
            .collect();
        let exact: Vec<LiveActivityTokenRecord> = filtered
            .iter()
            .filter(|t| t.session_key.as_deref() == Some(session_key))
            .cloned()
            .collect();
        if !exact.is_empty() {
            exact
        } else {
            filtered
        }
    }

    pub async fn stop_simulation(
        &self,
        device_id: Option<&str>,
    ) -> Result<LiveActivitySimulationStopOutcome, SimulationError> {
        let (handle, session_key, last_state, was_running) = {
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(sim) = guard.simulation.as_mut() {
                let was_running = sim.running;
                sim.running = false;
                sim.last_event = Some("end".to_owned());
                let handle = sim.task_handle.take();
                let key = sim.session_key.clone();
                let state = sim.last_state.clone();
                guard.active_session_key = None;
                guard.active_mode = None;
                (handle, Some(key), state, was_running)
            } else {
                (None, None, None, false)
            }
        };
        if let Some(handle) = handle {
            handle.abort();
        }

        let Some(apns) = self.apns.as_ref() else {
            return Ok(LiveActivitySimulationStopOutcome {
                stopped: was_running,
                ended_tokens: 0,
                end_delivered: 0,
            });
        };

        let target_tokens = match session_key.as_deref() {
            Some(key) => self.matching_simulation_update_tokens(key, device_id).await,
            None => self
                .store
                .list_active_live_activity_tokens(Some(
                    LiveActivityTokenKind::ActivityUpdate.as_str(),
                ))
                .await?
                .into_iter()
                .filter(|t| {
                    device_id.is_none_or(|id| t.device_id == id)
                        && t.session_key
                            .as_deref()
                            .is_some_and(|key| key.starts_with("sim:"))
                })
                .collect(),
        };

        let now = Utc::now();
        let end_state = last_state.unwrap_or_else(|| LiveActivityContentState {
            mode: LiveActivityMode::Charging,
            title: "模拟推送已停止".to_owned(),
            subtitle: None,
            updated_at: apple_reference_timestamp(now),
            order_no: None,
            queue_number: None,
            vehicles_ahead: None,
            estimated_wait_minutes: None,
            state_of_charge: None,
            charge_limit_percent: None,
            charging_power_kw: None,
            remaining_range_km: None,
            charged_energy_kwh: None,
        });
        let end_body = build_end_payload(&end_state, now);
        let ended_tokens = target_tokens.len();
        let mut end_delivered = 0usize;
        for token in &target_tokens {
            if self
                .deliver_and_handle(apns, token, "end", 10, 0, &end_body)
                .await
            {
                end_delivered += 1;
            }
            let _ = self.store.invalidate_live_activity_token(&token.token_id).await;
        }
        if end_delivered > 0 {
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard.last_push_at = Some(now);
            if let Some(sim) = guard.simulation.as_mut() {
                sim.last_delivered_count = end_delivered;
            }
        }

        Ok(LiveActivitySimulationStopOutcome {
            stopped: was_running || ended_tokens > 0,
            ended_tokens,
            end_delivered,
        })
    }

    /// Evaluates current vehicle + active swap order state and delivers APNs `start` / `update` / `end`
    /// pushes to registered devices when needed.
    pub async fn sync_live_state(
        &self,
        vehicle_payload: Option<&serde_json::Value>,
        live_charging_energy_kwh: Option<f64>,
    ) {
        let Some(apns) = self.apns.as_ref() else {
            return;
        };
        if self.is_simulation_running() {
            debug!("skipping live vehicle APNs sync while debug push simulation is running");
            return;
        }

        let observation = match vehicle_payload.and_then(LiveVehicleObservation::from_status_payload) {
            Some(obs) => Some(obs),
            None => self
                .store
                .list_vehicle_snapshots(1)
                .await
                .ok()
                .and_then(|mut list| list.pop())
                .map(|s| LiveVehicleObservation::from_snapshot(&s)),
        };
        let active_orders = match self.store.list_active_service_orders(10).await {
            Ok(orders) => orders,
            Err(error) => {
                warn!(%error, "failed to load active service orders for live activity push");
                Vec::new()
            }
        };
        let energy_kwh = if live_charging_energy_kwh.is_some() {
            live_charging_energy_kwh
        } else if observation.as_ref().is_some_and(|s| s.charge_state == Some(1)) {
            self.store
                .latest_vehicle_charging_session_page(1)
                .await
                .ok()
                .and_then(|page| page.energy_kwh)
        } else {
            None
        };
        let vehicle_name = self
            .store
            .latest_vehicle_profile()
            .await
            .ok()
            .flatten()
            .and_then(|p| p.display_name)
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| "我的蔚来".to_owned());

        let now = Utc::now();
        let plan = plan_live_activity(
            observation.as_ref(),
            &active_orders,
            energy_kwh,
            &vehicle_name,
            now,
        );

        let update_tokens = match self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::ActivityUpdate.as_str()))
            .await
        {
            Ok(tokens) => tokens,
            Err(error) => {
                warn!(%error, "failed to list live activity update tokens");
                return;
            }
        };
        let start_tokens = match self
            .store
            .list_active_live_activity_tokens(Some(LiveActivityTokenKind::PushToStart.as_str()))
            .await
        {
            Ok(tokens) => tokens,
            Err(error) => {
                warn!(%error, "failed to list live activity push-to-start tokens");
                return;
            }
        };

        match plan {
            None => {
                let final_state = {
                    let mut guard = self
                        .state
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    let prev = guard.last_pushed_state.take();
                    guard.active_session_key = None;
                    guard.active_mode = None;
                    guard.last_update_sent_at = None;
                    guard.start_sent_at.clear();
                    prev
                };
                if update_tokens.is_empty() {
                    return;
                }
                let end_state = final_state.unwrap_or_else(|| LiveActivityContentState {
                    mode: LiveActivityMode::Charging,
                    title: "已结束".to_owned(),
                    subtitle: None,
                    updated_at: apple_reference_timestamp(now),
                    order_no: None,
                    queue_number: None,
                    vehicles_ahead: None,
                    estimated_wait_minutes: None,
                    state_of_charge: observation.as_ref().and_then(|s| s.soc),
                    charge_limit_percent: observation.as_ref().and_then(|s| s.charge_limit_percent),
                    charging_power_kw: None,
                    remaining_range_km: observation
                        .as_ref()
                        .and_then(|s| s.remaining_actual_range.or(s.remaining_range)),
                    charged_energy_kwh: energy_kwh,
                });
                let body = build_end_payload(&end_state, now);
                for token in &update_tokens {
                    self.deliver_and_handle(apns, token, "end", 10, 0, &body)
                        .await;
                    let _ = self.store.invalidate_live_activity_token(&token.token_id).await;
                }
            }
            Some(plan) => {
                // 1. End any active update tokens belonging to a DIFFERENT session.
                let mut matching_update_tokens = Vec::new();
                let mut stale_session_tokens = Vec::new();
                for token in update_tokens {
                    if token.session_key.as_deref() == Some(plan.session_key.as_str()) {
                        matching_update_tokens.push(token);
                    } else {
                        stale_session_tokens.push(token);
                    }
                }
                if !stale_session_tokens.is_empty() {
                    let end_body = build_end_payload(&plan.state, now);
                    for token in &stale_session_tokens {
                        self.deliver_and_handle(apns, token, "end", 10, 0, &end_body)
                            .await;
                        let _ = self.store.invalidate_live_activity_token(&token.token_id).await;
                    }
                }

                // 2. Push-to-Start for devices that have a push_to_start token but NO active update token for this session.
                let devices_with_active_activity: HashSet<&str> = matching_update_tokens
                    .iter()
                    .map(|t| t.device_id.as_str())
                    .collect();
                let start_candidates: Vec<LiveActivityTokenRecord> = {
                    let now_inst = Instant::now();
                    let mut guard = self
                        .state
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    guard
                        .start_sent_at
                        .retain(|_, sent_at| now_inst.saturating_duration_since(*sent_at) < START_COOLDOWN);
                    start_tokens
                        .into_iter()
                        .filter(|token| !devices_with_active_activity.contains(token.device_id.as_str()))
                        .filter(|token| {
                            let key = (token.device_id.clone(), plan.session_key.clone());
                            !guard.start_sent_at.contains_key(&key)
                        })
                        .collect()
                };

                if !start_candidates.is_empty() {
                    let start_body = build_start_payload(&plan, now);
                    let exp = now.timestamp() + 300;
                    for token in &start_candidates {
                        let delivered = self
                            .deliver_and_handle(apns, token, "start", 10, exp, &start_body)
                            .await;
                        if delivered {
                            let mut guard = self
                                .state
                                .lock()
                                .unwrap_or_else(|poisoned| poisoned.into_inner());
                            guard.start_sent_at.insert(
                                (token.device_id.clone(), plan.session_key.clone()),
                                Instant::now(),
                            );
                            guard.last_push_at = Some(now);
                        }
                    }
                }

                // 3. Send `event: "update"` to active activity update tokens when displayed state changed.
                let should_send_update = {
                    let guard = self
                        .state
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    let session_changed =
                        guard.active_session_key.as_deref() != Some(plan.session_key.as_str());
                    let content_changed = guard
                        .last_pushed_state
                        .as_ref()
                        .is_none_or(|prev| plan.state.differs_meaningfully_from(prev));
                    let throttle_ok = match plan.state.mode {
                        LiveActivityMode::SwapQueue => true,
                        LiveActivityMode::Charging => guard
                            .last_update_sent_at
                            .is_none_or(|t| t.elapsed() >= CHARGING_UPDATE_MIN_INTERVAL),
                    };
                    !matching_update_tokens.is_empty()
                        && (session_changed || (content_changed && throttle_ok))
                };

                if should_send_update {
                    let update_body = build_update_payload(&plan.state, now);
                    let exp = now.timestamp() + 300;
                    let mut any_delivered = false;
                    for token in &matching_update_tokens {
                        if self
                            .deliver_and_handle(apns, token, "update", 10, exp, &update_body)
                            .await
                        {
                            any_delivered = true;
                        }
                    }
                    if any_delivered {
                        let mut guard = self
                            .state
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        guard.active_session_key = Some(plan.session_key.clone());
                        guard.active_mode = Some(plan.state.mode);
                        guard.last_pushed_state = Some(plan.state.clone());
                        guard.last_update_sent_at = Some(Instant::now());
                        guard.last_push_at = Some(now);
                    }
                } else {
                    let mut guard = self
                        .state
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    guard.active_session_key = Some(plan.session_key.clone());
                    guard.active_mode = Some(plan.state.mode);
                    if guard.last_pushed_state.is_none() {
                        guard.last_pushed_state = Some(plan.state.clone());
                    }
                }
            }
        }
    }

    async fn deliver_and_handle(
        &self,
        apns: &ApnsClient,
        token: &LiveActivityTokenRecord,
        event: &str,
        priority: u8,
        expiration_unix: i64,
        body: &serde_json::Value,
    ) -> bool {
        let env = token.environment(apns.default_environment);
        let outcome = apns
            .send_payload(
                env,
                &token.bundle_id,
                &token.push_token,
                priority,
                expiration_unix,
                body,
            )
            .await;
        match outcome {
            ApnsDeliveryOutcome::Delivered => {
                let _ = self.store.mark_live_activity_token_pushed(&token.token_id).await;
                info!(
                    event,
                    env = env.as_str(),
                    token_kind = %token.token_kind,
                    "APNs live activity push delivered"
                );
                true
            }
            ApnsDeliveryOutcome::InvalidToken(reason) => {
                warn!(
                    event,
                    env = env.as_str(),
                    token_kind = %token.token_kind,
                    %reason,
                    "APNs rejected live activity token; marking invalidated"
                );
                let _ = self.store.invalidate_live_activity_token(&token.token_id).await;
                false
            }
            ApnsDeliveryOutcome::ExpiredProviderToken => {
                debug!("APNs provider JWT expired; clearing cache and retrying once");
                apns.invalidate_cached_jwt();
                matches!(
                    apns.send_payload(
                        env,
                        &token.bundle_id,
                        &token.push_token,
                        priority,
                        expiration_unix,
                        body,
                    )
                    .await,
                    ApnsDeliveryOutcome::Delivered
                )
            }
            ApnsDeliveryOutcome::Failed { status, reason } => {
                warn!(
                    event,
                    env = env.as_str(),
                    status,
                    %reason,
                    "APNs live activity push failed"
                );
                false
            }
        }
    }
}

pub fn validate_hex_token(token: &str) -> Result<String, &'static str> {
    let normalized = token.trim().to_ascii_lowercase();
    if !(32..=512).contains(&normalized.len())
        || normalized.len() % 2 != 0
        || !normalized.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("push_token must be an even-length hexadecimal string between 32 and 512 chars");
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use ring::signature::{ECDSA_P256_SHA256_FIXED, KeyPair, UnparsedPublicKey};

    fn test_pkcs8_pem() -> String {
        let rng = SystemRandom::new();
        let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let b64 = BASE64_STANDARD.encode(doc.as_ref());
        format!("-----BEGIN PRIVATE KEY-----\n{b64}\n-----END PRIVATE KEY-----\n")
    }

    #[test]
    fn apns_jwt_signs_valid_es256_token_and_caches_within_ttl() {
        let config = ApnsConfig {
            team_id: "A8686RABF4".to_owned(),
            key_id: "KEY1234567".to_owned(),
            private_key_pem: test_pkcs8_pem(),
            bundle_id: "com.shuto.happyvalley".to_owned(),
            default_environment: ApnsEnvironment::Production,
        };
        let client = ApnsClient::new(&config).unwrap();
        let jwt = client.bearer_jwt(1_760_000_000).unwrap();
        let cached = client.bearer_jwt(1_760_000_120).unwrap();
        assert_eq!(jwt, cached);

        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header: serde_json::Value =
            serde_json::from_slice(&BASE64_URL.decode(parts[0]).unwrap()).unwrap();
        let claims: serde_json::Value =
            serde_json::from_slice(&BASE64_URL.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "KEY1234567");
        assert_eq!(claims["iss"], "A8686RABF4");
        assert_eq!(claims["iat"], 1_760_000_000);

        let sig = BASE64_URL.decode(parts[2]).unwrap();
        assert_eq!(sig.len(), 64);
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let public_key = UnparsedPublicKey::new(
            &ECDSA_P256_SHA256_FIXED,
            client.key_pair.public_key().as_ref(),
        );
        public_key.verify(signing_input.as_bytes(), &sig).unwrap();
    }

    #[test]
    fn start_update_end_payloads_match_swift_activity_attributes_contract() {
        let now = Utc.with_ymd_and_hms(2026, 11, 27, 8, 0, 0).unwrap();
        let observation = LiveVehicleObservation {
            vehicle_id: "veh-et5t".to_owned(),
            soc: Some(68.0),
            remaining_range: Some(340.0),
            remaining_actual_range: Some(295.0),
            charge_state: Some(1),
            charging_power_watts: Some(76_500.0),
            charge_limit_percent: Some(90.0),
            swapping: Some(false),
        };
        let plan =
            plan_live_activity(Some(&observation), &[], Some(18.42), "我的 ET5T", now).unwrap();
        assert_eq!(plan.session_key, "charging:veh-et5t");
        assert_eq!(plan.state.mode, LiveActivityMode::Charging);
        assert_eq!(plan.state.charging_power_kw, Some(76.5));
        assert_eq!(plan.state.charged_energy_kwh, Some(18.42));

        let start = build_start_payload(&plan, now);
        assert_eq!(start["aps"]["event"], "start");
        assert_eq!(start["aps"]["attributes-type"], "NIOVehicleLiveActivityAttributes");
        assert_eq!(start["aps"]["attributes"]["sessionKey"], "charging:veh-et5t");
        assert_eq!(start["aps"]["attributes"]["vehicleName"], "我的 ET5T");
        assert_eq!(start["aps"]["content-state"]["mode"], "charging");
        assert_eq!(start["aps"]["content-state"]["chargingPowerKW"], 76.5);
        assert_eq!(start["aps"]["content-state"]["chargedEnergyKWh"], 18.42);
        assert_eq!(
            start["aps"]["content-state"]["updatedAt"],
            (now.timestamp() - APPLE_REFERENCE_DATE_OFFSET_SECONDS) as f64
        );

        let update = build_update_payload(&plan.state, now);
        assert_eq!(update["aps"]["event"], "update");
        assert_eq!(update["aps"]["content-state"]["chargedEnergyKWh"], 18.42);

        let end = build_end_payload(&plan.state, now);
        assert_eq!(end["aps"]["event"], "end");
        assert_eq!(end["aps"]["dismissal-date"], now.timestamp());
    }

    #[test]
    fn content_state_diff_detects_continuous_charging_energy_increments() {
        let now = Utc::now();
        let base = LiveActivityContentState {
            mode: LiveActivityMode::Charging,
            title: "正在充电".to_owned(),
            subtitle: Some("充电中 · 上限 90%".to_owned()),
            updated_at: apple_reference_timestamp(now),
            order_no: None,
            queue_number: None,
            vehicles_ahead: None,
            estimated_wait_minutes: None,
            state_of_charge: Some(68.0),
            charge_limit_percent: Some(90.0),
            charging_power_kw: Some(60.0),
            remaining_range_km: Some(295.0),
            charged_energy_kwh: Some(12.1),
        };
        let mut same = base.clone();
        same.updated_at += 15.0;
        assert!(!same.differs_meaningfully_from(&base));

        let mut energy_up = base.clone();
        energy_up.charged_energy_kwh = Some(12.25);
        assert!(energy_up.differs_meaningfully_from(&base));
    }

    #[test]
    fn apns_error_classification_invalidates_dead_tokens() {
        assert_eq!(
            classify_apns_error(410, "Unregistered"),
            ApnsDeliveryOutcome::InvalidToken("Unregistered".to_owned())
        );
        assert_eq!(
            classify_apns_error(400, "BadDeviceToken"),
            ApnsDeliveryOutcome::InvalidToken("BadDeviceToken".to_owned())
        );
        assert_eq!(
            classify_apns_error(403, "ExpiredProviderToken"),
            ApnsDeliveryOutcome::ExpiredProviderToken
        );
    }

    #[test]
    fn hex_token_validation_accepts_apns_hex_and_rejects_garbage() {
        let valid = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
        assert_eq!(validate_hex_token(valid).unwrap(), valid);
        assert!(validate_hex_token("not-hex").is_err());
        assert!(validate_hex_token("abcd").is_err());
    }

    #[test]
    fn simulation_plans_advance_charging_energy_and_swap_countdown() {
        let now = Utc::now();
        let c0 = build_simulation_plan(
            LiveActivityMode::Charging,
            "sim:charging:12345678",
            "我的 ET5T",
            0,
            5,
            now,
        );
        let c2 = build_simulation_plan(
            LiveActivityMode::Charging,
            "sim:charging:12345678",
            "我的 ET5T",
            2,
            5,
            now,
        );
        assert_eq!(c0.state.mode, LiveActivityMode::Charging);
        assert!(c2.state.state_of_charge.unwrap() > c0.state.state_of_charge.unwrap());
        assert!(c2.state.charged_energy_kwh.unwrap() > c0.state.charged_energy_kwh.unwrap());
        assert!(c2.state.differs_meaningfully_from(&c0.state));

        let s0 = build_simulation_plan(
            LiveActivityMode::SwapQueue,
            "sim:swap:12345678",
            "我的 ET5T",
            0,
            4,
            now,
        );
        let s4 = build_simulation_plan(
            LiveActivityMode::SwapQueue,
            "sim:swap:12345678",
            "我的 ET5T",
            4,
            4,
            now,
        );
        assert_eq!(s0.state.vehicles_ahead, Some(4));
        assert_eq!(s4.state.vehicles_ahead, Some(0));
        assert_eq!(s4.state.estimated_wait_minutes, Some(0));
    }
}
