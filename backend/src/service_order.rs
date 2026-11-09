use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use reqwest::{Client, StatusCode, header::HeaderMap};
use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;
use tracing::{info, warn};
use url::Url;

use crate::{
    config::{ServiceOrderConfig, StationConfig, StationTemplateConfig, VehicleConfig},
    events::EventHub,
    models::{
        ImportedOrder, ObservedServiceOrder, ObservedServiceOrderQueue, ObservedSwapStation,
        StationQueueStatus, SwapPaymentItem,
    },
    poller::{Poller, StationTarget},
    provider::{NioStationProvider, ProviderError, decrypt_payload},
    store::{Store, StoreError},
    vehicle::sign_url,
};

const SWAP_ORDER_TYPE: &str = "pe_shaman_change";
const HISTORY_POLL_INTERVAL: Duration = Duration::from_secs(10 * 60);
const ORDER_DETAIL_ORIGIN: &str = "https://app.nio.com";
const ORDER_DETAIL_PATH_PREFIX: &str = "/app/api/pe/v1/swap/order/";
const ORDER_DETAIL_BACKFILL_LIMIT: usize = 20;
const ESTIMATED_MINUTES_PER_VEHICLE: u32 = 5;

#[derive(Clone)]
pub struct ServiceOrderProvider {
    client: Client,
    detail_client: Option<Client>,
    detail_config: Option<VehicleConfig>,
    active_url: Url,
    history_url: Url,
    vehicle_id: Option<String>,
    vin_code: Option<String>,
    station_template: Option<StationTemplateConfig>,
}

pub struct ServiceOrderMonitor {
    provider: ServiceOrderProvider,
    store: Store,
    poller: Poller,
    station_target: StationTarget,
    interval: Duration,
    events: EventHub,
}

#[derive(Debug, Error)]
pub enum ServiceOrderError {
    #[error("invalid service-order URL")]
    InvalidUrl,
    #[error("service-order endpoint must use HTTPS")]
    InsecureUrl,
    #[error("service-order endpoint requires an Authorization header")]
    MissingAuthorization,
    #[error("invalid service-order request header")]
    InvalidHeader,
    #[error("service-order request failed")]
    Request(#[source] reqwest::Error),
    #[error("service-order endpoint returned HTTP {0}")]
    HttpStatus(StatusCode),
    #[error("service-order endpoint returned invalid JSON")]
    InvalidJson(#[source] reqwest::Error),
    #[error("service-order response is invalid: {0}")]
    InvalidPayload(String),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServiceOrderWire {
    order_type: String,
    order_no: String,
    #[serde(default)]
    order_status: Option<String>,
    #[serde(default)]
    order_status_name: Option<String>,
    create_time: Value,
    #[serde(default)]
    vehicle_id: Option<String>,
    #[serde(default)]
    vin_code: Option<String>,
    #[serde(default)]
    resource_address: Option<String>,
    #[serde(default)]
    address: Option<String>,
    #[serde(default)]
    extend_info: Value,
}

#[derive(Clone, Debug, PartialEq)]
struct SwapOrderStatus {
    status: Option<String>,
    status_description: Option<String>,
    queue_number: Option<u32>,
    vehicles_ahead: Option<u32>,
    estimated_wait_minutes: Option<u32>,
}

impl ServiceOrderProvider {
    pub fn new(
        config: ServiceOrderConfig,
        detail_config: Option<VehicleConfig>,
    ) -> Result<Self, ServiceOrderError> {
        let active_url = build_order_url(&config.url, true)?;
        let history_url = build_order_url(&config.url, false)?;
        if !config
            .headers
            .keys()
            .any(|name| name.eq_ignore_ascii_case("authorization"))
        {
            return Err(ServiceOrderError::MissingAuthorization);
        }
        let mut headers = HeaderMap::new();
        for (name, value) in config.headers {
            let name = name
                .parse::<reqwest::header::HeaderName>()
                .map_err(|_| ServiceOrderError::InvalidHeader)?;
            let value = value
                .parse::<reqwest::header::HeaderValue>()
                .map_err(|_| ServiceOrderError::InvalidHeader)?;
            headers.insert(name, value);
        }
        if !headers.contains_key(reqwest::header::ACCEPT) {
            headers.insert(
                reqwest::header::ACCEPT,
                reqwest::header::HeaderValue::from_static("application/json, text/plain, */*"),
            );
        }
        if !headers.contains_key(reqwest::header::CONTENT_TYPE) {
            headers.insert(
                reqwest::header::CONTENT_TYPE,
                reqwest::header::HeaderValue::from_static("application/json"),
            );
        }
        let client = Client::builder()
            .default_headers(headers)
            .timeout(Duration::from_secs(20))
            .user_agent("nio-swap-history-backend/0.1")
            .build()
            .map_err(ServiceOrderError::Request)?;
        let detail_client = detail_config
            .as_ref()
            .map(|_| {
                Client::builder()
                    .timeout(Duration::from_secs(20))
                    .user_agent("nio-swap-history-backend/0.1")
                    .build()
            })
            .transpose()
            .map_err(ServiceOrderError::Request)?;
        Ok(Self {
            client,
            detail_client,
            detail_config,
            active_url,
            history_url,
            vehicle_id: config.vehicle_id,
            vin_code: config.vin_code,
            station_template: config.station_template,
        })
    }

    pub async fn fetch_active_swap_orders(
        &self,
    ) -> Result<Vec<ObservedServiceOrder>, ServiceOrderError> {
        self.fetch_swap_orders(self.active_url.clone()).await
    }

    pub async fn fetch_historical_swap_orders(
        &self,
    ) -> Result<Vec<ObservedServiceOrder>, ServiceOrderError> {
        self.fetch_swap_orders(self.history_url.clone()).await
    }

    async fn fetch_swap_orders(
        &self,
        url: Url,
    ) -> Result<Vec<ObservedServiceOrder>, ServiceOrderError> {
        let response = self
            .client
            .post(url)
            .body("")
            .send()
            .await
            .map_err(ServiceOrderError::Request)?;
        if !response.status().is_success() {
            return Err(ServiceOrderError::HttpStatus(response.status()));
        }
        let payload = response
            .json::<Value>()
            .await
            .map_err(ServiceOrderError::InvalidJson)?;
        parse_swap_orders(
            &payload,
            self.vehicle_id.as_deref(),
            self.vin_code.as_deref(),
        )
    }

    async fn fetch_swap_order_detail(
        &self,
        order_no: &str,
    ) -> Result<Option<Value>, ServiceOrderError> {
        self.fetch_swap_order_data(order_no, None).await
    }

    async fn fetch_swap_order_status(
        &self,
        order_no: &str,
    ) -> Result<Option<SwapOrderStatus>, ServiceOrderError> {
        self.fetch_swap_order_data(order_no, Some("status"))
            .await
            .map(|data| data.as_ref().map(parse_swap_order_status))
    }

    async fn fetch_swap_order_data(
        &self,
        order_no: &str,
        suffix: Option<&str>,
    ) -> Result<Option<Value>, ServiceOrderError> {
        let (Some(client), Some(config)) = (&self.detail_client, &self.detail_config) else {
            return Ok(None);
        };
        let order_no = order_no.trim();
        if order_no.is_empty() || order_no.len() > 128 {
            return Err(ServiceOrderError::InvalidPayload(
                "swap-order detail order number is invalid".to_owned(),
            ));
        }
        let mut url = Url::parse(ORDER_DETAIL_ORIGIN).map_err(|_| ServiceOrderError::InvalidUrl)?;
        let suffix = suffix.map(|value| format!("/{value}")).unwrap_or_default();
        url.set_path(&format!("{ORDER_DETAIL_PATH_PREFIX}{order_no}{suffix}"));
        url.query_pairs_mut()
            .append_pair("app_id", &config.app_id)
            .append_pair("app_ver", &config.app_version)
            .append_pair("device_id", &config.device_id)
            .append_pair("lang", &config.language)
            .append_pair("region", &config.region);
        let url = sign_url(url, &config.bearer_token, Utc::now().timestamp());
        let response = client
            .get(url)
            .bearer_auth(&config.bearer_token)
            .header(
                reqwest::header::ACCEPT,
                "application/json,text/json,text/plain",
            )
            .header(reqwest::header::ACCEPT_LANGUAGE, "zh-CN,zh-Hans;q=0.9")
            .send()
            .await
            .map_err(ServiceOrderError::Request)?;
        if !response.status().is_success() {
            return Err(ServiceOrderError::HttpStatus(response.status()));
        }
        let payload = response
            .json::<Value>()
            .await
            .map_err(ServiceOrderError::InvalidJson)?;
        let result_code = payload
            .get("result_code")
            .or_else(|| payload.get("resultCode"))
            .and_then(value_as_string)
            .unwrap_or_default();
        if !result_code.is_empty()
            && !result_code.eq_ignore_ascii_case("success")
            && result_code != "0000"
        {
            let message = payload
                .get("message")
                .or_else(|| payload.get("result_msg"))
                .or_else(|| payload.get("debug_msg"))
                .and_then(Value::as_str)
                .unwrap_or("swap-order detail request failed");
            return Err(ServiceOrderError::InvalidPayload(message.to_owned()));
        }
        swap_order_response_data(payload).map(Some)
    }
}

impl ServiceOrderMonitor {
    pub fn new(
        provider: ServiceOrderProvider,
        store: Store,
        poller: Poller,
        station_target: StationTarget,
        interval: Duration,
        events: EventHub,
    ) -> Self {
        Self {
            provider,
            store,
            poller,
            station_target,
            interval,
            events,
        }
    }

    pub async fn run_forever(self) {
        let mut ticker = tokio::time::interval(self.interval);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut last_history_poll = None;
        let mut previous_active_state = None;
        loop {
            ticker.tick().await;
            if let Err(error) = self.poll_orders_once().await {
                warn!(%error, "service-order poll failed; next poll will retry");
            } else {
                match self.store.list_active_service_orders(20).await {
                    Ok(mut orders) => {
                        for order in &mut orders {
                            order.first_seen_at = order.order_created_at;
                            order.last_seen_at = order.order_created_at;
                            order.queue_updated_at = None;
                        }
                        if previous_active_state.as_ref() != Some(&orders) {
                            match self
                                .events
                                .publish("active_orders_changed", "active_orders_changed")
                                .await
                            {
                                Ok(()) => previous_active_state = Some(orders),
                                Err(error) => {
                                    warn!(%error, "failed to publish active-order change event")
                                }
                            }
                        } else {
                            previous_active_state = Some(orders);
                        }
                    }
                    Err(error) => warn!(%error, "failed to compare active-order state"),
                }
            }
            if last_history_poll
                .is_none_or(|last: tokio::time::Instant| last.elapsed() >= HISTORY_POLL_INTERVAL)
            {
                if let Err(error) = self.poll_history_once().await {
                    warn!(%error, "service-order history poll failed; next history poll will retry");
                } else {
                    last_history_poll = Some(tokio::time::Instant::now());
                }
            }
        }
    }

    async fn poll_history_once(&self) -> Result<(), MonitorError> {
        let orders = self.provider.fetch_historical_swap_orders().await?;
        let mut imported_count = 0usize;
        let mut detail_attempt_count = 0usize;
        let mut enriched_count = 0usize;
        for order in orders {
            self.store.observe_service_order(&order).await?;
            let mut detail = self.store.swap_order_detail(&order.order_no).await?;
            if is_completed_order(&order)
                && detail.as_ref().and_then(exact_energy_from_detail).is_none()
                && detail_attempt_count < ORDER_DETAIL_BACKFILL_LIMIT
            {
                detail_attempt_count += 1;
                match self.provider.fetch_swap_order_detail(&order.order_no).await {
                    Ok(fetched_detail) => {
                        if fetched_detail
                            .as_ref()
                            .and_then(exact_energy_from_detail)
                            .is_some()
                        {
                            enriched_count += 1;
                        }
                        if fetched_detail.is_some() {
                            detail = fetched_detail;
                        }
                    }
                    Err(error) => {
                        warn!(order_no = %order.order_no, %error, "swap-order detail enrichment failed; next history poll will retry");
                    }
                }
            }
            let mut station = detail
                .as_ref()
                .and_then(|detail| swap_station_from_detail(&order, detail));
            if let Some(station) = station.as_mut()
                && station.station_address.is_none()
                && let Some(existing) = self.store.swap_station_by_id(&station.station_id).await?
            {
                // The service-order payloads carry no address; reuse the short
                // address/POI name that station polling wrote to the directory.
                station.station_address = existing.station_address;
            }
            if let Some(station) = &station {
                self.store.upsert_swap_station(station).await?;
            }
            if let Some(imported) = completed_import(&order, detail.as_ref(), station.as_ref()) {
                self.store
                    .import_order(&imported, Duration::from_secs(30 * 60))
                    .await?;
                imported_count += 1;
            }
        }
        info!(
            imported_count,
            detail_attempt_count, enriched_count, "completed swap-order history synchronized"
        );
        Ok(())
    }

    async fn poll_orders_once(&self) -> Result<(), MonitorError> {
        let mut orders = self.provider.fetch_active_swap_orders().await?;
        orders.sort_by_key(|order| std::cmp::Reverse(order.created_at));
        let mut observed_orders = Vec::with_capacity(orders.len());
        for order in orders {
            let state = self.store.observe_service_order(&order).await?;
            observed_orders.push((order, state));
        }
        let active_order_nos = observed_orders
            .iter()
            .map(|(order, _)| order.order_no.clone())
            .collect::<Vec<_>>();
        self.store
            .set_active_service_orders(&active_order_nos)
            .await?;

        let mut target_selected = false;
        for (mut order, mut state) in observed_orders {
            if state.is_new_or_changed {
                info!(
                    order_no = %order.order_no,
                    status = ?order.order_status,
                    station = ?order.station_name,
                    "active swap service order observed"
                );
            }
            match self.provider.fetch_swap_order_detail(&order.order_no).await {
                Ok(Some(detail)) => {
                    if let Some(station) = enrich_active_order_from_detail(&mut order, detail) {
                        self.store.upsert_swap_station(&station).await?;
                        if order.station_address.is_none()
                            && let Some(existing) =
                                self.store.swap_station_by_id(&station.station_id).await?
                        {
                            order.station_address = existing.station_address;
                        }
                        state = self.store.observe_service_order(&order).await?;
                        if state.is_new_or_changed {
                            info!(
                                order_no = %order.order_no,
                                station_id = %station.station_id,
                                "active swap order enriched from order detail"
                            );
                        }
                    } else {
                        warn!(
                            order_no = %order.order_no,
                            "active swap-order detail did not include a valid station id"
                        );
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        order_no = %order.order_no,
                        %error,
                        "active swap-order detail lookup failed; next poll will retry"
                    );
                }
            }
            let official_status = match self.provider.fetch_swap_order_status(&order.order_no).await
            {
                Ok(status) => status,
                Err(error) => {
                    warn!(
                        order_no = %order.order_no,
                        %error,
                        "active swap-order status lookup failed; station queue fallback will be used"
                    );
                    None
                }
            };
            if let Some(provider) = self.dynamic_station_provider(&order)? {
                if !target_selected {
                    self.station_target.set(provider.clone()).await;
                    target_selected = true;
                }
                let station_queue = match provider
                    .fetch_queue_status(target_battery_cap_level(&order))
                    .await
                {
                    Ok(queue) => Some(queue),
                    Err(error) => {
                        warn!(
                            order_no = %order.order_no,
                            %error,
                            "active swap-order queue refresh failed; next poll will retry"
                        );
                        None
                    }
                };
                if let Some(queue) =
                    observed_order_queue(&order, official_status.as_ref(), station_queue.as_ref())
                {
                    self.store.update_service_order_queue(&queue).await?;
                }
                if state.needs_baseline {
                    self.capture_baseline(&order, &provider).await?;
                }
                continue;
            }
            if let Some(queue) = observed_order_queue(&order, official_status.as_ref(), None) {
                self.store.update_service_order_queue(&queue).await?;
            }
            if !state.needs_baseline {
                continue;
            }
            if !self.poller.matches_station(
                order.station_key.as_deref(),
                order.station_name.as_deref(),
                order.station_address.as_deref(),
            ) {
                if state.is_new_or_changed {
                    warn!(
                        order_no = %order.order_no,
                        station = ?order.station_name,
                        "active order does not match the configured station; baseline not captured"
                    );
                }
                continue;
            }
            let outcome = self.poller.poll_once_for("service_order_observed").await?;
            if let Some(snapshot_id) = outcome.snapshot_id {
                self.store
                    .mark_service_order_baseline(&order.order_no, &snapshot_id)
                    .await?;
                info!(
                    order_no = %order.order_no,
                    snapshot_id,
                    "service-order station baseline captured"
                );
            }
        }
        Ok(())
    }

    fn dynamic_station_provider(
        &self,
        order: &ObservedServiceOrder,
    ) -> Result<Option<NioStationProvider>, ProviderError> {
        let (Some(template), Some(station_id)) = (
            self.provider.station_template.as_ref(),
            order.station_key.as_deref(),
        ) else {
            return Ok(None);
        };
        let url = template.url_template.replace("{station_id}", station_id);
        let name = order
            .station_name
            .clone()
            .unwrap_or_else(|| station_id.to_owned());
        NioStationProvider::new(StationConfig {
            key: station_id.to_owned(),
            name,
            url,
            headers: template.headers.clone(),
        })
        .map(Some)
    }

    async fn capture_baseline(
        &self,
        order: &ObservedServiceOrder,
        provider: &NioStationProvider,
    ) -> Result<(), MonitorError> {
        let outcome = self
            .poller
            .poll_once_with_provider(provider, "service_order_target_station")
            .await?;
        if let Some(snapshot_id) = outcome.snapshot_id {
            self.store
                .mark_service_order_baseline(&order.order_no, &snapshot_id)
                .await?;
            info!(
                order_no = %order.order_no,
                station_id = ?order.station_key,
                snapshot_id,
                "service-order target-station baseline captured"
            );
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
enum MonitorError {
    #[error(transparent)]
    Provider(#[from] ServiceOrderError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Poll(#[from] crate::poller::PollError),
    #[error(transparent)]
    StationProvider(#[from] ProviderError),
}

fn build_order_url(raw_url: &str, in_progress: bool) -> Result<Url, ServiceOrderError> {
    let mut url = Url::parse(raw_url).map_err(|_| ServiceOrderError::InvalidUrl)?;
    if url.scheme() != "https" {
        return Err(ServiceOrderError::InsecureUrl);
    }
    let mut pairs = url
        .query_pairs()
        .filter(|(name, _)| {
            !name.eq_ignore_ascii_case("ordertypes")
                && !name.eq_ignore_ascii_case("inprogressstatus")
                && !name.eq_ignore_ascii_case("offset")
                && !name.eq_ignore_ascii_case("limit")
        })
        .map(|(name, value)| (name.into_owned(), value.into_owned()))
        .collect::<Vec<_>>();
    pairs.push(("offset".to_owned(), "0".to_owned()));
    pairs.push(("limit".to_owned(), "2000".to_owned()));
    pairs.push(("orderTypes".to_owned(), SWAP_ORDER_TYPE.to_owned()));
    pairs.push(("inProgressStatus".to_owned(), in_progress.to_string()));
    url.query_pairs_mut().clear().extend_pairs(pairs);
    Ok(url)
}

fn parse_swap_orders(
    payload: &Value,
    expected_vehicle_id: Option<&str>,
    expected_vin: Option<&str>,
) -> Result<Vec<ObservedServiceOrder>, ServiceOrderError> {
    let code = payload
        .get("resultCode")
        .or_else(|| payload.get("result_code"))
        .and_then(value_as_string)
        .unwrap_or_default();
    if code != "0000" && !code.eq_ignore_ascii_case("success") {
        let description = payload
            .get("resultDesc")
            .or_else(|| payload.get("result_desc"))
            .or_else(|| payload.get("resultMsg"))
            .and_then(Value::as_str)
            .unwrap_or("unknown result code");
        return Err(ServiceOrderError::InvalidPayload(description.to_owned()));
    }
    let values = payload
        .pointer("/resultData/data")
        .or_else(|| payload.pointer("/result_data/data"))
        .and_then(Value::as_array)
        .ok_or_else(|| ServiceOrderError::InvalidPayload("missing resultData.data".to_owned()))?;

    values
        .iter()
        .filter_map(|raw| {
            if raw.get("orderType").and_then(Value::as_str) != Some(SWAP_ORDER_TYPE) {
                return None;
            }
            let wire = match serde_json::from_value::<ServiceOrderWire>(raw.clone()) {
                Ok(wire) => wire,
                Err(error) => {
                    return Some(Err(ServiceOrderError::InvalidPayload(error.to_string())));
                }
            };
            if wire.order_type != SWAP_ORDER_TYPE
                || !matches_vehicle(
                    wire.vehicle_id.as_deref(),
                    wire.vin_code.as_deref(),
                    expected_vehicle_id,
                    expected_vin,
                )
            {
                return None;
            }
            Some(service_order_from_wire(wire, raw.clone()))
        })
        .collect()
}

fn completed_import(
    order: &ObservedServiceOrder,
    detail: Option<&Value>,
    station: Option<&ObservedSwapStation>,
) -> Option<ImportedOrder> {
    if !is_completed_order(order) {
        return None;
    }
    let completed_at = completed_at(order, detail);
    // The list endpoint no longer returns `extendInfo.paymentInfo`, so itemize
    // the settled detail (electricity, service fee and coupon deduction) and
    // keep the legacy list parser only as a fallback.
    let payment_items = detail
        .map(payment_items_from_detail)
        .filter(|items| !items.is_empty())
        .unwrap_or_else(|| parse_payment_items(&order.raw_payload));
    // The service-order list carries the pre-discount `priceCash`, while the
    // settled order detail reports what was actually paid (`actual_price`,
    // also described by `fee_desc` after coupons). Prefer the settled amount.
    let detail_price = detail
        .and_then(|value| value_at_any_key(value, &["actual_price", "actualPrice"]))
        .and_then(value_as_f64)
        .filter(|price| price.is_finite() && *price >= 0.0);
    let explicit_price =
        detail_price.or_else(|| order.raw_payload.get("priceCash").and_then(value_as_f64));
    let price_amount = explicit_price.or_else(|| {
        (!payment_items.is_empty()).then(|| payment_items.iter().map(|item| item.amount).sum())
    });
    let raw_payload = if let Some(detail) = detail {
        let mut raw = order.raw_payload.clone();
        if let Some(object) = raw.as_object_mut() {
            object.insert("orderDetail".to_owned(), detail.clone());
        }
        raw
    } else {
        order.raw_payload.clone()
    };
    Some(ImportedOrder {
        order_no: order.order_no.clone(),
        occurred_at: completed_at,
        station_key: station
            .map(|station| station.station_id.clone())
            .or_else(|| order.station_key.clone()),
        station_name: station
            .map(|station| station.station_name.clone())
            .or_else(|| order.station_name.clone()),
        station_address: station
            .and_then(|station| station.station_address.clone())
            .or_else(|| order.station_address.clone()),
        order_status_name: order.order_status_name.clone(),
        price_amount,
        price_currency: price_amount.map(|_| "CNY".to_owned()),
        price_description: detail
            .and_then(|value| value_at_any_key(value, &["fee_desc", "feeDesc"]))
            .and_then(Value::as_str)
            .and_then(|value| non_empty(value.to_owned()))
            .or_else(|| {
                order
                    .raw_payload
                    .get("payDesc")
                    .and_then(Value::as_str)
                    .and_then(|value| non_empty(value.to_owned()))
            }),
        payment_items,
        energy_kwh: detail.and_then(exact_energy_from_detail),
        outgoing_battery: None,
        incoming_battery: None,
        raw_payload: Some(raw_payload),
    })
}

fn completed_at(order: &ObservedServiceOrder, detail: Option<&Value>) -> DateTime<Utc> {
    // The service-order list currently omits `extendInfo`, so the only reliable
    // completion time comes from the order detail (`finish_time`, in seconds).
    // Falling back to `createTime` would record the swap up to half an hour early.
    detail
        .and_then(|value| value_at_any_key(value, &["finish_time", "finishTime"]))
        .and_then(timestamp)
        .filter(|finished_at| *finished_at >= order.created_at)
        .or_else(|| {
            order
                .raw_payload
                .pointer("/extendInfo/order_finish_info/finish_time")
                .and_then(timestamp)
        })
        .unwrap_or(order.created_at)
}

fn enrich_active_order_from_detail(
    order: &mut ObservedServiceOrder,
    detail: Value,
) -> Option<ObservedSwapStation> {
    let station = swap_station_from_detail(order, &detail)?;
    order.station_key = Some(station.station_id.clone());
    order.station_name = Some(station.station_name.clone());
    order.station_address = station.station_address.clone();
    if let Some(payload) = order.raw_payload.as_object_mut() {
        payload.insert("orderDetail".to_owned(), detail);
    }
    Some(station)
}

fn swap_station_from_detail(
    order: &ObservedServiceOrder,
    detail: &Value,
) -> Option<ObservedSwapStation> {
    let station_id = value_at_any_key(detail, &["resource_id", "resourceId"])
        .and_then(value_as_string)
        .filter(|value| valid_swap_station_id(value))?
        .trim()
        .to_owned();
    let station_name = value_at_any_key(
        detail,
        &["resource_name", "resourceName", "swap_name", "swapName"],
    )
    .and_then(value_as_string)
    .and_then(non_empty)
    .or_else(|| order.station_name.clone())?;
    let station_address =
        value_at_any_key(detail, &["resource_address", "resourceAddress", "address"])
            .and_then(value_as_string)
            .and_then(non_empty)
            .or_else(|| order.station_address.clone());
    let operator_id = value_at_any_key(detail, &["operator_id", "operatorId"])
        .and_then(value_as_string)
        .and_then(non_empty);
    let operator_name = value_at_any_key(detail, &["operator_name", "operatorName"])
        .and_then(value_as_string)
        .and_then(non_empty);
    Some(ObservedSwapStation {
        station_id,
        station_name,
        station_address,
        operator_id,
        operator_name,
        source_order_no: order.order_no.clone(),
        observed_at: completed_at(order, Some(detail)),
    })
}

fn value_at_any_key<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key))
}

fn swap_order_response_data(payload: Value) -> Result<Value, ServiceOrderError> {
    match payload.get("data") {
        Some(Value::Object(_)) | Some(Value::Array(_)) => Ok(payload["data"].clone()),
        Some(Value::String(ciphertext)) => {
            let decrypted = decrypt_payload(ciphertext).map_err(|_| {
                ServiceOrderError::InvalidPayload(
                    "swap-order response data cannot be decrypted".to_owned(),
                )
            })?;
            serde_json::from_slice(&decrypted).map_err(|_| {
                ServiceOrderError::InvalidPayload(
                    "decrypted swap-order response is invalid".to_owned(),
                )
            })
        }
        _ if payload.is_object() && payload.get("status").is_some() => Ok(payload),
        _ => Err(ServiceOrderError::InvalidPayload(
            "missing swap-order response data".to_owned(),
        )),
    }
}

fn parse_swap_order_status(value: &Value) -> SwapOrderStatus {
    SwapOrderStatus {
        status: value_at_any_key(value, &["status"]).and_then(value_as_string),
        status_description: value_at_any_key(value, &["status_desc", "statusDesc"])
            .and_then(value_as_string)
            .and_then(non_empty),
        queue_number: value_at_any_key(value, &["swap_number", "swapNumber"])
            .and_then(value_as_u32),
        vehicles_ahead: value_at_any_key(value, &["waiting_count", "waitingCount"])
            .and_then(value_as_u32),
        estimated_wait_minutes: value_at_any_key(
            value,
            &["swap_wait_expected_time", "swapWaitExpectedTime"],
        )
        .and_then(wait_minutes),
    }
}

fn observed_order_queue(
    order: &ObservedServiceOrder,
    official: Option<&SwapOrderStatus>,
    station: Option<&StationQueueStatus>,
) -> Option<ObservedServiceOrderQueue> {
    let queue_number = official
        .and_then(|status| status.queue_number)
        .or_else(|| queue_number(order));
    let vehicles_ahead = official
        .and_then(|status| status.vehicles_ahead)
        .or_else(|| station.and_then(|status| status.vehicles_ahead));
    let official_wait = official.and_then(|status| status.estimated_wait_minutes);
    let estimated_wait_minutes = official_wait.or_else(|| {
        vehicles_ahead.map(|count| count.saturating_mul(ESTIMATED_MINUTES_PER_VEHICLE))
    });
    if queue_number.is_none() && vehicles_ahead.is_none() && estimated_wait_minutes.is_none() {
        return None;
    }
    let estimated_wait_source = estimated_wait_minutes.map(|_| {
        if official_wait.is_some() {
            "swap_order_status".to_owned()
        } else {
            "station_queue_estimate".to_owned()
        }
    });
    // `status_desc` describes the order lifecycle ("换电进行中") even while the
    // car is still queued. The order detail's own title is the queue-facing
    // text ("等待换电"), so prefer it when the detail payload is available.
    let queue_status_text = order
        .raw_payload
        .pointer("/orderDetail/order_title")
        .and_then(Value::as_str)
        .and_then(|value| non_empty(value.to_owned()))
        .or_else(|| official.and_then(|status| status.status_description.clone()))
        .or_else(|| official.and_then(|status| status.status.clone()))
        .or_else(|| station.and_then(|status| status.waiting_description.clone()));
    Some(ObservedServiceOrderQueue {
        order_no: order.order_no.clone(),
        queue_number,
        target_battery_cap_level: target_battery_cap_level(order),
        vehicles_ahead,
        estimated_wait_minutes,
        estimated_wait_source,
        queue_status_text,
        observed_at: Utc::now(),
    })
}

fn exact_energy_from_detail(detail: &Value) -> Option<f64> {
    detail
        .get("energy")
        .and_then(value_as_f64)
        .filter(|value| (0.0..=300.0).contains(value))
}

fn is_completed_order(order: &ObservedServiceOrder) -> bool {
    matches!(order.order_status.as_deref(), Some("100" | "1000"))
        || order
            .order_status_name
            .as_deref()
            .is_some_and(|name| name.contains("完成") || name.contains("已支付"))
}

fn payment_items_from_detail(detail: &Value) -> Vec<SwapPaymentItem> {
    fn line_name(detail: &Value, pointer: &str, fallback: &str) -> String {
        detail
            .pointer(pointer)
            .and_then(|value| value.get("key"))
            .and_then(Value::as_str)
            .and_then(|value| non_empty(value.to_owned()))
            .unwrap_or_else(|| fallback.to_owned())
    }

    let mut items = Vec::new();
    let electricity = value_at_any_key(detail, &["origin_electricity_price", "electricity_price"])
        .and_then(value_as_f64)
        .filter(|amount| amount.is_finite() && *amount > 0.0);
    if let Some(amount) = electricity {
        items.push(SwapPaymentItem {
            name: line_name(detail, "/electricity_charge_detail", "电费"),
            amount,
            payment_type: None,
        });
    }

    let service = value_at_any_key(detail, &["origin_service_price", "service_price"])
        .and_then(value_as_f64)
        .filter(|amount| amount.is_finite() && *amount > 0.0);
    if let Some(amount) = service {
        items.push(SwapPaymentItem {
            name: line_name(detail, "/service_charge_detail", "服务费"),
            amount,
            payment_type: None,
        });
    }

    // Coupon deductions are reported in cents, separately for electricity and
    // service fees. `service_price` is already net of the deduction, so the
    // coupon line has to use the pre-discount origin prices above.
    let coupon_cents = ["deducted_electricity_fee", "deducted_service_fee"]
        .iter()
        .filter_map(|key| {
            detail
                .pointer(&format!("/coupon_info/{key}"))
                .and_then(value_as_f64)
        })
        .sum::<f64>();
    if coupon_cents > 0.0 {
        let name = detail
            .pointer("/coupon_info/coupon_name")
            .and_then(Value::as_str)
            .and_then(|value| non_empty(value.to_owned()))
            .unwrap_or_else(|| "优惠券".to_owned());
        items.push(SwapPaymentItem {
            name,
            amount: -(coupon_cents / 100.0),
            payment_type: None,
        });
    }
    items
}

fn parse_payment_items(value: &Value) -> Vec<SwapPaymentItem> {
    value
        .pointer("/extendInfo/paymentInfo")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let name = item
                .get("name")
                .and_then(Value::as_str)
                .and_then(|value| non_empty(value.to_owned()))?;
            let amount = item.get("amount").and_then(value_as_f64)?;
            let payment_type = item
                .get("type")
                .and_then(|value| value.as_i64().or_else(|| value.as_str()?.parse().ok()));
            Some(SwapPaymentItem {
                name,
                amount,
                payment_type,
            })
        })
        .collect()
}

fn service_order_from_wire(
    wire: ServiceOrderWire,
    raw_payload: Value,
) -> Result<ObservedServiceOrder, ServiceOrderError> {
    let order_no = non_empty(wire.order_no)
        .ok_or_else(|| ServiceOrderError::InvalidPayload("orderNo is empty".to_owned()))?;
    let created_at = timestamp(&wire.create_time)
        .ok_or_else(|| ServiceOrderError::InvalidPayload("createTime is invalid".to_owned()))?;
    let location = wire.extend_info.get("expected_service_location");
    let station_name = non_empty_option(wire.resource_address).or_else(|| {
        location
            .and_then(|value| value.get("poi_name"))
            .and_then(Value::as_str)
            .and_then(|value| non_empty(value.to_owned()))
    });
    let station_address = location
        .and_then(|value| value.get("poi_address"))
        .and_then(Value::as_str)
        .and_then(|value| non_empty(value.to_owned()))
        .or_else(|| non_empty_option(wire.address));
    let station_key = find_swap_station_id(&raw_payload);
    Ok(ObservedServiceOrder {
        order_no,
        order_type: wire.order_type,
        order_status: non_empty_option(wire.order_status),
        order_status_name: non_empty_option(wire.order_status_name),
        created_at,
        vehicle_id: non_empty_option(wire.vehicle_id),
        vin_code: non_empty_option(wire.vin_code),
        station_key,
        station_name,
        station_address,
        raw_payload,
    })
}

fn find_swap_station_id(value: &Value) -> Option<String> {
    match value {
        Value::String(value) if valid_swap_station_id(value) => Some(value.trim().to_owned()),
        Value::Array(values) => values.iter().find_map(find_swap_station_id),
        Value::Object(values) => values.values().find_map(find_swap_station_id),
        _ => None,
    }
}

fn valid_swap_station_id(value: &str) -> bool {
    let value = value.trim();
    value.starts_with("PS-NIO-")
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn matches_vehicle(
    order_vehicle_id: Option<&str>,
    order_vin: Option<&str>,
    expected_vehicle_id: Option<&str>,
    expected_vin: Option<&str>,
) -> bool {
    if let (Some(actual), Some(expected)) = (order_vehicle_id, expected_vehicle_id)
        && !actual.trim().eq_ignore_ascii_case(expected.trim())
    {
        return false;
    }
    if let (Some(actual), Some(expected)) = (order_vin, expected_vin)
        && !actual.trim().eq_ignore_ascii_case(expected.trim())
    {
        return false;
    }
    true
}

fn timestamp(value: &Value) -> Option<DateTime<Utc>> {
    let raw = value
        .as_i64()
        .or_else(|| value.as_str().and_then(|value| value.parse::<i64>().ok()))?;
    if raw.abs() < 100_000_000_000 {
        Utc.timestamp_opt(raw, 0).single()
    } else {
        Utc.timestamp_millis_opt(raw).single()
    }
}

fn value_as_string(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| value.as_i64().map(|value| value.to_string()))
}

fn value_as_f64(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|value| value.trim().parse().ok()))
        .filter(|value| value.is_finite())
}

fn value_as_u32(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .or_else(|| value.as_str()?.trim().parse().ok())
}

/// The official ETA is localized (`"17分钟"`, `"1小时5分钟"`), while some
/// deployments return a bare number or numeric string. Parse all of them so the
/// official minutes are not silently dropped and replaced by the local
/// five-minute-per-vehicle estimate.
fn wait_minutes(value: &Value) -> Option<u32> {
    if let Some(minutes) = value_as_u32(value) {
        return Some(minutes);
    }
    let text = value.as_str()?.trim();
    if text.is_empty() {
        return None;
    }
    let chars = text.chars().collect::<Vec<_>>();
    let mut total = 0u32;
    let mut current: Option<u32> = None;
    let mut matched = false;
    let mut index = 0;
    while index < chars.len() {
        let ch = chars[index];
        if let Some(digit) = ch.to_digit(10) {
            current = Some(
                current
                    .unwrap_or(0)
                    .saturating_mul(10)
                    .saturating_add(digit),
            );
        } else if ch == '小' && chars.get(index + 1) == Some(&'时') {
            if let Some(hours) = current.take() {
                total = total.saturating_add(hours.saturating_mul(60));
                matched = true;
            }
            index += 1;
        } else if ch == '时' || ch == 'h' || ch == 'H' {
            if let Some(hours) = current.take() {
                total = total.saturating_add(hours.saturating_mul(60));
                matched = true;
            }
        } else if ch == '分' || ch == 'm' || ch == 'M' {
            if let Some(minutes) = current.take() {
                total = total.saturating_add(minutes);
                matched = true;
            }
        }
        index += 1;
    }
    if let Some(minutes) = current {
        total = total.saturating_add(minutes);
        matched = true;
    }
    (matched && total <= 24 * 60).then_some(total)
}

fn queue_number(order: &ObservedServiceOrder) -> Option<u32> {
    order
        .raw_payload
        .pointer("/orderDetail/swap_number")
        .or_else(|| order.raw_payload.pointer("/orderDetail/swapNumber"))
        .and_then(value_as_u32)
}

fn target_battery_cap_level(order: &ObservedServiceOrder) -> Option<u32> {
    order
        .raw_payload
        .pointer("/orderDetail/target_battery_cap_level")
        .or_else(|| {
            order
                .raw_payload
                .pointer("/orderDetail/targetBatteryCapLevel")
        })
        .and_then(value_as_u32)
}

fn non_empty_option(value: Option<String>) -> Option<String> {
    value.and_then(non_empty)
}

fn non_empty(value: String) -> Option<String> {
    let value = value.trim().to_owned();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forces_active_swap_query_without_losing_other_parameters() {
        let url = build_order_url(
            "https://gateway-front-external.nio.com/serviceOrder/getTabOrder?lang=zh&orderTypes=all&inProgressStatus=false",
            true,
        )
        .unwrap();
        let pairs = url.query_pairs().collect::<Vec<_>>();
        assert!(
            pairs
                .iter()
                .any(|pair| pair == &("lang".into(), "zh".into()))
        );
        assert!(
            pairs
                .iter()
                .any(|pair| pair == &("offset".into(), "0".into()))
        );
        assert!(
            pairs
                .iter()
                .any(|pair| pair == &("limit".into(), "2000".into()))
        );
        assert!(
            pairs
                .iter()
                .any(|pair| pair == &("orderTypes".into(), SWAP_ORDER_TYPE.into()))
        );
        assert!(
            pairs
                .iter()
                .any(|pair| pair == &("inProgressStatus".into(), "true".into()))
        );
    }

    #[test]
    fn parses_only_swap_orders_for_the_configured_vehicle() {
        let payload = serde_json::json!({
            "resultCode": "0000",
            "resultData": {"data": [
                {
                    "orderType": "pe_shaman_change",
                    "orderNo": "swap-1",
                    "orderStatus": "30",
                    "orderStatusName": "进行中",
                    "createTime": 1791511200000_i64,
                    "vehicleId": "vehicle-1",
                    "vinCode": "VIN-1",
                    "resourceAddress": "苏州中心蔚来换电站",
                    "extendInfo": {"expected_service_location": {
                        "poi_id": "PS-NIO-station-1",
                        "poi_name": "fallback name",
                        "poi_address": "station address"
                    }}
                },
                {
                    "orderType": "pe_shaman",
                    "orderNo": "charge-1",
                    "createTime": 1791511200000_i64,
                    "vehicleId": "vehicle-1"
                },
                {
                    "orderType": "pe_shaman_change",
                    "orderNo": "other-vehicle",
                    "createTime": 1791511200000_i64,
                    "vehicleId": "vehicle-2"
                }
            ]}
        });
        let orders = parse_swap_orders(&payload, Some("vehicle-1"), Some("VIN-1")).unwrap();
        assert_eq!(orders.len(), 1);
        assert_eq!(orders[0].order_no, "swap-1");
        assert_eq!(orders[0].station_key.as_deref(), Some("PS-NIO-station-1"));
        assert_eq!(
            orders[0].station_name.as_deref(),
            Some("苏州中心蔚来换电站")
        );
        assert_eq!(
            orders[0].station_address.as_deref(),
            Some("station address")
        );
    }

    #[test]
    fn finds_nested_swap_station_id_but_not_order_id() {
        let payload = serde_json::json!({
            "orderId": "825393300000000002",
            "extendInfo": {
                "target": {
                    "stationId": "PS-NIO-3606da31-f8539ae9"
                }
            }
        });
        assert_eq!(
            find_swap_station_id(&payload).as_deref(),
            Some("PS-NIO-3606da31-f8539ae9")
        );
        assert_eq!(
            find_swap_station_id(&serde_json::json!({"orderId": "825393300000000002"})),
            None
        );
    }

    #[test]
    fn reads_queue_number_and_target_level_from_order_detail() {
        let order = ObservedServiceOrder {
            order_no: "order-1".to_owned(),
            order_type: SWAP_ORDER_TYPE.to_owned(),
            order_status: Some("0".to_owned()),
            order_status_name: Some("服务进行中".to_owned()),
            created_at: Utc::now(),
            vehicle_id: None,
            vin_code: None,
            station_key: None,
            station_name: None,
            station_address: None,
            raw_payload: serde_json::json!({
                "orderDetail": {
                    "swap_number": 2,
                    "target_battery_cap_level": "1"
                }
            }),
        };
        assert_eq!(queue_number(&order), Some(2));
        assert_eq!(target_battery_cap_level(&order), Some(1));
    }

    #[test]
    fn parses_official_order_status_queue_fields() {
        let status = parse_swap_order_status(&serde_json::json!({
            "status": "created",
            "status_desc": "等待换电",
            "swap_number": "12",
            "waiting_count": 3,
            "swap_wait_expected_time": "17分钟",
            "estimated_wait_in_line": 99
        }));
        assert_eq!(status.status.as_deref(), Some("created"));
        assert_eq!(status.status_description.as_deref(), Some("等待换电"));
        assert_eq!(status.queue_number, Some(12));
        assert_eq!(status.vehicles_ahead, Some(3));
        assert_eq!(status.estimated_wait_minutes, Some(17));
    }

    #[test]
    fn parses_localized_official_wait_time() {
        for (raw, expected) in [
            (serde_json::json!("0分钟"), Some(0)),
            (serde_json::json!("17分钟"), Some(17)),
            (serde_json::json!("约 17 分钟"), Some(17)),
            (serde_json::json!("1小时5分钟"), Some(65)),
            (serde_json::json!("2小时"), Some(120)),
            (serde_json::json!(23), Some(23)),
            (serde_json::json!("23"), Some(23)),
            (serde_json::json!("暂无"), None),
            (serde_json::json!("-"), None),
            (serde_json::json!(null), None),
        ] {
            assert_eq!(wait_minutes(&raw), expected, "unexpected minutes for {raw}");
        }
        assert_eq!(
            parse_swap_order_status(&serde_json::json!({
                "swap_number": 10,
                "waiting_count": 0,
                "swap_wait_expected_time": "0分钟"
            }))
            .estimated_wait_minutes,
            Some(0)
        );
    }

    fn active_order_for_queue_test() -> ObservedServiceOrder {
        ObservedServiceOrder {
            order_no: "order-1".to_owned(),
            order_type: SWAP_ORDER_TYPE.to_owned(),
            order_status: Some("0".to_owned()),
            order_status_name: Some("服务进行中".to_owned()),
            created_at: Utc::now(),
            vehicle_id: None,
            vin_code: None,
            station_key: None,
            station_name: None,
            station_address: None,
            raw_payload: serde_json::json!({"orderDetail": {
                "swap_number": 2,
                "target_battery_cap_level": 1
            }}),
        }
    }

    #[test]
    fn localized_official_wait_time_wins_over_station_estimate() {
        let order = active_order_for_queue_test();
        let official = parse_swap_order_status(&serde_json::json!({
            "status": "created",
            "status_desc": "等待换电",
            "swap_number": 9,
            "waiting_count": 2,
            "swap_wait_expected_time": "13分钟"
        }));
        let station = StationQueueStatus {
            vehicles_ahead: Some(4),
            waiting_description: Some("正在排队".to_owned()),
            navigation_count: None,
        };

        let queue = observed_order_queue(&order, Some(&official), Some(&station)).unwrap();
        assert_eq!(queue.vehicles_ahead, Some(2));
        assert_eq!(queue.estimated_wait_minutes, Some(13));
        assert_eq!(
            queue.estimated_wait_source.as_deref(),
            Some("swap_order_status")
        );
    }

    #[test]
    fn queue_status_prefers_order_title_while_waiting() {
        let mut order = active_order_for_queue_test();
        order.raw_payload = serde_json::json!({"orderDetail": {
            "swap_number": 10,
            "target_battery_cap_level": 1,
            "order_title": "等待换电"
        }});
        let official = SwapOrderStatus {
            status: Some("created".to_owned()),
            status_description: Some("换电进行中".to_owned()),
            queue_number: Some(10),
            vehicles_ahead: Some(0),
            estimated_wait_minutes: Some(0),
        };

        let queue = observed_order_queue(&order, Some(&official), None).unwrap();
        assert_eq!(queue.queue_status_text.as_deref(), Some("等待换电"));

        // Without an order detail the official status description is kept.
        let fallback =
            observed_order_queue(&active_order_for_queue_test(), Some(&official), None).unwrap();
        assert_eq!(fallback.queue_status_text.as_deref(), Some("换电进行中"));
    }

    #[test]
    fn itemizes_settled_detail_fees_and_coupon() {
        let detail = serde_json::json!({
            "electricity_price": 19.44,
            "origin_electricity_price": 19.44,
            "service_price": 14.3,
            "origin_service_price": 24.3,
            "actual_price": 33.74,
            "origin_price": 43.74,
            "electricity_charge_detail": {"key": "电费"},
            "service_charge_detail": {"key": "服务费"},
            "coupon_info": {
                "coupon_name": "换电服务费10元优惠券",
                "deducted_electricity_fee": 0,
                "deducted_service_fee": 1000
            }
        });
        let items = payment_items_from_detail(&detail);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].name, "电费");
        assert!((items[0].amount - 19.44).abs() < 1e-9);
        assert_eq!(items[1].name, "服务费");
        assert!((items[1].amount - 24.3).abs() < 1e-9);
        assert_eq!(items[2].name, "换电服务费10元优惠券");
        assert!((items[2].amount + 10.0).abs() < 1e-9);
        let total: f64 = items.iter().map(|item| item.amount).sum();
        assert!((total - 33.74).abs() < 0.005);
    }

    #[test]
    fn itemizes_a_fully_covered_swap_as_zero_total() {
        let detail = serde_json::json!({
            "electricity_price": 0.0,
            "origin_electricity_price": 58.08,
            "service_price": 0.0,
            "origin_service_price": 24.66,
            "actual_price": 0.0,
            "origin_price": 82.74,
            "coupon_info": {
                "coupon_name": "蔚来换电券（限换标准续航级）",
                "deducted_electricity_fee": 5808,
                "deducted_service_fee": 2466
            }
        });
        let items = payment_items_from_detail(&detail);
        assert_eq!(items.len(), 3);
        assert!((items[2].amount + 82.74).abs() < 1e-9);
        let total: f64 = items.iter().map(|item| item.amount).sum();
        assert!(total.abs() < 1e-9);
    }

    #[test]
    fn completed_import_uses_detail_payment_items() {
        let raw = serde_json::json!({
            "orderType": "pe_shaman_change",
            "orderNo": "itemized-swap",
            "orderStatus": "100",
            "orderStatusName": "换电已完成，已支付",
            "createTime": 1793253068000_i64,
            "priceCash": "43.74",
            "payDesc": "¥ 43.74"
        });
        let order =
            service_order_from_wire(serde_json::from_value(raw.clone()).unwrap(), raw).unwrap();
        let detail = serde_json::json!({
            "finish_time": 1793255321_i64,
            "actual_price": 33.74,
            "origin_electricity_price": 19.44,
            "origin_service_price": 24.3,
            "coupon_info": {
                "coupon_name": "换电服务费10元优惠券",
                "deducted_service_fee": 1000
            }
        });
        let imported = completed_import(&order, Some(&detail), None).unwrap();
        assert_eq!(imported.payment_items.len(), 3);
        assert_eq!(imported.price_amount, Some(33.74));
    }

    #[test]
    fn official_wait_minutes_override_station_estimate() {
        let order = active_order_for_queue_test();
        let official = SwapOrderStatus {
            status: Some("created".to_owned()),
            status_description: Some("等待换电".to_owned()),
            queue_number: Some(12),
            vehicles_ahead: Some(3),
            estimated_wait_minutes: Some(17),
        };
        let station = StationQueueStatus {
            vehicles_ahead: Some(8),
            waiting_description: Some("正在排队".to_owned()),
            navigation_count: Some(9),
        };

        let queue = observed_order_queue(&order, Some(&official), Some(&station)).unwrap();
        assert_eq!(queue.queue_number, Some(12));
        assert_eq!(queue.vehicles_ahead, Some(3));
        assert_eq!(queue.estimated_wait_minutes, Some(17));
        assert_eq!(
            queue.estimated_wait_source.as_deref(),
            Some("swap_order_status")
        );
        assert_eq!(queue.queue_status_text.as_deref(), Some("等待换电"));
    }

    #[test]
    fn station_queue_is_only_a_labeled_wait_fallback() {
        let order = active_order_for_queue_test();
        let station = StationQueueStatus {
            vehicles_ahead: Some(3),
            waiting_description: Some("正在排队".to_owned()),
            navigation_count: None,
        };

        let queue = observed_order_queue(&order, None, Some(&station)).unwrap();
        assert_eq!(queue.vehicles_ahead, Some(3));
        assert_eq!(queue.estimated_wait_minutes, Some(15));
        assert_eq!(
            queue.estimated_wait_source.as_deref(),
            Some("station_queue_estimate")
        );
    }

    #[test]
    fn settled_detail_time_and_actual_price_override_list_values() {
        let raw = serde_json::json!({
            "orderType": "pe_shaman_change",
            "orderNo": "settled-swap",
            "orderStatus": "100",
            "orderStatusName": "换电已完成，已支付",
            "createTime": 1793253068000_i64,
            "priceCash": "43.74",
            "payDesc": "¥ 43.74",
            "resourceAddress": "天津红星美凯龙滨海店 蔚来换电站"
        });
        let order =
            service_order_from_wire(serde_json::from_value(raw.clone()).unwrap(), raw).unwrap();
        let detail = serde_json::json!({
            "finish_time": 1793255321_i64,
            "actual_price": 33.74,
            "origin_price": 43.74,
            "fee_desc": "33.74元",
            "energy": 54.0
        });
        let imported = completed_import(&order, Some(&detail), None).unwrap();
        assert_eq!(imported.occurred_at.timestamp(), 1793255321);
        assert_eq!(imported.price_amount, Some(33.74));
        assert_eq!(imported.price_description.as_deref(), Some("33.74元"));

        // A settled free swap is a real 0.0 amount, not a missing value.
        let free_detail = serde_json::json!({
            "finish_time": 1793255321_i64,
            "actual_price": 0.0,
            "fee_desc": "0.0元"
        });
        let free = completed_import(&order, Some(&free_detail), None).unwrap();
        assert_eq!(free.price_amount, Some(0.0));
    }

    #[test]
    fn builds_history_query_and_imports_completed_price_details() {
        let url = build_order_url(
            "https://gateway-front-external.nio.com/serviceOrder/getTabOrder?lang=zh",
            false,
        )
        .unwrap();
        assert!(
            url.query_pairs()
                .any(|(name, value)| { name == "inProgressStatus" && value == "false" })
        );

        let raw = serde_json::json!({
            "orderType": "pe_shaman_change",
            "orderNo": "finished-swap",
            "orderStatus": "100",
            "orderStatusName": "已完成",
            "createTime": 1791511200000_i64,
            "priceCash": "12.50",
            "payDesc": "实付 ¥12.50",
            "resourceAddress": "苏州中心蔚来换电站",
            "extendInfo": {
                "expected_service_location": {"poi_address": "苏州市工业园区"},
                "order_finish_info": {"finish_time": 1791511800_i64},
                "paymentInfo": [
                    {"name": "换电服务费", "amount": 10, "type": 1},
                    {"name": "电费", "amount": "2.5"}
                ]
            }
        });
        let order =
            service_order_from_wire(serde_json::from_value(raw.clone()).unwrap(), raw).unwrap();
        let detail = serde_json::json!({"energy": "60.7", "plate_number": "津A12345"});
        let imported = completed_import(&order, Some(&detail), None).unwrap();
        assert_eq!(imported.occurred_at.timestamp(), 1791511800);
        assert_eq!(imported.price_amount, Some(12.5));
        assert_eq!(imported.price_currency.as_deref(), Some("CNY"));
        assert_eq!(imported.payment_items.len(), 2);
        assert_eq!(imported.energy_kwh, Some(60.7));
        assert_eq!(imported.station_address.as_deref(), Some("苏州市工业园区"));
        assert_eq!(
            imported
                .raw_payload
                .as_ref()
                .and_then(|value| value.pointer("/orderDetail/energy"))
                .and_then(Value::as_str),
            Some("60.7")
        );
    }

    #[test]
    fn binds_station_identity_from_order_detail() {
        let raw = serde_json::json!({
            "orderType": "pe_shaman_change",
            "orderNo": "finished-swap",
            "orderStatus": "100",
            "createTime": 1791511200000_i64,
            "resourceAddress": "历史列表名称",
            "extendInfo": {
                "expected_service_location": {"poi_address": "天津市滨海新区"},
                "order_finish_info": {"finish_time": 1791511800_i64}
            }
        });
        let order =
            service_order_from_wire(serde_json::from_value(raw.clone()).unwrap(), raw).unwrap();
        let detail = serde_json::json!({
            "resource_id": "PS-NIO-3606da31-f8539ae9",
            "resource_name": "天津红星美凯龙滨海店 蔚来换电站",
            "operator_id": "NIO",
            "operator_name": "NIO Power",
            "energy": 60.7
        });
        let station = swap_station_from_detail(&order, &detail).unwrap();
        let imported = completed_import(&order, Some(&detail), Some(&station)).unwrap();

        assert_eq!(station.station_id, "PS-NIO-3606da31-f8539ae9");
        assert_eq!(station.station_name, "天津红星美凯龙滨海店 蔚来换电站");
        assert_eq!(station.operator_id.as_deref(), Some("NIO"));
        assert_eq!(station.operator_name.as_deref(), Some("NIO Power"));
        assert_eq!(
            imported.station_key.as_deref(),
            Some(station.station_id.as_str())
        );
        assert_eq!(
            imported.station_name.as_deref(),
            Some(station.station_name.as_str())
        );
    }

    #[test]
    fn enriches_active_order_with_station_identity_from_detail() {
        let raw = serde_json::json!({
            "orderType": "pe_shaman_change",
            "orderNo": "active-swap",
            "orderStatus": "10",
            "orderStatusName": "换电中",
            "createTime": 1791511200000_i64,
            "resourceAddress": "列表中的站名"
        });
        let mut order =
            service_order_from_wire(serde_json::from_value(raw.clone()).unwrap(), raw).unwrap();
        assert!(order.station_key.is_none());

        let station = enrich_active_order_from_detail(
            &mut order,
            serde_json::json!({
                "resource_id": "PS-NIO-3606da31-f8539ae9",
                "resource_name": "天津红星美凯龙滨海店 蔚来换电站",
                "resource_address": "天津市滨海新区"
            }),
        )
        .unwrap();

        assert_eq!(
            order.station_key.as_deref(),
            Some("PS-NIO-3606da31-f8539ae9")
        );
        assert_eq!(order.station_name, Some(station.station_name));
        assert_eq!(order.station_address.as_deref(), Some("天津市滨海新区"));
        assert_eq!(
            order
                .raw_payload
                .pointer("/orderDetail/resource_id")
                .and_then(Value::as_str),
            Some("PS-NIO-3606da31-f8539ae9")
        );
    }

    #[test]
    fn rejects_unreasonable_order_detail_energy() {
        assert_eq!(
            exact_energy_from_detail(&serde_json::json!({"energy": 60.7})),
            Some(60.7)
        );
        assert_eq!(
            exact_energy_from_detail(&serde_json::json!({"energy": 301})),
            None
        );
    }
}
