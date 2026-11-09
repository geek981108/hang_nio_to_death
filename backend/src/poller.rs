use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use chrono::{DateTime, Utc};
use thiserror::Error;
use tokio::sync::{Mutex, RwLock};
use tracing::{error, info, warn};

use crate::{
    detector::{
        DetectedOrderSwap, closest_battery_by_soc, detect_swap, detected_order_swap,
        inventory_delta,
    },
    models::{BatteryObservation, PollOutcome, StationSnapshot},
    provider::{NioStationProvider, ProviderError},
    store::{Store, StoreError, StoredSnapshot},
};

const OUTGOING_SOC_MAX_DELTA: f64 = 8.0;
const OUTGOING_SOC_MINIMUM_MARGIN: f64 = 3.0;

#[derive(Clone)]
pub struct Poller {
    provider: Option<NioStationProvider>,
    store: Store,
    gate: Arc<Mutex<()>>,
    in_progress: Arc<AtomicBool>,
}

// Reset observable progress even if a request is cancelled while awaiting
// the upstream provider or database. The mutex separately releases ownership.
struct PollProgressGuard(Arc<AtomicBool>);

impl PollProgressGuard {
    fn new(in_progress: Arc<AtomicBool>) -> Self {
        in_progress.store(true, Ordering::Relaxed);
        Self(in_progress)
    }
}

impl Drop for PollProgressGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Relaxed);
    }
}

#[derive(Clone, Default)]
pub struct StationTarget {
    provider: Arc<RwLock<Option<TargetEntry>>>,
}

struct TargetEntry {
    provider: NioStationProvider,
    refreshed_at: tokio::time::Instant,
}

impl StationTarget {
    pub async fn set(&self, provider: NioStationProvider) {
        *self.provider.write().await = Some(TargetEntry {
            provider,
            refreshed_at: tokio::time::Instant::now(),
        });
    }

    pub async fn current(&self) -> Option<NioStationProvider> {
        self.provider
            .read()
            .await
            .as_ref()
            .filter(|target| target.refreshed_at.elapsed() <= Duration::from_secs(2 * 60 * 60))
            .map(|target| target.provider.clone())
    }
}

#[derive(Debug, Error)]
pub enum PollError {
    #[error("station provider is not configured")]
    NotConfigured,
    #[error(transparent)]
    Provider(#[from] ProviderError),
    #[error(transparent)]
    Store(#[from] StoreError),
}

impl Poller {
    pub fn new(provider: Option<NioStationProvider>, store: Store) -> Self {
        Self {
            provider,
            store,
            gate: Arc::new(Mutex::new(())),
            in_progress: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn configured(&self) -> bool {
        self.provider.is_some()
    }

    pub fn in_progress(&self) -> bool {
        self.in_progress.load(Ordering::Relaxed)
    }

    pub fn station_key(&self) -> Option<&str> {
        self.provider.as_ref().map(NioStationProvider::station_key)
    }

    pub fn matches_station(
        &self,
        station_key: Option<&str>,
        station_name: Option<&str>,
        station_address: Option<&str>,
    ) -> bool {
        let Some(provider) = &self.provider else {
            return false;
        };
        if station_key.is_some_and(|key| key == provider.station_key()) {
            return true;
        }
        let configured_name = normalize_station_name(provider.station_name());
        [station_name, station_address]
            .into_iter()
            .flatten()
            .any(|value| normalize_station_name(value) == configured_name)
    }

    pub async fn poll_once_for(&self, trigger: &'static str) -> Result<PollOutcome, PollError> {
        let provider = self.provider.as_ref().ok_or(PollError::NotConfigured)?;
        self.poll_once_with_provider(provider, trigger).await
    }

    pub async fn poll_once_with_provider(
        &self,
        provider: &NioStationProvider,
        trigger: &'static str,
    ) -> Result<PollOutcome, PollError> {
        let started_at = Utc::now();
        let Ok(_guard) = self.gate.try_lock() else {
            let message = format!("trigger={trigger}; another poll is already in progress");
            self.store
                .record_poll(started_at, "skipped", None, &message)
                .await?;
            return Ok(PollOutcome {
                outcome: "skipped".to_owned(),
                snapshot_id: None,
                candidate_event_id: None,
                battery_count: None,
                message,
            });
        };
        let result = {
            let _progress = PollProgressGuard::new(self.in_progress.clone());
            self.poll_locked(provider).await.map(|mut outcome| {
                outcome.message = format!("trigger={trigger}; {}", outcome.message);
                outcome
            })
        };

        match result {
            Ok(outcome) => {
                self.store
                    .record_poll(
                        started_at,
                        &outcome.outcome,
                        outcome.snapshot_id.as_deref(),
                        &outcome.message,
                    )
                    .await?;
                Ok(outcome)
            }
            Err(error) => {
                let message = error.to_string();
                if let Err(record_error) = self
                    .store
                    .record_poll(started_at, "error", None, &message)
                    .await
                {
                    error!(%record_error, "failed to record poll failure");
                }
                Err(error)
            }
        }
    }

    async fn poll_locked(&self, provider: &NioStationProvider) -> Result<PollOutcome, PollError> {
        let snapshot = provider.fetch().await?;
        let previous = self.store.latest_snapshot(&snapshot.station_key).await?;
        let is_initial_snapshot = previous.is_none();
        let snapshot_id = self.store.insert_snapshot(&snapshot).await?;
        if let Err(error) = self
            .store
            .upsert_station_identity(
                &snapshot.station_key,
                &snapshot.station_name,
                snapshot.address.as_deref(),
                snapshot.captured_at,
            )
            .await
        {
            warn!(
                %error,
                station_key = %snapshot.station_key,
                "failed to refresh station directory identity"
            );
        }

        let (has_order_context, order_candidate_id) = if let Some(previous) = previous.as_ref() {
            self.detect_stable_order_candidate(previous, &snapshot_id, &snapshot)
                .await?
        } else {
            (false, None)
        };
        let candidate_event_id = if order_candidate_id.is_some() {
            order_candidate_id
        } else if has_order_context {
            None
        } else if let Some(previous) = previous {
            if let Some(detected) = detect_swap(&previous.batteries, &snapshot.batteries) {
                Some(
                    self.store
                        .insert_candidate(&previous.id, &snapshot_id, &snapshot, &detected)
                        .await?,
                )
            } else {
                None
            }
        } else {
            None
        };

        let message = if candidate_event_id.is_some() {
            "snapshot saved; one stable swap candidate detected"
        } else if is_initial_snapshot {
            "initial baseline snapshot saved"
        } else {
            "snapshot saved; no unambiguous one-added/one-removed change"
        };
        Ok(PollOutcome {
            outcome: "success".to_owned(),
            snapshot_id: Some(snapshot_id),
            candidate_event_id,
            battery_count: Some(snapshot.batteries.len()),
            message: message.to_owned(),
        })
    }

    async fn detect_stable_order_candidate(
        &self,
        previous: &StoredSnapshot,
        current_snapshot_id: &str,
        current: &StationSnapshot,
    ) -> Result<(bool, Option<String>), PollError> {
        let baselines = self
            .store
            .active_order_baselines_for_station(&current.station_key)
            .await?;
        if baselines.is_empty() {
            return Ok((false, None));
        }
        if baselines.len() != 1 {
            return Ok((true, None));
        }
        let order = &baselines[0];
        let Some(baseline) = self.store.snapshot_by_id(&order.snapshot_id).await? else {
            return Ok((true, None));
        };
        if baseline.station_key != current.station_key
            || previous.captured_at <= baseline.captured_at
        {
            return Ok((true, None));
        }
        let Some(previous_pair) = self
            .order_pair_at(
                &baseline,
                &previous.station_key,
                previous.captured_at,
                &previous.batteries,
                order.swap_start_soc,
            )
            .await?
        else {
            return Ok((true, None));
        };
        let Some(mut current_pair) = self
            .order_pair_at(
                &baseline,
                &current.station_key,
                current.captured_at,
                &current.batteries,
                order.swap_start_soc,
            )
            .await?
        else {
            return Ok((true, None));
        };
        if !same_battery_pair(&previous_pair, &current_pair) {
            return Ok((true, None));
        }

        if let Some(evidence) = current_pair.evidence.as_object_mut() {
            evidence.insert("method".to_owned(), "order_baseline_inventory_delta".into());
            evidence.insert("order_no".to_owned(), order.order_no.clone().into());
            evidence.insert(
                "baseline_snapshot_id".to_owned(),
                baseline.id.clone().into(),
            );
            evidence.insert(
                "previous_snapshot_id".to_owned(),
                previous.id.clone().into(),
            );
            evidence.insert(
                "current_snapshot_id".to_owned(),
                current_snapshot_id.to_owned().into(),
            );
            evidence.insert("stable_observation_count".to_owned(), 2.into());
        }
        let candidate_id = self
            .store
            .upsert_order_candidate(&order.order_no, &baseline.id, current, &current_pair)
            .await?;
        Ok((true, Some(candidate_id)))
    }

    async fn order_pair_at(
        &self,
        baseline: &StoredSnapshot,
        station_key: &str,
        captured_at: DateTime<Utc>,
        batteries: &[BatteryObservation],
        swap_start_soc: Option<f64>,
    ) -> Result<Option<DetectedOrderSwap>, PollError> {
        let delta = inventory_delta(&baseline.batteries, batteries);
        if delta.removed_from_station.len() != 1 {
            return Ok(None);
        }
        let mut outgoing_candidates = Vec::with_capacity(delta.added_to_station.len());
        for candidate in delta.added_to_station {
            outgoing_candidates.push(
                self.store
                    .first_battery_observation_after(
                        station_key,
                        &candidate.battery_id,
                        baseline.captured_at,
                        captured_at,
                    )
                    .await?
                    .unwrap_or(candidate),
            );
        }
        let (outgoing, selection) = if outgoing_candidates.is_empty() {
            (None, "awaiting_station_intake")
        } else if outgoing_candidates.len() == 1 {
            (Some(outgoing_candidates.remove(0)), "single_added_battery")
        } else if let Some(soc) = swap_start_soc {
            let Some(selected) = closest_battery_by_soc(
                &outgoing_candidates,
                soc,
                OUTGOING_SOC_MAX_DELTA,
                OUTGOING_SOC_MINIMUM_MARGIN,
            ) else {
                return Ok(None);
            };
            (Some(selected), "closest_to_vehicle_swap_start_soc")
        } else {
            return Ok(None);
        };
        let removed = delta.removed_from_station.into_iter().next().unwrap();
        // Some stations update a slot in two phases during a swap: the SOC is
        // overwritten with the vehicle battery's SOC first, while the battery
        // ID still names the battery that will leave the station. Its last
        // observation is therefore transient and cannot describe the incoming
        // battery. The order baseline is the last stable pre-swap identity/SOC.
        let incoming = baseline
            .batteries
            .iter()
            .find(|battery| battery.battery_id == removed.battery_id)
            .cloned()
            .unwrap_or(removed);
        let mut detected = detected_order_swap(outgoing, incoming);
        if let Some(evidence) = detected.evidence.as_object_mut() {
            evidence.insert("outgoing_selection".to_owned(), selection.into());
            if selection == "closest_to_vehicle_swap_start_soc" {
                evidence.insert("vehicle_swap_start_soc".to_owned(), swap_start_soc.into());
                evidence.insert(
                    "outgoing_candidate_count".to_owned(),
                    outgoing_candidates.len().into(),
                );
            }
        }
        Ok(Some(detected))
    }

    pub async fn run_forever(self, interval: Duration) {
        if !self.configured() {
            warn!("station polling is disabled because STATION_URL is not configured");
            return;
        }
        let mut ticker = tokio::time::interval(interval);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            match self.poll_once_for("scheduled_interval").await {
                Ok(outcome) => info!(
                    outcome = %outcome.outcome,
                    snapshot_id = ?outcome.snapshot_id,
                    candidate_event_id = ?outcome.candidate_event_id,
                    "station poll completed"
                ),
                Err(error) => warn!(%error, "station poll failed; next scheduled poll will retry"),
            }
        }
    }
}

fn same_battery_pair(left: &DetectedOrderSwap, right: &DetectedOrderSwap) -> bool {
    left.outgoing.as_ref().map(|battery| &battery.battery_id)
        == right.outgoing.as_ref().map(|battery| &battery.battery_id)
        && left.incoming.battery_id == right.incoming.battery_id
}

fn normalize_station_name(value: &str) -> String {
    value
        .trim()
        .strip_suffix("蔚来换电站")
        .unwrap_or(value.trim())
        .split_whitespace()
        .collect::<String>()
        .to_lowercase()
}

#[cfg(test)]
mod station_match_tests {
    use super::*;
    use crate::config::StationConfig;
    use crate::models::{ImportedOrder, ObservedServiceOrder};
    use chrono::{NaiveDate, TimeZone};
    use std::collections::HashMap;

    fn battery(id: &str, capacity_kwh: f64, soc_percent: f64, date: &str) -> BatteryObservation {
        BatteryObservation {
            battery_id: id.to_owned(),
            slot_id: None,
            battery_type: Some("70/75kWh".to_owned()),
            capacity_kwh: Some(capacity_kwh),
            soc_percent: Some(soc_percent),
            occupied: false,
            production_date: Some(NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap()),
        }
    }

    #[tokio::test]
    async fn cancellation_resets_poll_progress() {
        let in_progress = Arc::new(AtomicBool::new(false));
        let flag = in_progress.clone();
        let started = Arc::new(tokio::sync::Notify::new());
        let notify = started.clone();
        let task = tokio::spawn(async move {
            let _progress = PollProgressGuard::new(flag);
            notify.notify_one();
            std::future::pending::<()>().await;
        });
        started.notified().await;
        assert!(in_progress.load(Ordering::Relaxed));
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(!in_progress.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn matches_station_by_key_or_normalized_name() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let provider = NioStationProvider::new(StationConfig {
            key: "station-1".to_owned(),
            name: "苏州中心蔚来换电站".to_owned(),
            url: "https://example.com/station".to_owned(),
            headers: HashMap::new(),
        })
        .unwrap();
        let poller = Poller::new(Some(provider), store);
        assert!(poller.matches_station(Some("station-1"), None, None));
        assert!(poller.matches_station(None, Some("苏州中心"), None));
        assert!(!poller.matches_station(None, Some("上海中心"), None));
    }

    #[tokio::test]
    async fn order_baseline_detects_staggered_swap_after_two_stable_snapshots() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let poller = Poller::new(None, store.clone());
        let started_at = Utc.with_ymd_and_hms(2026, 10, 14, 5, 51, 22).unwrap();
        let baseline = StationSnapshot {
            station_key: "station-1".to_owned(),
            station_name: "Station 1".to_owned(),
            address: None,
            captured_at: started_at,
            batteries: vec![
                battery("kept", 75.0, 80.0, "2024-01-01"),
                battery("incoming", 75.0, 100.0, "2023-11-03"),
            ],
            current_fees: vec![],
        };
        let baseline_id = store.insert_snapshot(&baseline).await.unwrap();
        let order = ObservedServiceOrder {
            order_no: "active-order".to_owned(),
            order_type: "pe_shaman_change".to_owned(),
            order_status: Some("10".to_owned()),
            order_status_name: Some("换电中".to_owned()),
            created_at: started_at,
            vehicle_id: Some("vehicle-1".to_owned()),
            vin_code: Some("VIN-1".to_owned()),
            station_key: Some("station-1".to_owned()),
            station_name: Some("Station 1".to_owned()),
            station_address: None,
            raw_payload: serde_json::json!({"orderNo": "active-order"}),
        };
        store.observe_service_order(&order).await.unwrap();
        store
            .mark_service_order_baseline(&order.order_no, &baseline_id)
            .await
            .unwrap();
        store
            .set_active_service_orders(std::slice::from_ref(&order.order_no))
            .await
            .unwrap();

        let transient_soc_update = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(55),
            batteries: vec![
                battery("kept", 75.0, 80.0, "2024-01-01"),
                // The station has already overwritten the slot SOC, but has
                // not switched its battery ID yet.
                battery("incoming", 75.0, 43.0, "2023-11-03"),
            ],
            ..baseline.clone()
        };
        let transient_id = store.insert_snapshot(&transient_soc_update).await.unwrap();
        let transient_stored = store.snapshot_by_id(&transient_id).await.unwrap().unwrap();

        let first_complete = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(125),
            batteries: vec![
                battery("kept", 75.0, 80.0, "2024-01-01"),
                // The SOC is retained when the slot ID finally switches to
                // the battery removed from the vehicle.
                battery("outgoing", 70.0, 43.0, "2020-04-25"),
            ],
            ..baseline.clone()
        };
        let first_complete_id = store.insert_snapshot(&first_complete).await.unwrap();
        let (has_context, candidate) = poller
            .detect_stable_order_candidate(&transient_stored, &first_complete_id, &first_complete)
            .await
            .unwrap();
        assert!(has_context);
        assert!(candidate.is_none());

        let first_complete_stored = store
            .snapshot_by_id(&first_complete_id)
            .await
            .unwrap()
            .unwrap();
        let stable = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(135),
            batteries: vec![
                battery("kept", 75.0, 80.0, "2024-01-01"),
                battery("outgoing", 70.0, 37.0, "2020-04-25"),
            ],
            ..baseline
        };
        let stable_id = store.insert_snapshot(&stable).await.unwrap();
        let (_, candidate) = poller
            .detect_stable_order_candidate(&first_complete_stored, &stable_id, &stable)
            .await
            .unwrap();
        let event = store
            .event_by_id(candidate.as_deref().unwrap())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(event.order_no.as_deref(), Some("active-order"));
        assert_eq!(event.outgoing_battery_id.as_deref(), Some("outgoing"));
        assert_eq!(event.outgoing_soc_percent, Some(43.0));
        assert_eq!(event.incoming_battery_id.as_deref(), Some("incoming"));
        assert_eq!(event.incoming_soc_percent, Some(100.0));
        assert_eq!(event.estimated_energy_kwh, Some(44.9));

        let confirmed = store
            .import_order(
                &ImportedOrder {
                    order_no: order.order_no,
                    occurred_at: stable.captured_at,
                    station_key: Some(stable.station_key),
                    station_name: Some(stable.station_name),
                    station_address: None,
                    order_status_name: Some("换电已完成".to_owned()),
                    price_amount: None,
                    price_currency: None,
                    price_description: None,
                    payment_items: vec![],
                    energy_kwh: Some(32.6),
                    outgoing_battery: None,
                    incoming_battery: None,
                    raw_payload: None,
                },
                Duration::from_secs(30 * 60),
            )
            .await
            .unwrap();
        assert_eq!(confirmed.id, event.id);
        assert_eq!(confirmed.status, "confirmed");
        assert_eq!(confirmed.exact_energy_kwh, Some(32.6));
        assert_eq!(confirmed.outgoing_soc_percent, Some(43.0));
        assert_eq!(confirmed.incoming_soc_percent, Some(100.0));
    }

    #[tokio::test]
    async fn order_baseline_keeps_incoming_when_outgoing_appears_later() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let poller = Poller::new(None, store.clone());
        let started_at = Utc::now() - chrono::Duration::minutes(1);
        let baseline = StationSnapshot {
            station_key: "station-1".to_owned(),
            station_name: "Station 1".to_owned(),
            address: None,
            captured_at: started_at,
            batteries: vec![
                battery("kept", 75.0, 80.0, "2024-01-01"),
                battery("incoming", 75.0, 100.0, "2023-09-23"),
            ],
            current_fees: vec![],
        };
        let baseline_id = store.insert_snapshot(&baseline).await.unwrap();
        let order = ObservedServiceOrder {
            order_no: "partial-order".to_owned(),
            order_type: "pe_shaman_change".to_owned(),
            order_status: Some("10".to_owned()),
            order_status_name: Some("换电中".to_owned()),
            created_at: started_at,
            vehicle_id: Some("vehicle-1".to_owned()),
            vin_code: Some("VIN-1".to_owned()),
            station_key: Some("station-1".to_owned()),
            station_name: Some("Station 1".to_owned()),
            station_address: None,
            raw_payload: serde_json::json!({"orderNo": "partial-order"}),
        };
        store.observe_service_order(&order).await.unwrap();
        store
            .mark_service_order_baseline(&order.order_no, &baseline_id)
            .await
            .unwrap();
        store
            .set_active_service_orders(std::slice::from_ref(&order.order_no))
            .await
            .unwrap();
        assert!(
            store
                .record_active_order_swap_start_soc(32.5, started_at)
                .await
                .unwrap()
        );

        let first_partial = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(10),
            batteries: vec![battery("kept", 75.0, 80.0, "2024-01-01")],
            ..baseline.clone()
        };
        let first_partial_id = store.insert_snapshot(&first_partial).await.unwrap();
        let baseline_stored = store.snapshot_by_id(&baseline_id).await.unwrap().unwrap();
        let (_, first_candidate) = poller
            .detect_stable_order_candidate(&baseline_stored, &first_partial_id, &first_partial)
            .await
            .unwrap();
        assert!(first_candidate.is_none());

        let second_partial = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(20),
            ..first_partial.clone()
        };
        let second_partial_id = store.insert_snapshot(&second_partial).await.unwrap();
        let first_partial_stored = store
            .snapshot_by_id(&first_partial_id)
            .await
            .unwrap()
            .unwrap();
        let (_, partial_candidate) = poller
            .detect_stable_order_candidate(
                &first_partial_stored,
                &second_partial_id,
                &second_partial,
            )
            .await
            .unwrap();
        let partial_id = partial_candidate.unwrap();
        let partial = store.event_by_id(&partial_id).await.unwrap().unwrap();
        assert_eq!(partial.incoming_battery_id.as_deref(), Some("incoming"));
        assert_eq!(partial.incoming_soc_percent, Some(100.0));
        assert!(partial.outgoing_battery_id.is_none());
        assert_eq!(partial.energy_source, "unavailable");
        assert_eq!(partial.battery_source, "station_inventory_delta");

        let confirmed = store
            .import_order(
                &ImportedOrder {
                    order_no: order.order_no.clone(),
                    occurred_at: started_at,
                    station_key: Some("station-1".to_owned()),
                    station_name: Some("Station 1".to_owned()),
                    station_address: None,
                    order_status_name: Some("换电已完成".to_owned()),
                    price_amount: None,
                    price_currency: None,
                    price_description: None,
                    payment_items: vec![],
                    energy_kwh: None,
                    outgoing_battery: None,
                    incoming_battery: None,
                    raw_payload: None,
                },
                Duration::from_secs(30 * 60),
            )
            .await
            .unwrap();
        assert_eq!(confirmed.id, partial_id);
        assert_eq!(confirmed.incoming_battery_id.as_deref(), Some("incoming"));
        assert!(confirmed.outgoing_battery_id.is_none());

        store.set_active_service_orders(&[]).await.unwrap();
        let first_complete = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(30),
            batteries: vec![
                battery("kept", 75.0, 80.0, "2024-01-01"),
                battery("outgoing", 75.0, 33.0, "2020-04-25"),
            ],
            ..baseline.clone()
        };
        let first_complete_id = store.insert_snapshot(&first_complete).await.unwrap();
        let second_partial_stored = store
            .snapshot_by_id(&second_partial_id)
            .await
            .unwrap()
            .unwrap();
        let (_, transitional_candidate) = poller
            .detect_stable_order_candidate(
                &second_partial_stored,
                &first_complete_id,
                &first_complete,
            )
            .await
            .unwrap();
        assert!(transitional_candidate.is_none());

        let stable_complete = StationSnapshot {
            captured_at: started_at + chrono::Duration::seconds(40),
            ..first_complete.clone()
        };
        let stable_complete_id = store.insert_snapshot(&stable_complete).await.unwrap();
        let first_complete_stored = store
            .snapshot_by_id(&first_complete_id)
            .await
            .unwrap()
            .unwrap();
        let (_, complete_candidate) = poller
            .detect_stable_order_candidate(
                &first_complete_stored,
                &stable_complete_id,
                &stable_complete,
            )
            .await
            .unwrap();
        let completed_id = complete_candidate.unwrap();
        assert_eq!(completed_id, partial_id);
        let completed = store.event_by_id(&completed_id).await.unwrap().unwrap();
        assert_eq!(completed.status, "confirmed");
        assert_eq!(completed.incoming_battery_id.as_deref(), Some("incoming"));
        assert_eq!(completed.outgoing_battery_id.as_deref(), Some("outgoing"));
        assert_eq!(completed.outgoing_soc_percent, Some(33.0));
        assert_eq!(completed.estimated_energy_kwh, Some(50.25));
        assert_eq!(completed.energy_source, "station_inventory_estimate");
    }
}
