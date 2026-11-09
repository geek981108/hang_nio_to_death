//! Transparent straight-line calculation using the persisted daily 100 km cache.

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::trip_energy::TripEnergyCacheState;

const EARTH_RADIUS_KM: f64 = 6371.0088;

#[derive(Clone, Copy, Debug)]
pub struct StationCoordinateBasis {
    pub latitude: f64,
    pub longitude: f64,
    pub record_updated_at: Option<DateTime<Utc>>,
    pub source: &'static str,
}

#[derive(Debug, Serialize)]
pub struct StraightLineEnergyEstimate {
    pub station_id: String,
    pub station_coordinates_source: &'static str,
    pub station_record_updated_at: Option<DateTime<Utc>>,
    pub straight_line_distance_km: f64,
    pub energy_cache: TripEnergyCacheState,
    pub estimated_energy_for_straight_line_kwh: Option<f64>,
    pub distance_kind: &'static str,
    pub road_distance_km: Option<f64>,
    pub road_travel_time_minutes: Option<f64>,
    pub traffic_and_tolls_included: bool,
}

pub fn valid_coordinate(latitude: f64, longitude: f64) -> bool {
    latitude.is_finite()
        && longitude.is_finite()
        && (-90.0..=90.0).contains(&latitude)
        && (-180.0..=180.0).contains(&longitude)
}

pub fn straight_line_km(from_lat: f64, from_lon: f64, to_lat: f64, to_lon: f64) -> f64 {
    let lat_delta = (to_lat - from_lat).to_radians();
    let lon_delta = (to_lon - from_lon).to_radians();
    let from_lat = from_lat.to_radians();
    let to_lat = to_lat.to_radians();
    let a = (lat_delta / 2.0).sin().powi(2)
        + from_lat.cos() * to_lat.cos() * (lon_delta / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_KM * a.sqrt().atan2((1.0 - a).max(0.0).sqrt())
}

fn round(value: f64, decimals: i32) -> f64 {
    let factor = 10f64.powi(decimals);
    (value * factor).round() / factor
}

pub fn calculate(
    station_id: String,
    station: StationCoordinateBasis,
    from: (f64, f64),
    energy_cache: TripEnergyCacheState,
) -> StraightLineEnergyEstimate {
    let distance = round(
        straight_line_km(from.0, from.1, station.latitude, station.longitude),
        1,
    );
    let estimate = energy_cache
        .summary
        .as_ref()
        .and_then(|summary| summary.consumption_kwh_per_100km)
        .map(|rate| round(distance * rate / 100.0, 2));
    StraightLineEnergyEstimate {
        station_id,
        station_coordinates_source: station.source,
        station_record_updated_at: station.record_updated_at,
        straight_line_distance_km: distance,
        energy_cache,
        estimated_energy_for_straight_line_kwh: estimate,
        distance_kind: "geodesic_straight_line",
        road_distance_km: None,
        road_travel_time_minutes: None,
        traffic_and_tolls_included: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trip_energy::{TripEnergyCacheState, TripEnergySummary};
    use chrono::TimeZone;

    #[test]
    fn cached_rate_calculates_distance_without_echoing_vehicle_coordinates() {
        let now = Utc.with_ymd_and_hms(2026, 10, 30, 8, 0, 0).unwrap();
        let summary = TripEnergySummary {
            target_distance_km: 100.0,
            actual_distance_km: 100.0,
            covered_distance_km: 100.0,
            missing_energy_distance_km: 0.0,
            included_energy_kwh: 12.5,
            consumption_kwh_per_100km: Some(12.5),
            window_start: Some(now),
            window_end: Some(now),
            sample_cutoff_at: now,
            computed_at: now,
            included_trip_count: 2,
            energy_known_trip_count: 2,
            missing_energy_trip_count: 0,
            skipped_invalid_trip_count: 0,
            inspected_trip_count: 2,
            pages_fetched: 1,
            coverage_complete: true,
            coverage_status: "complete".to_owned(),
            boundary_method: "whole_trips".to_owned(),
            boundary_trip_used_distance_km: None,
            boundary_trip_full_distance_km: None,
            history_fetch_incomplete: false,
        };
        let cache = TripEnergyCacheState {
            status: "fresh",
            stale: false,
            last_attempt_failed: false,
            last_attempt_day: None,
            last_attempt_status: None,
            summary: Some(summary),
        };
        let station = StationCoordinateBasis {
            latitude: 31.1,
            longitude: 121.0,
            record_updated_at: None,
            source: "caller_supplied",
        };
        let result = calculate("PS-NIO-test".into(), station, (31.0, 121.0), cache);
        assert_eq!(result.straight_line_distance_km, 11.1);
        assert_eq!(result.estimated_energy_for_straight_line_kwh, Some(1.39));
        assert!(
            !serde_json::to_string(&result)
                .unwrap()
                .contains("\"latitude\"")
        );
    }
}
