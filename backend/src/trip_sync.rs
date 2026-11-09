//! Durable historical backfill and ongoing ingestion, independent of App reads.

use std::time::Duration;

use chrono::Utc;
use thiserror::Error;
use tracing::{info, warn};

use crate::{
    models::VehicleTripPage,
    store::{Store, StoreError, VehicleTripSyncState},
    vehicle::{NioVehicleClient, VehicleError},
};

const BACKFILL_PAGE_SIZE: u32 = 20;
const RECENT_PAGE_SIZE: u32 = 10;
const PAGES_PER_CYCLE: usize = 5;
const PAGE_PAUSE: Duration = Duration::from_secs(2);
const BACKFILL_INTERVAL: Duration = Duration::from_secs(60);
const FORWARD_INTERVAL: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Error)]
enum SyncError {
    #[error(transparent)]
    Vehicle(#[from] VehicleError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error("journey pagination did not move backwards; retrying without advancing checkpoint")]
    Stalled,
}

fn next_cursor(page: &VehicleTripPage, previous: Option<i64>) -> Result<Option<i64>, SyncError> {
    if !page.has_more {
        return Ok(None);
    }
    let cursor = page.next_query_time.ok_or(SyncError::Stalled)?;
    if previous.is_some_and(|previous| cursor >= previous) {
        return Err(SyncError::Stalled);
    }
    Ok(Some(cursor))
}

fn reached_covered_history(
    page: &VehicleTripPage,
    state: &VehicleTripSyncState,
    known: &std::collections::HashSet<String>,
) -> bool {
    state.covered_before.is_some_and(|cutoff| {
        page.items.iter().any(|trip| trip.started_at <= cutoff)
            && page.items.iter().all(|trip| known.contains(&trip.id))
    })
}

fn forward_page_size(cursor: Option<i64>) -> u32 {
    if cursor.is_none() {
        RECENT_PAGE_SIZE
    } else {
        BACKFILL_PAGE_SIZE
    }
}

async fn sync_forward(
    store: &Store,
    vehicle: &NioVehicleClient,
    state: &mut VehicleTripSyncState,
) -> Result<bool, SyncError> {
    let id = vehicle.vehicle_id();
    if state.forward_cursor.is_none() {
        state.forward_started_at = Some(Utc::now());
    }
    for index in 0..PAGES_PER_CYCLE {
        let cursor = state.forward_cursor;
        let page = vehicle.journeys(forward_page_size(cursor), cursor).await?;
        let known = store.known_vehicle_trip_ids(id, &page.items).await?;
        let overlaps = reached_covered_history(&page, state, &known);
        let next = next_cursor(&page, cursor)?;
        store.upsert_vehicle_trips(id, &page.items).await?;
        state.forward_cursor = if overlaps { None } else { next };
        if overlaps || next.is_none() {
            state.covered_before = state.forward_started_at;
            state.forward_started_at = None;
        }
        store.save_vehicle_trip_sync_state(id, &state).await?;
        if overlaps || next.is_none() {
            return Ok(false);
        }
        if index + 1 < PAGES_PER_CYCLE {
            tokio::time::sleep(PAGE_PAUSE).await;
        }
    }
    Ok(true)
}

async fn sync_cycle(store: &Store, vehicle: &NioVehicleClient) -> Result<bool, SyncError> {
    let id = vehicle.vehicle_id();
    let mut state = store.vehicle_trip_sync_state(id).await?;
    if state.backfill_completed {
        return sync_forward(store, vehicle, &mut state).await;
    }

    // Catch up with trips created during a long backfill or a service outage.
    // Its cursor is separate from the historical checkpoint and survives restarts.
    if state.backfill_cursor.is_some() && sync_forward(store, vehicle, &mut state).await? {
        return Ok(true);
    }
    for index in 0..PAGES_PER_CYCLE {
        let cursor = state.backfill_cursor;
        let started_at = Utc::now();
        let page = vehicle.journeys(BACKFILL_PAGE_SIZE, cursor).await?;
        let next = next_cursor(&page, cursor)?;
        store.upsert_vehicle_trips(id, &page.items).await?;
        if state.covered_before.is_none() {
            state.covered_before = Some(started_at);
        }
        state.backfill_cursor = next;
        if next.is_none() {
            state.backfill_completed = true;
            info!(vehicle_id = id, "historical journey backfill completed");
        }
        store.save_vehicle_trip_sync_state(id, &state).await?;
        if next.is_none() {
            return Ok(false);
        }
        if index + 1 < PAGES_PER_CYCLE {
            tokio::time::sleep(PAGE_PAUSE).await;
        }
    }
    Ok(true)
}

pub async fn run_forever(
    store: Store,
    vehicle: NioVehicleClient,
    mut requests: tokio::sync::mpsc::Receiver<()>,
) {
    loop {
        let interval = match sync_cycle(&store, &vehicle).await {
            Ok(true) => BACKFILL_INTERVAL,
            Ok(false) => FORWARD_INTERVAL,
            Err(error) => {
                warn!(vehicle_id = vehicle.vehicle_id(), %error, "journey sync failed; checkpoint retained");
                FORWARD_INTERVAL
            }
        };
        tokio::select! {
            _ = tokio::time::sleep(interval) => {},
            request = requests.recv() => {
                if request.is_none() { tokio::time::sleep(interval).await; }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::VehicleTripPage;
    use chrono::TimeZone;

    #[test]
    fn pagination_rejects_stalls_and_finishes_on_last_page() {
        let mut page = VehicleTripPage {
            items: vec![],
            has_more: true,
            next_query_time: None,
            server_time: None,
        };
        assert!(matches!(next_cursor(&page, None), Err(SyncError::Stalled)));
        page.next_query_time = Some(100);
        assert!(matches!(
            next_cursor(&page, Some(100)),
            Err(SyncError::Stalled)
        ));
        assert_eq!(next_cursor(&page, Some(101)).unwrap(), Some(100));
        page.has_more = false;
        assert_eq!(next_cursor(&page, Some(100)).unwrap(), None);
    }

    #[test]
    fn forward_starts_with_ten_then_paginates_when_needed() {
        assert_eq!(forward_page_size(None), 10);
        assert_eq!(forward_page_size(Some(1_700_000_000)), 20);
        assert_eq!(BACKFILL_PAGE_SIZE, 20);
    }

    #[test]
    fn latest_page_written_by_app_does_not_hide_older_gap() {
        let cutoff = Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, 0).unwrap();
        let location = serde_json::json!({
            "address": null, "poi": null, "road_name": null, "town": null,
            "district": null, "city": null, "province": null,
            "latitude": null, "longitude": null
        });
        let trip = |id: &str, started_at: &str| {
            serde_json::from_value(serde_json::json!({
                "id": id, "trip_id": null, "started_at": started_at,
                "ended_at": started_at, "distance_kilometers": 5.0,
                "duration_minutes": 10, "start_location": location, "end_location": location,
                "average_speed_kph": null, "average_energy_consumption_kwh_per_100km": null,
                "energy_consumed_kwh": null, "maximum_speed_kph": null,
                "odometer_kilometers": null, "rapid_acceleration_count": null,
                "rapid_deceleration_count": null, "rapid_swerve_count": null,
                "is_combined": false
            }))
            .unwrap()
        };
        let mut page = VehicleTripPage {
            items: vec![trip("new", "2026-10-02T08:00:00Z")],
            has_more: true,
            next_query_time: None,
            server_time: None,
        };
        let state = VehicleTripSyncState {
            covered_before: Some(cutoff),
            ..Default::default()
        };
        let mut known = std::collections::HashSet::from(["new".to_owned()]);
        assert!(!reached_covered_history(&page, &state, &known));
        page.items.push(trip("old", "2026-09-30T08:00:00Z"));
        assert!(!reached_covered_history(&page, &state, &known));
        known.insert("old".to_owned());
        assert!(reached_covered_history(&page, &state, &known));
    }
}
