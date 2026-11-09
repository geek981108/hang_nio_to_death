use std::collections::HashMap;

use serde_json::json;

use crate::models::BatteryObservation;

#[derive(Clone, Debug)]
pub struct DetectedSwap {
    pub outgoing: BatteryObservation,
    pub incoming: BatteryObservation,
    pub estimated_energy_kwh: Option<f64>,
    pub evidence: serde_json::Value,
}

#[derive(Clone, Debug)]
pub struct DetectedOrderSwap {
    pub outgoing: Option<BatteryObservation>,
    pub incoming: BatteryObservation,
    pub estimated_energy_kwh: Option<f64>,
    pub evidence: serde_json::Value,
}

#[derive(Clone, Debug)]
pub struct InventoryDelta {
    pub added_to_station: Vec<BatteryObservation>,
    pub removed_from_station: Vec<BatteryObservation>,
}

/// Detects only the unambiguous one-added/one-removed inventory case.
/// A battery added to the station is treated as outgoing from the car; a battery
/// removed from the station is treated as incoming to the car.
pub fn detect_swap(
    previous: &[BatteryObservation],
    current: &[BatteryObservation],
) -> Option<DetectedSwap> {
    let delta = inventory_delta(previous, current);
    if delta.removed_from_station.len() != 1 || delta.added_to_station.len() != 1 {
        return None;
    }
    let incoming = delta.removed_from_station.into_iter().next()?;
    let outgoing = delta.added_to_station.into_iter().next()?;
    Some(detected_swap(outgoing, incoming))
}

pub fn inventory_delta(
    previous: &[BatteryObservation],
    current: &[BatteryObservation],
) -> InventoryDelta {
    let previous_by_id = previous
        .iter()
        .map(|battery| (battery.battery_id.as_str(), battery))
        .collect::<HashMap<_, _>>();
    let current_by_id = current
        .iter()
        .map(|battery| (battery.battery_id.as_str(), battery))
        .collect::<HashMap<_, _>>();

    let removed_from_station = previous_by_id
        .iter()
        .filter(|(id, _)| !current_by_id.contains_key(**id))
        .map(|(_, battery)| (*battery).clone())
        .collect::<Vec<_>>();
    let added_to_station = current_by_id
        .iter()
        .filter(|(id, _)| !previous_by_id.contains_key(**id))
        .map(|(_, battery)| (*battery).clone())
        .collect::<Vec<_>>();

    InventoryDelta {
        added_to_station,
        removed_from_station,
    }
}

pub fn closest_battery_by_soc(
    batteries: &[BatteryObservation],
    target_soc: f64,
    max_delta: f64,
    minimum_margin: f64,
) -> Option<BatteryObservation> {
    if !target_soc.is_finite() || !max_delta.is_finite() || !minimum_margin.is_finite() {
        return None;
    }
    let mut scored = batteries
        .iter()
        .filter_map(|battery| {
            let soc = battery.soc_percent?;
            let delta = (soc - target_soc).abs();
            (soc.is_finite() && delta <= max_delta).then_some((delta, battery))
        })
        .collect::<Vec<_>>();
    scored.sort_by(|left, right| left.0.total_cmp(&right.0));
    let (best_delta, best) = scored.first()?;
    if let Some((second_delta, _)) = scored.get(1)
        && second_delta - best_delta < minimum_margin
    {
        return None;
    }
    Some((*best).clone())
}

pub fn detected_swap(outgoing: BatteryObservation, incoming: BatteryObservation) -> DetectedSwap {
    let estimated_energy_kwh = estimated_energy(&incoming, &outgoing);

    DetectedSwap {
        evidence: json!({
            "method": "station_inventory_delta",
            "meaning": {
                "removed_from_station": "incoming_to_vehicle",
                "added_to_station": "outgoing_from_vehicle"
            },
            "removed_battery_id": incoming.battery_id,
            "added_battery_id": outgoing.battery_id,
            "warning": "This is a station-level observation and is not attributed to a user until matched with an order."
        }),
        outgoing,
        incoming,
        estimated_energy_kwh,
    }
}

pub fn detected_order_swap(
    outgoing: Option<BatteryObservation>,
    incoming: BatteryObservation,
) -> DetectedOrderSwap {
    let estimated_energy_kwh = outgoing
        .as_ref()
        .and_then(|outgoing| estimated_energy(&incoming, outgoing));
    let outgoing_id = outgoing.as_ref().map(|battery| battery.battery_id.clone());
    DetectedOrderSwap {
        evidence: json!({
            "method": "order_baseline_inventory_delta",
            "meaning": {
                "removed_from_station": "incoming_to_vehicle",
                "added_to_station": "outgoing_from_vehicle"
            },
            "removed_battery_id": incoming.battery_id,
            "added_battery_id": outgoing_id,
            "completion": if outgoing.is_some() { "complete_pair" } else { "awaiting_outgoing_battery" },
            "warning": "The incoming battery is observed independently; the outgoing battery may appear in the station inventory later."
        }),
        outgoing,
        incoming,
        estimated_energy_kwh,
    }
}

fn estimated_energy(incoming: &BatteryObservation, outgoing: &BatteryObservation) -> Option<f64> {
    match (
        incoming.capacity_kwh,
        incoming.soc_percent,
        outgoing.capacity_kwh,
        outgoing.soc_percent,
    ) {
        (
            Some(incoming_capacity),
            Some(incoming_soc),
            Some(outgoing_capacity),
            Some(outgoing_soc),
        ) => Some((incoming_capacity * incoming_soc - outgoing_capacity * outgoing_soc) / 100.0),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn battery(id: &str, capacity: f64, soc: f64) -> BatteryObservation {
        BatteryObservation {
            battery_id: id.to_owned(),
            slot_id: None,
            battery_type: None,
            capacity_kwh: Some(capacity),
            soc_percent: Some(soc),
            occupied: false,
            production_date: None,
        }
    }

    #[test]
    fn maps_station_delta_to_vehicle_direction() {
        let previous = vec![
            battery("kept", 75.0, 80.0),
            battery("incoming", 100.0, 93.0),
        ];
        let current = vec![battery("kept", 75.0, 81.0), battery("outgoing", 75.0, 20.0)];
        let detected = detect_swap(&previous, &current).unwrap();
        assert_eq!(detected.incoming.battery_id, "incoming");
        assert_eq!(detected.outgoing.battery_id, "outgoing");
        assert_eq!(detected.estimated_energy_kwh, Some(78.0));
    }

    #[test]
    fn refuses_ambiguous_multi_battery_changes() {
        let previous = vec![battery("a", 75.0, 90.0), battery("b", 75.0, 90.0)];
        let current = vec![battery("c", 75.0, 20.0), battery("d", 75.0, 20.0)];
        assert!(detect_swap(&previous, &current).is_none());
    }

    #[test]
    fn selects_only_a_close_and_distinct_soc_match() {
        let candidates = vec![battery("close", 75.0, 43.0), battery("far", 75.0, 74.0)];
        assert_eq!(
            closest_battery_by_soc(&candidates, 42.0, 8.0, 3.0)
                .unwrap()
                .battery_id,
            "close"
        );
        let ambiguous = vec![battery("a", 75.0, 41.0), battery("b", 75.0, 43.0)];
        assert!(closest_battery_by_soc(&ambiguous, 42.0, 8.0, 3.0).is_none());
        assert!(closest_battery_by_soc(&candidates, 20.0, 8.0, 3.0).is_none());
    }
}
