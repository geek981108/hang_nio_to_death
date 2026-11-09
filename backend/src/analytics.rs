//! Historical energy and swap-cost aggregates. Missing measurements stay visible.
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::HashMap;

use crate::models::{SwapEvent, VehicleChargingSample};

#[derive(Debug, Serialize)]
pub struct EnergyStats {
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    pub swap_count: usize,
    pub swap_electricity_fee_cny_known: f64,
    pub swap_service_fee_cny_known: f64,
    pub swap_total_fee_cny_known: f64,
    pub coupon_discount_cny_known: f64,
    pub actual_paid_cny_known: f64,
    pub fee_breakdown_covered_count: usize,
    pub paid_amount_covered_count: usize,
    pub swap_energy_kwh_known: f64,
    pub swap_energy_covered_count: usize,
    pub charging_energy_kwh_estimated: Option<f64>,
    pub charging_energy_kwh_from_power: f64,
    pub charging_energy_kwh_from_soc: f64,
    pub charging_segments_from_power: usize,
    pub charging_segments_from_soc: usize,
    pub charging_segments_uncovered: usize,
    pub charging_sample_count: usize,
    pub total_energy_kwh_known: f64,
    pub swap_energy_share_percent_of_known: Option<f64>,
    pub charging_energy_share_percent_of_known: Option<f64>,
    pub energy_coverage_complete: bool,
    pub current_month_swap_count: i64,
    pub current_month_timezone: &'static str,
}

#[derive(Debug, Clone)]
pub struct SwapBatteryCapacity {
    pub occurred_at: DateTime<Utc>,
    pub capacity_kwh: Option<f64>,
}

#[derive(Default)]
pub struct ChargingEstimate {
    power_kwh: f64,
    soc_kwh: f64,
    power_segments: usize,
    soc_segments: usize,
    uncovered_segments: usize,
    sample_count: usize,
}

impl ChargingEstimate {
    fn known_kwh(&self) -> Option<f64> {
        (self.power_segments + self.soc_segments > 0).then_some(self.power_kwh + self.soc_kwh)
    }
}

pub struct ChargingAccumulator {
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    capacities: Vec<SwapBatteryCapacity>,
    last_by_vehicle: HashMap<String, VehicleChargingSample>,
    estimate: ChargingEstimate,
}

impl ChargingAccumulator {
    pub fn new(
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        capacities: Vec<SwapBatteryCapacity>,
    ) -> Self {
        Self {
            from,
            to,
            capacities,
            last_by_vehicle: HashMap::new(),
            estimate: ChargingEstimate::default(),
        }
    }

    pub fn observe(&mut self, sample: VehicleChargingSample) {
        self.estimate.sample_count += 1;
        if let Some(previous) = self.last_by_vehicle.get(&sample.vehicle_id) {
            accumulate_pair(
                &mut self.estimate,
                previous,
                &sample,
                &self.capacities,
                self.from,
                self.to,
            );
        }
        self.last_by_vehicle
            .insert(sample.vehicle_id.clone(), sample);
    }

    pub fn finish(self) -> ChargingEstimate {
        self.estimate
    }
}

/// Integrate measured charging power with the trapezoidal rule. Samples may be
/// in either order. Gaps over 15 minutes and non-charging samples are excluded.
pub fn integrated_charging_power_kwh(samples: &[VehicleChargingSample]) -> Option<f64> {
    let mut ordered = samples.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|sample| sample.sampled_at);
    let mut energy_kwh = 0.0;
    let mut segments = 0usize;
    for pair in ordered.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if a.vehicle_id != b.vehicle_id || a.charge_state != 1 || b.charge_state != 1 {
            continue;
        }
        let seconds = (b.sampled_at - a.sampled_at).num_milliseconds() as f64 / 1_000.0;
        if !(0.0..=900.0).contains(&seconds) || seconds == 0.0 {
            continue;
        }
        let (Some(pa), Some(pb)) = (a.charging_power, b.charging_power) else {
            continue;
        };
        if !pa.is_finite() || !pb.is_finite() || pa < 0.0 || pb < 0.0 {
            continue;
        }
        energy_kwh += (pa + pb) / 2.0 * seconds / 3_600_000.0;
        segments += 1;
    }
    (segments > 0).then_some(rounded(energy_kwh))
}

fn rounded(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

/// Integrate positive sampled power in watts over intervals no longer than 15 minutes.
/// Segment endpoints are linearly interpolated when a query boundary falls between samples.
#[cfg(test)]
fn estimated_charging_kwh(
    samples: &[VehicleChargingSample],
    capacities: &[SwapBatteryCapacity],
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> ChargingEstimate {
    let mut accumulator = ChargingAccumulator::new(from, to, capacities.to_vec());
    for sample in samples {
        accumulator.observe(sample.clone());
    }
    accumulator.finish()
}

fn accumulate_pair(
    result: &mut ChargingEstimate,
    a: &VehicleChargingSample,
    b: &VehicleChargingSample,
    capacities: &[SwapBatteryCapacity],
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) {
    if a.charge_state != 1 || b.charge_state != 1 {
        return;
    }
    let dt = (b.sampled_at - a.sampled_at).num_milliseconds() as f64 / 1000.0;
    if dt <= 0.0 {
        return;
    }
    let start = a.sampled_at.max(from);
    let end = b.sampled_at.min(to);
    if end <= start {
        return;
    }
    if dt > 900.0 {
        result.uncovered_segments += 1;
        return;
    }
    let t0 = (start - a.sampled_at).num_milliseconds() as f64 / 1000.0 / dt;
    let t1 = (end - a.sampled_at).num_milliseconds() as f64 / 1000.0 / dt;
    if let (Some(pa), Some(pb)) = (a.charging_power, b.charging_power)
        && pa.is_finite()
        && pb.is_finite()
        && pa >= 0.0
        && pb >= 0.0
    {
        let p0 = pa + (pb - pa) * t0;
        let p1 = pa + (pb - pa) * t1;
        result.power_kwh +=
            (p0 + p1) / 2.0 * (end - start).num_milliseconds() as f64 / 3_600_000_000.0;
        result.power_segments += 1;
        return;
    }
    let capacity_index = capacities.partition_point(|event| event.occurred_at <= a.sampled_at);
    let capacity = capacity_index
        .checked_sub(1)
        .and_then(|index| capacities.get(index))
        .filter(|_| {
            capacities
                .get(capacity_index)
                .is_none_or(|event| event.occurred_at > b.sampled_at)
        })
        .and_then(|event| event.capacity_kwh)
        .filter(|value| value.is_finite() && (50.0..=120.0).contains(value));
    if let (Some(capacity), Some(soc_a), Some(soc_b)) = (capacity, a.soc, b.soc)
        && soc_a.is_finite()
        && soc_b.is_finite()
        && (0.0..=100.0).contains(&soc_a)
        && (0.0..=100.0).contains(&soc_b)
        && soc_b >= soc_a
    {
        result.soc_kwh += capacity * (soc_b - soc_a) * (t1 - t0) / 100.0;
        result.soc_segments += 1;
    } else {
        result.uncovered_segments += 1;
    }
}

pub fn calculate(
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    swaps: &[SwapEvent],
    charging: &ChargingEstimate,
    current_month_swap_count: i64,
) -> EnergyStats {
    let mut electricity = 0.0;
    let mut service = 0.0;
    let mut coupon = 0.0;
    let mut paid = 0.0;
    let mut swap_kwh = 0.0;
    let mut fee_covered = 0;
    let mut paid_covered = 0;
    let mut energy_covered = 0;
    for swap in swaps {
        if let Some(amount) = swap.price_amount.filter(|v| v.is_finite()) {
            paid += amount;
            paid_covered += 1;
        }
        if !swap.payment_items.is_empty() {
            fee_covered += 1;
            for item in &swap.payment_items {
                if !item.amount.is_finite() {
                    continue;
                }
                if item.amount < 0.0 && (item.name.contains("优惠") || item.name.contains("券"))
                {
                    coupon += -item.amount;
                } else if item.name.contains("服务费") {
                    service += item.amount;
                } else if item.name.contains("电费") {
                    electricity += item.amount;
                }
            }
        }
        if let Some(kwh) = swap.exact_energy_kwh.filter(|v| v.is_finite() && *v >= 0.0) {
            swap_kwh += kwh;
            energy_covered += 1;
        }
    }
    let charging_known = charging.known_kwh();
    let total = swap_kwh + charging_known.unwrap_or(0.0);
    let energy_coverage_complete = charging_known.is_some()
        && charging.uncovered_segments == 0
        && energy_covered == swaps.len();
    let share = (total > 0.0).then_some(swap_kwh / total * 100.0);
    EnergyStats {
        from,
        to,
        swap_count: swaps.len(),
        swap_electricity_fee_cny_known: rounded(electricity),
        swap_service_fee_cny_known: rounded(service),
        swap_total_fee_cny_known: rounded(electricity + service),
        coupon_discount_cny_known: rounded(coupon),
        actual_paid_cny_known: rounded(paid),
        fee_breakdown_covered_count: fee_covered,
        paid_amount_covered_count: paid_covered,
        swap_energy_kwh_known: rounded(swap_kwh),
        swap_energy_covered_count: energy_covered,
        charging_energy_kwh_estimated: charging_known.map(rounded),
        charging_energy_kwh_from_power: rounded(charging.power_kwh),
        charging_energy_kwh_from_soc: rounded(charging.soc_kwh),
        charging_segments_from_power: charging.power_segments,
        charging_segments_from_soc: charging.soc_segments,
        charging_segments_uncovered: charging.uncovered_segments,
        charging_sample_count: charging.sample_count,
        total_energy_kwh_known: rounded(total),
        swap_energy_share_percent_of_known: share.map(rounded),
        charging_energy_share_percent_of_known: share.map(|value| rounded(100.0 - value)),
        energy_coverage_complete,
        current_month_swap_count,
        current_month_timezone: "Asia/Shanghai",
    }
}

pub fn charging_sample_window(
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> (DateTime<Utc>, DateTime<Utc>) {
    (from - Duration::minutes(15), to + Duration::minutes(15))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn sample(minute: u32, power: f64) -> VehicleChargingSample {
        VehicleChargingSample {
            vehicle_id: "v1".into(),
            sampled_at: Utc.with_ymd_and_hms(2026, 10, 1, 0, minute, 0).unwrap(),
            soc: None,
            charge_state: 1,
            charging_current: None,
            charging_power: Some(power),
            charging_voltage: None,
        }
    }

    #[test]
    fn known_energy_share_remains_available_with_explicit_incomplete_coverage() {
        let from = Utc.with_ymd_and_hms(2026, 10, 1, 0, 0, 0).unwrap();
        let to = from + Duration::hours(1);
        let charging = ChargingEstimate {
            power_kwh: 10.0,
            power_segments: 1,
            uncovered_segments: 1,
            ..Default::default()
        };
        let result = calculate(from, to, &[], &charging, 0);
        assert_eq!(result.charging_energy_share_percent_of_known, Some(100.0));
        assert_eq!(result.swap_energy_share_percent_of_known, Some(0.0));
        assert!(!result.energy_coverage_complete);
    }

    #[test]
    fn charging_integral_clips_window_and_skips_long_gaps() {
        let from = Utc.with_ymd_and_hms(2026, 10, 1, 0, 5, 0).unwrap();
        let to = Utc.with_ymd_and_hms(2026, 10, 1, 0, 15, 0).unwrap();
        let samples = [
            sample(0, 60_000.0),
            sample(10, 60_000.0),
            sample(20, 60_000.0),
        ];
        assert!(
            (estimated_charging_kwh(&samples, &[], from, to)
                .known_kwh()
                .unwrap()
                - 10.0)
                .abs()
                < 1e-8
        );
        assert_eq!(
            estimated_charging_kwh(&[sample(0, 60_000.0), sample(20, 60_000.0)], &[], from, to)
                .known_kwh(),
            None
        );
        assert_eq!(
            estimated_charging_kwh(&[sample(0, 60_000.0), sample(20, 60_000.0)], &[], from, to)
                .uncovered_segments,
            1
        );
    }

    #[test]
    fn session_power_integral_uses_trapezoids_and_rejects_long_gaps() {
        let mut samples = vec![sample(10, 30_000.0), sample(0, 60_000.0)];
        assert_eq!(integrated_charging_power_kwh(&samples), Some(7.5));
        samples.push(sample(30, 30_000.0));
        assert_eq!(integrated_charging_power_kwh(&samples), Some(7.5));
    }

    #[test]
    fn missing_power_uses_last_swapped_battery_capacity_and_clips_soc_delta() {
        let from = Utc.with_ymd_and_hms(2026, 10, 1, 0, 5, 0).unwrap();
        let to = Utc.with_ymd_and_hms(2026, 10, 1, 0, 15, 0).unwrap();
        let samples = [
            VehicleChargingSample {
                charging_power: None,
                soc: Some(40.0),
                ..sample(0, 0.0)
            },
            VehicleChargingSample {
                charging_power: None,
                soc: Some(50.0),
                ..sample(10, 0.0)
            },
            VehicleChargingSample {
                charging_power: None,
                soc: Some(60.0),
                ..sample(20, 0.0)
            },
        ];
        let capacities = [SwapBatteryCapacity {
            occurred_at: from - Duration::hours(1),
            capacity_kwh: Some(75.0),
        }];
        let result = estimated_charging_kwh(&samples, &capacities, from, to);
        assert!((result.known_kwh().unwrap() - 7.5).abs() < 1e-8);
        assert_eq!(result.soc_segments, 2);
        assert_eq!(result.power_segments, 0);
        assert_eq!(result.uncovered_segments, 0);
    }

    #[test]
    fn power_wins_and_unknown_battery_does_not_invent_energy() {
        let from = Utc.with_ymd_and_hms(2026, 10, 1, 0, 0, 0).unwrap();
        let to = from + Duration::minutes(10);
        let samples = [sample(0, 60_000.0), sample(10, 60_000.0)];
        let result = estimated_charging_kwh(&samples, &[], from, to);
        assert_eq!(result.known_kwh(), Some(10.0));
        assert_eq!(result.power_segments, 1);

        let unknown = [
            VehicleChargingSample {
                charging_power: None,
                soc: Some(40.0),
                ..samples[0].clone()
            },
            VehicleChargingSample {
                charging_power: None,
                soc: Some(50.0),
                ..samples[1].clone()
            },
        ];
        let result = estimated_charging_kwh(&unknown, &[], from, to);
        assert_eq!(result.known_kwh(), None);
        assert_eq!(result.uncovered_segments, 1);
    }
}
