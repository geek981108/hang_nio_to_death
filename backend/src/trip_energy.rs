//! Daily Beijing-time cache of energy consumption over the most recent 100 km.
//! HTTP/MCP reads never fetch journeys or update this cache.

use std::{collections::HashSet, time::Duration};

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::{info, warn};

use crate::{
    models::{VehicleTrip, VehicleTripPage},
    store::{Store, StoreError, TripEnergyCacheRows},
    vehicle::{NioVehicleClient, VehicleError},
};

pub const TARGET_DISTANCE_KM: f64 = 100.0;
pub const PAGE_SIZE: u32 = 20;
pub const MAX_TRIPS: usize = 200;
pub const MAX_PAGES: usize = 10;
const EPSILON: f64 = 1e-7;
const STALE_AFTER_HOURS: i64 = 36;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TripEnergySummary {
    pub target_distance_km: f64,
    /// Chronological window distance, including trips with unavailable energy.
    pub actual_distance_km: f64,
    /// Distance within that window whose whole-trip energy was available.
    pub covered_distance_km: f64,
    pub missing_energy_distance_km: f64,
    /// Includes proportional estimation for a partial boundary trip.
    pub included_energy_kwh: f64,
    /// Rate over covered_distance_km, not over gaps with missing energy.
    pub consumption_kwh_per_100km: Option<f64>,
    pub window_start: Option<DateTime<Utc>>,
    pub window_end: Option<DateTime<Utc>>,
    pub sample_cutoff_at: DateTime<Utc>,
    pub computed_at: DateTime<Utc>,
    pub included_trip_count: usize,
    pub energy_known_trip_count: usize,
    pub missing_energy_trip_count: usize,
    pub skipped_invalid_trip_count: usize,
    pub inspected_trip_count: usize,
    pub pages_fetched: usize,
    pub coverage_complete: bool,
    pub coverage_status: String,
    pub boundary_method: String,
    pub boundary_trip_used_distance_km: Option<f64>,
    pub boundary_trip_full_distance_km: Option<f64>,
    pub history_fetch_incomplete: bool,
}

#[derive(Debug, Serialize)]
pub struct TripEnergyCacheState {
    pub status: &'static str,
    pub stale: bool,
    pub last_attempt_failed: bool,
    pub last_attempt_day: Option<NaiveDate>,
    pub last_attempt_status: Option<String>,
    pub summary: Option<TripEnergySummary>,
}

#[derive(Debug, Error)]
pub enum TripEnergyError {
    #[error("NIO_TRIP_ENERGY_TIME must be HH:MM in Asia/Shanghai")]
    InvalidSchedule,
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Vehicle(#[from] VehicleError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Copy, Debug)]
pub struct DailySchedule {
    hour: u32,
    minute: u32,
}

impl DailySchedule {
    pub fn from_env() -> Result<Self, TripEnergyError> {
        let value = std::env::var("NIO_TRIP_ENERGY_TIME").unwrap_or_else(|_| "03:00".to_owned());
        Self::parse(&value)
    }

    fn parse(value: &str) -> Result<Self, TripEnergyError> {
        let (hour, minute) = value
            .split_once(':')
            .ok_or(TripEnergyError::InvalidSchedule)?;
        if hour.len() != 2
            || minute.len() != 2
            || !hour.bytes().all(|b| b.is_ascii_digit())
            || !minute.bytes().all(|b| b.is_ascii_digit())
        {
            return Err(TripEnergyError::InvalidSchedule);
        }
        let hour = hour.parse().map_err(|_| TripEnergyError::InvalidSchedule)?;
        let minute = minute
            .parse()
            .map_err(|_| TripEnergyError::InvalidSchedule)?;
        if hour > 23 || minute > 59 {
            return Err(TripEnergyError::InvalidSchedule);
        }
        Ok(Self { hour, minute })
    }

    fn at(&self, day: NaiveDate) -> DateTime<Utc> {
        let china = FixedOffset::east_opt(8 * 3600).expect("valid China offset");
        china
            .with_ymd_and_hms(
                day.year(),
                day.month(),
                day.day(),
                self.hour,
                self.minute,
                0,
            )
            .single()
            .expect("valid China schedule")
            .with_timezone(&Utc)
    }

    fn due_day(&self, now: DateTime<Utc>) -> (NaiveDate, DateTime<Utc>) {
        let day = crate::daily_checkin::china_day(now);
        (day, self.at(day))
    }
}

fn round(value: f64, decimals: i32) -> f64 {
    let factor = 10f64.powi(decimals);
    (value * factor).round() / factor
}

fn valid_trip_distance(trip: &VehicleTrip, cutoff: DateTime<Utc>) -> bool {
    trip.started_at <= trip.ended_at
        && trip.ended_at <= cutoff
        && trip.distance_kilometers.is_finite()
        && trip.distance_kilometers > 0.0
}

/// Count chronological distance, including energy-missing journeys, so older
/// journeys cannot silently replace gaps in the latest 100 km.
pub fn summarize(
    trips: &[VehicleTrip],
    sample_cutoff_at: DateTime<Utc>,
    computed_at: DateTime<Utc>,
    pages_fetched: usize,
    history_fetch_incomplete: bool,
) -> TripEnergySummary {
    let mut sorted = trips.iter().collect::<Vec<_>>();
    sorted.sort_by(|a, b| {
        b.ended_at
            .cmp(&a.ended_at)
            .then(b.started_at.cmp(&a.started_at))
    });
    let mut actual = 0.0;
    let mut covered = 0.0;
    let mut energy_sum = 0.0;
    let mut included = 0;
    let mut known = 0;
    let mut missing = 0;
    let mut invalid = 0;
    let mut window_start: Option<DateTime<Utc>> = None;
    let mut window_end: Option<DateTime<Utc>> = None;
    let mut boundary_method = "whole_trips";
    let mut boundary_used = None;
    let mut boundary_full = None;
    for trip in sorted {
        if actual >= TARGET_DISTANCE_KM - EPSILON {
            break;
        }
        if !valid_trip_distance(trip, sample_cutoff_at) {
            invalid += 1;
            continue;
        }
        let distance = trip.distance_kilometers.min(TARGET_DISTANCE_KM - actual);
        let partial = distance + EPSILON < trip.distance_kilometers;
        actual += distance;
        included += 1;
        window_start = Some(window_start.map_or(trip.started_at, |at| at.min(trip.started_at)));
        window_end = Some(window_end.map_or(trip.ended_at, |at| at.max(trip.ended_at)));
        if partial {
            boundary_used = Some(distance);
            boundary_full = Some(trip.distance_kilometers);
        }
        match trip
            .energy_consumed_kwh
            .filter(|value| value.is_finite() && *value >= 0.0)
        {
            Some(energy) => {
                covered += distance;
                // The proportional boundary energy comes from the whole-trip
                // average. It is not a measured segment of that trip.
                energy_sum += energy * distance / trip.distance_kilometers;
                known += 1;
                if partial {
                    boundary_method = "proportional_from_trip_average";
                }
            }
            None => {
                missing += 1;
                if partial {
                    boundary_method = "distance_only_energy_unavailable";
                }
            }
        }
    }
    let missing_distance = (actual - covered).max(0.0);
    let target_reached = actual >= TARGET_DISTANCE_KM - EPSILON;
    let complete = target_reached && missing_distance < EPSILON && invalid == 0;
    let status = if !target_reached {
        if history_fetch_incomplete {
            "query_limit_reached"
        } else {
            "insufficient_distance"
        }
    } else if !complete {
        "incomplete_data"
    } else {
        "complete"
    };
    TripEnergySummary {
        target_distance_km: TARGET_DISTANCE_KM,
        actual_distance_km: round(actual, 2),
        covered_distance_km: round(covered, 2),
        missing_energy_distance_km: round(missing_distance, 2),
        included_energy_kwh: round(energy_sum, 2),
        consumption_kwh_per_100km: (covered > 0.0)
            .then_some(round(energy_sum / covered * 100.0, 2)),
        window_start,
        window_end,
        sample_cutoff_at,
        computed_at,
        included_trip_count: included,
        energy_known_trip_count: known,
        missing_energy_trip_count: missing,
        skipped_invalid_trip_count: invalid,
        inspected_trip_count: trips.len(),
        pages_fetched,
        coverage_complete: complete,
        coverage_status: status.to_owned(),
        boundary_method: boundary_method.to_owned(),
        boundary_trip_used_distance_km: boundary_used.map(|value| round(value, 2)),
        boundary_trip_full_distance_km: boundary_full.map(|value| round(value, 2)),
        history_fetch_incomplete,
    }
}

fn observed_distance(trips: &[VehicleTrip], cutoff: DateTime<Utc>) -> f64 {
    trips
        .iter()
        .filter(|trip| valid_trip_distance(trip, cutoff))
        .map(|trip| trip.distance_kilometers)
        .sum::<f64>()
        .min(TARGET_DISTANCE_KM)
}

#[derive(Default)]
struct TripPages {
    trips: Vec<VehicleTrip>,
    seen_ids: HashSet<String>,
    pages_fetched: usize,
    next_cursor: Option<i64>,
    has_more: bool,
    stalled: bool,
}

impl TripPages {
    fn add(&mut self, page: VehicleTripPage) {
        self.pages_fetched += 1;
        self.has_more = page.has_more;
        let previous_cursor = self.next_cursor;
        self.next_cursor = page.next_query_time;
        let before = self.trips.len();
        for trip in page.items {
            if self.seen_ids.insert(trip.id.clone()) {
                self.trips.push(trip);
            }
        }
        self.stalled = self.has_more
            && (self.trips.len() == before
                || self.next_cursor.is_none()
                || previous_cursor
                    .is_some_and(|previous| self.next_cursor.is_some_and(|next| next >= previous)));
    }

    fn needs_more(&self, cutoff: DateTime<Utc>) -> bool {
        self.has_more
            && !self.stalled
            && self.trips.len() < MAX_TRIPS
            && self.pages_fetched < MAX_PAGES
            && observed_distance(&self.trips, cutoff) < TARGET_DISTANCE_KM - EPSILON
    }

    fn incomplete(&self, cutoff: DateTime<Utc>) -> bool {
        observed_distance(&self.trips, cutoff) < TARGET_DISTANCE_KM - EPSILON && self.has_more
    }
}

async fn fetch_recent_trips(
    vehicle: &NioVehicleClient,
    cutoff: DateTime<Utc>,
) -> Result<TripPages, VehicleError> {
    let mut pages = TripPages::default();
    loop {
        let remaining = MAX_TRIPS.saturating_sub(pages.trips.len());
        if remaining == 0 {
            break;
        }
        let count = PAGE_SIZE.min(remaining as u32);
        let page = vehicle.journeys(count, pages.next_cursor).await?;
        pages.add(page);
        if !pages.needs_more(cutoff) {
            break;
        }
    }
    Ok(pages)
}

pub async fn load_cache(
    store: &Store,
    now: DateTime<Utc>,
) -> Result<TripEnergyCacheState, TripEnergyError> {
    let TripEnergyCacheRows {
        latest_success_json,
        latest_attempt_day,
        latest_attempt_outcome,
    } = store.trip_energy_cache_rows().await?;
    let summary = latest_success_json
        .map(|raw| serde_json::from_str::<TripEnergySummary>(&raw))
        .transpose()?;
    let last_attempt_failed = latest_attempt_outcome.as_deref() == Some("failed");
    let attempt_incomplete = latest_attempt_outcome.as_deref() == Some("started");
    let aged = summary.as_ref().is_some_and(|result| {
        now.signed_duration_since(result.computed_at) > chrono::Duration::hours(STALE_AFTER_HOURS)
    });
    let stale = summary.is_some() && (aged || last_attempt_failed || attempt_incomplete);
    let status = if summary.is_none() {
        "unknown"
    } else if last_attempt_failed {
        "last_attempt_failed"
    } else if attempt_incomplete {
        "attempt_incomplete"
    } else if stale {
        "stale"
    } else {
        "fresh"
    };
    Ok(TripEnergyCacheState {
        status,
        stale,
        last_attempt_failed,
        last_attempt_day: latest_attempt_day,
        last_attempt_status: latest_attempt_outcome,
        summary,
    })
}

async fn perform_day(
    store: &Store,
    vehicle: &NioVehicleClient,
    day: NaiveDate,
    scheduled_at: DateTime<Utc>,
) -> Result<bool, TripEnergyError> {
    store.schedule_trip_energy_day(day, scheduled_at).await?;
    if !store.claim_trip_energy_day(day).await? {
        return Ok(false);
    }
    let cutoff = Utc::now();
    let result = fetch_recent_trips(vehicle, cutoff).await.map(|pages| {
        summarize(
            &pages.trips,
            cutoff,
            Utc::now(),
            pages.pages_fetched,
            pages.incomplete(cutoff),
        )
    });
    let result: Result<TripEnergySummary, TripEnergyError> = match result {
        Ok(summary) => match serde_json::to_string(&summary) {
            Ok(encoded) => store
                .finish_trip_energy_day_success(day, &encoded)
                .await
                .map(|()| summary)
                .map_err(Into::into),
            Err(error) => Err(error.into()),
        },
        Err(error) => Err(error.into()),
    };
    match result {
        Ok(summary) => {
            info!(%day, status = %summary.coverage_status, actual_km = summary.actual_distance_km,
                covered_km = summary.covered_distance_km, "daily trip energy cache updated");
            Ok(true)
        }
        Err(error) => {
            if let Err(store_error) = store.finish_trip_energy_day_failure(day).await {
                warn!(%day, %store_error, "failed to mark daily trip energy calculation failed");
            }
            Err(error.into())
        }
    }
}

pub async fn run_forever(store: Store, vehicle: NioVehicleClient, schedule: DailySchedule) {
    loop {
        let now = Utc::now();
        let (day, due_at) = schedule.due_day(now);
        if now < due_at {
            tokio::time::sleep((due_at - now).to_std().unwrap_or(Duration::ZERO)).await;
        }
        // A late start only attempts the current day, never a backlog of days.
        if crate::daily_checkin::china_day(Utc::now()) == day {
            match perform_day(&store, &vehicle, day, due_at).await {
                Ok(true) => {}
                Ok(false) => info!(%day, "daily trip energy already attempted by another instance"),
                Err(error) => {
                    warn!(%day, %error, "daily trip energy failed; old cache is retained")
                }
            }
        }
        let tomorrow = crate::daily_checkin::china_day(Utc::now())
            .succ_opt()
            .expect("valid next China date");
        let next = schedule.at(tomorrow);
        tokio::time::sleep((next - Utc::now()).to_std().unwrap_or(Duration::ZERO)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::VehicleTripLocation;

    fn at() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 30, 8, 0, 0).unwrap()
    }
    fn trip(id: &str, distance: f64, energy: Option<f64>, minutes_ago: i64) -> VehicleTrip {
        let ended_at = at() - chrono::Duration::minutes(minutes_ago);
        let location = || VehicleTripLocation {
            address: None,
            poi: None,
            road_name: None,
            town: None,
            district: None,
            city: None,
            province: None,
            latitude: None,
            longitude: None,
        };
        VehicleTrip {
            id: id.into(),
            trip_id: None,
            started_at: ended_at - chrono::Duration::minutes(20),
            ended_at,
            distance_kilometers: distance,
            duration_minutes: 20,
            start_location: location(),
            end_location: location(),
            average_speed_kph: None,
            average_energy_consumption_kwh_per_100km: None,
            energy_consumed_kwh: energy,
            maximum_speed_kph: None,
            odometer_kilometers: None,
            rapid_acceleration_count: None,
            rapid_deceleration_count: None,
            rapid_swerve_count: None,
            is_combined: false,
        }
    }

    #[test]
    fn beijing_daily_schedule_is_stable_and_configurable() {
        let schedule = DailySchedule::parse("03:00").unwrap();
        assert_eq!(
            schedule
                .at(NaiveDate::from_ymd_opt(2026, 10, 30).unwrap())
                .to_rfc3339(),
            "2026-10-29T19:00:00+00:00"
        );
        assert!(DailySchedule::parse("24:00").is_err());
        assert!(DailySchedule::parse("3:00").is_err());
    }

    #[test]
    fn short_trips_and_long_boundary_trip_cover_exactly_100_km() {
        let short = summarize(
            &[
                trip("older", 60.0, Some(12.0), 60),
                trip("newer", 40.0, Some(4.0), 0),
            ],
            at(),
            at(),
            1,
            false,
        );
        assert_eq!(short.actual_distance_km, 100.0);
        assert_eq!(short.included_energy_kwh, 16.0);
        assert_eq!(short.consumption_kwh_per_100km, Some(16.0));
        assert_eq!(short.coverage_status, "complete");
        let boundary = summarize(&[trip("long", 200.0, Some(30.0), 0)], at(), at(), 1, false);
        assert_eq!(boundary.included_energy_kwh, 15.0);
        assert_eq!(boundary.boundary_method, "proportional_from_trip_average");
        assert_eq!(boundary.boundary_trip_used_distance_km, Some(100.0));
    }

    #[test]
    fn insufficient_and_missing_energy_are_not_filled_with_older_trips() {
        let trips = [
            trip("new", 40.0, None, 0),
            trip("middle", 60.0, Some(12.0), 60),
            trip("old", 20.0, Some(10.0), 120),
        ];
        let result = summarize(&trips, at(), at(), 1, false);
        assert_eq!(result.actual_distance_km, 100.0);
        assert_eq!(result.covered_distance_km, 60.0);
        assert_eq!(result.missing_energy_distance_km, 40.0);
        assert_eq!(result.included_trip_count, 2);
        assert_eq!(result.coverage_status, "incomplete_data");
        let insufficient = summarize(&trips[..1], at(), at(), 1, false);
        assert_eq!(insufficient.coverage_status, "insufficient_distance");
        assert_eq!(insufficient.consumption_kwh_per_100km, None);
        let limited = summarize(&trips[..1], at(), at(), 1, true);
        assert_eq!(limited.coverage_status, "query_limit_reached");
    }

    #[test]
    fn pages_accumulate_without_duplicate_boundary_trip() {
        let mut pages = TripPages::default();
        pages.add(VehicleTripPage {
            items: vec![trip("a", 30.0, Some(3.0), 0)],
            has_more: true,
            next_query_time: Some(10),
            server_time: None,
        });
        assert!(pages.needs_more(at()));
        pages.add(VehicleTripPage {
            items: vec![
                trip("a", 30.0, Some(3.0), 0),
                trip("b", 80.0, Some(16.0), 60),
            ],
            has_more: false,
            next_query_time: Some(9),
            server_time: None,
        });
        assert_eq!(pages.trips.len(), 2);
        let summary = summarize(
            &pages.trips,
            at(),
            at(),
            pages.pages_fetched,
            pages.incomplete(at()),
        );
        assert_eq!(summary.actual_distance_km, 100.0);
        assert_eq!(summary.included_energy_kwh, 17.0);
        assert_eq!(summary.boundary_method, "proportional_from_trip_average");
        assert_eq!(summary.pages_fetched, 2);

        let mut capped = TripPages::default();
        capped.trips.push(trip("short", 1.0, Some(0.2), 0));
        capped.has_more = true;
        capped.pages_fetched = MAX_PAGES;
        assert!(!capped.needs_more(at()));
        assert!(capped.incomplete(at()));
    }

    #[tokio::test]
    async fn daily_claim_is_unique_and_failed_refresh_preserves_cached_result() {
        let store = match Store::in_memory().await {
            Ok(store) => store,
            Err(_) if std::env::var_os("NIO_TEST_POSTGRES_URL").is_none() => return,
            Err(error) => panic!("PostgreSQL test setup failed: {error}"),
        };
        let before = load_cache(&store, at()).await.unwrap();
        assert_eq!(before.status, "unknown");
        assert!(before.summary.is_none());

        let schedule = DailySchedule::parse("03:00").unwrap();
        let day = NaiveDate::from_ymd_opt(2026, 10, 30).unwrap();
        store
            .schedule_trip_energy_day(day, schedule.at(day))
            .await
            .unwrap();
        let (first, second) = tokio::join!(
            store.claim_trip_energy_day(day),
            store.claim_trip_energy_day(day)
        );
        assert_ne!(first.unwrap(), second.unwrap());
        let summary = summarize(&[trip("one", 100.0, Some(20.0), 0)], at(), at(), 1, false);
        store
            .finish_trip_energy_day_success(day, &serde_json::to_string(&summary).unwrap())
            .await
            .unwrap();
        let success = load_cache(&store, at()).await.unwrap();
        assert_eq!(success.status, "fresh");
        assert_eq!(
            success.summary.as_ref().unwrap().consumption_kwh_per_100km,
            Some(20.0)
        );
        let aged = load_cache(&store, at() + chrono::Duration::hours(37))
            .await
            .unwrap();
        assert_eq!(aged.status, "stale");
        assert!(aged.stale);
        assert!(!store.claim_trip_energy_day(day).await.unwrap());

        let next_day = day.succ_opt().unwrap();
        store
            .schedule_trip_energy_day(next_day, schedule.at(next_day))
            .await
            .unwrap();
        assert!(store.claim_trip_energy_day(next_day).await.unwrap());
        store
            .finish_trip_energy_day_failure(next_day)
            .await
            .unwrap();
        let after_failure = load_cache(&store, at() + chrono::Duration::days(1))
            .await
            .unwrap();
        assert_eq!(after_failure.status, "last_attempt_failed");
        assert!(after_failure.stale);
        assert!(after_failure.last_attempt_failed);
        assert_eq!(
            after_failure.summary.unwrap().consumption_kwh_per_100km,
            Some(20.0)
        );

        let rows_before = store.trip_energy_cache_rows().await.unwrap();
        let _ = load_cache(&store, at() + chrono::Duration::days(1))
            .await
            .unwrap();
        let rows_after = store.trip_energy_cache_rows().await.unwrap();
        assert_eq!(
            rows_before.latest_success_json,
            rows_after.latest_success_json
        );
        assert_eq!(
            rows_before.latest_attempt_outcome,
            rows_after.latest_attempt_outcome
        );
    }
}
