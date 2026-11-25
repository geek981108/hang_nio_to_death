//! Plan and send navigation routes / destinations to the bound NIO vehicle.
//!
//! Calls the NIO CN `PEService` endpoints on `https://app.nio.com`:
//! - `GET /app/api/pe/v1/route/send-vehicle/switch`
//! - `POST /app/api/pe/v6/power/energymap-multi`
//! - `POST /app/api/pe/v1/route/send-vehicle`
//!
//! Safety guarantees:
//! - Target `vehicle_id` always comes from the tenant's configured `VehicleConfig`,
//!   never from caller input.
//! - Each send or popup confirmation performs at most one upstream `send-vehicle`
//!   POST and never retries automatically on timeout or ambiguous transport errors.
//! - Pending popup confirmation contexts are bound in-memory to the tenant's
//!   `vehicle_id`, original route payload, and server-returned button actions with
//!   a short TTL, and are atomically consumed before sending.
//! - Logs never include coordinates, addresses, or credentials.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use chrono::Utc;
use md5::{Digest as _, Md5};
use reqwest::{Client, StatusCode, redirect::Policy};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;
use uuid::Uuid;

use crate::{config::VehicleConfig, provider::decrypt_payload, route_estimate::valid_coordinate};

const APP_ORIGIN: &str = "https://app.nio.com";
const SWITCH_PATH: &str = "/app/api/pe/v1/route/send-vehicle/switch";
const ROUTE_PLAN_PATH: &str = "/app/api/pe/v6/power/energymap-multi";
const SEND_PATH: &str = "/app/api/pe/v1/route/send-vehicle";
const SIGNING_SALT: &str = "2bc9b00fdcf8f7ded6d77afdd7077e79";
const CONFIRMATION_TTL: Duration = Duration::from_secs(300);
const MAX_PENDING_CONFIRMATIONS: usize = 16;
const MAX_POIS: usize = 20;
const CLONE_RESOURCE_SUFFIX: &str = "_clone";

#[derive(Clone)]
pub struct NioSendRouteClient {
    profile: Arc<VehicleConfig>,
    http: Client,
    origin: String,
    pending: Arc<Mutex<HashMap<String, PendingConfirmation>>>,
}

#[derive(Clone, Debug)]
struct PendingConfirmation {
    vehicle_id: String,
    request: UpstreamSendRouteRequest,
    planned_route: Option<PlannedRouteSummary>,
    allowed_actions: Vec<i32>,
    expires_at: Instant,
}

#[derive(Clone, Debug, Default)]
pub struct RouteVehicleContext {
    pub position: Option<(f64, f64)>,
    pub model_type: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum SendRouteError {
    #[error("invalid send-route input: {0}")]
    InvalidInput(&'static str),
    #[error("current vehicle position is unavailable for route planning")]
    VehiclePositionUnavailable,
    #[error("route planning returned no usable route: {0}")]
    RoutePlanEmpty(String),
    #[error("failed to construct NIO send-route request")]
    InvalidUrl,
    #[error("send-route request timed out or connection dropped; vehicle receipt is unknown")]
    ResultUnknown(#[source] reqwest::Error),
    #[error("NIO send-route request failed")]
    Request(#[source] reqwest::Error),
    #[error("NIO send-route endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("NIO send-route endpoint returned invalid JSON")]
    InvalidJson,
    #[error("NIO send-route response was invalid")]
    InvalidResponse,
    #[error("NIO send-route request was rejected ({code}): {message}")]
    Rejected {
        code: String,
        message: String,
        request_id: Option<String>,
    },
    #[error("confirmation token is invalid or has expired")]
    ConfirmationExpired,
    #[error("bound vehicle changed before confirmation completed")]
    VehicleChanged,
    #[error("confirmation action is not permitted for this popup")]
    InvalidAction,
}

/// Exact serialized values of `RoutePlan.RouteResource.NodeType`.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RouteNodeType {
    Orig,
    Dest,
    Waypoint,
    Resource,
    Candidate,
    WaypointCandidate,
    OrigCandidate,
    DestCandidate,
}

impl RouteNodeType {
    pub fn is_candidate(self) -> bool {
        matches!(
            self,
            Self::Candidate | Self::WaypointCandidate | Self::OrigCandidate | Self::DestCandidate
        )
    }

    pub fn is_poi(self) -> bool {
        matches!(self, Self::Orig | Self::Waypoint | Self::Dest)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SendRoutePoiInput {
    pub name: String,
    #[serde(default)]
    pub address: Option<String>,
    pub latitude: f64,
    pub longitude: f64,
    #[serde(default)]
    pub resource_id: Option<String>,
    #[serde(default)]
    pub clone_latitude: Option<f64>,
    #[serde(default)]
    pub clone_longitude: Option<f64>,
    #[serde(default)]
    pub next_point_distance: Option<i32>,
    #[serde(default)]
    pub station_type: Option<RouteNodeType>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SendRouteDriverInput {
    #[serde(default)]
    pub route_driver_duration: Option<i32>,
    #[serde(default)]
    pub charge_times: Option<i32>,
    #[serde(default)]
    pub route_distance: Option<i32>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlanRouteInput {
    pub poi_list: Vec<SendRoutePoiInput>,
    /// Defaults to `true`. When `false`, the backend still runs NIO
    /// `energymap-multi` to obtain an official `route_id` and route summary,
    /// but strips NIO's auto-inserted `candidate` charging/swap stations from
    /// the returned `poi_list` and summary.
    #[serde(default)]
    pub include_charge_stops: Option<bool>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SendRouteInput {
    pub poi_list: Vec<SendRoutePoiInput>,
    #[serde(default)]
    pub driver: Option<SendRouteDriverInput>,
    #[serde(default)]
    pub route_id: Option<String>,
    /// Legacy alias for `include_charge_stops`: NIO `send-vehicle` strictly
    /// requires a valid `route_id` from `energymap-multi`, so when `route_id`
    /// is absent the backend always runs `energymap-multi` first; setting
    /// `auto_plan: false` or `include_charge_stops: false` keeps the generated
    /// `route_id` while stripping auto-inserted `candidate` energy stops.
    #[serde(default)]
    pub auto_plan: Option<bool>,
    #[serde(default)]
    pub include_charge_stops: Option<bool>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfirmSendRouteInput {
    pub confirmation_token: String,
    pub btn_action: i32,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct SendRouteSwitchOutcome {
    pub expose_send_vehicle_button: Option<bool>,
    pub enabled: bool,
    pub request_id: Option<String>,
    pub server_time: Option<i64>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct PlannedRouteStation {
    pub name: String,
    pub address: Option<String>,
    pub resource_id: Option<String>,
    pub resource_type: Option<String>,
    pub station_type: RouteNodeType,
    pub duration_desc: Option<String>,
    pub distance_desc: Option<String>,
    pub remain_soc: Option<i32>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct PlannedRouteStep {
    pub title: String,
    pub subtitle: Option<String>,
    pub distance_desc: Option<String>,
    pub remain_soc: Option<i32>,
    pub resource_id: Option<String>,
    pub resource_type: Option<String>,
    pub is_poi: bool,
    pub is_power_swap_clone: bool,
    pub tags: Vec<String>,
    pub risk_msg: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct PlannedRouteOption {
    pub route_id: Option<String>,
    pub tag_desc: Option<String>,
    pub drive_distance_desc: Option<String>,
    pub drive_duration_desc: Option<String>,
    pub plan_duration_desc: Option<String>,
    pub charge_desc: Option<String>,
    pub charge_duration: Option<i32>,
    pub charge_duration_desc: Option<String>,
    pub toll_charge_desc: Option<String>,
    pub has_risk: Option<bool>,
    pub driver: Option<SendRouteDriverInput>,
    pub poi_list: Vec<SendRoutePoiInput>,
    pub charge_stations: Vec<PlannedRouteStation>,
    pub steps: Vec<PlannedRouteStep>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct PlanRouteOutcome {
    pub request_id: Option<String>,
    pub server_time: Option<i64>,
    pub toast_msg: Option<String>,
    pub plans: Vec<PlannedRouteOption>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct PlannedRouteSummary {
    pub route_id: Option<String>,
    pub tag_desc: Option<String>,
    pub drive_distance_desc: Option<String>,
    pub plan_duration_desc: Option<String>,
    pub charge_desc: Option<String>,
    pub charge_duration_desc: Option<String>,
    pub charge_times: Option<i32>,
    pub charge_station_names: Vec<String>,
    pub poi_count: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct SendRoutePopup {
    pub content: Option<String>,
    pub left_btn_text: Option<String>,
    pub left_btn_action: Option<i32>,
    pub right_btn_text: Option<String>,
    pub right_btn_action: Option<i32>,
}

impl SendRoutePopup {
    fn actionable_values(&self) -> Vec<i32> {
        let mut actions = Vec::new();
        if let Some(action) = self.left_btn_action {
            actions.push(action);
        }
        if let Some(action) = self.right_btn_action
            && !actions.contains(&action)
        {
            actions.push(action);
        }
        actions
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct SendRouteOutcome {
    pub status: &'static str,
    pub result_code: String,
    pub request_id: Option<String>,
    pub server_time: Option<i64>,
    pub toast_msg: Option<String>,
    pub popup_message: Option<SendRoutePopup>,
    pub confirmation_token: Option<String>,
    pub confirmation_expires_in_seconds: Option<u64>,
    pub planned_route: Option<PlannedRouteSummary>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamRoutePlanRequest {
    points: Vec<UpstreamRoutePlanPoint>,
    vehicle: UpstreamRoutePlanVehicle,
    filter: HashMap<String, String>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamRoutePlanPoint {
    location: String,
    poi_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    poi_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    resource_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sub_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    swap_use_clone: Option<bool>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamRoutePlanVehicle {
    vehicle_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    restriction_switch: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct UpstreamRoutePlanData {
    #[serde(default)]
    plans: Option<Vec<UpstreamPlan>>,
    #[serde(default)]
    toast_msg: Option<String>,
    #[serde(default)]
    fail_button_info: Option<UpstreamFailButtonInfo>,
}

#[derive(Debug, Deserialize)]
struct UpstreamFailButtonInfo {
    #[serde(default)]
    desc: Option<String>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    title: Option<String>,
}

impl UpstreamFailButtonInfo {
    fn best_message(&self) -> Option<String> {
        self.desc
            .as_deref()
            .or(self.message.as_deref())
            .or(self.title.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    }
}

#[derive(Debug, Deserialize)]
struct UpstreamPlan {
    #[serde(default)]
    route_id: Option<String>,
    #[serde(default)]
    summary: Option<UpstreamPlanSummary>,
    #[serde(default)]
    resources_and_points: Option<Vec<UpstreamRouteResource>>,
    #[serde(default)]
    card_steps: Option<Vec<UpstreamCardStep>>,
}

#[derive(Debug, Deserialize)]
struct UpstreamCardStep {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    subtitle: Option<String>,
    #[serde(default)]
    resource_id: Option<String>,
    #[serde(default)]
    resource_type: Option<String>,
    #[serde(default)]
    power_swap_clone: Option<bool>,
    #[serde(default)]
    remain_soc: Option<f64>,
    #[serde(default)]
    distance_desc: Option<String>,
    #[serde(default)]
    risk_msg: Option<String>,
    #[serde(default)]
    terminal_power_risk_msg: Option<String>,
    #[serde(default)]
    tag_list_v2: Option<Vec<UpstreamCardStepTag>>,
    #[serde(default)]
    poi: bool,
}

#[derive(Debug, Deserialize)]
struct UpstreamCardStepTag {
    #[serde(default)]
    tag_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UpstreamPlanSummary {
    #[serde(default)]
    tag_desc: Option<String>,
    #[serde(default)]
    brief_tag_desc: Option<String>,
    #[serde(default)]
    drive_distance: Option<f64>,
    #[serde(default)]
    drive_distance_desc: Option<String>,
    #[serde(default)]
    plan_driver_duration: Option<i32>,
    #[serde(default)]
    plan_drive_duration_desc: Option<String>,
    #[serde(default)]
    plan_duration_desc: Option<String>,
    #[serde(default)]
    plan_charge_count: Option<i32>,
    #[serde(default)]
    plan_charge_desc: Option<String>,
    #[serde(default)]
    plan_charge_duration: Option<i32>,
    #[serde(default)]
    plan_charge_duration_desc: Option<String>,
    #[serde(default)]
    toll_charge_desc: Option<String>,
    #[serde(default)]
    has_risk: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct UpstreamRouteResource {
    #[serde(default)]
    station_type: Option<RouteNodeType>,
    #[serde(default)]
    location: Option<String>,
    #[serde(default)]
    poi_name: Option<String>,
    #[serde(default)]
    poi_address: Option<String>,
    #[serde(default)]
    need_send_vehicle: Option<bool>,
    #[serde(default)]
    next_candidate_point_distance: Option<i32>,
    #[serde(default)]
    pin_info: Option<UpstreamMapPin>,
    #[serde(default)]
    resource: Option<UpstreamResource>,
}

#[derive(Debug, Deserialize)]
struct UpstreamMapPin {
    #[serde(default)]
    pin_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UpstreamResource {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    address: Option<String>,
    #[serde(default)]
    location: Option<String>,
    #[serde(default, rename = "type")]
    resource_type: Option<String>,
    #[serde(default)]
    swap_use_clone: Option<bool>,
    #[serde(default)]
    swap_clone: Option<UpstreamSwapClone>,
}

#[derive(Debug, Deserialize)]
struct UpstreamSwapClone {
    #[serde(default)]
    clone_name: Option<String>,
    #[serde(default)]
    address: Option<String>,
    #[serde(default)]
    location: Option<String>,
}

struct ConvertedPlan {
    upstream_request: UpstreamSendRouteRequest,
    option: PlannedRouteOption,
    summary: PlannedRouteSummary,
}

struct ParsedRoutePlan {
    request_id: Option<String>,
    server_time: Option<i64>,
    toast_msg: Option<String>,
    plans: Vec<ConvertedPlan>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamSendRouteRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    btn_action: Option<i32>,
    poi_list: Vec<UpstreamRoutePoi>,
    vehicle: UpstreamVehicle,
    #[serde(skip_serializing_if = "Option::is_none")]
    driver: Option<UpstreamDriver>,
    #[serde(skip_serializing_if = "Option::is_none")]
    route_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamRoutePoi {
    location: String,
    name: String,
    address: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    resource_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    clone_location: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    next_point_distance: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    station_type: Option<RouteNodeType>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamVehicle {
    vehicle_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    location: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
struct UpstreamDriver {
    #[serde(skip_serializing_if = "Option::is_none")]
    route_driver_duration: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    charge_times: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    route_distance: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct Envelope {
    result_code: String,
    #[serde(default)]
    data: Value,
    #[serde(default)]
    encrypt_type: Option<u64>,
    request_id: Option<String>,
    server_time: Option<i64>,
    display_msg: Option<String>,
    debug_msg: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SwitchData {
    #[serde(default)]
    expose_send_vehicle_button: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct SendResponseData {
    #[serde(default)]
    popup_message: Option<SendRoutePopup>,
    #[serde(default)]
    toast_msg: Option<String>,
}

impl NioSendRouteClient {
    pub fn new(profile: VehicleConfig) -> Result<Self, SendRouteError> {
        Self::with_origin(profile, APP_ORIGIN)
    }

    pub(crate) fn with_origin(
        profile: VehicleConfig,
        origin: impl Into<String>,
    ) -> Result<Self, SendRouteError> {
        let http = Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(Policy::none())
            .user_agent(format!("NextevCar/{}", profile.app_version))
            .build()
            .map_err(|error| SendRouteError::Request(error.without_url()))?;
        Ok(Self {
            profile: Arc::new(profile),
            http,
            origin: origin.into(),
            pending: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    pub async fn fetch_switch(&self) -> Result<SendRouteSwitchOutcome, SendRouteError> {
        let mut query = common_query(&self.profile, Utc::now().timestamp());
        query.push(("vehicle_id".to_owned(), self.profile.vehicle_id.clone()));
        let bearer_token = self.profile.current_bearer_token();
        let url = signed_get_url(&self.origin, SWITCH_PATH, &query, &bearer_token)?;
        let response = self
            .http
            .get(url)
            .bearer_auth(&bearer_token)
            .header("accept", "application/json,text/json,text/plain")
            .header("accept-encoding", "identity")
            .send()
            .await
            .map_err(|error| SendRouteError::Request(error.without_url()))?;
        let envelope = read_envelope(response).await?;
        let request_id = envelope.request_id.clone();
        let server_time = envelope.server_time;
        let data_value = decode_data(&envelope)?;
        let parsed: SwitchData = if data_value.is_null() {
            SwitchData {
                expose_send_vehicle_button: None,
            }
        } else {
            serde_json::from_value(data_value).map_err(|_| SendRouteError::InvalidResponse)?
        };
        Ok(SendRouteSwitchOutcome {
            expose_send_vehicle_button: parsed.expose_send_vehicle_button,
            enabled: parsed.expose_send_vehicle_button == Some(true),
            request_id,
            server_time,
        })
    }

    /// Plans a route via NIO `POST /app/api/pe/v6/power/energymap-multi` using the
    /// vehicle's current position (unless an explicit `orig` point is provided) and
    /// returns ready-to-send route options with official `route_id`, summary, and
    /// optional along-the-way recommended swap/charge stations. Read-only.
    pub async fn plan_route(
        &self,
        input: PlanRouteInput,
        vehicle_ctx: RouteVehicleContext,
    ) -> Result<PlanRouteOutcome, SendRouteError> {
        let include_charge_stops = input.include_charge_stops.unwrap_or(true);
        let parsed = self
            .fetch_converted_plans(&input.poi_list, &vehicle_ctx, include_charge_stops)
            .await?;
        Ok(PlanRouteOutcome {
            request_id: parsed.request_id,
            server_time: parsed.server_time,
            toast_msg: parsed.toast_msg,
            plans: parsed.plans.into_iter().map(|item| item.option).collect(),
        })
    }

    /// Sends one explicit route payload to the bound vehicle. Never auto-retries
    /// the upstream `send-vehicle` POST.
    ///
    /// Upstream NIO `send-vehicle` requires a valid `route_id` generated by
    /// `energymap-multi`. Whenever `route_id` is omitted, the backend first
    /// runs `POST /app/api/pe/v6/power/energymap-multi` to obtain an official
    /// `route_id` and route summary. When `include_charge_stops` (or legacy
    /// `auto_plan`) is `Some(false)`, auto-inserted along-the-way `candidate`
    /// charging/swap stops are stripped before sending while preserving the
    /// generated `route_id` and user-chosen waypoints.
    pub async fn send_route(
        &self,
        input: SendRouteInput,
        vehicle_ctx: RouteVehicleContext,
    ) -> Result<SendRouteOutcome, SendRouteError> {
        let has_route_id = input
            .route_id
            .as_deref()
            .is_some_and(|raw| !raw.trim().is_empty());
        if !has_route_id {
            let include_charge_stops = input
                .include_charge_stops
                .or(input.auto_plan)
                .unwrap_or(true);
            let parsed = self
                .fetch_converted_plans(&input.poi_list, &vehicle_ctx, include_charge_stops)
                .await?;
            let primary = parsed.plans.into_iter().next().ok_or_else(|| {
                SendRouteError::RoutePlanEmpty("未找到可发送到车机的规划路线".to_owned())
            })?;
            return self
                .dispatch_once(primary.upstream_request, Some(primary.summary))
                .await;
        }
        let upstream =
            build_upstream_request(&self.profile.vehicle_id, input, vehicle_ctx.position)?;
        self.dispatch_once(upstream, None).await
    }

    /// Replays the exact bound route with the user's selected popup `btn_action`.
    /// Consumes the confirmation token before performing the upstream POST so it
    /// cannot be replayed or applied to a different vehicle/route.
    pub async fn confirm_send_route(
        &self,
        input: ConfirmSendRouteInput,
    ) -> Result<SendRouteOutcome, SendRouteError> {
        let (upstream, planned_route) = self.consume_pending(&input)?;
        self.dispatch_once(upstream, planned_route).await
    }

    async fn fetch_converted_plans(
        &self,
        poi_list: &[SendRoutePoiInput],
        vehicle_ctx: &RouteVehicleContext,
        include_charge_stops: bool,
    ) -> Result<ParsedRoutePlan, SendRouteError> {
        let plan_req = build_route_plan_request(&self.profile.vehicle_id, poi_list, vehicle_ctx)?;
        let body = serde_json::to_string(&plan_req).map_err(|_| SendRouteError::InvalidResponse)?;
        let query = common_query(&self.profile, Utc::now().timestamp());
        let bearer_token = self.profile.current_bearer_token();
        let url = signed_post_url(&self.origin, ROUTE_PLAN_PATH, &query, &body, &bearer_token)?;
        let response = self
            .http
            .post(url)
            .bearer_auth(&bearer_token)
            .header("accept", "application/json,text/json,text/plain")
            .header("accept-encoding", "identity")
            .header("content-type", "application/json")
            .header(
                "x-request-session-id",
                Uuid::new_v4().to_string().to_uppercase(),
            )
            .body(body)
            .send()
            .await
            .map_err(|error| SendRouteError::Request(error.without_url()))?;
        let envelope = read_envelope(response).await?;
        parse_route_plan_envelope(
            &self.profile.vehicle_id,
            vehicle_ctx.position,
            envelope,
            include_charge_stops,
        )
    }

    async fn dispatch_once(
        &self,
        upstream: UpstreamSendRouteRequest,
        planned_route: Option<PlannedRouteSummary>,
    ) -> Result<SendRouteOutcome, SendRouteError> {
        let body = serde_json::to_string(&upstream).map_err(|_| SendRouteError::InvalidResponse)?;
        let query = common_query(&self.profile, Utc::now().timestamp());
        let bearer_token = self.profile.current_bearer_token();
        let url = signed_post_url(&self.origin, SEND_PATH, &query, &body, &bearer_token)?;
        let response = self
            .http
            .post(url)
            .bearer_auth(&bearer_token)
            .header("accept", "application/json,text/json,text/plain")
            .header("accept-encoding", "identity")
            .header("content-type", "application/json")
            .header(
                "x-request-session-id",
                Uuid::new_v4().to_string().to_uppercase(),
            )
            .body(body)
            .send()
            .await
            .map_err(|error| {
                let sanitized = error.without_url();
                if sanitized.is_timeout() || sanitized.is_request() || sanitized.is_body() {
                    SendRouteError::ResultUnknown(sanitized)
                } else {
                    SendRouteError::Request(sanitized)
                }
            })?;
        let envelope = read_envelope(response).await?;
        self.process_send_envelope(upstream, planned_route, envelope)
    }

    fn consume_pending(
        &self,
        input: &ConfirmSendRouteInput,
    ) -> Result<(UpstreamSendRouteRequest, Option<PlannedRouteSummary>), SendRouteError> {
        let token = input.confirmation_token.trim();
        if token.is_empty() || token.len() > 128 {
            return Err(SendRouteError::ConfirmationExpired);
        }
        let pending = {
            let mut map = self
                .pending
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let now = Instant::now();
            map.retain(|_, entry| entry.expires_at > now);
            let Some(entry) = map.get(token) else {
                return Err(SendRouteError::ConfirmationExpired);
            };
            if entry.vehicle_id != self.profile.vehicle_id {
                map.remove(token);
                return Err(SendRouteError::VehicleChanged);
            }
            if !entry.allowed_actions.contains(&input.btn_action) {
                return Err(SendRouteError::InvalidAction);
            }
            map.remove(token)
                .ok_or(SendRouteError::ConfirmationExpired)?
        };
        let mut upstream = pending.request;
        upstream.btn_action = Some(input.btn_action);
        Ok((upstream, pending.planned_route))
    }

    fn process_send_envelope(
        &self,
        upstream: UpstreamSendRouteRequest,
        planned_route: Option<PlannedRouteSummary>,
        envelope: Envelope,
    ) -> Result<SendRouteOutcome, SendRouteError> {
        let result_code = envelope.result_code.clone();
        let request_id = envelope.request_id.clone();
        let server_time = envelope.server_time;
        let data_value = decode_data(&envelope)?;
        let parsed: SendResponseData = if data_value.is_null() {
            SendResponseData {
                popup_message: None,
                toast_msg: None,
            }
        } else {
            serde_json::from_value(data_value).map_err(|_| SendRouteError::InvalidResponse)?
        };

        let toast_msg = parsed
            .toast_msg
            .map(|text| text.trim().to_owned())
            .filter(|text| !text.is_empty());

        if let Some(popup) = parsed.popup_message {
            let allowed_actions = popup.actionable_values();
            let (confirmation_token, expires_in) = if !allowed_actions.is_empty() {
                let token = self.store_pending(upstream, planned_route.clone(), allowed_actions);
                (Some(token), Some(CONFIRMATION_TTL.as_secs()))
            } else {
                (None, None)
            };
            tracing::info!(
                result_code = %result_code,
                request_id = ?request_id,
                has_confirmation_token = confirmation_token.is_some(),
                "NIO send-route returned server confirmation popup"
            );
            return Ok(SendRouteOutcome {
                status: "confirmation_required",
                result_code,
                request_id,
                server_time,
                toast_msg,
                popup_message: Some(popup),
                confirmation_token,
                confirmation_expires_in_seconds: expires_in,
                planned_route,
            });
        }

        tracing::info!(
            result_code = %result_code,
            request_id = ?request_id,
            "NIO send-route accepted by upstream"
        );
        Ok(SendRouteOutcome {
            status: "completed",
            result_code,
            request_id,
            server_time,
            toast_msg,
            popup_message: None,
            confirmation_token: None,
            confirmation_expires_in_seconds: None,
            planned_route,
        })
    }

    fn store_pending(
        &self,
        request: UpstreamSendRouteRequest,
        planned_route: Option<PlannedRouteSummary>,
        allowed_actions: Vec<i32>,
    ) -> String {
        let token = Uuid::new_v4().to_string();
        let now = Instant::now();
        let entry = PendingConfirmation {
            vehicle_id: self.profile.vehicle_id.clone(),
            request,
            planned_route,
            allowed_actions,
            expires_at: now + CONFIRMATION_TTL,
        };
        let mut map = self
            .pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        map.retain(|_, item| item.expires_at > now);
        while map.len() >= MAX_PENDING_CONFIRMATIONS {
            if let Some(oldest_key) = map
                .iter()
                .min_by_key(|(_, item)| item.expires_at)
                .map(|(key, _)| key.clone())
            {
                map.remove(&oldest_key);
            } else {
                break;
            }
        }
        map.insert(token.clone(), entry);
        token
    }
}

fn build_route_plan_request(
    vehicle_id: &str,
    poi_list: &[SendRoutePoiInput],
    vehicle_ctx: &RouteVehicleContext,
) -> Result<UpstreamRoutePlanRequest, SendRouteError> {
    if vehicle_id.trim().is_empty() {
        return Err(SendRouteError::InvalidInput("vehicle_id is not configured"));
    }
    if poi_list.is_empty() {
        return Err(SendRouteError::InvalidInput(
            "poi_list must contain at least one destination",
        ));
    }
    if poi_list.len() > MAX_POIS {
        return Err(SendRouteError::InvalidInput(
            "poi_list cannot contain more than 20 points",
        ));
    }

    let has_explicit_origin = poi_list.len() >= 2
        && poi_list
            .first()
            .is_some_and(|poi| poi.station_type == Some(RouteNodeType::Orig));

    let mut points = Vec::with_capacity(poi_list.len() + usize::from(!has_explicit_origin));
    if !has_explicit_origin {
        let Some((lat, lon)) = vehicle_ctx
            .position
            .filter(|(lat, lon)| valid_coordinate(*lat, *lon))
        else {
            return Err(SendRouteError::VehiclePositionUnavailable);
        };
        points.push(UpstreamRoutePlanPoint {
            location: format!("{lon},{lat}"),
            poi_name: "当前位置".to_owned(),
            poi_address: Some("当前位置".to_owned()),
            resource_id: None,
            id: None,
            sub_type: None,
            swap_use_clone: None,
        });
    }

    for poi in poi_list {
        let name = clean_text(&poi.name, 200)
            .ok_or(SendRouteError::InvalidInput("poi name is required"))?;
        if !valid_coordinate(poi.latitude, poi.longitude) {
            return Err(SendRouteError::InvalidInput(
                "poi latitude and longitude must be valid coordinates",
            ));
        }
        let address = poi
            .address
            .as_deref()
            .and_then(|value| clean_text(value, 300));
        let resource_id = clean_resource_id(poi.resource_id.as_deref())?;
        let (sub_type, swap_use_clone) = match resource_id.as_deref() {
            Some(rid) if rid.starts_with("PS-") => {
                let is_clone = rid.ends_with(CLONE_RESOURCE_SUFFIX)
                    || (poi.clone_latitude.is_some() && poi.clone_longitude.is_some());
                (
                    Some(if is_clone {
                        "PowerSwapClone".to_owned()
                    } else {
                        "PowerSwap".to_owned()
                    }),
                    Some(is_clone),
                )
            }
            Some(_) => (Some("ChargeStation".to_owned()), Some(false)),
            None => (None, None),
        };
        points.push(UpstreamRoutePlanPoint {
            location: format!("{},{}", poi.longitude, poi.latitude),
            poi_name: name,
            poi_address: address,
            id: resource_id.clone(),
            resource_id,
            sub_type,
            swap_use_clone,
        });
    }

    let model_type = vehicle_ctx
        .model_type
        .as_deref()
        .and_then(|raw| clean_text(raw, 64));

    Ok(UpstreamRoutePlanRequest {
        points,
        vehicle: UpstreamRoutePlanVehicle {
            vehicle_id: vehicle_id.to_owned(),
            model_type,
            restriction_switch: Some(false),
        },
        filter: HashMap::new(),
    })
}

fn parse_route_plan_envelope(
    vehicle_id: &str,
    vehicle_position: Option<(f64, f64)>,
    envelope: Envelope,
    include_charge_stops: bool,
) -> Result<ParsedRoutePlan, SendRouteError> {
    let request_id = envelope.request_id.clone();
    let server_time = envelope.server_time;
    let data_value = decode_data(&envelope)?;
    if data_value.is_null() {
        return Err(SendRouteError::RoutePlanEmpty(
            "上游未返回规划数据".to_owned(),
        ));
    }
    let parsed: UpstreamRoutePlanData =
        serde_json::from_value(data_value).map_err(|_| SendRouteError::InvalidResponse)?;
    let toast_msg = parsed
        .toast_msg
        .as_deref()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned);
    let raw_plans = parsed.plans.unwrap_or_default();
    if raw_plans.is_empty() {
        let message = parsed
            .fail_button_info
            .as_ref()
            .and_then(UpstreamFailButtonInfo::best_message)
            .or(toast_msg)
            .unwrap_or_else(|| "未找到可用加电规划路线".to_owned());
        return Err(SendRouteError::RoutePlanEmpty(message));
    }

    let converted: Vec<ConvertedPlan> = raw_plans
        .into_iter()
        .filter_map(|plan| convert_plan(vehicle_id, vehicle_position, plan, include_charge_stops))
        .collect();
    if converted.is_empty() {
        return Err(SendRouteError::RoutePlanEmpty(
            "规划结果不包含可发送到车机的节点".to_owned(),
        ));
    }

    tracing::info!(
        request_id = ?request_id,
        plan_count = converted.len(),
        include_charge_stops,
        "NIO energymap-multi route planning succeeded"
    );
    Ok(ParsedRoutePlan {
        request_id,
        server_time,
        toast_msg,
        plans: converted,
    })
}

fn convert_plan(
    vehicle_id: &str,
    vehicle_position: Option<(f64, f64)>,
    plan: UpstreamPlan,
    include_charge_stops: bool,
) -> Option<ConvertedPlan> {
    let raw_steps = plan.card_steps.unwrap_or_default();
    let steps: Vec<PlannedRouteStep> = raw_steps
        .iter()
        .filter_map(|step| {
            let title = non_empty(step.title.as_deref())?;
            let subtitle = non_empty(step.subtitle.as_deref());
            let distance_desc = non_empty(step.distance_desc.as_deref());
            let remain_soc = step
                .remain_soc
                .filter(|v| v.is_finite() && *v >= 0.0 && *v <= 100.0)
                .map(|v| v.round() as i32);
            let is_power_swap_clone = step.power_swap_clone == Some(true);
            let resource_id = non_empty(step.resource_id.as_deref()).map(|raw| {
                if is_power_swap_clone
                    && let Some(stripped) = raw.strip_suffix(CLONE_RESOURCE_SUFFIX)
                    && !stripped.is_empty()
                {
                    stripped.to_owned()
                } else {
                    raw
                }
            });
            let tags = step
                .tag_list_v2
                .as_deref()
                .unwrap_or_default()
                .iter()
                .filter_map(|tag| non_empty(tag.tag_name.as_deref()))
                .collect::<Vec<_>>();
            let risk_msg = non_empty(step.terminal_power_risk_msg.as_deref())
                .or_else(|| non_empty(step.risk_msg.as_deref()));
            Some(PlannedRouteStep {
                title,
                subtitle,
                distance_desc,
                remain_soc,
                resource_id,
                resource_type: non_empty(step.resource_type.as_deref()),
                is_poi: step.poi,
                is_power_swap_clone,
                tags,
                risk_msg,
            })
        })
        .collect();

    // Index card steps by resource_id and location/title so candidate stations
    // inherit exact per-stop duration/SOC descriptions from NIO `card_steps`.
    let mut step_by_resource_id: HashMap<&str, &PlannedRouteStep> = HashMap::new();
    let mut step_by_title: HashMap<&str, &PlannedRouteStep> = HashMap::new();
    for step in &steps {
        if let Some(rid) = step.resource_id.as_deref() {
            step_by_resource_id.entry(rid).or_insert(step);
        }
        step_by_title.entry(step.title.as_str()).or_insert(step);
    }

    let resources_and_points = plan.resources_and_points.unwrap_or_default();
    let mut upstream_pois = Vec::new();
    let mut client_pois = Vec::new();
    let mut charge_stations = Vec::new();

    let mut skipped_auto_candidate_ids: Vec<String> = Vec::new();
    let mut skipped_auto_candidate_names: Vec<String> = Vec::new();

    for node in resources_and_points {
        if node.need_send_vehicle != Some(true) {
            continue;
        }
        let Some(station_type) = node.station_type else {
            continue;
        };

        // When energy planning is disabled, drop NIO's auto-inserted `candidate`
        // charging/swap stops while keeping origin, user-chosen waypoints
        // (`waypoint` / `waypoint_candidate`), and destination (`dest` / `dest_candidate`).
        if !include_charge_stops && station_type == RouteNodeType::Candidate {
            if let Some(rid) = node.resource.as_ref().and_then(orig_power_swap_id) {
                skipped_auto_candidate_ids.push(rid);
            }
            if let Some(name) = non_empty(
                node.resource
                    .as_ref()
                    .and_then(|r| r.swap_clone.as_ref())
                    .and_then(|c| c.clone_name.as_deref()),
            )
            .or_else(|| non_empty(node.resource.as_ref().and_then(|r| r.name.as_deref())))
            .or_else(|| non_empty(node.poi_name.as_deref()))
            {
                skipped_auto_candidate_names.push(name);
            }
            continue;
        }

        if station_type.is_candidate() {
            let resource = node.resource.as_ref();
            let is_clone = node
                .pin_info
                .as_ref()
                .and_then(|pin| pin.pin_type.as_deref())
                .is_some_and(|t| t.eq_ignore_ascii_case("ps_clone"))
                || resource.and_then(|r| r.swap_use_clone) == Some(true);
            let swap_clone = resource.and_then(|r| r.swap_clone.as_ref());

            let name = if is_clone {
                non_empty(swap_clone.and_then(|c| c.clone_name.as_deref()))
                    .or_else(|| non_empty(resource.and_then(|r| r.name.as_deref())))
                    .or_else(|| non_empty(node.poi_name.as_deref()))
            } else {
                non_empty(resource.and_then(|r| r.name.as_deref()))
                    .or_else(|| non_empty(node.poi_name.as_deref()))
            };
            let Some(name) = name else {
                continue;
            };

            let address = if is_clone {
                non_empty(swap_clone.and_then(|c| c.address.as_deref()))
                    .or_else(|| non_empty(resource.and_then(|r| r.address.as_deref())))
                    .unwrap_or_else(|| name.clone())
            } else {
                non_empty(resource.and_then(|r| r.address.as_deref()))
                    .unwrap_or_else(|| name.clone())
            };

            let location = non_empty(node.location.as_deref())
                .or_else(|| non_empty(resource.and_then(|r| r.location.as_deref())));
            let Some(location) = location else {
                continue;
            };
            let Some((latitude, longitude)) = parse_lon_lat(&location) else {
                continue;
            };

            let resource_id = resource.and_then(orig_power_swap_id);
            let clone_location = if is_clone {
                non_empty(swap_clone.and_then(|c| c.location.as_deref()))
            } else {
                None
            };
            let (clone_latitude, clone_longitude) = clone_location
                .as_deref()
                .and_then(parse_lon_lat)
                .map_or((None, None), |(lat, lon)| (Some(lat), Some(lon)));

            let matched_step = resource_id
                .as_deref()
                .and_then(|rid| step_by_resource_id.get(rid).copied())
                .or_else(|| step_by_title.get(name.as_str()).copied());

            upstream_pois.push(UpstreamRoutePoi {
                location,
                name: name.clone(),
                address: address.clone(),
                resource_id: resource_id.clone(),
                clone_location,
                next_point_distance: node.next_candidate_point_distance,
                station_type: Some(station_type),
            });
            client_pois.push(SendRoutePoiInput {
                name: name.clone(),
                address: Some(address.clone()),
                latitude,
                longitude,
                resource_id: resource_id.clone(),
                clone_latitude,
                clone_longitude,
                next_point_distance: node.next_candidate_point_distance,
                station_type: Some(station_type),
            });
            charge_stations.push(PlannedRouteStation {
                name,
                address: Some(address),
                resource_id,
                resource_type: non_empty(resource.and_then(|r| r.resource_type.as_deref())),
                station_type,
                duration_desc: matched_step.and_then(|s| s.subtitle.clone()),
                distance_desc: matched_step.and_then(|s| s.distance_desc.clone()),
                remain_soc: matched_step.and_then(|s| s.remain_soc),
            });
        } else if station_type.is_poi() {
            let Some(name) = non_empty(node.poi_name.as_deref()) else {
                continue;
            };
            let Some(location) = non_empty(node.location.as_deref()) else {
                continue;
            };
            let Some((latitude, longitude)) = parse_lon_lat(&location) else {
                continue;
            };
            let address = non_empty(node.poi_address.as_deref()).unwrap_or_else(|| name.clone());

            upstream_pois.push(UpstreamRoutePoi {
                location,
                name: name.clone(),
                address: address.clone(),
                resource_id: None,
                clone_location: None,
                next_point_distance: None,
                station_type: Some(station_type),
            });
            client_pois.push(SendRoutePoiInput {
                name,
                address: Some(address),
                latitude,
                longitude,
                resource_id: None,
                clone_latitude: None,
                clone_longitude: None,
                next_point_distance: None,
                station_type: Some(station_type),
            });
        }
    }

    if upstream_pois.is_empty() {
        return None;
    }

    let steps = if include_charge_stops {
        steps
    } else {
        let kept_station_ids: Vec<&str> = charge_stations
            .iter()
            .filter_map(|s| s.resource_id.as_deref())
            .collect();
        let kept_station_names: Vec<&str> =
            charge_stations.iter().map(|s| s.name.as_str()).collect();
        steps
            .into_iter()
            .filter(|step| {
                let matches_skipped_id = step
                    .resource_id
                    .as_deref()
                    .is_some_and(|rid| skipped_auto_candidate_ids.iter().any(|s| s == rid));
                let matches_skipped_name = skipped_auto_candidate_names
                    .iter()
                    .any(|name| name == &step.title);
                if matches_skipped_id || matches_skipped_name {
                    return false;
                }
                if !step.is_poi {
                    let matches_kept_id = step
                        .resource_id
                        .as_deref()
                        .is_some_and(|rid| kept_station_ids.contains(&rid));
                    let matches_kept_name = kept_station_names.contains(&step.title.as_str());
                    return matches_kept_id || matches_kept_name;
                }
                true
            })
            .collect()
    };

    let summary_ref = plan.summary.as_ref();
    let route_driver_duration = summary_ref.and_then(|s| s.plan_driver_duration);
    let charge_times = if include_charge_stops {
        summary_ref.and_then(|s| s.plan_charge_count)
    } else {
        Some(charge_stations.len() as i32)
    };
    let route_distance = summary_ref
        .and_then(|s| s.drive_distance)
        .filter(|d| d.is_finite() && *d >= 0.0)
        .map(|d| d as i32);

    let has_driver =
        route_driver_duration.is_some() || charge_times.is_some() || route_distance.is_some();
    let upstream_driver = has_driver.then_some(UpstreamDriver {
        route_driver_duration,
        charge_times,
        route_distance,
    });
    let client_driver = has_driver.then_some(SendRouteDriverInput {
        route_driver_duration,
        charge_times,
        route_distance,
    });

    let route_id = non_empty(plan.route_id.as_deref());
    let tag_desc = non_empty(summary_ref.and_then(|s| s.tag_desc.as_deref()))
        .or_else(|| non_empty(summary_ref.and_then(|s| s.brief_tag_desc.as_deref())));
    let drive_distance_desc = non_empty(summary_ref.and_then(|s| s.drive_distance_desc.as_deref()));
    let drive_duration_desc =
        non_empty(summary_ref.and_then(|s| s.plan_drive_duration_desc.as_deref()));
    let plan_duration_desc = if include_charge_stops {
        non_empty(summary_ref.and_then(|s| s.plan_duration_desc.as_deref()))
            .or_else(|| drive_duration_desc.clone())
    } else {
        drive_duration_desc
            .clone()
            .or_else(|| non_empty(summary_ref.and_then(|s| s.plan_duration_desc.as_deref())))
    };
    let charge_desc = if include_charge_stops {
        non_empty(summary_ref.and_then(|s| s.plan_charge_desc.as_deref()))
    } else if charge_stations.is_empty() {
        None
    } else {
        Some(format!("用户自选补能 {} 站", charge_stations.len()))
    };
    let charge_duration = if include_charge_stops {
        summary_ref.and_then(|s| s.plan_charge_duration)
    } else if charge_stations.is_empty() {
        Some(0)
    } else {
        None
    };
    let charge_duration_desc = if include_charge_stops {
        non_empty(summary_ref.and_then(|s| s.plan_charge_duration_desc.as_deref()))
    } else {
        None
    };
    let toll_charge_desc = non_empty(summary_ref.and_then(|s| s.toll_charge_desc.as_deref()));
    let has_risk = summary_ref.and_then(|s| s.has_risk);

    let vehicle_location = vehicle_position
        .and_then(|(lat, lon)| valid_coordinate(lat, lon).then(|| format!("{lon},{lat}")));

    let charge_station_names = charge_stations
        .iter()
        .map(|station| station.name.clone())
        .collect::<Vec<_>>();
    let poi_count = upstream_pois.len();

    let upstream_request = UpstreamSendRouteRequest {
        btn_action: None,
        poi_list: upstream_pois,
        vehicle: UpstreamVehicle {
            vehicle_id: vehicle_id.to_owned(),
            location: vehicle_location,
        },
        driver: upstream_driver,
        route_id: route_id.clone(),
    };
    let option = PlannedRouteOption {
        route_id: route_id.clone(),
        tag_desc: tag_desc.clone(),
        drive_distance_desc: drive_distance_desc.clone(),
        drive_duration_desc,
        plan_duration_desc: plan_duration_desc.clone(),
        charge_desc: charge_desc.clone(),
        charge_duration,
        charge_duration_desc: charge_duration_desc.clone(),
        toll_charge_desc,
        has_risk,
        driver: client_driver,
        poi_list: client_pois,
        charge_stations,
        steps,
    };
    let summary = PlannedRouteSummary {
        route_id,
        tag_desc,
        drive_distance_desc,
        plan_duration_desc,
        charge_desc,
        charge_duration_desc,
        charge_times,
        charge_station_names,
        poi_count,
    };

    Some(ConvertedPlan {
        upstream_request,
        option,
        summary,
    })
}

fn orig_power_swap_id(resource: &UpstreamResource) -> Option<String> {
    let raw = non_empty(resource.id.as_deref())?;
    if resource.resource_type.as_deref() == Some("FakePowerSwap")
        && let Some(stripped) = raw.strip_suffix(CLONE_RESOURCE_SUFFIX)
        && !stripped.is_empty()
    {
        return Some(stripped.to_owned());
    }
    Some(raw)
}

fn parse_lon_lat(raw: &str) -> Option<(f64, f64)> {
    let (lon_str, lat_str) = raw.trim().split_once(',')?;
    let lon = lon_str.trim().parse::<f64>().ok()?;
    let lat = lat_str.trim().parse::<f64>().ok()?;
    valid_coordinate(lat, lon).then_some((lat, lon))
}

fn non_empty(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn clean_resource_id(raw: Option<&str>) -> Result<Option<String>, SendRouteError> {
    match raw {
        None => Ok(None),
        Some(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else if trimmed.len() > 128
                || !trimmed
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
            {
                Err(SendRouteError::InvalidInput("poi resource_id is invalid"))
            } else {
                Ok(Some(trimmed.to_owned()))
            }
        }
    }
}

fn build_upstream_request(
    vehicle_id: &str,
    input: SendRouteInput,
    vehicle_position: Option<(f64, f64)>,
) -> Result<UpstreamSendRouteRequest, SendRouteError> {
    if vehicle_id.trim().is_empty() {
        return Err(SendRouteError::InvalidInput("vehicle_id is not configured"));
    }
    if input.poi_list.is_empty() {
        return Err(SendRouteError::InvalidInput(
            "poi_list must contain at least one destination",
        ));
    }
    if input.poi_list.len() > MAX_POIS {
        return Err(SendRouteError::InvalidInput(
            "poi_list cannot contain more than 20 points",
        ));
    }

    let mut pois = Vec::with_capacity(input.poi_list.len());
    for poi in input.poi_list {
        let name = clean_text(&poi.name, 200)
            .ok_or(SendRouteError::InvalidInput("poi name is required"))?;
        if !valid_coordinate(poi.latitude, poi.longitude) {
            return Err(SendRouteError::InvalidInput(
                "poi latitude and longitude must be valid coordinates",
            ));
        }
        let address = poi
            .address
            .as_deref()
            .and_then(|value| clean_text(value, 300))
            .unwrap_or_else(|| name.clone());
        let resource_id = clean_resource_id(poi.resource_id.as_deref())?;
        let clone_location = match (poi.clone_latitude, poi.clone_longitude) {
            (None, None) => None,
            (Some(lat), Some(lon)) if valid_coordinate(lat, lon) => Some(format!("{lon},{lat}")),
            _ => {
                return Err(SendRouteError::InvalidInput(
                    "clone_latitude and clone_longitude must be valid coordinates supplied together",
                ));
            }
        };
        if let Some(distance) = poi.next_point_distance
            && distance < 0
        {
            return Err(SendRouteError::InvalidInput(
                "next_point_distance cannot be negative",
            ));
        }
        pois.push(UpstreamRoutePoi {
            location: format!("{},{}", poi.longitude, poi.latitude),
            name,
            address,
            resource_id,
            clone_location,
            next_point_distance: poi.next_point_distance,
            station_type: poi.station_type,
        });
    }

    let driver = input
        .driver
        .map(|d| {
            if d.route_driver_duration.is_some_and(|v| v < 0)
                || d.charge_times.is_some_and(|v| v < 0)
                || d.route_distance.is_some_and(|v| v < 0)
            {
                return Err(SendRouteError::InvalidInput(
                    "driver summary values cannot be negative",
                ));
            }
            Ok(UpstreamDriver {
                route_driver_duration: d.route_driver_duration,
                charge_times: d.charge_times,
                route_distance: d.route_distance,
            })
        })
        .transpose()?;

    let route_id = match input.route_id.as_deref() {
        None => None,
        Some(raw) => {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                None
            } else if trimmed.len() > 128 || trimmed.chars().any(char::is_control) {
                return Err(SendRouteError::InvalidInput("route_id is invalid"));
            } else {
                Some(trimmed.to_owned())
            }
        }
    };

    let vehicle_location = vehicle_position
        .and_then(|(lat, lon)| valid_coordinate(lat, lon).then(|| format!("{lon},{lat}")));

    Ok(UpstreamSendRouteRequest {
        btn_action: None,
        poi_list: pois,
        vehicle: UpstreamVehicle {
            vehicle_id: vehicle_id.to_owned(),
            location: vehicle_location,
        },
        driver,
        route_id,
    })
}

fn clean_text(raw: &str, max_chars: usize) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.chars().count() > max_chars
        || trimmed.chars().any(char::is_control)
    {
        return None;
    }
    Some(trimmed.to_owned())
}

fn common_query(profile: &VehicleConfig, timestamp: i64) -> Vec<(String, String)> {
    vec![
        ("app_id".to_owned(), profile.app_id.clone()),
        ("region".to_owned(), profile.region.clone()),
        (
            "lang".to_owned(),
            profile.language.replace('-', "_").to_ascii_lowercase(),
        ),
        ("app_ver".to_owned(), profile.app_version.clone()),
        ("timestamp".to_owned(), timestamp.to_string()),
        ("device_id".to_owned(), profile.device_id.clone()),
    ]
}

fn signed_get_url(
    origin: &str,
    path: &str,
    query: &[(String, String)],
    bearer_token: &str,
) -> Result<Url, SendRouteError> {
    let mut canonical = query
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>();
    canonical.sort();
    let material = format!(
        "GET{path}?{}{SIGNING_SALT}Bearer {bearer_token}",
        canonical.join("&")
    );
    let signature = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url = Url::parse(origin).map_err(|_| SendRouteError::InvalidUrl)?;
    url.set_path(path);
    url.query_pairs_mut()
        .extend_pairs(query.iter().map(|(name, value)| (name, value)))
        .append_pair("sign", &signature);
    Ok(url)
}

fn signed_post_url(
    origin: &str,
    path: &str,
    query: &[(String, String)],
    body: &str,
    bearer_token: &str,
) -> Result<Url, SendRouteError> {
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
        "POST{path}?{}{SIGNING_SALT}Bearer {bearer_token}",
        canonical.join("&")
    );
    let signature = format!("{:x}", Md5::digest(material.as_bytes()));
    let mut url = Url::parse(origin).map_err(|_| SendRouteError::InvalidUrl)?;
    url.set_path(path);
    url.query_pairs_mut()
        .extend_pairs(query.iter().map(|(name, value)| (name, value)))
        .append_pair("sign", &signature);
    Ok(url)
}

async fn read_envelope(response: reqwest::Response) -> Result<Envelope, SendRouteError> {
    if !response.status().is_success() {
        return Err(SendRouteError::HttpStatus(response.status()));
    }
    let envelope = response
        .json::<Envelope>()
        .await
        .map_err(|_| SendRouteError::InvalidJson)?;
    if envelope.result_code != "success" && envelope.result_code != "0" {
        return Err(SendRouteError::Rejected {
            code: envelope.result_code.clone(),
            message: envelope
                .display_msg
                .or(envelope.debug_msg)
                .unwrap_or(envelope.result_code),
            request_id: envelope.request_id,
        });
    }
    Ok(envelope)
}

fn decode_data(envelope: &Envelope) -> Result<Value, SendRouteError> {
    match envelope.encrypt_type {
        Some(1) => {
            let encoded = envelope
                .data
                .as_str()
                .ok_or(SendRouteError::InvalidResponse)?;
            let plain = decrypt_payload(encoded).map_err(|_| SendRouteError::InvalidResponse)?;
            serde_json::from_slice(&plain).map_err(|_| SendRouteError::InvalidResponse)
        }
        Some(0) | None => Ok(envelope.data.clone()),
        _ => Err(SendRouteError::InvalidResponse),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn test_profile() -> VehicleConfig {
        VehicleConfig {
            bearer_token: "test-token-value".into(),
            account_id: None,
            vehicle_id: "veh-bound-123".to_owned(),
            device_id: "0123456789abcdef0123456789abcdef".to_owned(),
            app_id: "10002".to_owned(),
            app_version: "6.9.6".to_owned(),
            region: "cn".to_owned(),
            language: "zh-CN".to_owned(),
            vin_code: None,
        }
    }

    fn sample_input() -> SendRouteInput {
        SendRouteInput {
            poi_list: vec![SendRoutePoiInput {
                name: "滨海换电站".to_owned(),
                address: None,
                latitude: 39.0294,
                longitude: 117.7105,
                resource_id: Some("PS-NIO-001".to_owned()),
                clone_latitude: None,
                clone_longitude: None,
                next_point_distance: None,
                station_type: Some(RouteNodeType::Dest),
            }],
            driver: Some(SendRouteDriverInput {
                route_driver_duration: Some(25),
                charge_times: Some(1),
                route_distance: Some(15200),
            }),
            route_id: Some("route-abc".to_owned()),
            auto_plan: None,
            include_charge_stops: None,
        }
    }

    #[test]
    fn builds_upstream_request_with_bound_vehicle_address_fallback_and_lon_lat() {
        let req =
            build_upstream_request("veh-bound-123", sample_input(), Some((39.01, 117.70))).unwrap();
        let value = serde_json::to_value(&req).unwrap();
        assert!(value.get("btn_action").is_none());
        assert_eq!(value["vehicle"]["vehicle_id"], "veh-bound-123");
        assert_eq!(value["vehicle"]["location"], "117.7,39.01");
        assert_eq!(value["poi_list"][0]["location"], "117.7105,39.0294");
        assert_eq!(value["poi_list"][0]["name"], "滨海换电站");
        assert_eq!(value["poi_list"][0]["address"], "滨海换电站");
        assert_eq!(value["poi_list"][0]["resource_id"], "PS-NIO-001");
        assert_eq!(value["poi_list"][0]["station_type"], "dest");
        assert_eq!(value["driver"]["route_distance"], 15200);
        assert_eq!(value["route_id"], "route-abc");
    }

    #[test]
    fn omits_vehicle_location_when_position_unavailable_and_rejects_empty_pois() {
        let req = build_upstream_request("veh-bound-123", sample_input(), None).unwrap();
        let value = serde_json::to_value(&req).unwrap();
        assert!(value["vehicle"].get("location").is_none());

        let empty = SendRouteInput {
            poi_list: vec![],
            driver: None,
            route_id: None,
            auto_plan: None,
            include_charge_stops: None,
        };
        assert!(matches!(
            build_upstream_request("veh-bound-123", empty, None),
            Err(SendRouteError::InvalidInput(_))
        ));
    }

    #[test]
    fn builds_route_plan_request_from_vehicle_position_and_preserves_explicit_origin() {
        let dest = vec![SendRoutePoiInput {
            name: "滨海换电站".to_owned(),
            address: Some("天津市滨海新区".to_owned()),
            latitude: 39.0294,
            longitude: 117.7105,
            resource_id: Some("PS-NIO-001".to_owned()),
            clone_latitude: None,
            clone_longitude: None,
            next_point_distance: None,
            station_type: Some(RouteNodeType::Dest),
        }];
        let ctx = RouteVehicleContext {
            position: Some((39.01, 117.70)),
            model_type: Some("ET5T".to_owned()),
        };
        let req = build_route_plan_request("veh-bound-123", &dest, &ctx).unwrap();
        let value = serde_json::to_value(&req).unwrap();
        assert_eq!(value["points"].as_array().unwrap().len(), 2);
        assert_eq!(value["points"][0]["location"], "117.7,39.01");
        assert_eq!(value["points"][0]["poi_name"], "当前位置");
        assert_eq!(value["points"][1]["location"], "117.7105,39.0294");
        assert_eq!(value["points"][1]["resource_id"], "PS-NIO-001");
        assert_eq!(value["points"][1]["id"], "PS-NIO-001");
        assert_eq!(value["points"][1]["sub_type"], "PowerSwap");
        assert_eq!(value["points"][1]["swap_use_clone"], false);
        assert_eq!(value["vehicle"]["vehicle_id"], "veh-bound-123");
        assert_eq!(value["vehicle"]["model_type"], "ET5T");
        assert_eq!(value["vehicle"]["restriction_switch"], false);

        // Missing vehicle position without explicit orig must fail cleanly.
        let no_pos = RouteVehicleContext::default();
        assert!(matches!(
            build_route_plan_request("veh-bound-123", &dest, &no_pos),
            Err(SendRouteError::VehiclePositionUnavailable)
        ));

        // Explicit orig avoids requiring vehicle position.
        let with_orig = vec![
            SendRoutePoiInput {
                name: "公司".to_owned(),
                address: None,
                latitude: 39.01,
                longitude: 117.70,
                resource_id: None,
                clone_latitude: None,
                clone_longitude: None,
                next_point_distance: None,
                station_type: Some(RouteNodeType::Orig),
            },
            dest[0].clone(),
        ];
        let explicit = build_route_plan_request("veh-bound-123", &with_orig, &no_pos).unwrap();
        assert_eq!(explicit.points.len(), 2);
        assert_eq!(explicit.points[0].poi_name, "公司");

        // Waypoints between auto vehicle origin and destination preserve exact order.
        let with_waypoints = vec![
            SendRoutePoiInput {
                name: "廊坊服务区".to_owned(),
                address: Some("廊坊".to_owned()),
                latitude: 39.50,
                longitude: 116.80,
                resource_id: None,
                clone_latitude: None,
                clone_longitude: None,
                next_point_distance: None,
                station_type: Some(RouteNodeType::Waypoint),
            },
            dest[0].clone(),
        ];
        let planned_wp = build_route_plan_request("veh-bound-123", &with_waypoints, &ctx).unwrap();
        assert_eq!(planned_wp.points.len(), 3);
        assert_eq!(planned_wp.points[0].poi_name, "当前位置");
        assert_eq!(planned_wp.points[1].poi_name, "廊坊服务区");
        assert_eq!(planned_wp.points[2].poi_name, "滨海换电站");
    }

    #[test]
    fn parses_energymap_multi_plan_into_official_send_payload_and_swap_stops() {
        let envelope: Envelope = serde_json::from_value(json!({
            "result_code": "success",
            "request_id": "req-plan-1",
            "server_time": 1764000100,
            "data": {
                "plans": [
                    {
                        "route_id": "nio-route-998877",
                        "summary": {
                            "tag_desc": "换电优先",
                            "drive_distance": 325400.6,
                            "drive_distance_desc": "325公里",
                            "plan_driver_duration": 210,
                            "plan_drive_duration_desc": "3小时30分",
                            "plan_duration_desc": "3小时40分",
                            "plan_charge_count": 2,
                            "plan_charge_desc": "换电2次",
                            "plan_charge_duration": 10,
                            "plan_charge_duration_desc": "补能共10分钟",
                            "toll_charge_desc": "约140元",
                            "has_risk": false
                        },
                        "card_steps": [
                            {
                                "title": "当前位置",
                                "subtitle": "出发电量 76%",
                                "poi": true,
                                "remain_soc": 76
                            },
                            {
                                "title": "京沪高速廊坊换电站",
                                "subtitle": "预计换电5分钟 · 到达剩余24%",
                                "distance_desc": "120公里",
                                "resource_id": "PS-NIO-001",
                                "resource_type": "PowerSwap",
                                "remain_soc": 24,
                                "poi": false,
                                "tag_list_v2": [{"tag_name": "推荐换电"}]
                            },
                            {
                                "title": "亦庄换电站(南区)",
                                "subtitle": "预计换电5分钟 · 到达剩余38%",
                                "distance_desc": "160公里",
                                "resource_id": "PS-NIO-002_clone",
                                "resource_type": "PowerSwap",
                                "power_swap_clone": true,
                                "remain_soc": 38,
                                "poi": false
                            },
                            {
                                "title": "天安门广场",
                                "subtitle": "到达预计剩余 78%",
                                "distance_desc": "全程325公里",
                                "remain_soc": 78,
                                "poi": true
                            }
                        ],
                        "resources_and_points": [
                            {
                                "station_type": "orig",
                                "location": "117.70,39.01",
                                "poi_name": "当前位置",
                                "poi_address": "",
                                "need_send_vehicle": true
                            },
                            {
                                "station_type": "resource",
                                "location": "117.50,39.10",
                                "need_send_vehicle": true,
                                "resource": { "id": "PS-SKIP", "name": "非候选站", "type": "PowerSwap" }
                            },
                            {
                                "station_type": "candidate",
                                "location": "117.10,39.30",
                                "need_send_vehicle": false,
                                "resource": { "id": "PS-NO-SEND", "name": "不下发站", "type": "PowerSwap" }
                            },
                            {
                                "station_type": "candidate",
                                "location": "116.80,39.50",
                                "need_send_vehicle": true,
                                "next_candidate_point_distance": 120000,
                                "resource": {
                                    "id": "PS-NIO-001",
                                    "name": "京沪高速廊坊换电站",
                                    "address": "廊坊服务区北区",
                                    "type": "PowerSwap"
                                }
                            },
                            {
                                "station_type": "candidate",
                                "location": "116.50,39.70",
                                "need_send_vehicle": true,
                                "next_candidate_point_distance": 45000,
                                "pin_info": { "pin_type": "ps_clone" },
                                "resource": {
                                    "id": "PS-NIO-002_clone",
                                    "name": "亦庄原站",
                                    "address": "亦庄原地址",
                                    "type": "FakePowerSwap",
                                    "swap_use_clone": true,
                                    "swap_clone": {
                                        "clone_name": "亦庄换电站(南区)",
                                        "address": "亦庄南区入口",
                                        "location": "116.501,39.702"
                                    }
                                }
                            },
                            {
                                "station_type": "dest",
                                "location": "116.397,39.908",
                                "poi_name": "天安门广场",
                                "poi_address": "北京市东城区",
                                "need_send_vehicle": true
                            }
                        ]
                    }
                ]
            }
        }))
        .unwrap();

        let parsed =
            parse_route_plan_envelope("veh-bound-123", Some((39.01, 117.70)), envelope, true)
                .unwrap();
        assert_eq!(parsed.request_id.as_deref(), Some("req-plan-1"));
        assert_eq!(parsed.plans.len(), 1);
        let plan = &parsed.plans[0];

        // Verify official upstream send payload matches Android rules.
        let upstream_val = serde_json::to_value(&plan.upstream_request).unwrap();
        assert_eq!(upstream_val["route_id"], "nio-route-998877");
        assert_eq!(upstream_val["vehicle"]["vehicle_id"], "veh-bound-123");
        assert_eq!(upstream_val["vehicle"]["location"], "117.7,39.01");
        assert_eq!(upstream_val["driver"]["route_driver_duration"], 210);
        assert_eq!(upstream_val["driver"]["charge_times"], 2);
        assert_eq!(upstream_val["driver"]["route_distance"], 325400);

        let pois = upstream_val["poi_list"].as_array().unwrap();
        assert_eq!(pois.len(), 4);
        assert_eq!(pois[0]["station_type"], "orig");
        assert_eq!(pois[0]["address"], "当前位置");
        assert_eq!(pois[1]["station_type"], "candidate");
        assert_eq!(pois[1]["resource_id"], "PS-NIO-001");
        assert_eq!(pois[1]["next_point_distance"], 120000);
        assert_eq!(pois[2]["station_type"], "candidate");
        assert_eq!(pois[2]["name"], "亦庄换电站(南区)");
        assert_eq!(pois[2]["address"], "亦庄南区入口");
        assert_eq!(pois[2]["resource_id"], "PS-NIO-002");
        assert_eq!(pois[2]["clone_location"], "116.501,39.702");
        assert_eq!(pois[3]["station_type"], "dest");
        assert_eq!(pois[3]["name"], "天安门广场");

        // Verify summary & option expose along-the-way swap stops and per-stop durations cleanly.
        assert_eq!(plan.option.charge_stations.len(), 2);
        assert_eq!(
            plan.option.charge_duration_desc.as_deref(),
            Some("补能共10分钟")
        );
        assert_eq!(
            plan.option.charge_stations[0].duration_desc.as_deref(),
            Some("预计换电5分钟 · 到达剩余24%")
        );
        assert_eq!(plan.option.charge_stations[0].remain_soc, Some(24));
        assert_eq!(
            plan.option.charge_stations[1].duration_desc.as_deref(),
            Some("预计换电5分钟 · 到达剩余38%")
        );
        assert_eq!(plan.option.steps.len(), 4);
        assert_eq!(plan.option.steps[1].tags, vec!["推荐换电"]);
        assert_eq!(
            plan.summary.charge_station_names,
            vec!["京沪高速廊坊换电站", "亦庄换电站(南区)"]
        );
        assert_eq!(plan.summary.route_id.as_deref(), Some("nio-route-998877"));
        assert_eq!(plan.summary.poi_count, 4);
    }

    #[test]
    fn disabling_charge_stops_keeps_route_id_and_strips_auto_candidates() {
        let envelope: Envelope = serde_json::from_value(json!({
            "result_code": "success",
            "request_id": "req-plan-no-charge",
            "server_time": 1764000200,
            "data": {
                "plans": [
                    {
                        "route_id": "nio-route-no-charge-123",
                        "summary": {
                            "tag_desc": "换电优先",
                            "drive_distance": 325400.0,
                            "drive_distance_desc": "325公里",
                            "plan_driver_duration": 210,
                            "plan_drive_duration_desc": "3小时30分",
                            "plan_duration_desc": "3小时40分",
                            "plan_charge_count": 2,
                            "plan_charge_desc": "换电2次",
                            "plan_charge_duration": 10,
                            "plan_charge_duration_desc": "补能共10分钟",
                            "toll_charge_desc": "约140元",
                            "has_risk": false
                        },
                        "card_steps": [
                            {
                                "title": "当前位置",
                                "subtitle": "出发电量 76%",
                                "poi": true,
                                "remain_soc": 76
                            },
                            {
                                "title": "京沪高速廊坊换电站",
                                "subtitle": "预计换电5分钟 · 到达剩余24%",
                                "resource_id": "PS-AUTO-001",
                                "resource_type": "PowerSwap",
                                "poi": false
                            },
                            {
                                "title": "用户自选亦庄换电站",
                                "subtitle": "预计换电5分钟 · 到达剩余40%",
                                "resource_id": "PS-USER-WP",
                                "resource_type": "PowerSwap",
                                "poi": false
                            },
                            {
                                "title": "天安门广场",
                                "subtitle": "到达预计剩余 70%",
                                "poi": true
                            }
                        ],
                        "resources_and_points": [
                            {
                                "station_type": "orig",
                                "location": "117.70,39.01",
                                "poi_name": "当前位置",
                                "need_send_vehicle": true
                            },
                            {
                                "station_type": "candidate",
                                "location": "116.80,39.50",
                                "need_send_vehicle": true,
                                "resource": {
                                    "id": "PS-AUTO-001",
                                    "name": "京沪高速廊坊换电站",
                                    "address": "廊坊服务区北区",
                                    "type": "PowerSwap"
                                }
                            },
                            {
                                "station_type": "waypoint_candidate",
                                "location": "116.50,39.70",
                                "need_send_vehicle": true,
                                "resource": {
                                    "id": "PS-USER-WP",
                                    "name": "用户自选亦庄换电站",
                                    "address": "亦庄",
                                    "type": "PowerSwap"
                                }
                            },
                            {
                                "station_type": "dest",
                                "location": "116.397,39.908",
                                "poi_name": "天安门广场",
                                "poi_address": "北京市东城区",
                                "need_send_vehicle": true
                            }
                        ]
                    }
                ]
            }
        }))
        .unwrap();

        let parsed =
            parse_route_plan_envelope("veh-bound-123", Some((39.01, 117.70)), envelope, false)
                .unwrap();
        let plan = &parsed.plans[0];
        let upstream_val = serde_json::to_value(&plan.upstream_request).unwrap();

        // Official route_id is preserved so NIO send-vehicle accepts the route.
        assert_eq!(upstream_val["route_id"], "nio-route-no-charge-123");
        assert_eq!(
            plan.option.route_id.as_deref(),
            Some("nio-route-no-charge-123")
        );
        // Auto-inserted `candidate` is stripped; `orig`, user `waypoint_candidate`, and `dest` remain.
        let pois = upstream_val["poi_list"].as_array().unwrap();
        assert_eq!(pois.len(), 3);
        assert_eq!(pois[0]["station_type"], "orig");
        assert_eq!(pois[1]["station_type"], "waypoint_candidate");
        assert_eq!(pois[1]["resource_id"], "PS-USER-WP");
        assert_eq!(pois[2]["station_type"], "dest");

        // Driver and summary reflect pure driving time and only kept user energy stops.
        assert_eq!(upstream_val["driver"]["charge_times"], 1);
        assert_eq!(upstream_val["driver"]["route_driver_duration"], 210);
        assert_eq!(plan.option.plan_duration_desc.as_deref(), Some("3小时30分"));
        assert_eq!(plan.option.charge_stations.len(), 1);
        assert_eq!(plan.option.charge_stations[0].name, "用户自选亦庄换电站");
        assert_eq!(
            plan.option
                .steps
                .iter()
                .map(|s| s.title.as_str())
                .collect::<Vec<_>>(),
            vec!["当前位置", "用户自选亦庄换电站", "天安门广场"]
        );
    }

    #[test]
    fn signs_get_and_post_urls_with_expected_parameters() {
        let profile = test_profile();
        let mut get_query = common_query(&profile, 1764000000);
        get_query.push(("vehicle_id".to_owned(), profile.vehicle_id.clone()));
        let get_url = signed_get_url(APP_ORIGIN, SWITCH_PATH, &get_query, "tok").unwrap();
        let get_pairs: HashMap<_, _> = get_url.query_pairs().into_owned().collect();
        assert_eq!(get_url.path(), SWITCH_PATH);
        assert_eq!(
            get_pairs.get("vehicle_id").map(String::as_str),
            Some("veh-bound-123")
        );
        assert_eq!(get_pairs.get("sign").map(String::len), Some(32));

        let post_query = common_query(&profile, 1764000000);
        let post_url = signed_post_url(APP_ORIGIN, SEND_PATH, &post_query, "{}", "tok").unwrap();
        let post_pairs: HashMap<_, _> = post_url.query_pairs().into_owned().collect();
        assert_eq!(post_url.path(), SEND_PATH);
        assert_eq!(post_pairs.get("sign").map(String::len), Some(32));
    }

    #[test]
    fn popup_confirmation_binds_exact_route_validates_action_and_consumes_once() {
        let client = NioSendRouteClient::new(test_profile()).unwrap();
        let original =
            build_upstream_request("veh-bound-123", sample_input(), Some((39.01, 117.70))).unwrap();
        let summary = PlannedRouteSummary {
            route_id: Some("route-abc".to_owned()),
            tag_desc: Some("换电优先".to_owned()),
            drive_distance_desc: Some("15.2公里".to_owned()),
            plan_duration_desc: Some("25分钟".to_owned()),
            charge_desc: Some("换电1次".to_owned()),
            charge_duration_desc: Some("换电5分钟".to_owned()),
            charge_times: Some(1),
            charge_station_names: vec!["滨海换电站".to_owned()],
            poi_count: 1,
        };

        let popup_envelope: Envelope = serde_json::from_value(json!({
            "result_code": "success",
            "request_id": "req-send-1",
            "server_time": 1764000001,
            "data": {
                "popup_message": {
                    "content": "车机已有导航，是否覆盖？",
                    "left_btn_text": "取消",
                    "left_btn_action": null,
                    "right_btn_text": "覆盖发送",
                    "right_btn_action": 2
                }
            }
        }))
        .unwrap();

        let first = client
            .process_send_envelope(original, Some(summary.clone()), popup_envelope)
            .unwrap();
        assert_eq!(first.status, "confirmation_required");
        assert_eq!(first.planned_route, Some(summary.clone()));
        let token = first.confirmation_token.clone().unwrap();

        // Fabricated action must be rejected without consuming the token.
        let invalid = client.consume_pending(&ConfirmSendRouteInput {
            confirmation_token: token.clone(),
            btn_action: 99,
        });
        assert!(matches!(invalid, Err(SendRouteError::InvalidAction)));

        // Valid server-provided action consumes token and replays exact bound payload.
        let (replayed, replayed_summary) = client
            .consume_pending(&ConfirmSendRouteInput {
                confirmation_token: token.clone(),
                btn_action: 2,
            })
            .unwrap();
        assert_eq!(replayed.btn_action, Some(2));
        assert_eq!(replayed.vehicle.vehicle_id, "veh-bound-123");
        assert_eq!(replayed.poi_list[0].name, "滨海换电站");
        assert_eq!(replayed.route_id.as_deref(), Some("route-abc"));
        assert_eq!(replayed_summary, Some(summary.clone()));

        // Second use of the consumed token must fail.
        let second = client.consume_pending(&ConfirmSendRouteInput {
            confirmation_token: token,
            btn_action: 2,
        });
        assert!(matches!(second, Err(SendRouteError::ConfirmationExpired)));

        // Completed envelope with toast only yields no confirmation token.
        let completed_envelope: Envelope = serde_json::from_value(json!({
            "result_code": "success",
            "request_id": "req-send-2",
            "server_time": 1764000002,
            "data": { "toast_msg": "已发送到车机" }
        }))
        .unwrap();
        let completed = client
            .process_send_envelope(replayed, replayed_summary, completed_envelope)
            .unwrap();
        assert_eq!(completed.status, "completed");
        assert_eq!(completed.toast_msg.as_deref(), Some("已发送到车机"));
        assert!(completed.confirmation_token.is_none());
        assert_eq!(completed.planned_route, Some(summary));
    }

    #[test]
    fn popup_with_only_null_actions_emits_no_confirmation_token() {
        let popup = SendRoutePopup {
            content: Some("提示".to_owned()),
            left_btn_text: Some("知道了".to_owned()),
            left_btn_action: None,
            right_btn_text: None,
            right_btn_action: None,
        };
        assert!(popup.actionable_values().is_empty());
    }
}
