use std::{sync::Arc, time::Duration};

use actix_web::{
    HttpRequest, HttpResponse, ResponseError,
    http::{StatusCode, header::AUTHORIZATION},
    web,
};
use chrono::{DateTime, Datelike, FixedOffset, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;

use crate::{
    analytics::{self, EnergyStats},
    config::{StationConfig, StationTemplateConfig},
    daily_checkin::{self, DailyCheckInError},
    events::EventHub,
    live_activity_push::{
        LiveActivityCoordinator, LiveActivityPushStatus, LiveActivitySimulationOutcome,
        LiveActivitySimulationRequest, LiveActivitySimulationStopInput,
        LiveActivitySimulationStopOutcome, LiveActivityTokenDeleteInput, LiveActivityTokenKind,
        LiveActivityTokenRegistration, LiveActivityTokenResponse, SimulationError,
        validate_hex_token,
    },
    models::{
        ActiveServiceOrderPage, ImportedBattery, ImportedOrder, NearestStationLive, ServiceStatus,
        StationLiveStatus, SwapEventPage, SwapStation, SwapStationPage, VehicleChargingSamplePage,
        VehicleChargingSessionPage, VehicleProfileResponse, VehicleSnapshotPage, VehicleTripPage,
        VehicleTripTrack,
    },
    nearby_stations::{NearbyError, NearbyStationResult, NioNearbyStationClient},
    nio_login::{LoginError, LoginInput, NioLogin, SmsInput},
    poller::{PollError, Poller},
    provider::{NioStationProvider, ProviderError},
    rewards::{AvailableCouponsPage, CheckInOutcome, NioRewardsClient, RewardsError},
    route_estimate::{self, StationCoordinateBasis, StraightLineEnergyEstimate},
    send_route::{
        ConfirmSendRouteInput, NioSendRouteClient, PlanRouteInput, PlanRouteOutcome,
        RouteVehicleContext, SendRouteError, SendRouteInput, SendRouteOutcome,
        SendRouteSwitchOutcome,
    },
    station_search::{
        NioStationSearchClient, StationSearchError, SwapStationSearchItem, SwapStationSearchResult,
        normalize_search_name,
    },
    store::{Store, StoreError},
    swap_order::{CreateSwapOrderInput, CreateSwapOrderOutcome, SwapOrderError, SwapOrderRuntime},
    trip_energy,
    vehicle::{NioVehicleClient, VehicleError, snapshot_from_status},
    vehicle_control::{ActionInput, ActionOutcome, ControlError, ControlRuntime},
};

mod mcp;
pub(crate) mod mcp_oauth;

#[derive(Clone)]
pub struct AppState {
    pub store: Store,
    pub events: EventHub,
    pub live_activity: Arc<LiveActivityCoordinator>,
    pub poller: Poller,
    pub api_key: Option<Arc<str>>,
    pub tenant_mode: bool,
    pub poll_interval: Duration,
    pub match_window: Duration,
    pub vehicle: Arc<std::sync::RwLock<Option<NioVehicleClient>>>,
    pub vehicle_login_seed: Option<crate::config::VehicleLoginSeed>,
    pub nio_login: Option<Arc<NioLogin>>,
    pub tenant_persistence: Option<Arc<crate::tenant_config::TenantPersistence>>,
    pub trip_sync: Option<tokio::sync::mpsc::Sender<()>>,
    pub control: Option<ControlRuntime>,
    pub swap_order: Option<SwapOrderRuntime>,
    pub station_search: Arc<std::sync::RwLock<Option<NioStationSearchClient>>>,
    pub nearby_stations: Arc<std::sync::RwLock<Option<NioNearbyStationClient>>>,
    pub rewards: Arc<std::sync::RwLock<Option<NioRewardsClient>>>,
    pub send_route: Arc<std::sync::RwLock<Option<NioSendRouteClient>>>,
    pub service_order_configured: bool,
    pub station_template_configured: bool,
    pub station_template: Option<StationTemplateConfig>,
    pub station_provider_template: Arc<tokio::sync::OnceCell<NioStationProvider>>,
    pub service_order_poll_interval: Duration,
    pub mcp_client: reqwest::Client,
    pub mcp_origin: String,
    pub mcp_oauth: Option<mcp_oauth::OAuthServer>,
}

impl AppState {
    pub fn vehicle(&self) -> Option<NioVehicleClient> {
        self.vehicle
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn station_search(&self) -> Option<NioStationSearchClient> {
        self.station_search
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn nearby_stations(&self) -> Option<NioNearbyStationClient> {
        self.nearby_stations
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn rewards(&self) -> Option<NioRewardsClient> {
        self.rewards
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn send_route(&self) -> Option<NioSendRouteClient> {
        self.send_route
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// Hot-reload the in-memory NIO Bearer Token for all running clients
    /// without restarting the process. If the server booted with a pending
    /// `vehicle_login_seed` (no initial token), initializes the vehicle and
    /// companion clients in-place.
    pub fn hot_reload_vehicle_token(&self, access_token: &str) -> bool {
        let normalized = crate::config::SharedBearerToken::normalize(access_token);
        if normalized.is_empty()
            || normalized.len() > 4096
            || normalized.chars().any(char::is_whitespace)
        {
            return false;
        }
        if let Some(existing) = self.vehicle() {
            existing.update_bearer_token(&normalized);
            tracing::info!("hot-reloaded NIO bearer token for running vehicle clients");
            return true;
        }
        let Some(seed) = &self.vehicle_login_seed else {
            return false;
        };
        let mut vehicle_guard = self
            .vehicle
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(existing) = vehicle_guard.as_ref() {
            existing.update_bearer_token(&normalized);
            tracing::info!("hot-reloaded NIO bearer token for running vehicle clients");
            return true;
        }
        let config = seed.to_vehicle_config(normalized);
        let Ok(vehicle) = NioVehicleClient::new(config.clone()) else {
            tracing::warn!("failed to construct NioVehicleClient during login hot-reload");
            return false;
        };
        let station_search = NioStationSearchClient::new(config.clone()).ok();
        let nearby_stations = NioNearbyStationClient::new(config.clone()).ok();
        let rewards = NioRewardsClient::new(config.clone()).ok();
        let send_route = NioSendRouteClient::new(config).ok();
        *vehicle_guard = Some(vehicle.clone());
        *self
            .station_search
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = station_search;
        *self
            .nearby_stations
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = nearby_stations;
        *self
            .rewards
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = rewards;
        *self
            .send_route
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = send_route;
        drop(vehicle_guard);
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let store = self.store.clone();
            handle.spawn(async move {
                crate::vehicle_profile::run_startup(store, vehicle).await;
            });
        }
        tracing::info!("hot-initialized NIO vehicle clients from SMS login");
        true
    }
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[derive(Debug, Deserialize)]
struct ListQuery {
    #[serde(default = "default_limit")]
    limit: u32,
    #[serde(default)]
    offset: u32,
    #[serde(default)]
    include_candidates: bool,
}

#[derive(Debug, Deserialize)]
struct StationListQuery {
    #[serde(default = "default_limit")]
    limit: u32,
    #[serde(default)]
    offset: u32,
    q: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StationSearchQuery {
    name: String,
}

#[derive(Debug, Deserialize)]
struct VehicleHistoryQuery {
    #[serde(default = "default_vehicle_history_limit")]
    limit: u32,
}

#[derive(Debug, Deserialize)]
struct VehicleChargingSessionsQuery {
    #[serde(default = "default_charging_session_limit")]
    limit: u32,
}

#[derive(Debug, Deserialize)]
struct VehicleTripQuery {
    #[serde(default = "default_vehicle_trip_count")]
    count: u32,
    query_time: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct AvailableCouponsQuery {
    #[serde(default = "default_coupon_limit")]
    limit: u32,
    #[serde(default)]
    offset: u32,
}

fn default_coupon_limit() -> u32 {
    20
}

#[derive(Debug, Deserialize)]
struct StraightLineEnergyRequest {
    latitude: f64,
    longitude: f64,
    station_latitude: Option<f64>,
    station_longitude: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct NearbyStationsRequest {
    latitude: f64,
    longitude: f64,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: &'static str,
    message: String,
}

#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn unauthorized() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "unauthorized",
            message: "provide the configured API key as Bearer token or X-API-Key".to_owned(),
        }
    }

    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_request",
            message: message.into(),
        }
    }

    fn not_found() -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: "not_found",
            message: "swap event was not found".to_owned(),
        }
    }
}

impl ResponseError for ApiError {
    fn status_code(&self) -> StatusCode {
        self.status
    }

    fn error_response(&self) -> HttpResponse {
        HttpResponse::build(self.status).json(ErrorBody {
            error: self.code,
            message: self.message.clone(),
        })
    }
}

impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        tracing::error!(%error, "database operation failed");
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "database_error",
            message: "database operation failed".to_owned(),
        }
    }
}

impl From<PollError> for ApiError {
    fn from(error: PollError) -> Self {
        match error {
            PollError::NotConfigured => Self {
                status: StatusCode::SERVICE_UNAVAILABLE,
                code: "station_not_configured",
                message: error.to_string(),
            },
            PollError::Provider(_) => {
                tracing::warn!(%error, "manual station poll failed");
                Self {
                    status: StatusCode::BAD_GATEWAY,
                    code: "upstream_error",
                    message: error.to_string(),
                }
            }
            PollError::Store(error) => error.into(),
        }
    }
}

impl From<VehicleError> for ApiError {
    fn from(error: VehicleError) -> Self {
        tracing::warn!(%error, "NIO vehicle request failed");
        Self {
            status: StatusCode::BAD_GATEWAY,
            code: "upstream_error",
            message: error.to_string(),
        }
    }
}

impl From<ProviderError> for ApiError {
    fn from(error: ProviderError) -> Self {
        tracing::warn!(%error, "NIO station request failed");
        Self {
            status: StatusCode::BAD_GATEWAY,
            code: "upstream_error",
            message: error.to_string(),
        }
    }
}

impl From<RewardsError> for ApiError {
    fn from(error: RewardsError) -> Self {
        tracing::warn!(%error, "NIO rewards request failed");
        Self {
            status: StatusCode::BAD_GATEWAY,
            code: "rewards_upstream_error",
            message: error.to_string(),
        }
    }
}

pub fn configure(config: &mut web::ServiceConfig) {
    config
        .route("/healthz", web::get().to(health))
        .route("/api/v1/status", web::get().to(status))
        .route("/api/v1/events", web::get().to(events))
        .route("/api/v1/swaps", web::get().to(list_swaps))
        .route("/api/v1/energy/stats", web::get().to(energy_stats))
        .route("/api/v1/swaps/{id}", web::get().to(get_swap))
        .route("/api/v1/orders/active", web::get().to(list_active_orders))
        .route("/api/v1/swap-orders", web::post().to(create_swap_order))
        .route(
            "/api/v1/coupons/available",
            web::get().to(available_coupons),
        )
        .route("/api/v1/check-in", web::post().to(check_in))
        .route("/api/v1/stations", web::get().to(list_stations))
        .route("/api/v1/stations/search", web::get().to(search_stations))
        .route("/api/v1/stations/nearby", web::post().to(nearby_stations))
        .route(
            "/api/v1/stations/nearest",
            web::get().to(nearest_station_live),
        )
        .route("/api/v1/stations/{id}", web::get().to(get_station))
        .route(
            "/api/v1/stations/{id}/live",
            web::get().to(get_station_live),
        )
        .route(
            "/api/v1/stations/{id}/straight-line-energy",
            web::post().to(straight_line_energy),
        )
        .route("/api/v1/vehicle/status", web::get().to(vehicle_status))
        .route("/api/v1/vehicle/history", web::get().to(vehicle_history))
        .route(
            "/api/v1/vehicle/charging/current",
            web::get().to(vehicle_charging_current),
        )
        .route(
            "/api/v1/vehicle/charging/sessions",
            web::get().to(vehicle_charging_sessions),
        )
        .route(
            "/api/v1/vehicle/charging/sessions/{id}",
            web::get().to(vehicle_charging_session),
        )
        .route("/api/v1/vehicle/profile", web::get().to(vehicle_profile))
        .route("/api/v1/vehicle/image", web::get().to(vehicle_image))
        .route("/api/v1/vehicle/trips", web::get().to(vehicle_trips))
        .route(
            "/api/v1/vehicle/trips/{journey_id}/track",
            web::get().to(vehicle_trip_track),
        )
        .route("/api/v1/auth/sms", web::post().to(send_login_sms))
        .route("/api/v1/auth/login", web::post().to(login_with_sms))
        .route("/api/v1/vehicle/action", web::post().to(vehicle_action))
        .route(
            "/api/v1/vehicle/route/switch",
            web::get().to(vehicle_route_switch),
        )
        .route(
            "/api/v1/vehicle/route/plan",
            web::post().to(plan_vehicle_route),
        )
        .route(
            "/api/v1/vehicle/route/send",
            web::post().to(send_vehicle_route),
        )
        .route(
            "/api/v1/vehicle/route/send/confirm",
            web::post().to(confirm_send_vehicle_route),
        )
        .route(
            "/api/v1/vehicle/widget-info",
            web::get().to(vehicle_widget_info),
        )
        .route(
            "/api/v1/live-activities/tokens",
            web::post().to(register_live_activity_token),
        )
        .route(
            "/api/v1/live-activities/tokens",
            web::delete().to(delete_live_activity_token),
        )
        .route(
            "/api/v1/live-activities/status",
            web::get().to(live_activity_status),
        )
        .route(
            "/api/v1/live-activities/simulation",
            web::post().to(start_live_activity_simulation),
        )
        .route(
            "/api/v1/live-activities/simulation",
            web::delete().to(stop_live_activity_simulation),
        )
        .route("/api/v1/poll", web::post().to(manual_poll))
        .route("/api/v1/orders/import", web::post().to(import_order))
        .route("/mcp", web::post().to(mcp::handle))
        .route(
            "/.well-known/oauth-protected-resource/mcp",
            web::get().to(mcp_oauth::protected_resource),
        )
        .route(
            "/.well-known/oauth-authorization-server",
            web::get().to(mcp_oauth::authorization_server),
        )
        .route("/oauth/register", web::post().to(mcp_oauth::register))
        .route("/oauth/authorize", web::get().to(mcp_oauth::authorize_page))
        .route(
            "/oauth/authorize",
            web::post().to(mcp_oauth::authorize_submit),
        )
        .route("/oauth/token", web::post().to(mcp_oauth::token));
}

pub fn json_config() -> web::JsonConfig {
    web::JsonConfig::default()
        .limit(256 * 1024)
        .error_handler(|error, _request| {
            ApiError::bad_request(format!("invalid JSON body: {error}")).into()
        })
}

async fn health() -> web::Json<HealthResponse> {
    web::Json(HealthResponse { status: "ok" })
}

fn login_api_error(error: LoginError) -> ApiError {
    match error {
        LoginError::InvalidInput | LoginError::NoChallenge => {
            ApiError::bad_request(error.to_string())
        }
        LoginError::Rejected {
            code,
            message,
            display_msg,
        } => ApiError {
            status: StatusCode::BAD_GATEWAY,
            code: "nio_login_rejected",
            message: format!("{code}: {}", display_msg.or(message).unwrap_or_default()),
        },
        other => {
            tracing::warn!(%other, "NIO login request failed");
            ApiError {
                status: StatusCode::BAD_GATEWAY,
                code: "nio_login_upstream_error",
                message: other.to_string(),
            }
        }
    }
}

fn login_runtime<'a>(state: &'a AppState, request: &HttpRequest) -> Result<&'a NioLogin, ApiError> {
    // Login returns upstream credentials. Never allow the loopback no-key shortcut here.
    if state.api_key.is_none() {
        return Err(ApiError {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "login_not_configured",
            message: "API_KEY is required for NIO login".to_owned(),
        });
    }
    authorize(state, request)?;
    state.nio_login.as_deref().ok_or(ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "login_not_configured",
        message: "NIO_DEVICE_ID is required for NIO login".to_owned(),
    })
}

async fn send_login_sms(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<SmsInput>,
) -> Result<HttpResponse, ApiError> {
    let login = login_runtime(&state, &request)?;
    let outcome = login
        .send_sms(input.into_inner())
        .await
        .map_err(login_api_error)?;
    Ok(HttpResponse::Ok()
        .insert_header(("Cache-Control", "no-store"))
        .json(outcome))
}

async fn login_with_sms(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<LoginInput>,
) -> Result<HttpResponse, ApiError> {
    let login = login_runtime(&state, &request)?;
    let mut outcome = login
        .login(input.into_inner())
        .await
        .map_err(login_api_error)?;
    let data = outcome
        .get("data")
        .ok_or_else(|| login_api_error(LoginError::InvalidResponse))?;
    let access = data
        .get("access_token")
        .and_then(|value| value.as_str())
        .ok_or_else(|| login_api_error(LoginError::InvalidResponse))?
        .to_owned();
    let refresh = data
        .get("refresh_token")
        .and_then(|value| value.as_str())
        .ok_or_else(|| login_api_error(LoginError::InvalidResponse))?
        .to_owned();
    if let Some(persistence) = &state.tenant_persistence {
        let saved = match persistence.save_login(&access, &refresh).await {
            Ok(()) => true,
            Err(error) => {
                tracing::warn!(%error, "NIO login succeeded but tenant token was not saved");
                false
            }
        };
        outcome["backend_config_saved"] = serde_json::json!(saved);
    }
    let reloaded = state.hot_reload_vehicle_token(&access);
    outcome["vehicle_client_reloaded"] = serde_json::json!(reloaded);
    Ok(HttpResponse::Ok()
        .insert_header(("Cache-Control", "no-store"))
        .json(outcome))
}

async fn status(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<ServiceStatus>, ApiError> {
    if state.tenant_mode {
        authorize(&state, &request)?;
    }
    let (snapshot_count, candidate_count, confirmed_count, observed_service_order_count) =
        state.store.counts().await?;
    Ok(web::Json(ServiceStatus {
        station_configured: state.poller.configured(),
        vehicle_configured: state.vehicle().is_some(),
        service_order_configured: state.service_order_configured,
        station_template_configured: state.station_template_configured,
        poll_interval_seconds: state.poll_interval.as_secs(),
        service_order_poll_interval_seconds: state.service_order_poll_interval.as_secs(),
        poll_in_progress: state.poller.in_progress(),
        last_poll: state.store.last_poll().await?,
        snapshot_count,
        candidate_count,
        confirmed_count,
        observed_service_order_count,
    }))
}

#[derive(Debug, Deserialize)]
struct EnergyStatsQuery {
    from: DateTime<Utc>,
    to: DateTime<Utc>,
}

async fn energy_stats(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<EnergyStatsQuery>,
) -> Result<web::Json<EnergyStats>, ApiError> {
    authorize(&state, &request)?;
    let (from, to) = (query.from, query.to);
    if to <= from || (to - from).num_days() > 3660 {
        return Err(ApiError::bad_request(
            "from must precede to; maximum interval is ten years",
        ));
    }
    let swaps = state.store.confirmed_swaps_between(from, to).await?;
    let (sample_from, sample_to) = analytics::charging_sample_window(from, to);
    let capacities = state
        .store
        .swap_battery_capacities_for_interval(sample_from, sample_to)
        .await?;
    let charging = state
        .store
        .charging_estimate_between(from, to, capacities)
        .await?;
    let china = FixedOffset::east_opt(8 * 3600).expect("valid China offset");
    let now = Utc::now().with_timezone(&china);
    let month_start = china
        .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .single()
        .expect("valid month start")
        .with_timezone(&Utc);
    let next_month = if now.month() == 12 {
        (now.year() + 1, 1)
    } else {
        (now.year(), now.month() + 1)
    };
    let month_end = china
        .with_ymd_and_hms(next_month.0, next_month.1, 1, 0, 0, 0)
        .single()
        .expect("valid next month")
        .with_timezone(&Utc);
    let month_count = state
        .store
        .count_confirmed_swaps_between(month_start, month_end)
        .await?;
    Ok(web::Json(analytics::calculate(
        from,
        to,
        &swaps,
        &charging,
        month_count,
    )))
}

async fn vehicle_status(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<serde_json::Value>, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    let payload = vehicle.status().await?;
    if let Some(snapshot) = snapshot_from_status(&payload)
        && let Err(error) = state.store.insert_vehicle_snapshot(&snapshot).await
    {
        tracing::warn!(%error, "failed to persist vehicle snapshot from status request");
    }
    Ok(web::Json(payload))
}

async fn vehicle_history(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<VehicleHistoryQuery>,
) -> Result<web::Json<VehicleSnapshotPage>, ApiError> {
    authorize(&state, &request)?;
    let limit = query.limit.clamp(1, 2000);
    let items = state.store.list_vehicle_snapshots(limit).await?;
    Ok(web::Json(VehicleSnapshotPage { items, limit }))
}

async fn vehicle_charging_current(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<VehicleChargingSamplePage>, ApiError> {
    authorize(&state, &request)?;
    Ok(web::Json(
        state
            .store
            .latest_vehicle_charging_session_page(5_000)
            .await?,
    ))
}

async fn vehicle_charging_sessions(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<VehicleChargingSessionsQuery>,
) -> Result<web::Json<VehicleChargingSessionPage>, ApiError> {
    authorize(&state, &request)?;
    let limit = query.limit.clamp(1, 100);
    let items = state.store.list_vehicle_charging_sessions(limit).await?;
    Ok(web::Json(VehicleChargingSessionPage { items, limit }))
}

async fn vehicle_charging_session(
    state: web::Data<AppState>,
    request: HttpRequest,
    session_id: web::Path<String>,
) -> Result<web::Json<VehicleChargingSamplePage>, ApiError> {
    authorize(&state, &request)?;
    let session_id = session_id.into_inner();
    let page = state
        .store
        .vehicle_charging_session_page(&session_id)
        .await?
        .ok_or_else(|| ApiError {
            status: StatusCode::NOT_FOUND,
            code: "charging_session_not_found",
            message: "charging session was not found".to_owned(),
        })?;
    Ok(web::Json(page))
}

async fn vehicle_trips(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<VehicleTripQuery>,
) -> Result<web::Json<VehicleTripPage>, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    let page = state
        .store
        .vehicle_trips(vehicle.vehicle_id(), query.count, query.query_time)
        .await?;
    if let Some(sync) = &state.trip_sync {
        // A full channel means one refresh is already queued. Never delay the response.
        let _ = sync.try_send(());
    }
    Ok(web::Json(page))
}

/// Vehicle identity plus whether the image bytes are cached. The image itself is
/// served by the image endpoint so a client never needs the NIO CDN.
async fn vehicle_profile(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<VehicleProfileResponse>, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    let vehicle_id = vehicle.vehicle_id();
    if let Some(profile) = state.store.vehicle_profile(vehicle_id).await? {
        return Ok(web::Json(profile.into()));
    }
    // Startup refresh may still be retrying; fill it in once on demand.
    if let Err(error) = crate::vehicle_profile::refresh(&state.store, &vehicle).await {
        tracing::warn!(%error, "on-demand vehicle profile refresh failed");
    }
    state
        .store
        .vehicle_profile(vehicle_id)
        .await?
        .map(VehicleProfileResponse::from)
        .map(web::Json)
        .ok_or_else(|| ApiError {
            status: StatusCode::NOT_FOUND,
            code: "vehicle_profile_not_found",
            message: "vehicle profile is not available yet".to_owned(),
        })
}

async fn vehicle_image(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<HttpResponse, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    let image = state
        .store
        .vehicle_profile_image(vehicle.vehicle_id())
        .await?
        .ok_or_else(|| ApiError {
            status: StatusCode::NOT_FOUND,
            code: "vehicle_image_not_found",
            message: "no cached vehicle image".to_owned(),
        })?;
    // The bytes only change when the upstream image URL changes, so a client can
    // keep them for as long as its ETag matches.
    let etag = image.sha256.as_ref().map(|sha| format!("\"{sha}\""));
    if let Some(etag) = &etag
        && request
            .headers()
            .get(actix_web::http::header::IF_NONE_MATCH)
            .and_then(|value| value.to_str().ok())
            == Some(etag.as_str())
    {
        return Ok(HttpResponse::NotModified()
            .insert_header((actix_web::http::header::ETAG, etag.clone()))
            .finish());
    }
    let mut response = HttpResponse::Ok();
    response.content_type(image.content_type);
    response.insert_header((
        actix_web::http::header::CACHE_CONTROL,
        "public, max-age=86400",
    ));
    if let Some(etag) = etag {
        response.insert_header((actix_web::http::header::ETAG, etag));
    }
    Ok(response.body(image.bytes))
}

/// Journey ids are upstream strings; reject anything that is not a plain
/// identifier so a bad path never reaches the database.
fn valid_journey_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

async fn vehicle_trip_track(
    state: web::Data<AppState>,
    request: HttpRequest,
    journey_id: web::Path<String>,
) -> Result<web::Json<VehicleTripTrack>, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    let journey_id = journey_id.into_inner();
    if !valid_journey_id(&journey_id) {
        return Err(ApiError {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_journey_id",
            message: "journey_id may only contain ASCII letters, digits, hyphens and underscores"
                .to_owned(),
        });
    }
    let points = state
        .store
        .vehicle_trip_track(vehicle.vehicle_id(), &journey_id)
        .await?;
    if points.is_empty() {
        return Err(ApiError {
            status: StatusCode::NOT_FOUND,
            code: "trip_track_not_found",
            message: "no stored GPS track for this journey".to_owned(),
        });
    }
    Ok(web::Json(VehicleTripTrack { journey_id, points }))
}

async fn vehicle_widget_info(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<serde_json::Value>, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    Ok(web::Json(vehicle.widget_info().await?))
}

async fn vehicle_action(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<ActionInput>,
) -> Result<web::Json<ActionOutcome>, ApiError> {
    authorize(&state, &request)?;
    let control = authorize_vehicle_control(&state, &request)?;
    let outcome = control.execute(input.into_inner()).await.map_err(|error| {
        let (status, code) = match error {
            ControlError::InvalidInput(_) => (StatusCode::BAD_REQUEST, "invalid_vehicle_action"),
            ControlError::PinUnavailable => {
                (StatusCode::SERVICE_UNAVAILABLE, "vehicle_pin_unavailable")
            }
            ControlError::UnsafeState => (StatusCode::CONFLICT, "vehicle_state_unsafe"),
            ControlError::NotVerified => (StatusCode::CONFLICT, "vehicle_action_unverified"),
            _ => (StatusCode::BAD_GATEWAY, "vehicle_action_failed"),
        };
        tracing::warn!(%error, "NIO vehicle action did not complete");
        ApiError {
            status,
            code,
            message: error.to_string(),
        }
    })?;
    Ok(web::Json(outcome))
}

async fn vehicle_route_switch(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<SendRouteSwitchOutcome>, ApiError> {
    authorize(&state, &request)?;
    let client = state.send_route().ok_or_else(vehicle_not_configured)?;
    Ok(web::Json(
        client.fetch_switch().await.map_err(send_route_error)?,
    ))
}

async fn resolve_route_vehicle_context(state: &AppState) -> RouteVehicleContext {
    let (position, model_type) = match state.vehicle() {
        Some(vehicle) => {
            let position = match vehicle.status().await {
                Ok(status) => current_vehicle_position(&status),
                Err(error) => {
                    tracing::debug!(%error, "vehicle position unavailable for route planning/send");
                    None
                }
            };
            let model_type = match state.store.vehicle_profile(vehicle.vehicle_id()).await {
                Ok(Some(profile)) => profile.model_type,
                _ => None,
            };
            (position, model_type)
        }
        None => (None, None),
    };
    RouteVehicleContext {
        position,
        model_type,
    }
}

async fn plan_vehicle_route(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<PlanRouteInput>,
) -> Result<web::Json<PlanRouteOutcome>, ApiError> {
    authorize(&state, &request)?;
    let client = state.send_route().ok_or_else(vehicle_not_configured)?;
    let vehicle_ctx = resolve_route_vehicle_context(&state).await;
    Ok(web::Json(
        client
            .plan_route(input.into_inner(), vehicle_ctx)
            .await
            .map_err(send_route_error)?,
    ))
}

async fn send_vehicle_route(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<SendRouteInput>,
) -> Result<web::Json<SendRouteOutcome>, ApiError> {
    authorize(&state, &request)?;
    let client = state.send_route().ok_or_else(vehicle_not_configured)?;
    let vehicle_ctx = resolve_route_vehicle_context(&state).await;
    Ok(web::Json(
        client
            .send_route(input.into_inner(), vehicle_ctx)
            .await
            .map_err(send_route_error)?,
    ))
}

async fn confirm_send_vehicle_route(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<ConfirmSendRouteInput>,
) -> Result<web::Json<SendRouteOutcome>, ApiError> {
    authorize(&state, &request)?;
    let client = state.send_route().ok_or_else(vehicle_not_configured)?;
    Ok(web::Json(
        client
            .confirm_send_route(input.into_inner())
            .await
            .map_err(send_route_error)?,
    ))
}

fn send_route_error(error: SendRouteError) -> ApiError {
    let (status, code) = match &error {
        SendRouteError::InvalidInput(_) => (StatusCode::BAD_REQUEST, "invalid_send_route_input"),
        SendRouteError::VehiclePositionUnavailable => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "vehicle_position_unavailable",
        ),
        SendRouteError::RoutePlanEmpty(_) => (StatusCode::BAD_GATEWAY, "route_plan_failed"),
        SendRouteError::InvalidAction => (StatusCode::BAD_REQUEST, "invalid_btn_action"),
        SendRouteError::ConfirmationExpired => (StatusCode::GONE, "confirmation_expired"),
        SendRouteError::VehicleChanged => (StatusCode::CONFLICT, "vehicle_changed"),
        SendRouteError::ResultUnknown(_) => {
            (StatusCode::GATEWAY_TIMEOUT, "send_route_result_unknown")
        }
        SendRouteError::Rejected { request_id, .. } => {
            tracing::warn!(
                error_code = "send_route_rejected",
                request_id = ?request_id,
                "NIO send-route request was rejected by upstream"
            );
            return ApiError {
                status: StatusCode::BAD_GATEWAY,
                code: "send_route_rejected",
                message: error.to_string(),
            };
        }
        _ => (StatusCode::BAD_GATEWAY, "send_route_upstream_error"),
    };
    tracing::warn!(error_code = code, "NIO send-route request did not complete");
    ApiError {
        status,
        code,
        message: error.to_string(),
    }
}

async fn create_swap_order(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<CreateSwapOrderInput>,
) -> Result<web::Json<CreateSwapOrderOutcome>, ApiError> {
    authorize(&state, &request)?;
    let runtime = authorize_swap_order(&state, &request)?;
    let input = input.into_inner();
    let station_id = input.station_id.clone();
    if !valid_station_id(&station_id) {
        return Err(ApiError::bad_request("station id is invalid"));
    }
    let template = state.station_template.as_ref().ok_or_else(|| ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "station_template_not_configured",
        message: "station request template is not configured".to_owned(),
    })?;
    let station_name = state
        .store
        .swap_station_by_id(&station_id)
        .await?
        .map(|station| station.station_name)
        .unwrap_or_else(|| station_id.clone());
    let provider_template = state
        .station_provider_template
        .get_or_try_init(|| async {
            NioStationProvider::new(StationConfig {
                key: "template".to_owned(),
                name: "Station request template".to_owned(),
                url: template.url_template.clone(),
                headers: template.headers.clone(),
            })
        })
        .await?;
    let provider = provider_template.retarget(
        station_id.clone(),
        station_name,
        template.url_template.replace("{station_id}", &station_id),
    );
    let coordinates = provider.fetch_coordinates().await?;
    state
        .store
        .update_swap_station_coordinates(&station_id, coordinates.latitude, coordinates.longitude)
        .await?;
    Ok(web::Json(
        runtime
            .create(input, coordinates)
            .await
            .map_err(swap_order_error)?,
    ))
}

async fn available_coupons(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<AvailableCouponsQuery>,
) -> Result<web::Json<AvailableCouponsPage>, ApiError> {
    authorize(&state, &request)?;
    if !(1..=100).contains(&query.limit) {
        return Err(ApiError::bad_request("limit must be between 1 and 100"));
    }
    let rewards = state.rewards().ok_or_else(rewards_not_configured)?;
    Ok(web::Json(
        rewards.available_coupons(query.limit, query.offset).await?,
    ))
}

async fn check_in(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<CheckInOutcome>, ApiError> {
    authorize(&state, &request)?;
    let rewards = state.rewards().ok_or_else(rewards_not_configured)?;
    let day = daily_checkin::china_day(Utc::now());
    match daily_checkin::perform_once(&state.store, &rewards, day).await {
        Ok(outcome) => Ok(web::Json(outcome)),
        Err(DailyCheckInError::AlreadyAttempted | DailyCheckInError::DateElapsed) => {
            Err(ApiError {
                status: StatusCode::CONFLICT,
                code: "check_in_already_attempted",
                message: "daily check-in has already been attempted for this Beijing date"
                    .to_owned(),
            })
        }
        Err(DailyCheckInError::Store(error)) => Err(error.into()),
        Err(DailyCheckInError::Rewards(error)) => Err(error.into()),
        Err(DailyCheckInError::RetryScheduled(error)) => Err(error.into()),
        Err(DailyCheckInError::PersistResult(error)) => {
            tracing::error!(%error, "failed to persist daily check-in result");
            Err(ApiError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                code: "check_in_result_not_recorded",
                message:
                    "check-in result could not be recorded; verify the NIO app before retrying"
                        .to_owned(),
            })
        }
    }
}

fn rewards_not_configured() -> ApiError {
    ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "rewards_disabled",
        message: "NIO account credentials are not configured".to_owned(),
    }
}

fn authorize_swap_order<'a>(
    state: &'a AppState,
    request: &HttpRequest,
) -> Result<&'a SwapOrderRuntime, ApiError> {
    authorize_vehicle_control(state, request)?;
    let runtime = state.swap_order.as_ref().ok_or_else(|| ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "swap_order_disabled",
        message: "swap-order creation is not configured".to_owned(),
    })?;
    Ok(runtime)
}

fn authorize_vehicle_control<'a>(
    state: &'a AppState,
    request: &HttpRequest,
) -> Result<&'a ControlRuntime, ApiError> {
    let control = state.control.as_ref().ok_or_else(|| ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "vehicle_control_disabled",
        message: "vehicle control is not configured".to_owned(),
    })?;
    let provided = request
        .headers()
        .get("x-vehicle-control-key")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(ApiError::unauthorized)?;
    if !bool::from(control.key.as_bytes().ct_eq(provided.as_bytes())) {
        return Err(ApiError::unauthorized());
    }
    Ok(control)
}

fn swap_order_error(error: SwapOrderError) -> ApiError {
    let (status, code) = match error {
        SwapOrderError::InvalidInput(_) => (StatusCode::BAD_REQUEST, "invalid_swap_order"),
        SwapOrderError::InvalidConfig(_) => {
            (StatusCode::SERVICE_UNAVAILABLE, "swap_order_disabled")
        }
        SwapOrderError::Rejected(_) => (StatusCode::CONFLICT, "swap_order_rejected"),
        _ => (StatusCode::BAD_GATEWAY, "swap_order_failed"),
    };
    tracing::warn!(%error, "NIO swap-order request did not complete");
    ApiError {
        status,
        code,
        message: error.to_string(),
    }
}

fn vehicle_not_configured() -> ApiError {
    ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "vehicle_not_configured",
        message: "NIO vehicle credentials are not configured".to_owned(),
    }
}

async fn list_swaps(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<ListQuery>,
) -> Result<web::Json<SwapEventPage>, ApiError> {
    if state.tenant_mode {
        authorize(&state, &request)?;
    }
    let limit = query.limit.clamp(1, 200);
    let items = state
        .store
        .list_events(limit, query.offset, query.include_candidates)
        .await?;
    Ok(web::Json(SwapEventPage {
        items,
        limit,
        offset: query.offset,
    }))
}

async fn get_swap(
    state: web::Data<AppState>,
    request: HttpRequest,
    id: web::Path<String>,
) -> Result<web::Json<crate::models::SwapEvent>, ApiError> {
    if state.tenant_mode {
        authorize(&state, &request)?;
    }
    state
        .store
        .event_by_id(&id)
        .await?
        .map(web::Json)
        .ok_or_else(ApiError::not_found)
}

async fn list_active_orders(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<ActiveServiceOrderPage>, ApiError> {
    authorize(&state, &request)?;
    let items = state.store.list_active_service_orders(20).await?;
    Ok(web::Json(ActiveServiceOrderPage { items }))
}

async fn list_stations(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<StationListQuery>,
) -> Result<web::Json<SwapStationPage>, ApiError> {
    authorize(&state, &request)?;
    let limit = query.limit.clamp(1, 200);
    let items = state
        .store
        .list_swap_stations(limit, query.offset, query.q.as_deref())
        .await?;
    Ok(web::Json(SwapStationPage {
        items,
        limit,
        offset: query.offset,
    }))
}

async fn search_stations(
    state: web::Data<AppState>,
    request: HttpRequest,
    query: web::Query<StationSearchQuery>,
) -> Result<web::Json<SwapStationSearchResult>, ApiError> {
    authorize(&state, &request)?;
    let name = normalize_search_name(&query.name).map_err(station_search_error)?;
    let local = state.store.list_swap_stations(50, 0, Some(&name)).await?;
    if !local.is_empty() {
        return Ok(web::Json(local_station_search_result(name, local)));
    }
    let client = state.station_search().ok_or_else(vehicle_not_configured)?;
    let result = client.search(&name).await.map_err(station_search_error)?;
    for station in &result.stations {
        if let (Some(latitude), Some(longitude)) = (station.latitude, station.longitude) {
            state
                .store
                .upsert_searched_swap_station(
                    &station.station_id,
                    &station.name,
                    station.address.as_deref(),
                    latitude,
                    longitude,
                )
                .await?;
        }
    }
    Ok(web::Json(result))
}

fn local_station_search_result(
    query: String,
    stations: Vec<SwapStation>,
) -> SwapStationSearchResult {
    SwapStationSearchResult {
        query,
        source: "local".to_owned(),
        request_id: None,
        stations: stations
            .into_iter()
            .map(|station| SwapStationSearchItem {
                station_id: station.station_id,
                name: station.station_name,
                address: station.station_address,
                longitude: station.longitude,
                latitude: station.latitude,
                icon_url: None,
            })
            .collect(),
    }
}

fn station_search_error(error: StationSearchError) -> ApiError {
    let (status, code) = match error {
        StationSearchError::InvalidName => (StatusCode::BAD_REQUEST, "invalid_request"),
        StationSearchError::Rejected(_) => (StatusCode::BAD_GATEWAY, "upstream_rejected"),
        _ => (StatusCode::BAD_GATEWAY, "upstream_error"),
    };
    tracing::warn!(%error, "NIO remote station search failed");
    ApiError {
        status,
        code,
        message: error.to_string(),
    }
}

async fn nearby_stations(
    state: web::Data<AppState>,
    request: HttpRequest,
    input: web::Json<NearbyStationsRequest>,
) -> Result<web::Json<NearbyStationResult>, ApiError> {
    authorize(&state, &request)?;
    if !route_estimate::valid_coordinate(input.latitude, input.longitude) {
        return Err(ApiError::bad_request(
            "valid latitude and longitude are required",
        ));
    }
    let client = state.nearby_stations().ok_or_else(vehicle_not_configured)?;
    Ok(web::Json(
        client
            .search(input.latitude, input.longitude)
            .await
            .map_err(|error| {
                tracing::warn!(%error, "NIO nearby station lookup failed");
                ApiError {
                    status: if matches!(error, NearbyError::InvalidCoordinates) {
                        StatusCode::BAD_REQUEST
                    } else {
                        StatusCode::BAD_GATEWAY
                    },
                    code: if matches!(error, NearbyError::InvalidCoordinates) {
                        "invalid_request"
                    } else {
                        "upstream_error"
                    },
                    message: error.to_string(),
                }
            })?,
    ))
}

async fn get_station(
    state: web::Data<AppState>,
    request: HttpRequest,
    station_id: web::Path<String>,
) -> Result<web::Json<crate::models::SwapStation>, ApiError> {
    authorize(&state, &request)?;
    state
        .store
        .swap_station_by_id(&station_id)
        .await?
        .map(web::Json)
        .ok_or_else(|| ApiError {
            status: StatusCode::NOT_FOUND,
            code: "station_not_found",
            message: "swap station was not found".to_owned(),
        })
}

async fn get_station_live(
    state: web::Data<AppState>,
    request: HttpRequest,
    station_id: web::Path<String>,
) -> Result<web::Json<StationLiveStatus>, ApiError> {
    authorize(&state, &request)?;
    let station_id = station_id.into_inner();
    if !valid_station_id(&station_id) {
        return Err(ApiError::bad_request("station id is invalid"));
    }
    Ok(web::Json(station_live(&state, station_id).await?))
}

/// Coordinates from the vehicle's last valid position sample. Parked vehicles
/// may sleep without updating the sample timestamp, so age is not rejected.
fn current_vehicle_position(status: &serde_json::Value) -> Option<(f64, f64)> {
    let snapshot = snapshot_from_status(status)?;
    Some((snapshot.latitude, snapshot.longitude))
}

/// Live status of the swap station nearest to the vehicle's reported position.
async fn nearest_station_live(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<NearestStationLive>, ApiError> {
    authorize(&state, &request)?;
    let vehicle = state.vehicle().ok_or_else(vehicle_not_configured)?;
    let status = vehicle.status().await?;
    let position_unavailable = || ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "vehicle_position_unavailable",
        message: "vehicle status did not contain a valid position sample".to_owned(),
    };
    let (latitude, longitude) =
        current_vehicle_position(&status).ok_or_else(position_unavailable)?;
    let nearby_client = state.nearby_stations().ok_or_else(vehicle_not_configured)?;
    let nearby = nearby_client
        .search(latitude, longitude)
        .await
        .map_err(|error| {
            tracing::warn!(%error, "NIO nearby station lookup failed");
            ApiError {
                status: StatusCode::BAD_GATEWAY,
                code: "upstream_error",
                message: error.to_string(),
            }
        })?;
    let nearest = nearby
        .stations
        .into_iter()
        .filter(|station| valid_station_id(&station.station_id))
        .min_by(|left, right| {
            left.straight_line_distance_km
                .total_cmp(&right.straight_line_distance_km)
        })
        .ok_or_else(|| ApiError {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "no_nearby_station",
            message: "no nearby swap station was found".to_owned(),
        })?;
    // Persist the identity so later lookups by ID can show the station name.
    if let Some(name) = nearest.name.as_deref()
        && let Err(error) = state
            .store
            .upsert_searched_swap_station(
                &nearest.station_id,
                name,
                None,
                nearest.latitude,
                nearest.longitude,
            )
            .await
    {
        tracing::warn!(%error, "failed to persist nearest station identity");
    }
    let live = station_live(&state, nearest.station_id.clone()).await?;
    Ok(web::Json(NearestStationLive {
        station_id: live.station_id,
        station_name: nearest.name.unwrap_or(live.station_name),
        straight_line_distance_km: nearest.straight_line_distance_km,
        captured_at: live.captured_at,
        current_fees: live.current_fees,
        fee_periods: live.fee_periods,
        fee_notices: live.fee_notices,
        fee_timezone: live.fee_timezone,
        is_scannable: live.is_scannable,
        status_tags: live.status_tags,
        notification: live.notification,
        queue: live.queue,
        battery_readiness: live.battery_readiness,
        available_75_count: live.available_75_count,
        available_75_batteries: live.available_75_batteries,
    }))
}

async fn station_live(state: &AppState, station_id: String) -> Result<StationLiveStatus, ApiError> {
    let template = state.station_template.as_ref().ok_or_else(|| ApiError {
        status: StatusCode::SERVICE_UNAVAILABLE,
        code: "station_template_not_configured",
        message: "station request template is not configured".to_owned(),
    })?;
    let station_name = state
        .store
        .swap_station_by_id(&station_id)
        .await?
        .map(|station| station.station_name)
        .unwrap_or_else(|| station_id.clone());
    let provider_template = state
        .station_provider_template
        .get_or_try_init(|| async {
            NioStationProvider::new(StationConfig {
                key: "template".to_owned(),
                name: "Station request template".to_owned(),
                url: template.url_template.clone(),
                headers: template.headers.clone(),
            })
        })
        .await?;
    let provider = provider_template.retarget(
        station_id.clone(),
        station_name.clone(),
        template.url_template.replace("{station_id}", &station_id),
    );
    let details = provider.fetch_live_details().await?;
    // Unknown catalogue IDs fall back to the name in the live payload itself.
    let station_name = details.station_name.clone().unwrap_or(station_name);
    let available_75_batteries = details
        .battery_readiness
        .iter()
        .filter(|battery| {
            battery.capacity_kwh == Some(75.0)
                && battery.battery_occupied == Some(false)
                && battery.progress_percent.is_some_and(|soc| soc >= 92.0)
        })
        .map(|battery| crate::models::StationAvailableBattery {
            battery_id: battery.battery_id.clone(),
            slot_id: battery.slot_id,
            battery_cap_series: battery.battery_cap_series,
            capacity_kwh: battery.capacity_kwh,
            soc_percent: battery.progress_percent,
            occupied: battery.battery_occupied.unwrap_or(false),
            production_date: battery.production_date,
        })
        .collect::<Vec<_>>();
    Ok(StationLiveStatus {
        station_id,
        station_name,
        captured_at: details.captured_at,
        current_fees: details.current_fees,
        fee_periods: details.fee_periods,
        fee_notices: details.fee_notices,
        fee_timezone: details.fee_timezone,
        is_scannable: details.is_scannable,
        status_tags: details.status_tags,
        notification: details.notification,
        queue: details.queue,
        battery_readiness: details.battery_readiness,
        available_75_count: available_75_batteries.len(),
        available_75_batteries,
    })
}

async fn straight_line_energy(
    state: web::Data<AppState>,
    request: HttpRequest,
    station_id: web::Path<String>,
    input: web::Json<StraightLineEnergyRequest>,
) -> Result<web::Json<StraightLineEnergyEstimate>, ApiError> {
    authorize(&state, &request)?;
    let station_id = station_id.into_inner();
    if !valid_station_id(&station_id)
        || !route_estimate::valid_coordinate(input.latitude, input.longitude)
    {
        return Err(ApiError::bad_request(
            "valid station id, latitude and longitude are required",
        ));
    }
    let supplied = match (input.station_latitude, input.station_longitude) {
        (None, None) => None,
        (Some(latitude), Some(longitude))
            if route_estimate::valid_coordinate(latitude, longitude) =>
        {
            Some((latitude, longitude))
        }
        _ => {
            return Err(ApiError::bad_request(
                "station_latitude and station_longitude must be supplied together as valid coordinates",
            ));
        }
    };
    let station = resolve_station_coordinates(&state.store, &station_id, supplied).await?;
    let cache = trip_energy::load_cache(&state.store, Utc::now())
        .await
        .map_err(|error| {
            tracing::error!(%error, "failed to load daily trip energy cache");
            ApiError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                code: "energy_cache_error",
                message: "daily trip energy cache could not be read".to_owned(),
            }
        })?;
    Ok(web::Json(route_estimate::calculate(
        station_id,
        station,
        (input.latitude, input.longitude),
        cache,
    )))
}

async fn resolve_station_coordinates(
    store: &Store,
    station_id: &str,
    supplied: Option<(f64, f64)>,
) -> Result<StationCoordinateBasis, ApiError> {
    let known = store.swap_station_by_id(station_id).await?;
    if let Some(station) = &known
        && let (Some(latitude), Some(longitude)) = (station.latitude, station.longitude)
        && route_estimate::valid_coordinate(latitude, longitude)
    {
        return Ok(StationCoordinateBasis {
            latitude,
            longitude,
            record_updated_at: Some(station.updated_at),
            source: "known_directory",
        });
    }
    if let Some((latitude, longitude)) = supplied {
        return Ok(StationCoordinateBasis {
            latitude,
            longitude,
            record_updated_at: None,
            source: "caller_supplied",
        });
    }
    Err(ApiError {
        status: if known.is_some() { StatusCode::UNPROCESSABLE_ENTITY } else { StatusCode::NOT_FOUND },
        code: if known.is_some() { "station_coordinates_unavailable" } else { "station_not_found" },
        message: "station coordinates are not in the known directory; provide coordinates from a nearby result".to_owned(),
    })
}

fn valid_station_id(value: &str) -> bool {
    value.starts_with("PS-NIO-")
        && value.len() > "PS-NIO-".len()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

async fn manual_poll(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<crate::models::PollOutcome>, ApiError> {
    authorize(&state, &request)?;
    Ok(web::Json(state.poller.poll_once_for("manual_api").await?))
}

async fn import_order(
    state: web::Data<AppState>,
    request: HttpRequest,
    order: web::Json<ImportedOrder>,
) -> Result<web::Json<crate::models::SwapEvent>, ApiError> {
    authorize(&state, &request)?;
    let mut order = order.into_inner();
    normalize_and_validate_order(&mut order)?;
    let should_poll_station = should_poll_for_order(&state, &order);
    let event = state.store.import_order(&order, state.match_window).await?;
    if should_poll_station {
        let poller = state.poller.clone();
        actix_web::rt::spawn(async move {
            match poller.poll_once_for("order_import").await {
                Ok(outcome) => tracing::info!(
                    outcome = %outcome.outcome,
                    snapshot_id = ?outcome.snapshot_id,
                    candidate_event_id = ?outcome.candidate_event_id,
                    "order-triggered station poll completed"
                ),
                Err(error) => tracing::warn!(%error, "order-triggered station poll failed"),
            }
        });
    }
    Ok(web::Json(event))
}

fn should_poll_for_order(state: &AppState, order: &ImportedOrder) -> bool {
    if !state.poller.configured() {
        return false;
    }
    if let Some(order_station_key) = order.station_key.as_deref()
        && state.poller.station_key() != Some(order_station_key)
    {
        return false;
    }
    let age_seconds = (Utc::now() - order.occurred_at)
        .num_seconds()
        .unsigned_abs();
    age_seconds <= state.match_window.as_secs()
}

fn authorize(state: &AppState, request: &HttpRequest) -> Result<(), ApiError> {
    let Some(expected) = state.api_key.as_deref() else {
        return Ok(());
    };
    let provided = request
        .headers()
        .get("x-api-key")
        .and_then(|value| value.to_str().ok())
        .or_else(|| {
            request
                .headers()
                .get(AUTHORIZATION)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.strip_prefix("Bearer "))
        });
    let Some(provided) = provided else {
        return Err(ApiError::unauthorized());
    };
    if expected.as_bytes().ct_eq(provided.as_bytes()).into() {
        Ok(())
    } else {
        Err(ApiError::unauthorized())
    }
}

async fn events(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<HttpResponse, ApiError> {
    authorize(&state, &request)?;
    let last_id = request
        .headers()
        .get("Last-Event-ID")
        .map(|v| v.to_str().unwrap_or(""));
    Ok(state.events.response(last_id).await?)
}

fn normalize_and_validate_order(order: &mut ImportedOrder) -> Result<(), ApiError> {
    order.order_no = order.order_no.trim().to_owned();
    if order.order_no.is_empty() || order.order_no.len() > 256 {
        return Err(ApiError::bad_request(
            "order_no must contain 1 to 256 characters",
        ));
    }
    validate_number("energy_kwh", order.energy_kwh, 0.0, 300.0)?;
    normalize_battery("outgoing_battery", &mut order.outgoing_battery)?;
    normalize_battery("incoming_battery", &mut order.incoming_battery)?;
    if let Some(station_key) = &mut order.station_key {
        *station_key = station_key.trim().to_owned();
        if station_key.is_empty() {
            order.station_key = None;
        }
    }
    if let Some(station_name) = &mut order.station_name {
        *station_name = station_name.trim().to_owned();
        if station_name.is_empty() {
            order.station_name = None;
        }
    }
    Ok(())
}

fn normalize_battery(name: &str, battery: &mut Option<ImportedBattery>) -> Result<(), ApiError> {
    let Some(battery) = battery else {
        return Ok(());
    };
    if let Some(id) = &mut battery.battery_id {
        *id = id.trim().to_owned();
        if id.is_empty() {
            battery.battery_id = None;
        }
    }
    validate_number(
        &format!("{name}.capacity_kwh"),
        battery.capacity_kwh,
        0.0,
        300.0,
    )?;
    validate_number(
        &format!("{name}.soc_percent"),
        battery.soc_percent,
        0.0,
        100.0,
    )?;
    Ok(())
}

fn validate_number(name: &str, value: Option<f64>, min: f64, max: f64) -> Result<(), ApiError> {
    if let Some(value) = value
        && (!value.is_finite() || !(min..=max).contains(&value))
    {
        return Err(ApiError::bad_request(format!(
            "{name} must be between {min} and {max}"
        )));
    }
    Ok(())
}

fn default_limit() -> u32 {
    50
}

fn default_vehicle_history_limit() -> u32 {
    2000
}

fn default_vehicle_trip_count() -> u32 {
    20
}

fn default_charging_session_limit() -> u32 {
    50
}

fn validate_live_activity_identifier(
    field: &'static str,
    raw: &str,
    max_len: usize,
) -> Result<String, ApiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.len() > max_len
        || !trimmed
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':'))
    {
        return Err(ApiError {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_live_activity_token",
            message: format!("{field} contains invalid characters or length"),
        });
    }
    Ok(trimmed.to_owned())
}

async fn register_live_activity_token(
    state: web::Data<AppState>,
    request: HttpRequest,
    body: web::Json<LiveActivityTokenRegistration>,
) -> Result<web::Json<LiveActivityTokenResponse>, ApiError> {
    authorize(&state, &request)?;
    let input = body.into_inner();
    let device_id = validate_live_activity_identifier("device_id", &input.device_id, 128)?;
    let push_token = validate_hex_token(&input.push_token).map_err(|message| ApiError {
        status: StatusCode::BAD_REQUEST,
        code: "invalid_live_activity_token",
        message: message.to_owned(),
    })?;
    let activity_id = match input.activity_id.as_deref() {
        Some(raw) if !raw.trim().is_empty() => {
            Some(validate_live_activity_identifier("activity_id", raw, 128)?)
        }
        _ => None,
    };
    if input.token_kind == LiveActivityTokenKind::ActivityUpdate && activity_id.is_none() {
        return Err(ApiError {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_live_activity_token",
            message: "activity_id is required for activity_update tokens".to_owned(),
        });
    }
    let session_key = match input.session_key.as_deref() {
        Some(raw) if !raw.trim().is_empty() => {
            Some(validate_live_activity_identifier("session_key", raw, 160)?)
        }
        _ => None,
    };
    let activity_mode = match input.activity_mode.as_deref().map(str::trim) {
        Some("charging") => Some("charging"),
        Some("swapQueue") | Some("swap_queue") => Some("swapQueue"),
        Some("") | None => None,
        Some(_) => {
            return Err(ApiError {
                status: StatusCode::BAD_REQUEST,
                code: "invalid_live_activity_token",
                message: "activity_mode must be charging or swapQueue".to_owned(),
            });
        }
    };
    let bundle_id = match input.bundle_id.as_deref() {
        Some(raw) if !raw.trim().is_empty() => {
            validate_live_activity_identifier("bundle_id", raw, 128)?
        }
        _ => state.live_activity.default_bundle_id(),
    };
    let apns_environment = input
        .apns_environment
        .unwrap_or_else(|| state.live_activity.default_environment());
    let token_id = match input.token_kind {
        LiveActivityTokenKind::PushToStart => format!("start:{device_id}"),
        LiveActivityTokenKind::ActivityUpdate => format!(
            "update:{device_id}:{}",
            activity_id.as_deref().unwrap_or("default")
        ),
    };
    state
        .store
        .upsert_live_activity_token(
            &token_id,
            &device_id,
            input.token_kind.as_str(),
            &push_token,
            activity_id.as_deref(),
            session_key.as_deref(),
            activity_mode,
            &bundle_id,
            apns_environment.as_str(),
        )
        .await?;
    tracing::info!(
        token_kind = input.token_kind.as_str(),
        apns_environment = apns_environment.as_str(),
        "registered live activity APNs token"
    );
    Ok(web::Json(LiveActivityTokenResponse {
        registered: true,
        apns_configured: state.live_activity.is_apns_configured(),
        token_kind: input.token_kind,
        apns_environment,
    }))
}

#[derive(Debug, Serialize)]
struct DeleteLiveActivityTokensResponse {
    deleted: u64,
}

async fn delete_live_activity_token(
    state: web::Data<AppState>,
    request: HttpRequest,
    body: web::Json<LiveActivityTokenDeleteInput>,
) -> Result<web::Json<DeleteLiveActivityTokensResponse>, ApiError> {
    authorize(&state, &request)?;
    let input = body.into_inner();
    let device_id = validate_live_activity_identifier("device_id", &input.device_id, 128)?;
    let activity_id = match input.activity_id.as_deref() {
        Some(raw) if !raw.trim().is_empty() => {
            Some(validate_live_activity_identifier("activity_id", raw, 128)?)
        }
        _ => None,
    };
    let deleted = state
        .store
        .delete_live_activity_tokens(
            &device_id,
            input.token_kind.map(LiveActivityTokenKind::as_str),
            activity_id.as_deref(),
        )
        .await?;
    Ok(web::Json(DeleteLiveActivityTokensResponse { deleted }))
}

async fn live_activity_status(
    state: web::Data<AppState>,
    request: HttpRequest,
) -> Result<web::Json<LiveActivityPushStatus>, ApiError> {
    authorize(&state, &request)?;
    Ok(web::Json(state.live_activity.status().await?))
}

async fn start_live_activity_simulation(
    state: web::Data<AppState>,
    request: HttpRequest,
    body: Option<web::Json<LiveActivitySimulationRequest>>,
) -> Result<web::Json<LiveActivitySimulationOutcome>, ApiError> {
    authorize(&state, &request)?;
    let mut input = body.map(web::Json::into_inner).unwrap_or(LiveActivitySimulationRequest {
        mode: crate::live_activity_push::LiveActivityMode::Charging,
        interval_seconds: 5,
        steps: 6,
        device_id: None,
    });
    if let Some(raw_device_id) = input.device_id.as_deref() {
        if raw_device_id.trim().is_empty() {
            input.device_id = None;
        } else {
            input.device_id = Some(validate_live_activity_identifier(
                "device_id",
                raw_device_id,
                128,
            )?);
        }
    }
    let outcome = state
        .live_activity
        .start_simulation(input)
        .await
        .map_err(map_simulation_error)?;
    Ok(web::Json(outcome))
}

async fn stop_live_activity_simulation(
    state: web::Data<AppState>,
    request: HttpRequest,
    body: Option<web::Json<LiveActivitySimulationStopInput>>,
) -> Result<web::Json<LiveActivitySimulationStopOutcome>, ApiError> {
    authorize(&state, &request)?;
    let input = body.map(web::Json::into_inner).unwrap_or_default();
    let device_id = match input.device_id.as_deref() {
        Some(raw) if !raw.trim().is_empty() => {
            Some(validate_live_activity_identifier("device_id", raw, 128)?)
        }
        _ => None,
    };
    let outcome = state
        .live_activity
        .stop_simulation(device_id.as_deref())
        .await
        .map_err(map_simulation_error)?;
    Ok(web::Json(outcome))
}

fn map_simulation_error(error: SimulationError) -> ApiError {
    match error {
        SimulationError::ApnsNotConfigured => ApiError {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "apns_not_configured",
            message: "服务端尚未配置 APNs .p8 凭证，请先在 .env 中设置 APNS_TEAM_ID / APNS_KEY_ID / APNS_PRIVATE_KEY_P8。".to_owned(),
        },
        SimulationError::NoRegisteredTokens => ApiError {
            status: StatusCode::BAD_REQUEST,
            code: "no_live_activity_tokens",
            message: "当前没有已注册的 Live Activity 推送令牌，请先在真机上同步令牌后再试。".to_owned(),
        },
        SimulationError::Store(err) => err.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::{App, http::header::CONTENT_TYPE, test};
    use chrono::{TimeZone, Utc};

    fn tenant_test_state(store: Store, key: &str) -> AppState {
        AppState {
            poller: Poller::new(None, store.clone()),
            events: EventHub::new(store.clone()),
            live_activity: Arc::new(LiveActivityCoordinator::new(store.clone(), None)),
            store,
            api_key: Some(Arc::from(key)),
            tenant_mode: true,
            poll_interval: Duration::from_secs(60),
            match_window: Duration::from_secs(1800),
            vehicle: Arc::new(std::sync::RwLock::new(None)),
            vehicle_login_seed: None,
            nio_login: None,
            tenant_persistence: None,
            trip_sync: None,
            control: None,
            swap_order: None,
            station_search: Arc::new(std::sync::RwLock::new(None)),
            nearby_stations: Arc::new(std::sync::RwLock::new(None)),
            rewards: Arc::new(std::sync::RwLock::new(None)),
            send_route: Arc::new(std::sync::RwLock::new(None)),
            service_order_configured: false,
            station_template_configured: false,
            station_template: None,
            station_provider_template: Arc::default(),
            service_order_poll_interval: Duration::from_secs(15),
            mcp_client: reqwest::Client::new(),
            mcp_origin: "http://127.0.0.1:1".into(),
            mcp_oauth: None,
        }
    }

    #[actix_web::test]
    async fn nearest_position_accepts_numeric_strings_and_old_parked_samples() {
        let now = Utc.with_ymd_and_hms(2026, 11, 15, 8, 0, 0).unwrap();
        let fresh = serde_json::json!({
            "data": {
                "vehicle_id": "vehicle-1",
                "position_status": {
                    "latitude": "31.2304",
                    "longitude": "121.4737",
                    "sample_time": now.timestamp_millis().to_string()
                }
            }
        });
        assert_eq!(current_vehicle_position(&fresh), Some((31.2304, 121.4737)));

        let old_sample = serde_json::json!({
            "data": {
                "vehicle_id": "vehicle-1",
                "position_status": {
                    "latitude": 31.2304,
                    "longitude": 121.4737,
                    "sample_time": now.timestamp_millis() - 901_000
                }
            }
        });
        assert_eq!(
            current_vehicle_position(&old_sample),
            Some((31.2304, 121.4737))
        );
    }

    #[actix_web::test]
    async fn tenant_routes_require_their_own_key() {
        let default_store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let alice_store = Store::in_memory().await.unwrap();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(tenant_test_state(
                    default_store,
                    "default-key",
                )))
                .configure(configure)
                .service(
                    web::scope("/t/alice")
                        .app_data(web::Data::new(tenant_test_state(alice_store, "alice-key")))
                        .configure(configure),
                ),
        )
        .await;
        for (path, key, expected) in [
            ("/api/v1/status", None, StatusCode::UNAUTHORIZED),
            ("/api/v1/events", None, StatusCode::UNAUTHORIZED),
            ("/t/alice/api/v1/events", None, StatusCode::UNAUTHORIZED),
            (
                "/t/alice/api/v1/events",
                Some("default-key"),
                StatusCode::UNAUTHORIZED,
            ),
            ("/t/alice/api/v1/events", Some("alice-key"), StatusCode::OK),
            ("/api/v1/events", Some("default-key"), StatusCode::OK),
            ("/t/alice/api/v1/status", None, StatusCode::UNAUTHORIZED),
            (
                "/t/alice/api/v1/status",
                Some("default-key"),
                StatusCode::UNAUTHORIZED,
            ),
            ("/t/alice/api/v1/status", Some("alice-key"), StatusCode::OK),
            ("/api/v1/status", Some("default-key"), StatusCode::OK),
        ] {
            let mut request = test::TestRequest::get().uri(path);
            if let Some(key) = key {
                request = request.insert_header(("X-API-Key", key));
            }
            let response = test::call_service(&app, request.to_request()).await;
            assert_eq!(response.status(), expected, "{path}");
        }
    }

    #[actix_web::test]
    async fn journey_ids_are_restricted_to_path_safe_identifiers() {
        assert!(valid_journey_id("1794288460"));
        assert!(valid_journey_id("a-b_c9"));
        assert!(!valid_journey_id(""));
        assert!(!valid_journey_id("../etc/passwd"));
        assert!(!valid_journey_id("a b"));
        assert!(!valid_journey_id("行程"));
        assert!(!valid_journey_id(&"9".repeat(129)));
    }

    #[actix_web::test]
    async fn trips_return_stored_page_before_triggering_upstream_sync() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let vehicle = NioVehicleClient::new(crate::config::VehicleConfig {
            bearer_token: "unused".into(),
            account_id: None,
            vehicle_id: "test-vehicle".into(),
            device_id: "unused".into(),
            app_id: "unused".into(),
            app_version: "unused".into(),
            region: "cn".into(),
            language: "zh-CN".into(),
            vin_code: None,
        })
        .unwrap();
        let (trigger, mut receiver) = tokio::sync::mpsc::channel(1);
        let state = web::Data::new(AppState {
            poller: Poller::new(None, store.clone()),
            events: EventHub::new(store.clone()),
            live_activity: Arc::new(LiveActivityCoordinator::new(store.clone(), None)),
            store,
            api_key: Some(Arc::from("test-key")),
            tenant_mode: false,
            poll_interval: Duration::from_secs(60),
            match_window: Duration::from_secs(1_800),
            vehicle: Arc::new(std::sync::RwLock::new(Some(vehicle))),
            vehicle_login_seed: None,
            nio_login: None,
            tenant_persistence: None,
            trip_sync: Some(trigger),
            control: None,
            swap_order: None,
            station_search: Arc::new(std::sync::RwLock::new(None)),
            nearby_stations: Arc::new(std::sync::RwLock::new(None)),
            rewards: Arc::new(std::sync::RwLock::new(None)),
            send_route: Arc::new(std::sync::RwLock::new(None)),
            service_order_configured: false,
            station_template_configured: false,
            station_template: None,
            station_provider_template: Arc::default(),
            service_order_poll_interval: Duration::from_secs(15),
            mcp_client: reqwest::Client::new(),
            mcp_origin: "http://127.0.0.1:1".into(),
            mcp_oauth: None,
        });
        let request = test::TestRequest::get()
            .insert_header(("X-API-Key", "test-key"))
            .to_http_request();
        let page = vehicle_trips(
            state.clone(),
            request,
            web::Query(VehicleTripQuery {
                count: 20,
                query_time: None,
            }),
        )
        .await
        .unwrap()
        .into_inner();
        assert!(page.items.is_empty());
        assert!(!page.has_more);
        assert!(receiver.try_recv().is_ok());
        // No network call is made in the handler, even with an invalid upstream token.
    }

    #[actix_web::test]
    async fn actix_routes_preserve_auth_and_json_contracts() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        store
            .upsert_swap_station(&crate::models::ObservedSwapStation {
                station_id: "PS-NIO-api-test".to_owned(),
                station_name: "API Test Station".to_owned(),
                station_address: None,
                operator_id: Some("NIO".to_owned()),
                operator_name: Some("NIO Power".to_owned()),
                source_order_no: "api-order".to_owned(),
                observed_at: Utc.with_ymd_and_hms(2026, 10, 9, 12, 0, 0).unwrap(),
            })
            .await
            .unwrap();
        let active_order = crate::models::ObservedServiceOrder {
            order_no: "active-api-order".to_owned(),
            order_type: "pe_shaman_change".to_owned(),
            order_status: Some("10".to_owned()),
            order_status_name: Some("换电中".to_owned()),
            created_at: Utc.with_ymd_and_hms(2026, 10, 9, 12, 5, 0).unwrap(),
            vehicle_id: Some("vehicle-1".to_owned()),
            vin_code: Some("VIN-1".to_owned()),
            station_key: Some("PS-NIO-api-test".to_owned()),
            station_name: Some("API Test Station".to_owned()),
            station_address: None,
            raw_payload: serde_json::json!({"orderNo": "active-api-order"}),
        };
        store.observe_service_order(&active_order).await.unwrap();
        store
            .set_active_service_orders(std::slice::from_ref(&active_order.order_no))
            .await
            .unwrap();
        let verification_store = store.clone();
        let state = web::Data::new(AppState {
            poller: Poller::new(None, store.clone()),
            events: EventHub::new(store.clone()),
            live_activity: Arc::new(LiveActivityCoordinator::new(store.clone(), None)),
            store,
            api_key: Some(Arc::from("test-key")),
            tenant_mode: false,
            poll_interval: Duration::from_secs(60),
            match_window: Duration::from_secs(1_800),
            vehicle: Arc::new(std::sync::RwLock::new(None)),
            vehicle_login_seed: None,
            nio_login: None,
            tenant_persistence: None,
            trip_sync: None,
            control: None,
            swap_order: None,
            station_search: Arc::new(std::sync::RwLock::new(None)),
            nearby_stations: Arc::new(std::sync::RwLock::new(None)),
            rewards: Arc::new(std::sync::RwLock::new(None)),
            send_route: Arc::new(std::sync::RwLock::new(None)),
            service_order_configured: false,
            station_template_configured: false,
            station_template: None,
            station_provider_template: Arc::default(),
            service_order_poll_interval: Duration::from_secs(15),
            mcp_client: reqwest::Client::new(),
            mcp_origin: "http://127.0.0.1:1".to_owned(),
            mcp_oauth: None,
        });
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state.mcp_oauth.clone()))
                .app_data(state)
                .app_data(json_config())
                .configure(configure),
        )
        .await;

        let health_request = test::TestRequest::get().uri("/healthz").to_request();
        let health_response = test::call_service(&app, health_request).await;
        assert_eq!(health_response.status(), StatusCode::OK);
        let health_body: serde_json::Value = test::read_body_json(health_response).await;
        assert_eq!(health_body["status"], "ok");

        let unauthorized_request = test::TestRequest::post().uri("/api/v1/poll").to_request();
        let unauthorized_response = test::call_service(&app, unauthorized_request).await;
        assert_eq!(unauthorized_response.status(), StatusCode::UNAUTHORIZED);
        let unauthorized_body: serde_json::Value =
            test::read_body_json(unauthorized_response).await;
        assert_eq!(unauthorized_body["error"], "unauthorized");

        let station_request = test::TestRequest::get()
            .uri("/api/v1/stations/PS-NIO-api-test")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .to_request();
        let station_response = test::call_service(&app, station_request).await;
        assert_eq!(station_response.status(), StatusCode::OK);
        let station_body: serde_json::Value = test::read_body_json(station_response).await;
        assert_eq!(station_body["station_name"], "API Test Station");

        let invalid_energy = test::TestRequest::post()
            .uri("/api/v1/stations/PS-NIO-api-test/straight-line-energy")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({"latitude":91.0,"longitude":121.0}))
            .to_request();
        let invalid_energy_response = test::call_service(&app, invalid_energy).await;
        assert_eq!(invalid_energy_response.status(), StatusCode::BAD_REQUEST);
        let invalid_energy_body: serde_json::Value =
            test::read_body_json(invalid_energy_response).await;
        assert_eq!(invalid_energy_body["error"], "invalid_request");

        let unknown_energy = test::TestRequest::post()
            .uri("/api/v1/stations/PS-NIO-unknown-energy/straight-line-energy")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({"latitude":31.0,"longitude":121.0}))
            .to_request();
        let unknown_energy_response = test::call_service(&app, unknown_energy).await;
        assert_eq!(unknown_energy_response.status(), StatusCode::NOT_FOUND);

        let now = Utc::now();
        let day = crate::daily_checkin::china_day(now);
        let mut summary = trip_energy::summarize(&[], now, now, 0, false);
        summary.actual_distance_km = 100.0;
        summary.covered_distance_km = 100.0;
        summary.included_energy_kwh = 20.0;
        summary.consumption_kwh_per_100km = Some(20.0);
        summary.coverage_complete = true;
        summary.coverage_status = "complete".to_owned();
        verification_store
            .schedule_trip_energy_day(day, now)
            .await
            .unwrap();
        assert!(verification_store.claim_trip_energy_day(day).await.unwrap());
        verification_store
            .finish_trip_energy_day_success(day, &serde_json::to_string(&summary).unwrap())
            .await
            .unwrap();
        let new_station_id = "PS-NIO-nearby-only";
        assert!(
            verification_store
                .swap_station_by_id(new_station_id)
                .await
                .unwrap()
                .is_none()
        );
        let nearby_energy = test::TestRequest::post()
            .uri("/api/v1/stations/PS-NIO-nearby-only/straight-line-energy")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({
                "latitude":31.0,"longitude":121.0,
                "station_latitude":31.1,"station_longitude":121.0
            }))
            .to_request();
        let nearby_energy_response = test::call_service(&app, nearby_energy).await;
        assert_eq!(nearby_energy_response.status(), StatusCode::OK);
        let nearby_energy_body: serde_json::Value =
            test::read_body_json(nearby_energy_response).await;
        assert_eq!(nearby_energy_body["station_id"], new_station_id);
        assert_eq!(
            nearby_energy_body["station_coordinates_source"],
            "caller_supplied"
        );
        assert_eq!(nearby_energy_body["straight_line_distance_km"], 11.1);
        assert_eq!(
            nearby_energy_body["estimated_energy_for_straight_line_kwh"],
            2.22
        );
        assert_eq!(nearby_energy_body["energy_cache"]["status"], "fresh");
        assert!(nearby_energy_body.get("latitude").is_none());
        assert!(nearby_energy_body.get("longitude").is_none());
        assert!(
            verification_store
                .swap_station_by_id(new_station_id)
                .await
                .unwrap()
                .is_none()
        );

        let half_pair = test::TestRequest::post()
            .uri("/api/v1/stations/PS-NIO-nearby-only/straight-line-energy")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(
                serde_json::json!({"latitude":31.0,"longitude":121.0,"station_latitude":31.1}),
            )
            .to_request();
        assert_eq!(
            test::call_service(&app, half_pair).await.status(),
            StatusCode::BAD_REQUEST
        );
        assert!(!valid_station_id("PS-NIO-"));
        assert!(!valid_station_id("PS-NIO-bad/slash"));
        let out_of_range_station = test::TestRequest::post()
            .uri("/api/v1/stations/PS-NIO-nearby-only/straight-line-energy")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({
                "latitude":31.0,"longitude":121.0,
                "station_latitude":91.0,"station_longitude":121.0
            }))
            .to_request();
        assert_eq!(
            test::call_service(&app, out_of_range_station)
                .await
                .status(),
            StatusCode::BAD_REQUEST
        );

        let local_search_request = test::TestRequest::get()
            .uri("/api/v1/stations/search?name=API")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .to_request();
        let local_search_response = test::call_service(&app, local_search_request).await;
        assert_eq!(local_search_response.status(), StatusCode::OK);
        let local_search_body: serde_json::Value =
            test::read_body_json(local_search_response).await;
        assert_eq!(local_search_body["source"], "local");
        assert_eq!(
            local_search_body["stations"][0]["station_id"],
            "PS-NIO-api-test"
        );

        let remote_search_request = test::TestRequest::get()
            .uri("/api/v1/stations/search?name=%E6%BB%A8%E6%B5%B7")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .to_request();
        let remote_search_response = test::call_service(&app, remote_search_request).await;
        assert_eq!(
            remote_search_response.status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
        let remote_search_body: serde_json::Value =
            test::read_body_json(remote_search_response).await;
        assert_eq!(remote_search_body["error"], "vehicle_not_configured");

        let invalid_nearby_request = test::TestRequest::post()
            .uri("/api/v1/stations/nearby")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({"latitude":91.0,"longitude":121.0}))
            .to_request();
        let invalid_nearby_response = test::call_service(&app, invalid_nearby_request).await;
        assert_eq!(invalid_nearby_response.status(), StatusCode::BAD_REQUEST);
        let disabled_nearby_request = test::TestRequest::post()
            .uri("/api/v1/stations/nearby")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({"latitude":31.0,"longitude":121.0}))
            .to_request();
        let disabled_nearby_response = test::call_service(&app, disabled_nearby_request).await;
        assert_eq!(
            disabled_nearby_response.status(),
            StatusCode::SERVICE_UNAVAILABLE
        );

        let active_orders_request = test::TestRequest::get()
            .uri("/api/v1/orders/active")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .to_request();
        let active_orders_response = test::call_service(&app, active_orders_request).await;
        assert_eq!(active_orders_response.status(), StatusCode::OK);
        let active_orders_body: serde_json::Value =
            test::read_body_json(active_orders_response).await;
        assert_eq!(
            active_orders_body["items"][0]["order_no"],
            "active-api-order"
        );
        assert_eq!(
            active_orders_body["items"][0]["station_key"],
            "PS-NIO-api-test"
        );

        let missing_vehicle_request = test::TestRequest::get()
            .uri("/api/v1/vehicle/status")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .to_request();
        let missing_vehicle_response = test::call_service(&app, missing_vehicle_request).await;
        assert_eq!(
            missing_vehicle_response.status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
        let missing_vehicle_body: serde_json::Value =
            test::read_body_json(missing_vehicle_response).await;
        assert_eq!(missing_vehicle_body["error"], "vehicle_not_configured");

        let action_body =
            serde_json::json!({"action":"ac-on","confirmation":"START AC","temperature":24});
        let unauthorized_action = test::TestRequest::post()
            .uri("/api/v1/vehicle/action")
            .set_json(&action_body)
            .to_request();
        let unauthorized_action_response = test::call_service(&app, unauthorized_action).await;
        assert_eq!(
            unauthorized_action_response.status(),
            StatusCode::UNAUTHORIZED
        );
        let disabled_action = test::TestRequest::post()
            .uri("/api/v1/vehicle/action")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(&action_body)
            .to_request();
        let disabled_action_response = test::call_service(&app, disabled_action).await;
        assert_eq!(
            disabled_action_response.status(),
            StatusCode::SERVICE_UNAVAILABLE
        );

        let swap_order_body = serde_json::json!({
            "station_id": "PS-NIO-api-test",
            "confirmation": "CREATE SWAP ORDER"
        });
        let unauthorized_swap_order = test::TestRequest::post()
            .uri("/api/v1/swap-orders")
            .set_json(&swap_order_body)
            .to_request();
        let unauthorized_swap_order_response =
            test::call_service(&app, unauthorized_swap_order).await;
        assert_eq!(
            unauthorized_swap_order_response.status(),
            StatusCode::UNAUTHORIZED
        );
        let disabled_swap_order = test::TestRequest::post()
            .uri("/api/v1/swap-orders")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(&swap_order_body)
            .to_request();
        let disabled_swap_order_response = test::call_service(&app, disabled_swap_order).await;
        assert_eq!(
            disabled_swap_order_response.status(),
            StatusCode::SERVICE_UNAVAILABLE
        );

        let mcp_list = test::TestRequest::post()
            .uri("/mcp")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(serde_json::json!({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}))
            .to_request();
        let mcp_list_response = test::call_service(&app, mcp_list).await;
        assert_eq!(mcp_list_response.status(), StatusCode::OK);
        let mcp_list_body: serde_json::Value = test::read_body_json(mcp_list_response).await;
        let tools = mcp_list_body["result"]["tools"].as_array().unwrap();
        assert!(
            tools
                .iter()
                .any(|tool| tool["name"] == "nio_create_swap_order")
        );
        assert!(
            tools
                .iter()
                .any(|tool| tool["name"] == "nio_available_coupons")
        );
        assert!(tools.iter().any(|tool| tool["name"] == "nio_check_in"));
        let energy_tool = tools
            .iter()
            .find(|tool| tool["name"] == "nio_straight_line_energy")
            .unwrap();
        assert_eq!(energy_tool["annotations"]["readOnlyHint"], true);
        assert_eq!(energy_tool["annotations"]["destructiveHint"], false);
        assert!(
            energy_tool["inputSchema"]["properties"]["body"]["properties"]
                .get("recent_trip_count")
                .is_none()
        );
        assert_eq!(
            energy_tool["inputSchema"]["properties"]["body"]["dependentRequired"]["station_latitude"],
            serde_json::json!(["station_longitude"])
        );
        let nearby_tool = tools
            .iter()
            .find(|tool| tool["name"] == "nio_nearby_swap_stations")
            .unwrap();
        assert_eq!(nearby_tool["annotations"]["readOnlyHint"], true);
        assert_eq!(nearby_tool["annotations"]["openWorldHint"], true);
        assert_eq!(
            energy_tool["inputSchema"]["properties"]["body"]["required"],
            serde_json::json!(["latitude", "longitude"])
        );
        assert_eq!(
            tools
                .iter()
                .find(|tool| tool["name"] == "nio_vehicle_status")
                .unwrap()["annotations"]["readOnlyHint"],
            false
        );
        assert!(
            tools
                .iter()
                .all(|tool| tool["name"] != "nio_vehicle_action")
        );
        let mcp_order_without_control_key = test::TestRequest::post()
            .uri("/mcp")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(
                serde_json::json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
                    "name":"nio_create_swap_order","arguments":{"body":swap_order_body}
                }}),
            )
            .to_request();
        let mcp_order_response = test::call_service(&app, mcp_order_without_control_key).await;
        assert_eq!(mcp_order_response.status(), StatusCode::OK);
        let mcp_order_body: serde_json::Value = test::read_body_json(mcp_order_response).await;
        assert_eq!(mcp_order_body["result"]["isError"], true);
        assert!(
            mcp_order_body["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("X-Vehicle-Control-Key")
        );

        for (method, path) in [
            ("GET", "/api/v1/coupons/available"),
            ("POST", "/api/v1/check-in"),
        ] {
            let unauthorized = test::TestRequest::default()
                .method(method.parse().unwrap())
                .uri(path)
                .to_request();
            assert_eq!(
                test::call_service(&app, unauthorized).await.status(),
                StatusCode::UNAUTHORIZED
            );
            let disabled = test::TestRequest::default()
                .method(method.parse().unwrap())
                .uri(path)
                .insert_header((AUTHORIZATION, "Bearer test-key"))
                .to_request();
            assert_eq!(
                test::call_service(&app, disabled).await.status(),
                StatusCode::SERVICE_UNAVAILABLE
            );
        }

        let malformed_request = test::TestRequest::post()
            .uri("/api/v1/orders/import")
            .insert_header((CONTENT_TYPE, "application/json"))
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_payload("{not-json")
            .to_request();
        let malformed_response = test::call_service(&app, malformed_request).await;
        assert_eq!(malformed_response.status(), StatusCode::BAD_REQUEST);
        let malformed_body: serde_json::Value = test::read_body_json(malformed_response).await;
        assert_eq!(malformed_body["error"], "invalid_request");

        let order = ImportedOrder {
            order_no: "actix-order".to_owned(),
            occurred_at: Utc.with_ymd_and_hms(2026, 10, 9, 12, 0, 0).unwrap(),
            station_key: Some("station".to_owned()),
            station_name: Some("Station".to_owned()),
            station_address: None,
            order_status_name: None,
            price_amount: None,
            price_currency: None,
            price_description: None,
            payment_items: vec![],
            energy_kwh: Some(42.5),
            outgoing_battery: None,
            incoming_battery: None,
            raw_payload: None,
        };
        let import_request = test::TestRequest::post()
            .uri("/api/v1/orders/import")
            .insert_header((AUTHORIZATION, "Bearer test-key"))
            .set_json(&order)
            .to_request();
        let import_response = test::call_service(&app, import_request).await;
        assert_eq!(import_response.status(), StatusCode::OK);
        let imported: serde_json::Value = test::read_body_json(import_response).await;
        assert_eq!(imported["order_no"], "actix-order");
        assert_eq!(imported["exact_energy_kwh"], 42.5);

        let list_request = test::TestRequest::get().uri("/api/v1/swaps").to_request();
        let list_response = test::call_service(&app, list_request).await;
        assert_eq!(list_response.status(), StatusCode::OK);
        let list_body: serde_json::Value = test::read_body_json(list_response).await;
        assert_eq!(list_body["items"].as_array().map(Vec::len), Some(1));
    }

    #[actix_web::test]
    async fn hot_reload_vehicle_token_updates_existing_clients_and_initializes_from_seed() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };

        // Case 1: Existing vehicle client shares token with clones; hot-reload updates in place.
        let seed = crate::config::VehicleLoginSeed {
            account_id: None,
            vehicle_id: "veh-hot".to_owned(),
            device_id: "dev-hot".to_owned(),
            app_id: "10001".to_owned(),
            app_version: "6.4.0".to_owned(),
            region: "cn".to_owned(),
            language: "zh".to_owned(),
            vin_code: None,
        };
        let initial_config = seed.to_vehicle_config("old-token");
        let existing_client = NioVehicleClient::new(initial_config.clone()).unwrap();
        let cloned_background_client = existing_client.clone();

        let mut warm_state = tenant_test_state(store.clone(), "warm-key");
        warm_state.vehicle = Arc::new(std::sync::RwLock::new(Some(existing_client)));
        assert!(!warm_state.hot_reload_vehicle_token(""));
        assert!(!warm_state.hot_reload_vehicle_token("bad token with space"));
        assert_eq!(cloned_background_client.current_bearer_token(), "old-token");

        assert!(warm_state.hot_reload_vehicle_token("new-rotated-token"));
        assert_eq!(
            warm_state.vehicle().unwrap().current_bearer_token(),
            "new-rotated-token"
        );
        assert_eq!(
            cloned_background_client.current_bearer_token(),
            "new-rotated-token"
        );
        assert_eq!(initial_config.current_bearer_token(), "new-rotated-token");

        // Case 2: Cold start with neither vehicle nor seed cannot hot-reload.
        let empty_state = tenant_test_state(store.clone(), "empty-key");
        assert!(!empty_state.hot_reload_vehicle_token("some-token"));
        assert!(empty_state.vehicle().is_none());

        // Case 3: Cold start with vehicle_login_seed hot-initializes clients and flips /api/v1/status.
        let mut cold_state = tenant_test_state(store, "cold-key");
        cold_state.vehicle_login_seed = Some(seed);
        let shared_cold_state = web::Data::new(cold_state);
        let app = test::init_service(
            App::new()
                .app_data(shared_cold_state.clone())
                .configure(configure),
        )
        .await;

        let before = test::call_service(
            &app,
            test::TestRequest::get()
                .uri("/api/v1/status")
                .insert_header((AUTHORIZATION, "Bearer cold-key"))
                .to_request(),
        )
        .await;
        assert_eq!(before.status(), StatusCode::OK);
        let before_body: serde_json::Value = test::read_body_json(before).await;
        assert_eq!(before_body["vehicle_configured"], false);

        assert!(shared_cold_state.hot_reload_vehicle_token("first-login-token"));
        let first_vehicle = shared_cold_state
            .vehicle()
            .expect("vehicle client should be initialized");
        assert_eq!(first_vehicle.current_bearer_token(), "first-login-token");
        assert!(shared_cold_state.station_search().is_some());
        assert!(shared_cold_state.nearby_stations().is_some());
        assert!(shared_cold_state.rewards().is_some());

        let after = test::call_service(
            &app,
            test::TestRequest::get()
                .uri("/api/v1/status")
                .insert_header((AUTHORIZATION, "Bearer cold-key"))
                .to_request(),
        )
        .await;
        assert_eq!(after.status(), StatusCode::OK);
        let after_body: serde_json::Value = test::read_body_json(after).await;
        assert_eq!(after_body["vehicle_configured"], true);

        // Subsequent token refresh updates the same shared token without splitting clones.
        assert!(shared_cold_state.hot_reload_vehicle_token("second-login-token"));
        assert_eq!(first_vehicle.current_bearer_token(), "second-login-token");
    }

    #[actix_web::test]
    async fn live_activity_token_endpoints_register_status_and_delete() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };

        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(tenant_test_state(store, "la-key")))
                .configure(configure),
        )
        .await;

        // Auth is required.
        let unauth = test::call_service(
            &app,
            test::TestRequest::get()
                .uri("/api/v1/live-activities/status")
                .to_request(),
        )
        .await;
        assert_eq!(unauth.status(), StatusCode::UNAUTHORIZED);

        // Reject invalid hex push token.
        let bad_token = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/api/v1/live-activities/tokens")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .set_json(serde_json::json!({
                    "device_id": "iphone-1",
                    "token_kind": "push_to_start",
                    "push_token": "not-valid-hex!",
                    "environment": "sandbox"
                }))
                .to_request(),
        )
        .await;
        assert_eq!(bad_token.status(), StatusCode::BAD_REQUEST);

        // Register push-to-start token.
        let register_start = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/api/v1/live-activities/tokens")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .set_json(serde_json::json!({
                    "device_id": "iphone-1",
                    "token_kind": "push_to_start",
                    "push_token": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    "environment": "sandbox"
                }))
                .to_request(),
        )
        .await;
        assert_eq!(register_start.status(), StatusCode::OK);
        let start_body: serde_json::Value = test::read_body_json(register_start).await;
        assert_eq!(start_body["token_kind"], "push_to_start");
        assert_eq!(start_body["apns_configured"], false);

        // Register activity update token.
        let register_update = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/api/v1/live-activities/tokens")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .set_json(serde_json::json!({
                    "device_id": "iphone-1",
                    "token_kind": "activity_update",
                    "push_token": "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
                    "activity_id": "act-1",
                    "session_key": "charging:veh-1",
                    "activity_mode": "charging",
                    "environment": "sandbox"
                }))
                .to_request(),
        )
        .await;
        assert_eq!(register_update.status(), StatusCode::OK);

        // Status reflects both active tokens.
        let status = test::call_service(
            &app,
            test::TestRequest::get()
                .uri("/api/v1/live-activities/status")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .to_request(),
        )
        .await;
        assert_eq!(status.status(), StatusCode::OK);
        let status_body: serde_json::Value = test::read_body_json(status).await;
        assert_eq!(status_body["apns_configured"], false);
        assert_eq!(status_body["push_to_start_token_count"], 1);
        assert_eq!(status_body["activity_update_token_count"], 1);

        // Delete only activity_update token for act-1.
        let delete_update = test::call_service(
            &app,
            test::TestRequest::delete()
                .uri("/api/v1/live-activities/tokens")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .set_json(serde_json::json!({
                    "device_id": "iphone-1",
                    "token_kind": "activity_update",
                    "activity_id": "act-1"
                }))
                .to_request(),
        )
        .await;
        assert_eq!(delete_update.status(), StatusCode::OK);
        let delete_body: serde_json::Value = test::read_body_json(delete_update).await;
        assert_eq!(delete_body["deleted"], 1);

        let status_after = test::call_service(
            &app,
            test::TestRequest::get()
                .uri("/api/v1/live-activities/status")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .to_request(),
        )
        .await;
        let status_after_body: serde_json::Value = test::read_body_json(status_after).await;
        assert_eq!(status_after_body["push_to_start_token_count"], 1);
        assert_eq!(status_after_body["activity_update_token_count"], 0);

        // Simulation requires auth and returns 503 when APNs is not configured.
        let sim_unauth = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/api/v1/live-activities/simulation")
                .to_request(),
        )
        .await;
        assert_eq!(sim_unauth.status(), StatusCode::UNAUTHORIZED);

        let sim_no_apns = test::call_service(
            &app,
            test::TestRequest::post()
                .uri("/api/v1/live-activities/simulation")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .set_json(serde_json::json!({"mode": "charging", "interval_seconds": 5, "steps": 3}))
                .to_request(),
        )
        .await;
        assert_eq!(sim_no_apns.status(), StatusCode::SERVICE_UNAVAILABLE);

        let sim_stop = test::call_service(
            &app,
            test::TestRequest::delete()
                .uri("/api/v1/live-activities/simulation")
                .insert_header((AUTHORIZATION, "Bearer la-key"))
                .to_request(),
        )
        .await;
        assert_eq!(sim_stop.status(), StatusCode::OK);
        let sim_stop_body: serde_json::Value = test::read_body_json(sim_stop).await;
        assert_eq!(sim_stop_body["stopped"], false);
    }
}
