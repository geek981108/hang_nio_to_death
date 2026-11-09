use std::time::Duration;

use tracing::{info, warn};

use crate::{
    events::EventHub,
    poller::{Poller, StationTarget},
    store::Store,
    vehicle::{
        NioVehicleClient, charging_sample_from_status, charging_state, snapshot_from_status,
        swapping_state, vehicle_locked,
    },
};

pub struct SwapMonitor {
    vehicle: NioVehicleClient,
    poller: Poller,
    store: Store,
    station_target: StationTarget,
    unlocked_interval: Duration,
    locked_interval: Duration,
    post_swap_poll_count: u32,
    events: EventHub,
}

impl SwapMonitor {
    pub fn new(
        vehicle: NioVehicleClient,
        poller: Poller,
        store: Store,
        station_target: StationTarget,
        unlocked_interval: Duration,
        locked_interval: Duration,
        post_swap_poll_count: u32,
        events: EventHub,
    ) -> Self {
        Self {
            vehicle,
            poller,
            store,
            station_target,
            unlocked_interval,
            locked_interval,
            post_swap_poll_count,
            events,
        }
    }

    pub async fn run_forever(self) {
        let mut tracker = SwapTracker::default();
        let mut charging_tracker = ChargingTracker::default();
        let mut next_interval = Duration::ZERO;
        let mut last_poll_state = None;
        let mut previous_ui_state = None;

        loop {
            tokio::time::sleep(next_interval).await;
            match self.vehicle.status().await {
                Ok(payload) => {
                    let ui_state = normalized_vehicle_state(&payload);
                    if let Some(ui_state) = ui_state {
                        if previous_ui_state.as_ref() != Some(&ui_state) {
                            match self
                                .events
                                .publish("vehicle_changed", "vehicle_status_changed")
                                .await
                            {
                                Ok(()) => previous_ui_state = Some(ui_state),
                                Err(error) => {
                                    warn!(%error, "failed to publish vehicle change event")
                                }
                            }
                        } else {
                            previous_ui_state = Some(ui_state);
                        }
                    }
                    let lock_state = vehicle_locked(&payload);
                    let charging = charging_state(&payload) == Some(true);
                    next_interval = poll_interval_for_vehicle_state(
                        lock_state,
                        charging,
                        self.unlocked_interval,
                        self.locked_interval,
                    );
                    let poll_state = (lock_state, charging);
                    if Some(poll_state) != last_poll_state {
                        info!(locked = ?lock_state, charging, interval_seconds = next_interval.as_secs(),
                            "vehicle polling interval changed");
                        last_poll_state = Some(poll_state);
                    }
                    let vehicle_snapshot = snapshot_from_status(&payload);
                    let vehicle_soc = vehicle_snapshot.as_ref().and_then(|snapshot| snapshot.soc);
                    if let Some(snapshot) = vehicle_snapshot
                        && let Err(error) = self.store.insert_vehicle_snapshot(&snapshot).await
                    {
                        warn!(%error, "failed to persist monitored vehicle snapshot");
                    }
                    if let Some(sample) = charging_sample_from_status(&payload) {
                        let charging = sample.charge_state == 1;
                        if let Some(event) = charging_tracker.observe(charging) {
                            info!(event, "vehicle charging state changed");
                            if event == "vehicle_exited_charging"
                                && let Err(error) =
                                    self.store.finalize_latest_vehicle_charging_session().await
                            {
                                warn!(%error, "failed to finalize charging-session energy");
                            }
                        }
                        if charging
                            && let Err(error) =
                                self.store.insert_vehicle_charging_sample(&sample).await
                        {
                            warn!(%error, "failed to persist vehicle charging sample");
                        }
                    } else {
                        warn!("vehicle status did not contain a complete soc_status sample");
                    }
                    if let Some(swapping) = swapping_state(&payload) {
                        if let Some(trigger) =
                            tracker.observe(swapping, self.post_swap_poll_count, vehicle_soc)
                        {
                            if let Some(soc) = tracker.active_swap_start_soc
                                && let Err(error) = self
                                    .store
                                    .record_active_order_swap_start_soc(soc, chrono::Utc::now())
                                    .await
                            {
                                warn!(%error, soc, "failed to persist pre-swap vehicle SOC");
                            }
                            self.poll_station(trigger).await;
                        }
                    } else {
                        warn!("vehicle status did not contain special_status.swapping");
                    }
                }
                Err(error) => {
                    next_interval = self.locked_interval;
                    warn!(%error, "vehicle swap state poll failed; next poll will retry");
                }
            }
        }
    }

    async fn poll_station(&self, trigger: &'static str) {
        let result = if let Some(provider) = self.station_target.current().await {
            self.poller
                .poll_once_with_provider(&provider, trigger)
                .await
        } else {
            self.poller.poll_once_for(trigger).await
        };
        match result {
            Ok(outcome) => info!(
                trigger,
                outcome = %outcome.outcome,
                snapshot_id = ?outcome.snapshot_id,
                candidate_event_id = ?outcome.candidate_event_id,
                "swap-triggered station poll completed"
            ),
            Err(error) => warn!(%error, trigger, "swap-triggered station poll failed"),
        }
    }
}

fn normalized_vehicle_state(payload: &serde_json::Value) -> Option<serde_json::Value> {
    let data = payload.get("data")?;
    let mut status = data.get("status").unwrap_or(data).clone();
    let object = status.as_object_mut()?;
    object.retain(|key, _| {
        matches!(
            key.as_str(),
            "connection_status"
                | "door_status"
                | "exterior_status"
                | "hvac_status"
                | "offcar_mode_status"
                | "position_status"
                | "soc_status"
                | "special_status"
        )
    });
    if object.is_empty() {
        return None;
    }
    fn strip_times(value: &mut serde_json::Value) {
        match value {
            serde_json::Value::Object(map) => {
                map.retain(|key, _| {
                    !matches!(
                        key.as_str(),
                        "sample_time"
                            | "update_time"
                            | "preparing_sample_time"
                            | "repair_sample_time"
                    )
                });
                for child in map.values_mut() {
                    strip_times(child);
                }
            }
            serde_json::Value::Array(items) => {
                for child in items {
                    strip_times(child);
                }
            }
            _ => {}
        }
    }
    strip_times(&mut status);
    Some(status)
}

fn poll_interval_for_vehicle_state(
    locked: Option<bool>,
    charging: bool,
    unlocked_interval: Duration,
    locked_interval: Duration,
) -> Duration {
    if locked == Some(true) && !charging {
        locked_interval
    } else {
        unlocked_interval
    }
}

#[derive(Default)]
struct ChargingTracker {
    previous: Option<bool>,
}

impl ChargingTracker {
    fn observe(&mut self, charging: bool) -> Option<&'static str> {
        let event = match (self.previous, charging) {
            (Some(false), true) | (None, true) => Some("vehicle_entered_charging"),
            (Some(true), false) => Some("vehicle_exited_charging"),
            _ => None,
        };
        self.previous = Some(charging);
        event
    }
}

#[derive(Default)]
struct SwapTracker {
    previous: Option<bool>,
    remaining_post_swap_polls: u32,
    last_non_swapping_soc: Option<f64>,
    active_swap_start_soc: Option<f64>,
}

impl SwapTracker {
    fn observe(
        &mut self,
        swapping: bool,
        post_swap_poll_count: u32,
        vehicle_soc: Option<f64>,
    ) -> Option<&'static str> {
        let trigger = match (self.previous, swapping) {
            (Some(true), true) => Some("vehicle_swap_active"),
            (_, true) => {
                self.remaining_post_swap_polls = 0;
                // A status sample taken after swapping turns true may already
                // expose a transient new-battery SOC. Only a sample observed
                // while swapping was false is safe as the old battery SOC.
                self.active_swap_start_soc = self.last_non_swapping_soc;
                Some("vehicle_entered_swap")
            }
            (Some(true), false) => {
                self.remaining_post_swap_polls = post_swap_poll_count;
                Some("vehicle_exited_swap")
            }
            (_, false) if self.remaining_post_swap_polls > 0 => {
                self.remaining_post_swap_polls -= 1;
                Some("post_swap_settlement")
            }
            _ => None,
        };
        if !swapping {
            self.last_non_swapping_soc = vehicle_soc;
            if trigger.is_none() && self.remaining_post_swap_polls == 0 {
                self.active_swap_start_soc = None;
            }
        }
        self.previous = Some(swapping);
        trigger
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_entry_active_exit_and_post_swap_settlement() {
        let mut tracker = SwapTracker::default();
        assert_eq!(tracker.observe(false, 2, Some(43.0)), None);
        assert_eq!(
            tracker.observe(true, 2, Some(42.0)),
            Some("vehicle_entered_swap")
        );
        assert_eq!(tracker.active_swap_start_soc, Some(43.0));
        assert_eq!(
            tracker.observe(true, 2, Some(90.0)),
            Some("vehicle_swap_active")
        );
        assert_eq!(tracker.active_swap_start_soc, Some(43.0));
        assert_eq!(
            tracker.observe(false, 2, Some(100.0)),
            Some("vehicle_exited_swap")
        );
        assert_eq!(
            tracker.observe(false, 2, Some(100.0)),
            Some("post_swap_settlement")
        );
        assert_eq!(
            tracker.observe(false, 2, Some(100.0)),
            Some("post_swap_settlement")
        );
        assert_eq!(tracker.observe(false, 2, Some(100.0)), None);
        assert_eq!(tracker.active_swap_start_soc, None);
    }

    #[test]
    fn captures_charging_entry_and_exit_only_once() {
        let mut tracker = ChargingTracker::default();
        assert_eq!(tracker.observe(false), None);
        assert_eq!(tracker.observe(true), Some("vehicle_entered_charging"));
        assert_eq!(tracker.observe(true), None);
        assert_eq!(tracker.observe(false), Some("vehicle_exited_charging"));
        assert_eq!(tracker.observe(false), None);
    }

    #[test]
    fn polls_unlocked_or_unknown_status_quickly_and_locked_status_slowly() {
        let fast = Duration::from_secs(3);
        let slow = Duration::from_secs(20);
        assert_eq!(
            poll_interval_for_vehicle_state(Some(false), false, fast, slow),
            fast
        );
        assert_eq!(
            poll_interval_for_vehicle_state(None, false, fast, slow),
            fast
        );
        assert_eq!(
            poll_interval_for_vehicle_state(Some(true), false, fast, slow),
            slow
        );
        assert_eq!(
            poll_interval_for_vehicle_state(Some(true), true, fast, slow),
            fast
        );
    }

    #[test]
    fn vehicle_ui_state_ignores_sample_timestamps_but_detects_lock_changes() {
        let first = serde_json::json!({"data":{"door_status":{"vehicle_lock_status":1,"sample_time":100},"soc_status":{"soc":80,"sample_time":100}}});
        let later = serde_json::json!({"data":{"door_status":{"vehicle_lock_status":1,"sample_time":200},"soc_status":{"soc":80,"sample_time":200}}});
        let unlocked = serde_json::json!({"data":{"door_status":{"vehicle_lock_status":0,"sample_time":300},"soc_status":{"soc":80,"sample_time":300}}});
        assert_eq!(
            normalized_vehicle_state(&first),
            normalized_vehicle_state(&later)
        );
        assert_ne!(
            normalized_vehicle_state(&later),
            normalized_vehicle_state(&unlocked)
        );
    }
}
