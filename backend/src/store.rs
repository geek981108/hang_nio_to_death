use std::time::Duration;

use crate::{diesel_query as db, pg_store::PgPool};
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use diesel_async::{AsyncConnection, AsyncPgConnection};
use serde::Deserialize;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    analytics::{ChargingAccumulator, ChargingEstimate, SwapBatteryCapacity},
    detector::{DetectedOrderSwap, DetectedSwap},
    models::{
        ActiveServiceOrder, BatteryObservation, CachedVehicleImage, ImportedOrder,
        ObservedServiceOrder, ObservedServiceOrderQueue, ObservedSwapStation, PollRunSummary,
        StationSnapshot, StoredVehicleProfile, SwapEvent, SwapPaymentItem, SwapStation,
        VehicleChargingSample, VehicleChargingSession, VehicleProfile, VehicleSnapshot,
        VehicleTrip, VehicleTripPage, VehicleTripTrack, VehicleTripTrackPoint,
    },
};

#[derive(Clone)]
pub struct Store {
    pub(crate) pool: PgPool,
}

/// Multi-row insert width for track points. Nine bound parameters per point
/// keeps one statement well under PostgreSQL's parameter limit.
const TRACK_INSERT_CHUNK: usize = 200;
/// Row count per statement for the bulk backfill insert: 9 parameters each, so
/// 6_000 rows stay under PostgreSQL's 65_535 parameter limit with headroom.
const TRACK_ROWS_PER_INSERT: usize = 6_000;

#[derive(Debug)]
pub struct DailyCheckInRun {
    pub scheduled_at: DateTime<Utc>,
    pub attempted_at: Option<DateTime<Utc>>,
    pub attempts: i32,
    pub result: String,
}

#[derive(Debug)]
pub struct TripEnergyCacheRows {
    pub latest_success_json: Option<String>,
    pub latest_attempt_day: Option<NaiveDate>,
    pub latest_attempt_outcome: Option<String>,
}

#[derive(Debug, Default)]
pub struct VehicleTripSyncState {
    pub backfill_cursor: Option<i64>,
    pub backfill_completed: bool,
    pub forward_cursor: Option<i64>,
    pub covered_before: Option<DateTime<Utc>>,
    pub forward_started_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
struct ChargingSessionEnergyRow {
    energy_kwh: f64,
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Database(#[from] db::Error),
    #[error("database connection or migration error: {0}")]
    Connect(String),
    #[error("stored data is invalid: {0}")]
    InvalidStoredData(String),
}

#[derive(Debug)]
pub struct StoredSnapshot {
    pub id: String,
    pub station_key: String,
    pub captured_at: DateTime<Utc>,
    pub batteries: Vec<BatteryObservation>,
}

#[derive(Debug)]
pub struct ActiveOrderBaseline {
    pub order_no: String,
    pub snapshot_id: String,
    pub swap_start_soc: Option<f64>,
}

#[derive(Debug)]
pub struct ServiceOrderObservationState {
    pub is_new_or_changed: bool,
    pub needs_baseline: bool,
}

#[derive(Debug, Deserialize)]
struct EventRow {
    id: String,
    status: String,
    occurred_at: DateTime<Utc>,
    station_key: Option<String>,
    station_name: Option<String>,
    station_address: Option<String>,
    order_no: Option<String>,
    order_status_name: Option<String>,
    price_amount: Option<f64>,
    price_currency: Option<String>,
    price_description: Option<String>,
    payment_items_json: Option<String>,
    exact_energy_kwh: Option<f64>,
    estimated_energy_kwh: Option<f64>,
    energy_source: String,
    outgoing_battery_id: Option<String>,
    outgoing_production_date: Option<chrono::NaiveDate>,
    outgoing_capacity_kwh: Option<f64>,
    outgoing_soc_percent: Option<f64>,
    incoming_battery_id: Option<String>,
    incoming_production_date: Option<chrono::NaiveDate>,
    incoming_capacity_kwh: Option<f64>,
    incoming_soc_percent: Option<f64>,
    battery_source: String,
    confidence: String,
    evidence: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct SwapStationRow {
    station_id: String,
    station_name: String,
    station_address: Option<String>,
    latitude: Option<f64>,
    longitude: Option<f64>,
    operator_id: Option<String>,
    operator_name: Option<String>,
    source_order_no: Option<String>,
    first_seen_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct ActiveServiceOrderRow {
    order_no: String,
    order_type: String,
    order_status: Option<String>,
    order_status_name: Option<String>,
    order_created_at: DateTime<Utc>,
    station_key: Option<String>,
    station_name: Option<String>,
    station_address: Option<String>,
    baseline_captured_at: Option<DateTime<Utc>>,
    queue_number: Option<i64>,
    target_battery_cap_level: Option<i64>,
    vehicles_ahead: Option<i64>,
    estimated_wait_minutes: Option<i64>,
    estimated_wait_source: Option<String>,
    queue_status_text: Option<String>,
    queue_updated_at: Option<DateTime<Utc>>,
    first_seen_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct CountsRow {
    snapshots: i64,
    candidates: i64,
    confirmed: i64,
    service_orders: i64,
}

#[derive(Debug, Deserialize)]
struct CapacityRow {
    occurred_at: DateTime<Utc>,
    incoming_capacity_kwh: Option<f64>,
}

impl From<CapacityRow> for SwapBatteryCapacity {
    fn from(row: CapacityRow) -> Self {
        Self {
            occurred_at: row.occurred_at,
            capacity_kwh: row.incoming_capacity_kwh,
        }
    }
}

impl Store {
    pub async fn vehicle_trips(
        &self,
        vehicle_id: &str,
        count: u32,
        query_time: Option<i64>,
    ) -> Result<VehicleTripPage, StoreError> {
        let select = "SELECT journey_id AS id, trip_id, started_at, ended_at, distance_kilometers, \
                      duration_minutes, start_location, end_location, average_speed_kph, \
                      average_energy_consumption_kwh_per_100km, energy_consumed_kwh, maximum_speed_kph, \
                      odometer_kilometers, rapid_acceleration_count, rapid_deceleration_count, \
                      rapid_swerve_count, is_combined FROM vehicle_trips WHERE vehicle_id = ?";
        let sql = if query_time.is_some() {
            format!(
                "{select} AND started_at < to_timestamp(?) ORDER BY started_at DESC, journey_id DESC LIMIT ?"
            )
        } else {
            format!("{select} ORDER BY started_at DESC, journey_id DESC LIMIT ?")
        };
        let limit = count.clamp(1, 100) as usize;
        let mut query = db::query_as::<VehicleTrip>(&sql).bind(vehicle_id);
        if let Some(query_time) = query_time {
            query = query.bind(query_time);
        }
        let mut items = query.bind((limit + 1) as i64).fetch_all(&self.pool).await?;
        let mut has_more = items.len() > limit;
        if has_more
            && items[limit].started_at.timestamp() == items[limit - 1].started_at.timestamp()
        {
            // The public cursor has second precision. Never cut through journeys
            // sharing that second, or the next page would silently skip them.
            let boundary = items[limit - 1].started_at.timestamp();
            let tie_query = db::query_as::<VehicleTrip>(&format!(
                "{select} AND started_at >= to_timestamp(?) AND started_at < to_timestamp(?) ORDER BY started_at DESC, journey_id DESC"
            )).bind(vehicle_id).bind(boundary).bind(boundary + 1);
            let ties = tie_query.fetch_all(&self.pool).await?;
            items.truncate(limit);
            let known = items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<std::collections::HashSet<_>>();
            let extra = ties
                .into_iter()
                .filter(|item| !known.contains(item.id.as_str()))
                .collect::<Vec<_>>();
            items.extend(extra);
            items.sort_by(|a, b| b.started_at.cmp(&a.started_at).then(b.id.cmp(&a.id)));
            has_more = db::query_scalar::<bool>(
                "SELECT EXISTS(SELECT 1 FROM vehicle_trips WHERE vehicle_id = ? AND started_at < to_timestamp(?))"
            ).bind(vehicle_id).bind(boundary).fetch_one(&self.pool).await?;
        } else {
            items.truncate(limit);
        }
        let next_query_time = has_more.then(|| items.last().unwrap().started_at.timestamp());
        Ok(VehicleTripPage {
            items,
            has_more,
            next_query_time,
            server_time: None,
        })
    }

    pub async fn vehicle_trip_sync_state(
        &self,
        vehicle_id: &str,
    ) -> Result<VehicleTripSyncState, StoreError> {
        let row = db::query("SELECT backfill_cursor, backfill_completed, forward_cursor, covered_before, forward_started_at FROM vehicle_trip_sync WHERE vehicle_id = ?")
            .bind(vehicle_id).fetch_optional(&self.pool).await?;
        match row {
            Some(row) => Ok(VehicleTripSyncState {
                backfill_cursor: row.try_get("backfill_cursor")?,
                backfill_completed: row.try_get("backfill_completed")?,
                forward_cursor: row.try_get("forward_cursor")?,
                covered_before: row.try_get("covered_before")?,
                forward_started_at: row.try_get("forward_started_at")?,
            }),
            None => Ok(VehicleTripSyncState::default()),
        }
    }

    pub async fn save_vehicle_trip_sync_state(
        &self,
        vehicle_id: &str,
        state: &VehicleTripSyncState,
    ) -> Result<(), StoreError> {
        db::query("INSERT INTO vehicle_trip_sync (vehicle_id, backfill_cursor, backfill_completed, forward_cursor, covered_before, forward_started_at) \
                   VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (vehicle_id) DO UPDATE SET \
                   backfill_cursor = EXCLUDED.backfill_cursor, backfill_completed = EXCLUDED.backfill_completed, \
                   forward_cursor = EXCLUDED.forward_cursor, covered_before = EXCLUDED.covered_before, \
                   forward_started_at = EXCLUDED.forward_started_at, updated_at = NOW()")
            .bind(vehicle_id).bind(state.backfill_cursor).bind(state.backfill_completed)
            .bind(state.forward_cursor).bind(state.covered_before)
            .bind(state.forward_started_at).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn known_vehicle_trip_ids(
        &self,
        vehicle_id: &str,
        trips: &[VehicleTrip],
    ) -> Result<std::collections::HashSet<String>, StoreError> {
        let Some(oldest) = trips.iter().map(|trip| trip.started_at).min() else {
            return Ok(Default::default());
        };
        let newest = trips.iter().map(|trip| trip.started_at).max().unwrap();
        let rows = db::query("SELECT journey_id FROM vehicle_trips WHERE vehicle_id = ? AND started_at BETWEEN ? AND ?")
            .bind(vehicle_id).bind(oldest).bind(newest).fetch_all(&self.pool).await?;
        let ids = rows
            .into_iter()
            .map(|row| row.try_get("journey_id"))
            .collect::<Result<std::collections::HashSet<String>, db::Error>>()?;
        Ok(ids)
    }

    pub async fn upsert_vehicle_trips(
        &self,
        vehicle_id: &str,
        trips: &[VehicleTrip],
    ) -> Result<(), StoreError> {
        if trips.is_empty() {
            return Ok(());
        }
        let locations = trips
            .iter()
            .map(|trip| {
                Ok((
                    serde_json::to_string(&trip.start_location)?,
                    serde_json::to_string(&trip.end_location)?,
                ))
            })
            .collect::<Result<Vec<_>, serde_json::Error>>()
            .map_err(db::Error::from)?;
        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        conn.transaction::<_, db::Error, _>(|conn| Box::pin(async move {
            for (trip, (start_location, end_location)) in trips.iter().zip(locations) {
                db::query(
                    "INSERT INTO vehicle_trips \
                     (vehicle_id, journey_id, trip_id, started_at, ended_at, distance_kilometers, duration_minutes, \
                      start_location, end_location, average_speed_kph, average_energy_consumption_kwh_per_100km, \
                      energy_consumed_kwh, maximum_speed_kph, odometer_kilometers, rapid_acceleration_count, \
                      rapid_deceleration_count, rapid_swerve_count, is_combined) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, CAST(? AS jsonb), CAST(? AS jsonb), ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                     ON CONFLICT (vehicle_id, journey_id) DO UPDATE SET \
                      trip_id = COALESCE(EXCLUDED.trip_id, vehicle_trips.trip_id), \
                      started_at = EXCLUDED.started_at, ended_at = EXCLUDED.ended_at, \
                       distance_kilometers = CASE WHEN vehicle_trips.distance_kilometers <> TRUNC(vehicle_trips.distance_kilometers) \
                           AND EXCLUDED.distance_kilometers = TRUNC(EXCLUDED.distance_kilometers) \
                           THEN vehicle_trips.distance_kilometers ELSE EXCLUDED.distance_kilometers END, \
                       duration_minutes = EXCLUDED.duration_minutes, \
                      start_location = vehicle_trips.start_location || jsonb_strip_nulls(EXCLUDED.start_location), \
                      end_location = vehicle_trips.end_location || jsonb_strip_nulls(EXCLUDED.end_location), \
                      average_speed_kph = COALESCE(EXCLUDED.average_speed_kph, vehicle_trips.average_speed_kph), \
                       average_energy_consumption_kwh_per_100km = CASE \
                           WHEN EXCLUDED.energy_consumed_kwh IS NOT NULL \
                               AND vehicle_trips.distance_kilometers > 0 \
                               AND vehicle_trips.distance_kilometers <> TRUNC(vehicle_trips.distance_kilometers) \
                               AND EXCLUDED.distance_kilometers = TRUNC(EXCLUDED.distance_kilometers) \
                               THEN EXCLUDED.energy_consumed_kwh / vehicle_trips.distance_kilometers * 100 \
                           WHEN EXCLUDED.energy_consumed_kwh IS NOT NULL \
                               AND EXCLUDED.distance_kilometers > 0 \
                               THEN EXCLUDED.average_energy_consumption_kwh_per_100km \
                           WHEN EXCLUDED.distance_kilometers <> TRUNC(EXCLUDED.distance_kilometers) \
                               AND vehicle_trips.energy_consumed_kwh IS NOT NULL AND EXCLUDED.distance_kilometers > 0 \
                               THEN vehicle_trips.energy_consumed_kwh / EXCLUDED.distance_kilometers * 100 \
                           ELSE vehicle_trips.average_energy_consumption_kwh_per_100km END, \
                      energy_consumed_kwh = COALESCE(EXCLUDED.energy_consumed_kwh, vehicle_trips.energy_consumed_kwh), \
                      maximum_speed_kph = COALESCE(EXCLUDED.maximum_speed_kph, vehicle_trips.maximum_speed_kph), \
                      odometer_kilometers = COALESCE(EXCLUDED.odometer_kilometers, vehicle_trips.odometer_kilometers), \
                      rapid_acceleration_count = CASE WHEN EXCLUDED.rapid_acceleration_count = 0 AND vehicle_trips.rapid_acceleration_count > 0 \
                          THEN vehicle_trips.rapid_acceleration_count ELSE COALESCE(EXCLUDED.rapid_acceleration_count, vehicle_trips.rapid_acceleration_count) END, \
                      rapid_deceleration_count = CASE WHEN EXCLUDED.rapid_deceleration_count = 0 AND vehicle_trips.rapid_deceleration_count > 0 \
                          THEN vehicle_trips.rapid_deceleration_count ELSE COALESCE(EXCLUDED.rapid_deceleration_count, vehicle_trips.rapid_deceleration_count) END, \
                      rapid_swerve_count = CASE WHEN EXCLUDED.rapid_swerve_count = 0 AND vehicle_trips.rapid_swerve_count > 0 \
                          THEN vehicle_trips.rapid_swerve_count ELSE COALESCE(EXCLUDED.rapid_swerve_count, vehicle_trips.rapid_swerve_count) END, \
                      is_combined = EXCLUDED.is_combined, updated_at = NOW()",
                )
                .bind(vehicle_id)
                .bind(&trip.id)
                .bind(&trip.trip_id)
                .bind(trip.started_at)
                .bind(trip.ended_at)
                .bind(trip.distance_kilometers)
                .bind(i64::from(trip.duration_minutes))
                .bind(start_location)
                .bind(end_location)
                .bind(trip.average_speed_kph)
                .bind(trip.average_energy_consumption_kwh_per_100km)
                .bind(trip.energy_consumed_kwh)
                .bind(trip.maximum_speed_kph)
                .bind(trip.odometer_kilometers)
                .bind(trip.rapid_acceleration_count.map(i64::from))
                .bind(trip.rapid_deceleration_count.map(i64::from))
                .bind(trip.rapid_swerve_count.map(i64::from))
                .bind(trip.is_combined)
                .execute_conn(conn)
                .await?;
            }
            Ok(())
        })).await?;
        Ok(())
    }

    /// Persist upstream journey tracks. Compare the complete point sequence so
    /// upstream corrections are retained even when the point count is unchanged.
    pub async fn store_vehicle_trip_tracks(
        &self,
        vehicle_id: &str,
        tracks: &[VehicleTripTrack],
    ) -> Result<(), StoreError> {
        let tracks = tracks
            .iter()
            .filter(|track| !track.points.is_empty())
            .collect::<Vec<_>>();
        if tracks.is_empty() {
            return Ok(());
        }
        let mut changed = Vec::new();
        for track in tracks {
            let stored = self
                .vehicle_trip_track(vehicle_id, &track.journey_id)
                .await?;
            if stored != track.points {
                changed.push(track);
            }
        }
        if changed.is_empty() {
            return Ok(());
        }
        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        conn.transaction::<_, db::Error, _>(|conn| {
            Box::pin(async move {
                for track in changed {
                    db::query(
                        "DELETE FROM vehicle_trip_tracks WHERE vehicle_id = ? AND journey_id = ?",
                    )
                    .bind(vehicle_id)
                    .bind(&track.journey_id)
                    .execute_conn(conn)
                    .await?;
                    for (chunk_index, chunk) in track.points.chunks(TRACK_INSERT_CHUNK).enumerate()
                    {
                        let placeholders =
                            std::iter::repeat_n("(?, ?, ?, ?, ?, ?, ?, ?, ?)", chunk.len())
                                .collect::<Vec<_>>()
                                .join(", ");
                        let sql = format!(
                            "INSERT INTO vehicle_trip_tracks \
                             (vehicle_id, journey_id, seq, sampled_at, latitude, longitude, \
                              speed_kph, power_consumption, np_status) VALUES {placeholders}"
                        );
                        let mut query = db::query(&sql);
                        for (offset, point) in chunk.iter().enumerate() {
                            let seq = chunk_index * TRACK_INSERT_CHUNK + offset;
                            query = query
                                .bind(vehicle_id)
                                .bind(&track.journey_id)
                                .bind(seq as i64)
                                .bind(point.sampled_at)
                                .bind(point.latitude)
                                .bind(point.longitude)
                                .bind(point.speed_kph)
                                .bind(point.power_consumption)
                                .bind(point.np_status);
                        }
                        query.execute_conn(conn).await?;
                    }
                }
                Ok(())
            })
        })
        .await?;
        Ok(())
    }

    /// Bulk insert for the one-shot backfill. The caller already excluded
    /// journeys that own points, so this needs no existence check and no
    /// delete: one statement per parameter-budget chunk instead of two
    /// statements per journey. `DO NOTHING` keeps a concurrent sync from
    /// turning the batch into a primary-key error.
    pub async fn insert_vehicle_trip_tracks(
        &self,
        vehicle_id: &str,
        tracks: &[VehicleTripTrack],
    ) -> Result<(), StoreError> {
        if tracks.iter().all(|track| track.points.is_empty()) {
            return Ok(());
        }
        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        conn.transaction::<_, db::Error, _>(|conn| {
            Box::pin(async move {
                let mut rows: Vec<(&VehicleTripTrack, usize)> =
                    Vec::with_capacity(TRACK_ROWS_PER_INSERT);
                for track in tracks {
                    for seq in 0..track.points.len() {
                        rows.push((track, seq));
                        if rows.len() == TRACK_ROWS_PER_INSERT {
                            insert_track_rows(conn, vehicle_id, &rows).await?;
                            rows.clear();
                        }
                    }
                }
                if !rows.is_empty() {
                    insert_track_rows(conn, vehicle_id, &rows).await?;
                }
                Ok(())
            })
        })
        .await?;
        Ok(())
    }

    /// Store the vehicle identity and, when upstream produced one, the image
    /// bytes. A refresh that failed to download keeps the previously cached
    /// image instead of erasing it.
    pub async fn upsert_vehicle_profile(&self, profile: &VehicleProfile) -> Result<(), StoreError> {
        use diesel::sql_types::{Bytea, Nullable, Text, Timestamptz};
        use diesel_async::RunQueryDsl;

        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        diesel::sql_query(
            "INSERT INTO vehicle_profile \
             (vehicle_id, display_name, model_type, color, image_url, image_content_type, \
              image_sha256, image_bytes, image_fetched_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) \
             ON CONFLICT (vehicle_id) DO UPDATE SET \
              display_name = EXCLUDED.display_name, \
              model_type = EXCLUDED.model_type, \
              color = EXCLUDED.color, \
              image_url = EXCLUDED.image_url, \
              image_content_type = CASE \
                WHEN EXCLUDED.image_url IS NULL THEN NULL \
                WHEN EXCLUDED.image_bytes IS NOT NULL THEN EXCLUDED.image_content_type \
                WHEN vehicle_profile.image_url IS NOT DISTINCT FROM EXCLUDED.image_url \
                  THEN vehicle_profile.image_content_type ELSE NULL END, \
              image_sha256 = CASE \
                WHEN EXCLUDED.image_url IS NULL THEN NULL \
                WHEN EXCLUDED.image_bytes IS NOT NULL THEN EXCLUDED.image_sha256 \
                WHEN vehicle_profile.image_url IS NOT DISTINCT FROM EXCLUDED.image_url \
                  THEN vehicle_profile.image_sha256 ELSE NULL END, \
              image_bytes = CASE \
                WHEN EXCLUDED.image_url IS NULL THEN NULL \
                WHEN EXCLUDED.image_bytes IS NOT NULL THEN EXCLUDED.image_bytes \
                WHEN vehicle_profile.image_url IS NOT DISTINCT FROM EXCLUDED.image_url \
                  THEN vehicle_profile.image_bytes ELSE NULL END, \
              image_fetched_at = CASE \
                WHEN EXCLUDED.image_url IS NULL THEN NULL \
                WHEN EXCLUDED.image_bytes IS NOT NULL THEN EXCLUDED.image_fetched_at \
                WHEN vehicle_profile.image_url IS NOT DISTINCT FROM EXCLUDED.image_url \
                  THEN vehicle_profile.image_fetched_at ELSE NULL END, \
              updated_at = NOW()",
        )
        .bind::<Text, _>(profile.vehicle_id.as_str())
        .bind::<Nullable<Text>, _>(profile.display_name.as_deref())
        .bind::<Nullable<Text>, _>(profile.model_type.as_deref())
        .bind::<Nullable<Text>, _>(profile.color.as_deref())
        .bind::<Nullable<Text>, _>(profile.image_url.as_deref())
        .bind::<Nullable<Text>, _>(profile.image_content_type.as_deref())
        .bind::<Nullable<Text>, _>(profile.image_sha256.as_deref())
        .bind::<Nullable<Bytea>, _>(profile.image_bytes.as_deref())
        .bind::<Nullable<Timestamptz>, _>(profile.image_fetched_at)
        .execute(&mut conn)
        .await
        .map_err(db::Error::from)?;
        Ok(())
    }

    /// Metadata only; `image_available` says whether the bytes are cached.
    pub async fn vehicle_profile(
        &self,
        vehicle_id: &str,
    ) -> Result<Option<StoredVehicleProfile>, StoreError> {
        Ok(db::query_as::<StoredVehicleProfile>(
            "SELECT vehicle_id, display_name, model_type, color, image_url, \
                    (image_bytes IS NOT NULL) AS image_available, image_sha256, image_fetched_at \
             FROM vehicle_profile WHERE vehicle_id = ?",
        )
        .bind(vehicle_id)
        .fetch_optional(&self.pool)
        .await?)
    }

    /// Cached image bytes with their content type and digest, read in native
    /// form so the binary never passes through the JSON row wrapper.
    pub async fn vehicle_profile_image(
        &self,
        vehicle_id: &str,
    ) -> Result<Option<CachedVehicleImage>, StoreError> {
        use diesel::{
            QueryableByName,
            sql_types::{Bytea, Nullable, Text},
        };
        use diesel_async::RunQueryDsl;

        #[derive(QueryableByName)]
        struct ImageRow {
            #[diesel(sql_type = Nullable<Text>)]
            content_type: Option<String>,
            #[diesel(sql_type = Nullable<Text>)]
            sha256: Option<String>,
            #[diesel(sql_type = Bytea)]
            payload: Vec<u8>,
        }

        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        let rows: Vec<ImageRow> = diesel::sql_query(
            "SELECT image_content_type AS content_type, image_sha256 AS sha256, \
                    image_bytes AS payload \
             FROM vehicle_profile WHERE vehicle_id = $1 AND image_bytes IS NOT NULL",
        )
        .bind::<Text, _>(vehicle_id)
        .load(&mut conn)
        .await
        .map_err(db::Error::from)?;
        Ok(rows.into_iter().next().map(|row| CachedVehicleImage {
            content_type: row
                .content_type
                .unwrap_or_else(|| "application/octet-stream".to_owned()),
            sha256: row.sha256,
            bytes: row.payload,
        }))
    }

    /// Stored journeys whose track was never requested from upstream, newest
    /// first. Trips that already have points are excluded even when the scan
    /// marker is absent, so the normal sync does not create needless work.
    pub async fn vehicle_trip_ids_missing_tracks(
        &self,
        vehicle_id: &str,
        limit: usize,
    ) -> Result<Vec<String>, StoreError> {
        let rows = db::query(
            "SELECT t.journey_id FROM vehicle_trips t \
             WHERE t.vehicle_id = ? AND t.track_scanned_at IS NULL \
               AND NOT EXISTS (SELECT 1 FROM vehicle_trip_tracks k \
                               WHERE k.vehicle_id = t.vehicle_id AND k.journey_id = t.journey_id) \
             ORDER BY t.started_at DESC, t.journey_id DESC LIMIT ?",
        )
        .bind(vehicle_id)
        .bind(limit.clamp(1, 10_000) as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| row.try_get("journey_id"))
            .collect::<Result<Vec<String>, db::Error>>()
            .map_err(StoreError::from)
    }

    /// Remember that upstream was asked for these journeys' tracks, whether or
    /// not it returned one. Only called after a successful upstream response so
    /// a failed request stays retryable.
    pub async fn mark_trips_track_scanned(
        &self,
        vehicle_id: &str,
        journey_ids: &[String],
    ) -> Result<(), StoreError> {
        for chunk in journey_ids.chunks(TRACK_INSERT_CHUNK) {
            let placeholders = std::iter::repeat_n("?", chunk.len())
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "UPDATE vehicle_trips SET track_scanned_at = NOW() \
                 WHERE vehicle_id = ? AND journey_id IN ({placeholders})"
            );
            let mut query = db::query(&sql).bind(vehicle_id);
            for journey_id in chunk {
                query = query.bind(journey_id.as_str());
            }
            query.execute(&self.pool).await?;
        }
        Ok(())
    }

    /// The App's own polled positions inside one journey's time window, in
    /// sample order. These are not the official track: the status payload has
    /// no per-point speed or power, so those stay null.
    pub async fn vehicle_trip_sampled_points(
        &self,
        vehicle_id: &str,
        journey_id: &str,
    ) -> Result<Vec<VehicleTripTrackPoint>, StoreError> {
        Ok(db::query_as::<VehicleTripTrackPoint>(
            "SELECT s.sampled_at, s.latitude, s.longitude, \
                    CAST(NULL AS DOUBLE PRECISION) AS speed_kph, \
                    CAST(NULL AS DOUBLE PRECISION) AS power_consumption, \
                    CAST(NULL AS BIGINT) AS np_status \
             FROM vehicle_snapshots s \
             JOIN vehicle_trips t ON t.vehicle_id = s.vehicle_id AND t.journey_id = ? \
             WHERE s.vehicle_id = ? AND s.sampled_at BETWEEN t.started_at AND t.ended_at \
             ORDER BY s.sampled_at",
        )
        .bind(journey_id)
        .bind(vehicle_id)
        .fetch_all(&self.pool)
        .await?)
    }

    /// Track points in stored order. An empty result means the journey is not
    /// stored or upstream did not return a track for it.
    pub async fn vehicle_trip_track(
        &self,
        vehicle_id: &str,
        journey_id: &str,
    ) -> Result<Vec<VehicleTripTrackPoint>, StoreError> {
        Ok(db::query_as::<VehicleTripTrackPoint>(
            "SELECT sampled_at, latitude, longitude, speed_kph, power_consumption, np_status \
             FROM vehicle_trip_tracks WHERE vehicle_id = ? AND journey_id = ? ORDER BY seq",
        )
        .bind(vehicle_id)
        .bind(journey_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn schedule_trip_energy_day(
        &self,
        china_day: NaiveDate,
        scheduled_at: DateTime<Utc>,
    ) -> Result<(), StoreError> {
        db::query(
            "INSERT INTO trip_energy_daily_runs (china_day, scheduled_at) VALUES (?, ?) \
             ON CONFLICT (china_day) DO NOTHING",
        )
        .bind(china_day)
        .bind(scheduled_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn claim_trip_energy_day(&self, china_day: NaiveDate) -> Result<bool, StoreError> {
        Ok(db::query(
            "UPDATE trip_energy_daily_runs SET attempted_at = NOW(), outcome = 'started' \
             WHERE china_day = ? AND attempted_at IS NULL",
        )
        .bind(china_day)
        .execute(&self.pool)
        .await?
        .rows_affected()
            == 1)
    }

    pub async fn finish_trip_energy_day_success(
        &self,
        china_day: NaiveDate,
        result_json: &str,
    ) -> Result<(), StoreError> {
        let updated = db::query(
            "UPDATE trip_energy_daily_runs SET finished_at = NOW(), outcome = 'succeeded', \
             result_json = ? WHERE china_day = ? AND outcome = 'started'",
        )
        .bind(result_json)
        .bind(china_day)
        .execute(&self.pool)
        .await?
        .rows_affected();
        if updated != 1 {
            return Err(StoreError::InvalidStoredData(
                "trip energy daily claim was not active".to_owned(),
            ));
        }
        Ok(())
    }

    pub async fn finish_trip_energy_day_failure(
        &self,
        china_day: NaiveDate,
    ) -> Result<(), StoreError> {
        db::query(
            "UPDATE trip_energy_daily_runs SET finished_at = NOW(), outcome = 'failed' \
             WHERE china_day = ? AND outcome = 'started'",
        )
        .bind(china_day)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn trip_energy_cache_rows(&self) -> Result<TripEnergyCacheRows, StoreError> {
        let row = db::query(
            "SELECT \
             (SELECT result_json FROM trip_energy_daily_runs WHERE outcome = 'succeeded' \
              ORDER BY china_day DESC LIMIT 1) AS latest_success_json, \
             (SELECT china_day FROM trip_energy_daily_runs ORDER BY china_day DESC LIMIT 1) AS latest_attempt_day, \
             (SELECT outcome FROM trip_energy_daily_runs ORDER BY china_day DESC LIMIT 1) AS latest_attempt_outcome",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(TripEnergyCacheRows {
            latest_success_json: row.try_get("latest_success_json")?,
            latest_attempt_day: row.try_get("latest_attempt_day")?,
            latest_attempt_outcome: row.try_get("latest_attempt_outcome")?,
        })
    }

    pub async fn daily_checkin_schedule(
        &self,
        china_day: NaiveDate,
        candidate: DateTime<Utc>,
    ) -> Result<DailyCheckInRun, StoreError> {
        db::query(
            "INSERT INTO daily_checkin_runs (china_day, scheduled_at) VALUES (?, ?) \
             ON CONFLICT (china_day) DO NOTHING",
        )
        .bind(china_day)
        .bind(candidate)
        .execute(&self.pool)
        .await?;
        let row = db::query(
            "SELECT scheduled_at, attempted_at, attempts, result \
             FROM daily_checkin_runs WHERE china_day = ?",
        )
        .bind(china_day)
        .fetch_one(&self.pool)
        .await?;
        Ok(DailyCheckInRun {
            scheduled_at: row.try_get("scheduled_at")?,
            attempted_at: row.try_get("attempted_at")?,
            attempts: row.try_get("attempts")?,
            result: row.try_get("result")?,
        })
    }

    /// Atomically takes today's send slot. Returns the attempt number (starting at 1),
    /// or `None` when another caller already holds or finished the slot.
    pub async fn claim_daily_checkin(
        &self,
        china_day: NaiveDate,
    ) -> Result<Option<i32>, StoreError> {
        let claimed = db::query(
            "UPDATE daily_checkin_runs \
             SET attempted_at = NOW(), result = 'started', attempts = attempts + 1 \
             WHERE china_day = ? AND attempted_at IS NULL",
        )
        .bind(china_day)
        .execute(&self.pool)
        .await?
        .rows_affected()
            == 1;
        if !claimed {
            return Ok(None);
        }
        // The row is now claimed, so no other caller can change `attempts`.
        let row = db::query("SELECT attempts FROM daily_checkin_runs WHERE china_day = ?")
            .bind(china_day)
            .fetch_one(&self.pool)
            .await?;
        Ok(Some(row.try_get("attempts")?))
    }

    /// Releases a claim whose request was provably never sent, so the day can be
    /// retried at `scheduled_at`. Ambiguous failures must not call this.
    pub async fn release_daily_checkin(
        &self,
        china_day: NaiveDate,
        scheduled_at: DateTime<Utc>,
        error: &str,
    ) -> Result<(), StoreError> {
        db::query(
            "UPDATE daily_checkin_runs \
             SET attempted_at = NULL, scheduled_at = ?, result = 'not_sent', last_error = ? \
             WHERE china_day = ? AND result = 'started'",
        )
        .bind(scheduled_at)
        .bind(error)
        .bind(china_day)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn finish_daily_checkin(
        &self,
        china_day: NaiveDate,
        succeeded: bool,
        error: Option<&str>,
    ) -> Result<(), StoreError> {
        db::query(
            "UPDATE daily_checkin_runs \
             SET finished_at = NOW(), result = ?, last_error = ? \
             WHERE china_day = ? AND result = 'started'",
        )
        .bind(if succeeded { "succeeded" } else { "failed" })
        .bind(error.map(str::to_owned))
        .bind(china_day)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn connect(database_url: &str) -> Result<Self, StoreError> {
        let pool = crate::pg_store::connect(database_url)
            .await
            .map_err(|error| StoreError::Connect(error.to_string()))?;
        Ok(Self { pool })
    }

    #[cfg(test)]
    pub async fn in_memory() -> Result<Self, StoreError> {
        use diesel::{Connection, RunQueryDsl};
        let base_url = std::env::var("NIO_TEST_POSTGRES_URL")
            .map_err(|_| StoreError::Connect("NIO_TEST_POSTGRES_URL is required".to_owned()))?;
        let schema = format!("test_{}", Uuid::new_v4().simple());
        let admin_url = base_url.clone();
        let schema_name = schema.clone();
        tokio::task::spawn_blocking(move || -> Result<(), StoreError> {
            let mut conn = diesel::pg::PgConnection::establish(&admin_url)
                .map_err(|error| StoreError::Connect(error.to_string()))?;
            diesel::sql_query(format!("CREATE SCHEMA {schema_name}"))
                .execute(&mut conn)
                .map_err(db::Error::from)?;
            Ok(())
        })
        .await
        .map_err(|error| StoreError::Connect(error.to_string()))??;
        let mut url =
            url::Url::parse(&base_url).map_err(|error| StoreError::Connect(error.to_string()))?;
        url.query_pairs_mut()
            .append_pair("options", &format!("-csearch_path={schema}"));
        Self::connect(url.as_str()).await
    }

    pub async fn latest_snapshot(
        &self,
        station_key: &str,
    ) -> Result<Option<StoredSnapshot>, StoreError> {
        let id = db::query_scalar::<String>(
            "SELECT id FROM station_snapshots WHERE station_key = ? ORDER BY captured_at DESC LIMIT 1",
        )
        .bind(station_key)
        .fetch_optional(&self.pool)
        .await?;
        let Some(id) = id else {
            return Ok(None);
        };
        self.snapshot_by_id(&id).await
    }

    pub async fn snapshot_by_id(&self, id: &str) -> Result<Option<StoredSnapshot>, StoreError> {
        let row = db::query(
            "SELECT station_key, captured_at FROM station_snapshots WHERE id = ? LIMIT 1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else {
            return Ok(None);
        };
        let station_key: String = row.try_get("station_key")?;
        let captured_at: DateTime<Utc> = row.try_get("captured_at")?;
        let batteries = db::query(
            r#"SELECT battery_id, slot_id, battery_type, capacity_kwh, soc_percent, occupied, production_date
               FROM station_batteries WHERE snapshot_id = ? ORDER BY slot_id"#,
        )
        .bind(id)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(|row| {
            Ok(BatteryObservation {
                battery_id: row.try_get("battery_id")?,
                slot_id: row.try_get("slot_id")?,
                battery_type: row.try_get("battery_type")?,
                capacity_kwh: row.try_get("capacity_kwh")?,
                soc_percent: row.try_get("soc_percent")?,
                occupied: row.try_get::<i64, _>("occupied")? != 0,
                production_date: row.try_get("production_date")?,
            })
        })
        .collect::<Result<Vec<_>, db::Error>>()?;
        Ok(Some(StoredSnapshot {
            id: id.to_owned(),
            station_key,
            captured_at,
            batteries,
        }))
    }

    pub async fn first_battery_observation_after(
        &self,
        station_key: &str,
        battery_id: &str,
        after: DateTime<Utc>,
        through: DateTime<Utc>,
    ) -> Result<Option<BatteryObservation>, StoreError> {
        let row = db::query(
            r#"SELECT b.battery_id, b.slot_id, b.battery_type, b.capacity_kwh,
                      b.soc_percent, b.occupied, b.production_date
               FROM station_batteries b
               JOIN station_snapshots s ON s.id = b.snapshot_id
               WHERE s.station_key = ? AND b.battery_id = ?
                 AND s.captured_at > ? AND s.captured_at <= ?
               ORDER BY s.captured_at ASC
               LIMIT 1"#,
        )
        .bind(station_key)
        .bind(battery_id)
        .bind(after)
        .bind(through)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.as_ref().map(battery_observation_from_row).transpose()?)
    }

    pub async fn insert_snapshot(&self, snapshot: &StationSnapshot) -> Result<String, StoreError> {
        let id = Uuid::new_v4().to_string();
        let now = Utc::now();
        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        conn.transaction::<_, db::Error, _>(|conn| Box::pin(async {
            db::query(
            r#"INSERT INTO station_snapshots
               (id, station_key, station_name, captured_at, battery_count, created_at)
               VALUES (?, ?, ?, ?, ?, ?)"#,
            )
            .bind(&id)
            .bind(&snapshot.station_key)
            .bind(&snapshot.station_name)
            .bind(snapshot.captured_at)
            .bind(snapshot.batteries.len() as i64)
            .bind(now)
            .execute_conn(conn)
            .await?;

            for battery in &snapshot.batteries {
                db::query(
                r#"INSERT INTO station_batteries
                   (snapshot_id, battery_id, slot_id, battery_type, capacity_kwh, soc_percent, occupied, production_date)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#,
                )
                .bind(&id)
                .bind(&battery.battery_id)
                .bind(battery.slot_id)
                .bind(&battery.battery_type)
                .bind(battery.capacity_kwh)
                .bind(battery.soc_percent)
                .bind(battery.occupied as i64)
                .bind(battery.production_date)
                .execute_conn(conn)
                .await?;
            }
            Ok(())
        })).await?;
        Ok(id)
    }

    pub async fn insert_candidate(
        &self,
        previous_snapshot_id: &str,
        current_snapshot_id: &str,
        snapshot: &StationSnapshot,
        detected: &DetectedSwap,
    ) -> Result<String, StoreError> {
        let id = Uuid::new_v4().to_string();
        let detection_key = format!(
            "station:{}:{}:{}:{}:{}",
            snapshot.station_key,
            previous_snapshot_id,
            current_snapshot_id,
            detected.incoming.battery_id,
            detected.outgoing.battery_id,
        );
        let now = Utc::now();
        let evidence = serde_json::to_string(&detected.evidence)
            .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        let result = db::query(
            r#"INSERT INTO swap_events (
                 id, detection_key, status, occurred_at, station_key, station_name,
                 exact_energy_kwh, estimated_energy_kwh, energy_source,
                 outgoing_battery_id, outgoing_production_date, outgoing_capacity_kwh, outgoing_soc_percent,
                 incoming_battery_id, incoming_production_date, incoming_capacity_kwh, incoming_soc_percent,
                 battery_source, confidence, evidence, created_at, updated_at
               ) VALUES (?, ?, 'observed_candidate', ?, ?, ?, NULL, ?, 'station_inventory_estimate',
                         ?, ?, ?, ?, ?, ?, ?, ?, 'station_inventory_delta', 'medium', ?, ?, ?)
               ON CONFLICT(detection_key) DO NOTHING"#,
        )
        .bind(&id)
        .bind(&detection_key)
        .bind(snapshot.captured_at)
        .bind(&snapshot.station_key)
        .bind(&snapshot.station_name)
        .bind(detected.estimated_energy_kwh)
        .bind(&detected.outgoing.battery_id)
        .bind(detected.outgoing.production_date)
        .bind(detected.outgoing.capacity_kwh)
        .bind(detected.outgoing.soc_percent)
        .bind(&detected.incoming.battery_id)
        .bind(detected.incoming.production_date)
        .bind(detected.incoming.capacity_kwh)
        .bind(detected.incoming.soc_percent)
        .bind(evidence)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            let existing: String =
                db::query_scalar::<String>("SELECT id FROM swap_events WHERE detection_key = ?")
                    .bind(detection_key)
                    .fetch_one(&self.pool)
                    .await?;
            return Ok(existing);
        }
        Ok(id)
    }

    pub async fn upsert_order_candidate(
        &self,
        order_no: &str,
        baseline_snapshot_id: &str,
        snapshot: &StationSnapshot,
        detected: &DetectedOrderSwap,
    ) -> Result<String, StoreError> {
        let id = Uuid::new_v4().to_string();
        let detection_key = format!(
            "order:{order_no}:{baseline_snapshot_id}:{}:{}",
            detected.incoming.battery_id,
            detected
                .outgoing
                .as_ref()
                .map(|battery| battery.battery_id.as_str())
                .unwrap_or("pending"),
        );
        let now = Utc::now();
        let evidence = serde_json::to_string(&detected.evidence)
            .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        db::query(
            r#"INSERT INTO swap_events (
                 id, detection_key, status, occurred_at, station_key, station_name, order_no,
                 exact_energy_kwh, estimated_energy_kwh, energy_source,
                 outgoing_battery_id, outgoing_production_date, outgoing_capacity_kwh, outgoing_soc_percent,
                 incoming_battery_id, incoming_production_date, incoming_capacity_kwh, incoming_soc_percent,
                 battery_source, confidence, evidence, created_at, updated_at
               ) VALUES (?, ?, 'observed_candidate', ?, ?, ?, ?, NULL, ?, ?,
                         ?, ?, ?, ?, ?, ?, ?, ?, 'station_inventory_delta', 'medium', ?, ?, ?)
               ON CONFLICT(order_no) DO UPDATE SET
                 station_key = COALESCE(swap_events.station_key, excluded.station_key),
                 station_name = COALESCE(swap_events.station_name, excluded.station_name),
                 estimated_energy_kwh = COALESCE(swap_events.estimated_energy_kwh, excluded.estimated_energy_kwh),
                 energy_source = CASE
                   WHEN excluded.estimated_energy_kwh IS NOT NULL THEN excluded.energy_source
                   ELSE swap_events.energy_source
                 END,
                 outgoing_battery_id = COALESCE(swap_events.outgoing_battery_id, excluded.outgoing_battery_id),
                 outgoing_production_date = COALESCE(swap_events.outgoing_production_date, excluded.outgoing_production_date),
                 outgoing_capacity_kwh = COALESCE(swap_events.outgoing_capacity_kwh, excluded.outgoing_capacity_kwh),
                 outgoing_soc_percent = COALESCE(swap_events.outgoing_soc_percent, excluded.outgoing_soc_percent),
                 incoming_battery_id = COALESCE(swap_events.incoming_battery_id, excluded.incoming_battery_id),
                 incoming_production_date = COALESCE(swap_events.incoming_production_date, excluded.incoming_production_date),
                 incoming_capacity_kwh = COALESCE(swap_events.incoming_capacity_kwh, excluded.incoming_capacity_kwh),
                 incoming_soc_percent = COALESCE(swap_events.incoming_soc_percent, excluded.incoming_soc_percent),
                 battery_source = CASE
                   WHEN swap_events.outgoing_battery_id IS NULL OR swap_events.incoming_battery_id IS NULL
                     THEN excluded.battery_source
                   ELSE swap_events.battery_source
                 END,
                 evidence = excluded.evidence,
                 updated_at = excluded.updated_at"#,
        )
        .bind(&id)
        .bind(&detection_key)
        .bind(snapshot.captured_at)
        .bind(&snapshot.station_key)
        .bind(&snapshot.station_name)
        .bind(order_no)
        .bind(detected.estimated_energy_kwh)
        .bind(if detected.estimated_energy_kwh.is_some() {
            "station_inventory_estimate"
        } else {
            "unavailable"
        })
        .bind(
            detected
                .outgoing
                .as_ref()
                .map(|battery| battery.battery_id.as_str()),
        )
        .bind(
            detected
                .outgoing
                .as_ref()
                .and_then(|battery| battery.production_date),
        )
        .bind(
            detected
                .outgoing
                .as_ref()
                .and_then(|battery| battery.capacity_kwh),
        )
        .bind(
            detected
                .outgoing
                .as_ref()
                .and_then(|battery| battery.soc_percent),
        )
        .bind(&detected.incoming.battery_id)
        .bind(detected.incoming.production_date)
        .bind(detected.incoming.capacity_kwh)
        .bind(detected.incoming.soc_percent)
        .bind(evidence)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        db::query_scalar::<String>("SELECT id FROM swap_events WHERE order_no = ? LIMIT 1")
            .bind(order_no)
            .fetch_one(&self.pool)
            .await
            .map_err(StoreError::from)
    }

    pub async fn import_order(
        &self,
        order: &ImportedOrder,
        match_window: Duration,
    ) -> Result<SwapEvent, StoreError> {
        let order_no = order.order_no.trim();
        let lower = order.occurred_at
            - chrono::Duration::from_std(match_window)
                .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        let upper = order.occurred_at
            + chrono::Duration::from_std(match_window)
                .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;

        let existing_by_order =
            db::query_as::<EventRow>("SELECT * FROM swap_events WHERE order_no = ? LIMIT 1")
                .bind(order_no)
                .fetch_optional(&self.pool)
                .await?;

        let target_id = if let Some(existing) = existing_by_order {
            Some(existing.id)
        } else {
            let candidates = db::query_as::<EventRow>(
                r#"SELECT * FROM swap_events
                   WHERE status = 'observed_candidate' AND occurred_at BETWEEN ? AND ?
                   ORDER BY ABS(EXTRACT(EPOCH FROM occurred_at - ?)) ASC"#,
            )
            .bind(lower)
            .bind(upper)
            .bind(order.occurred_at)
            .fetch_all(&self.pool)
            .await?;
            let matching = candidates
                .into_iter()
                .filter(|candidate| candidate_matches(candidate, order))
                .collect::<Vec<_>>();
            (matching.len() == 1).then(|| matching[0].id.clone())
        };

        let outgoing = order.outgoing_battery.as_ref();
        let incoming = order.incoming_battery.as_ref();
        let has_imported_batteries = outgoing
            .and_then(|battery| battery.battery_id.as_ref())
            .is_some()
            || incoming
                .and_then(|battery| battery.battery_id.as_ref())
                .is_some();
        let confidence = if order.energy_kwh.is_some()
            && outgoing
                .and_then(|battery| battery.battery_id.as_ref())
                .is_some()
            && incoming
                .and_then(|battery| battery.battery_id.as_ref())
                .is_some()
        {
            "exact"
        } else {
            "high"
        };
        let exact_energy_source = if order
            .raw_payload
            .as_ref()
            .and_then(|payload| payload.pointer("/orderDetail/energy"))
            .is_some()
        {
            "order_detail"
        } else {
            "order_import"
        };
        let raw_json = order
            .raw_payload
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        let payment_items_json = (!order.payment_items.is_empty())
            .then(|| serde_json::to_string(&order.payment_items))
            .transpose()
            .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        let now = Utc::now();

        let id = if let Some(id) = target_id {
            db::query(
                r#"UPDATE swap_events SET
                     status = 'confirmed', occurred_at = ?,
                     station_key = COALESCE(?, station_key), station_name = COALESCE(?, station_name),
                     station_address = COALESCE(?, station_address),
                     order_no = ?, order_status_name = COALESCE(?, order_status_name),
                     price_amount = COALESCE(?, price_amount),
                     price_currency = COALESCE(?, price_currency),
                     price_description = COALESCE(?, price_description),
                     payment_items_json = COALESCE(?, payment_items_json),
                     exact_energy_kwh = COALESCE(?, exact_energy_kwh),
                     energy_source = CASE WHEN ? IS NULL THEN energy_source ELSE ? END,
                     outgoing_battery_id = COALESCE(?, outgoing_battery_id),
                     outgoing_production_date = COALESCE(?, outgoing_production_date),
                     outgoing_capacity_kwh = COALESCE(?, outgoing_capacity_kwh),
                     outgoing_soc_percent = COALESCE(?, outgoing_soc_percent),
                     incoming_battery_id = COALESCE(?, incoming_battery_id),
                     incoming_production_date = COALESCE(?, incoming_production_date),
                     incoming_capacity_kwh = COALESCE(?, incoming_capacity_kwh),
                     incoming_soc_percent = COALESCE(?, incoming_soc_percent),
                     battery_source = CASE WHEN ? THEN 'order_import' ELSE battery_source END,
                     confidence = CASE WHEN confidence = 'exact' THEN 'exact' ELSE ? END,
                     raw_order_json = COALESCE(?, raw_order_json), updated_at = ?
                   WHERE id = ?"#,
            )
            .bind(order.occurred_at)
            .bind(&order.station_key)
            .bind(&order.station_name)
            .bind(&order.station_address)
            .bind(order_no)
            .bind(&order.order_status_name)
            .bind(order.price_amount)
            .bind(&order.price_currency)
            .bind(&order.price_description)
            .bind(&payment_items_json)
            .bind(order.energy_kwh)
            .bind(order.energy_kwh)
            .bind(exact_energy_source)
            .bind(outgoing.and_then(|battery| battery.battery_id.as_deref()))
            .bind(outgoing.and_then(|battery| battery.production_date))
            .bind(outgoing.and_then(|battery| battery.capacity_kwh))
            .bind(outgoing.and_then(|battery| battery.soc_percent))
            .bind(incoming.and_then(|battery| battery.battery_id.as_deref()))
            .bind(incoming.and_then(|battery| battery.production_date))
            .bind(incoming.and_then(|battery| battery.capacity_kwh))
            .bind(incoming.and_then(|battery| battery.soc_percent))
            .bind(has_imported_batteries)
            .bind(confidence)
            .bind(raw_json)
            .bind(now)
            .bind(&id)
            .execute(&self.pool)
            .await?;
            id
        } else {
            let id = Uuid::new_v4().to_string();
            db::query(
                r#"INSERT INTO swap_events (
                     id, detection_key, status, occurred_at, station_key, station_name, station_address,
                     order_no, order_status_name, price_amount, price_currency, price_description,
                     payment_items_json,
                     exact_energy_kwh, estimated_energy_kwh, energy_source,
                     outgoing_battery_id, outgoing_production_date, outgoing_capacity_kwh, outgoing_soc_percent,
                     incoming_battery_id, incoming_production_date, incoming_capacity_kwh, incoming_soc_percent,
                     battery_source, confidence, raw_order_json, created_at, updated_at
                   ) VALUES (?, ?, 'confirmed', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL,
                     CASE WHEN ? IS NULL THEN 'unavailable' ELSE ? END,
                     ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
            )
            .bind(&id)
            .bind(format!("order:{order_no}"))
            .bind(order.occurred_at)
            .bind(&order.station_key)
            .bind(&order.station_name)
            .bind(&order.station_address)
            .bind(order_no)
            .bind(&order.order_status_name)
            .bind(order.price_amount)
            .bind(&order.price_currency)
            .bind(&order.price_description)
            .bind(&payment_items_json)
            .bind(order.energy_kwh)
            .bind(order.energy_kwh)
            .bind(exact_energy_source)
            .bind(outgoing.and_then(|battery| battery.battery_id.as_deref()))
            .bind(outgoing.and_then(|battery| battery.production_date))
            .bind(outgoing.and_then(|battery| battery.capacity_kwh))
            .bind(outgoing.and_then(|battery| battery.soc_percent))
            .bind(incoming.and_then(|battery| battery.battery_id.as_deref()))
            .bind(incoming.and_then(|battery| battery.production_date))
            .bind(incoming.and_then(|battery| battery.capacity_kwh))
            .bind(incoming.and_then(|battery| battery.soc_percent))
            .bind(if has_imported_batteries { "order_import" } else { "unavailable" })
            .bind(confidence)
            .bind(raw_json)
            .bind(now)
            .bind(now)
            .execute(&self.pool)
            .await?;
            id
        };

        self.event_by_id(&id)
            .await?
            .ok_or_else(|| StoreError::InvalidStoredData("saved order disappeared".to_owned()))
    }

    pub async fn observe_service_order(
        &self,
        order: &ObservedServiceOrder,
    ) -> Result<ServiceOrderObservationState, StoreError> {
        let existing = db::query(
            r#"SELECT order_type, order_status, order_status_name, order_created_at,
                      vehicle_id, vin_code, station_key, station_name, station_address,
                      baseline_snapshot_id
               FROM service_orders WHERE order_no = ?"#,
        )
        .bind(&order.order_no)
        .fetch_optional(&self.pool)
        .await?;

        let (is_new_or_changed, baseline_snapshot_id, station_key, station_name, station_address) =
            if let Some(row) = existing {
                let stored_created_at: DateTime<Utc> = row.try_get("order_created_at")?;
                let stored_station_key: Option<String> = row.try_get("station_key")?;
                let stored_station_name: Option<String> = row.try_get("station_name")?;
                let stored_station_address: Option<String> = row.try_get("station_address")?;
                let station_changed = matches!(
                    (stored_station_key.as_deref(), order.station_key.as_deref()),
                    (Some(stored), Some(observed)) if stored != observed
                );
                let station_key = order
                    .station_key
                    .clone()
                    .or_else(|| stored_station_key.clone());
                let station_name = if station_changed {
                    order.station_name.clone()
                } else {
                    order
                        .station_name
                        .clone()
                        .or_else(|| stored_station_name.clone())
                };
                let station_address = if station_changed {
                    order.station_address.clone()
                } else {
                    order
                        .station_address
                        .clone()
                        .or_else(|| stored_station_address.clone())
                };
                let changed = stored_station_key != station_key
                    || stored_station_name != station_name
                    || stored_station_address != station_address
                    || row.try_get::<String, _>("order_type")? != order.order_type
                    || row.try_get::<Option<String>, _>("order_status")? != order.order_status
                    || row.try_get::<Option<String>, _>("order_status_name")?
                        != order.order_status_name
                    || stored_created_at != order.created_at
                    || row.try_get::<Option<String>, _>("vehicle_id")? != order.vehicle_id
                    || row.try_get::<Option<String>, _>("vin_code")? != order.vin_code;
                let baseline: Option<String> = if station_changed {
                    None
                } else {
                    row.try_get("baseline_snapshot_id")?
                };
                (
                    changed,
                    baseline,
                    station_key,
                    station_name,
                    station_address,
                )
            } else {
                (
                    true,
                    None,
                    order.station_key.clone(),
                    order.station_name.clone(),
                    order.station_address.clone(),
                )
            };

        let raw_json = serde_json::to_string(&order.raw_payload)
            .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        let now = Utc::now();
        db::query(
            r#"INSERT INTO service_orders (
                 order_no, order_type, order_status, order_status_name, order_created_at,
                 vehicle_id, vin_code, station_key, station_name, station_address,
                 raw_order_json, baseline_snapshot_id, baseline_captured_at,
                 first_seen_at, last_seen_at, updated_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
               ON CONFLICT(order_no) DO UPDATE SET
                 order_type = excluded.order_type,
                 order_status = excluded.order_status,
                 order_status_name = excluded.order_status_name,
                 order_created_at = excluded.order_created_at,
                 vehicle_id = excluded.vehicle_id,
                 vin_code = excluded.vin_code,
                 station_key = excluded.station_key,
                 station_name = excluded.station_name,
                 station_address = excluded.station_address,
                 raw_order_json = excluded.raw_order_json,
                 baseline_snapshot_id = excluded.baseline_snapshot_id,
                 baseline_captured_at = CASE
                   WHEN excluded.baseline_snapshot_id IS NULL THEN NULL
                   ELSE service_orders.baseline_captured_at
                 END,
                 last_seen_at = excluded.last_seen_at,
                 updated_at = excluded.updated_at"#,
        )
        .bind(&order.order_no)
        .bind(&order.order_type)
        .bind(&order.order_status)
        .bind(&order.order_status_name)
        .bind(order.created_at)
        .bind(&order.vehicle_id)
        .bind(&order.vin_code)
        .bind(&station_key)
        .bind(&station_name)
        .bind(&station_address)
        .bind(raw_json)
        .bind(&baseline_snapshot_id)
        .bind(now)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;

        Ok(ServiceOrderObservationState {
            is_new_or_changed,
            needs_baseline: baseline_snapshot_id.is_none(),
        })
    }

    pub async fn mark_service_order_baseline(
        &self,
        order_no: &str,
        snapshot_id: &str,
    ) -> Result<(), StoreError> {
        db::query(
            "UPDATE service_orders SET baseline_snapshot_id = ?, baseline_captured_at = ?, updated_at = ? WHERE order_no = ?",
        )
        .bind(snapshot_id)
        .bind(Utc::now())
        .bind(Utc::now())
        .bind(order_no)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_service_order_queue(
        &self,
        queue: &ObservedServiceOrderQueue,
    ) -> Result<(), StoreError> {
        db::query(
            r#"UPDATE service_orders SET
                 queue_number = ?,
                 target_battery_cap_level = ?,
                 vehicles_ahead = ?,
                 estimated_wait_minutes = ?,
                 estimated_wait_source = ?,
                 queue_status_text = ?,
                 queue_updated_at = ?,
                 updated_at = ?
               WHERE order_no = ?"#,
        )
        .bind(queue.queue_number.map(i64::from))
        .bind(queue.target_battery_cap_level.map(i64::from))
        .bind(queue.vehicles_ahead.map(i64::from))
        .bind(queue.estimated_wait_minutes.map(i64::from))
        .bind(&queue.estimated_wait_source)
        .bind(&queue.queue_status_text)
        .bind(queue.observed_at)
        .bind(queue.observed_at)
        .bind(&queue.order_no)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn active_order_baselines_for_station(
        &self,
        station_key: &str,
    ) -> Result<Vec<ActiveOrderBaseline>, StoreError> {
        let recent_swap_threshold = Utc::now() - chrono::Duration::minutes(15);
        let rows = db::query(
            r#"SELECT order_no, baseline_snapshot_id, swap_start_soc
               FROM service_orders
               WHERE station_key = ? AND baseline_snapshot_id IS NOT NULL
                 AND (is_active = 1 OR swap_start_soc_observed_at >= ?)
               ORDER BY order_created_at DESC"#,
        )
        .bind(station_key)
        .bind(recent_swap_threshold)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                Ok(ActiveOrderBaseline {
                    order_no: row.try_get("order_no")?,
                    snapshot_id: row.try_get("baseline_snapshot_id")?,
                    swap_start_soc: row.try_get("swap_start_soc")?,
                })
            })
            .collect::<Result<Vec<_>, db::Error>>()
            .map_err(StoreError::from)
    }

    pub async fn record_active_order_swap_start_soc(
        &self,
        soc: f64,
        observed_at: DateTime<Utc>,
    ) -> Result<bool, StoreError> {
        if !soc.is_finite() || !(0.0..=100.0).contains(&soc) {
            return Ok(false);
        }
        let rows = db::query_scalar::<String>(
            r#"SELECT order_no
               FROM service_orders
               WHERE is_active = 1
               ORDER BY order_created_at DESC
               LIMIT 2"#,
        )
        .fetch_all(&self.pool)
        .await?;
        if rows.len() != 1 {
            return Ok(false);
        }
        let result = db::query(
            r#"UPDATE service_orders
               SET swap_start_soc = ?, swap_start_soc_observed_at = ?, updated_at = ?
               WHERE order_no = ? AND swap_start_soc IS NULL"#,
        )
        .bind(soc)
        .bind(observed_at)
        .bind(Utc::now())
        .bind(&rows[0])
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn set_active_service_orders(&self, order_nos: &[String]) -> Result<(), StoreError> {
        let mut conn = self.pool.get().await.map_err(db::Error::from)?;
        conn.transaction::<_, db::Error, _>(|conn| {
            Box::pin(async {
                db::query("UPDATE service_orders SET is_active = 0 WHERE is_active != 0")
                    .execute_conn(conn)
                    .await?;
                for order_no in order_nos {
                    db::query("UPDATE service_orders SET is_active = 1 WHERE order_no = ?")
                        .bind(order_no)
                        .execute_conn(conn)
                        .await?;
                }
                Ok(())
            })
        })
        .await?;
        Ok(())
    }

    pub async fn list_active_service_orders(
        &self,
        limit: u32,
    ) -> Result<Vec<ActiveServiceOrder>, StoreError> {
        let rows = db::query_as::<ActiveServiceOrderRow>(
            r#"SELECT order_no, order_type, order_status, order_status_name,
                      order_created_at, station_key, station_name, station_address,
                      baseline_captured_at, queue_number, target_battery_cap_level,
                      vehicles_ahead, estimated_wait_minutes, estimated_wait_source,
                      queue_status_text, queue_updated_at, first_seen_at, last_seen_at
               FROM service_orders
               WHERE is_active = 1
               ORDER BY order_created_at DESC
               LIMIT ?"#,
        )
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                Ok(ActiveServiceOrder {
                    order_no: row.order_no,
                    order_type: row.order_type,
                    order_status: row.order_status,
                    order_status_name: row.order_status_name,
                    order_created_at: row.order_created_at,
                    station_key: row.station_key,
                    station_name: row.station_name,
                    station_address: row.station_address,
                    baseline_captured_at: row.baseline_captured_at,
                    queue_number: optional_u32(row.queue_number)?,
                    target_battery_cap_level: optional_u32(row.target_battery_cap_level)?,
                    vehicles_ahead: optional_u32(row.vehicles_ahead)?,
                    estimated_wait_minutes: optional_u32(row.estimated_wait_minutes)?,
                    estimated_wait_source: row.estimated_wait_source,
                    queue_status_text: row.queue_status_text,
                    queue_updated_at: row.queue_updated_at,
                    first_seen_at: row.first_seen_at,
                    last_seen_at: row.last_seen_at,
                })
            })
            .collect()
    }

    pub async fn swap_order_detail(
        &self,
        order_no: &str,
    ) -> Result<Option<serde_json::Value>, StoreError> {
        let raw_json = db::query_scalar::<Option<String>>(
            "SELECT raw_order_json FROM swap_events WHERE order_no = ? LIMIT 1",
        )
        .bind(order_no.trim())
        .fetch_optional(&self.pool)
        .await?
        .flatten();
        let Some(raw_json) = raw_json else {
            return Ok(None);
        };
        let raw_payload: serde_json::Value = serde_json::from_str(&raw_json)
            .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
        Ok(raw_payload.pointer("/orderDetail").cloned())
    }

    pub async fn upsert_swap_station(
        &self,
        station: &ObservedSwapStation,
    ) -> Result<(), StoreError> {
        let now = Utc::now();
        db::query(
            r#"INSERT INTO swap_stations (
                 station_id, station_name, station_address, operator_id, operator_name,
                 source_order_no, first_seen_at, last_seen_at, created_at, updated_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(station_id) DO UPDATE SET
                 station_name = CASE
                   WHEN excluded.last_seen_at >= swap_stations.last_seen_at
                   THEN excluded.station_name ELSE swap_stations.station_name END,
                 station_address = CASE
                   WHEN excluded.last_seen_at >= swap_stations.last_seen_at
                   THEN COALESCE(excluded.station_address, swap_stations.station_address)
                   ELSE COALESCE(swap_stations.station_address, excluded.station_address) END,
                 operator_id = CASE
                   WHEN excluded.last_seen_at >= swap_stations.last_seen_at
                   THEN COALESCE(excluded.operator_id, swap_stations.operator_id)
                   ELSE COALESCE(swap_stations.operator_id, excluded.operator_id) END,
                 operator_name = CASE
                   WHEN excluded.last_seen_at >= swap_stations.last_seen_at
                   THEN COALESCE(excluded.operator_name, swap_stations.operator_name)
                   ELSE COALESCE(swap_stations.operator_name, excluded.operator_name) END,
                 source_order_no = CASE
                   WHEN excluded.last_seen_at >= swap_stations.last_seen_at
                   THEN excluded.source_order_no ELSE swap_stations.source_order_no END,
                 first_seen_at = LEAST(swap_stations.first_seen_at, excluded.first_seen_at),
                 last_seen_at = GREATEST(swap_stations.last_seen_at, excluded.last_seen_at),
                 updated_at = excluded.updated_at"#,
        )
        .bind(&station.station_id)
        .bind(&station.station_name)
        .bind(&station.station_address)
        .bind(&station.operator_id)
        .bind(&station.operator_name)
        .bind(&station.source_order_no)
        .bind(station.observed_at)
        .bind(station.observed_at)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Refresh only the identity columns that the station detail endpoint owns.
    /// Operators and order attribution are left untouched.
    pub async fn upsert_station_identity(
        &self,
        station_id: &str,
        station_name: &str,
        station_address: Option<&str>,
        observed_at: DateTime<Utc>,
    ) -> Result<(), StoreError> {
        let now = Utc::now();
        db::query(
            r#"INSERT INTO swap_stations (
                 station_id, station_name, station_address,
                 first_seen_at, last_seen_at, created_at, updated_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(station_id) DO UPDATE SET
                 station_name = excluded.station_name,
                 station_address = COALESCE(excluded.station_address, swap_stations.station_address),
                 first_seen_at = LEAST(swap_stations.first_seen_at, excluded.first_seen_at),
                 last_seen_at = GREATEST(swap_stations.last_seen_at, excluded.last_seen_at),
                 updated_at = excluded.updated_at"#,
        )
        .bind(station_id.trim())
        .bind(station_name.trim())
        .bind(station_address.map(str::trim).filter(|value| !value.is_empty()))
        .bind(observed_at)
        .bind(observed_at)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_swap_stations(
        &self,
        limit: u32,
        offset: u32,
        search: Option<&str>,
    ) -> Result<Vec<SwapStation>, StoreError> {
        let search = search.map(str::trim).filter(|value| !value.is_empty());
        db::query_as::<SwapStationRow>(
            r#"SELECT * FROM swap_stations
               WHERE ? IS NULL
                  OR POSITION(LOWER(?) IN LOWER(station_id)) > 0
                  OR POSITION(LOWER(?) IN LOWER(station_name)) > 0
                  OR POSITION(LOWER(?) IN LOWER(COALESCE(station_address, ''))) > 0
                  OR POSITION(LOWER(?) IN LOWER(COALESCE(operator_name, ''))) > 0
               ORDER BY last_seen_at DESC, station_id LIMIT ? OFFSET ?"#,
        )
        .bind(search)
        .bind(search)
        .bind(search)
        .bind(search)
        .bind(search)
        .bind(limit as i64)
        .bind(offset as i64)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(swap_station_from_row)
        .collect()
    }

    pub async fn upsert_searched_swap_station(
        &self,
        station_id: &str,
        station_name: &str,
        station_address: Option<&str>,
        latitude: f64,
        longitude: f64,
    ) -> Result<(), StoreError> {
        if !latitude.is_finite()
            || !longitude.is_finite()
            || !(-90.0..=90.0).contains(&latitude)
            || !(-180.0..=180.0).contains(&longitude)
        {
            return Err(StoreError::InvalidStoredData(
                "station coordinates are invalid".to_owned(),
            ));
        }
        let now = Utc::now();
        db::query(
            r#"INSERT INTO swap_stations (
                 station_id, station_name, station_address, latitude, longitude,
                 operator_id, operator_name, source_order_no,
                 first_seen_at, last_seen_at, created_at, updated_at
               ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?)
               ON CONFLICT(station_id) DO UPDATE SET
                 station_name = excluded.station_name,
                 station_address = COALESCE(excluded.station_address, swap_stations.station_address),
                 latitude = excluded.latitude,
                 longitude = excluded.longitude,
                 last_seen_at = GREATEST(swap_stations.last_seen_at, excluded.last_seen_at),
                 updated_at = excluded.updated_at"#,
        )
        .bind(station_id.trim())
        .bind(station_name.trim())
        .bind(station_address.map(str::trim).filter(|value| !value.is_empty()))
        .bind(latitude)
        .bind(longitude)
        .bind(now)
        .bind(now)
        .bind(now)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_swap_station_coordinates(
        &self,
        station_id: &str,
        latitude: f64,
        longitude: f64,
    ) -> Result<(), StoreError> {
        if !latitude.is_finite()
            || !longitude.is_finite()
            || !(-90.0..=90.0).contains(&latitude)
            || !(-180.0..=180.0).contains(&longitude)
        {
            return Err(StoreError::InvalidStoredData(
                "station coordinates are invalid".to_owned(),
            ));
        }
        db::query(
            "UPDATE swap_stations SET latitude = ?, longitude = ?, updated_at = ? WHERE station_id = ?",
        )
        .bind(latitude)
        .bind(longitude)
        .bind(Utc::now())
        .bind(station_id.trim())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    #[cfg(test)]
    pub async fn swap_stations_missing_coordinates(&self) -> Result<Vec<SwapStation>, StoreError> {
        db::query_as::<SwapStationRow>(
            r#"SELECT * FROM swap_stations
               WHERE latitude IS NULL OR longitude IS NULL
               ORDER BY last_seen_at DESC, station_id"#,
        )
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(swap_station_from_row)
        .collect()
    }

    pub async fn update_swap_station_identity(
        &self,
        station_id: &str,
        latitude: f64,
        longitude: f64,
        station_address: Option<&str>,
    ) -> Result<(), StoreError> {
        if !latitude.is_finite()
            || !longitude.is_finite()
            || !(-90.0..=90.0).contains(&latitude)
            || !(-180.0..=180.0).contains(&longitude)
        {
            return Err(StoreError::InvalidStoredData(
                "station coordinates are invalid".to_owned(),
            ));
        }
        db::query(
            r#"UPDATE swap_stations SET
                 latitude = ?,
                 longitude = ?,
                 station_address = COALESCE(?, station_address),
                 updated_at = ?
               WHERE station_id = ?"#,
        )
        .bind(latitude)
        .bind(longitude)
        .bind(
            station_address
                .map(str::trim)
                .filter(|value| !value.is_empty()),
        )
        .bind(Utc::now())
        .bind(station_id.trim())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn swap_stations_missing_identity(&self) -> Result<Vec<SwapStation>, StoreError> {
        db::query_as::<SwapStationRow>(
            r#"SELECT * FROM swap_stations
               WHERE latitude IS NULL OR longitude IS NULL
                  OR station_address IS NULL OR TRIM(station_address) = ''
               ORDER BY last_seen_at DESC, station_id"#,
        )
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(swap_station_from_row)
        .collect()
    }

    /// Copy directory addresses onto completed swaps that predate address
    /// collection. Only empty event addresses are touched.
    pub async fn backfill_swap_event_station_addresses(&self) -> Result<u64, StoreError> {
        let result = db::query(
            r#"UPDATE swap_events SET
                 station_address = (
                   SELECT station_address FROM swap_stations
                   WHERE swap_stations.station_id = swap_events.station_key
                 ),
                 updated_at = ?
               WHERE (station_address IS NULL OR TRIM(station_address) = '')
                 AND station_key IS NOT NULL
                 AND EXISTS (
                   SELECT 1 FROM swap_stations
                   WHERE station_id = swap_events.station_key
                     AND station_address IS NOT NULL
                     AND TRIM(station_address) <> ''
                 )"#,
        )
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    pub async fn swap_station_by_id(
        &self,
        station_id: &str,
    ) -> Result<Option<SwapStation>, StoreError> {
        db::query_as::<SwapStationRow>("SELECT * FROM swap_stations WHERE station_id = ?")
            .bind(station_id.trim())
            .fetch_optional(&self.pool)
            .await?
            .map(swap_station_from_row)
            .transpose()
    }

    pub async fn list_events(
        &self,
        limit: u32,
        offset: u32,
        include_candidates: bool,
    ) -> Result<Vec<SwapEvent>, StoreError> {
        let rows = if include_candidates {
            db::query_as::<EventRow>(
                "SELECT * FROM swap_events ORDER BY occurred_at DESC LIMIT ? OFFSET ?",
            )
            .bind(limit as i64)
            .bind(offset as i64)
            .fetch_all(&self.pool)
            .await?
        } else {
            db::query_as::<EventRow>(
                "SELECT * FROM swap_events WHERE status = 'confirmed' ORDER BY occurred_at DESC LIMIT ? OFFSET ?"
            ).bind(limit as i64).bind(offset as i64).fetch_all(&self.pool).await?
        };
        rows.into_iter().map(event_from_row).collect()
    }

    pub async fn confirmed_swaps_between(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<SwapEvent>, StoreError> {
        let rows = db::query_as::<EventRow>(
            "SELECT * FROM swap_events WHERE status = 'confirmed' AND occurred_at >= ? AND occurred_at < ? ORDER BY occurred_at"
        ).bind(from).bind(to).fetch_all(&self.pool).await?;
        rows.into_iter().map(event_from_row).collect()
    }

    pub async fn swap_battery_capacities_for_interval(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<SwapBatteryCapacity>, StoreError> {
        let previous = db::query_as::<CapacityRow>(
            "SELECT occurred_at, incoming_capacity_kwh FROM swap_events WHERE status = 'confirmed' AND occurred_at < ? ORDER BY occurred_at DESC, id DESC LIMIT 1"
        ).bind(from).fetch_optional(&self.pool).await?;
        let mut events = Vec::new();
        if let Some(previous) = previous {
            events.push(previous.into());
        }
        events.extend(db::query_as::<CapacityRow>(
            "SELECT occurred_at, incoming_capacity_kwh FROM swap_events WHERE status = 'confirmed' AND occurred_at >= ? AND occurred_at <= ? ORDER BY occurred_at, id"
        ).bind(from).bind(to).fetch_all(&self.pool).await?
            .into_iter().map(Into::into));
        Ok(events)
    }

    pub async fn count_confirmed_swaps_between(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<i64, StoreError> {
        Ok(db::query_scalar::<i64>(
            "SELECT count(*) FROM swap_events WHERE status = 'confirmed' AND occurred_at >= ? AND occurred_at < ?"
        ).bind(from).bind(to).fetch_one(&self.pool).await?)
    }

    pub async fn charging_estimate_between(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        capacities: Vec<SwapBatteryCapacity>,
    ) -> Result<ChargingEstimate, StoreError> {
        let (sample_from, sample_to) = crate::analytics::charging_sample_window(from, to);
        let mut accumulator = ChargingAccumulator::new(from, to, capacities);
        let mut cursor: Option<(DateTime<Utc>, String)> = None;
        loop {
            let page = if let Some((sampled_at, vehicle_id)) = &cursor {
                db::query_as::<VehicleChargingSample>(
                    "SELECT vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage FROM vehicle_charging_samples WHERE sampled_at >= ? AND sampled_at <= ? AND (sampled_at, vehicle_id) > (?, ?) ORDER BY sampled_at, vehicle_id LIMIT 2048"
                ).bind(sample_from).bind(sample_to).bind(*sampled_at).bind(vehicle_id)
                    .fetch_all(&self.pool).await?
            } else {
                db::query_as::<VehicleChargingSample>(
                    "SELECT vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage FROM vehicle_charging_samples WHERE sampled_at >= ? AND sampled_at <= ? ORDER BY sampled_at, vehicle_id LIMIT 2048"
                ).bind(sample_from).bind(sample_to).fetch_all(&self.pool).await?
            };
            let page_len = page.len();
            if page_len == 0 {
                break;
            }
            cursor = page
                .last()
                .map(|sample| (sample.sampled_at, sample.vehicle_id.clone()));
            for sample in page {
                accumulator.observe(sample);
            }
            if page_len < 2048 {
                break;
            }
        }
        Ok(accumulator.finish())
    }

    pub async fn event_by_id(&self, id: &str) -> Result<Option<SwapEvent>, StoreError> {
        db::query_as::<EventRow>("SELECT * FROM swap_events WHERE id = ?")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
            .map(event_from_row)
            .transpose()
    }

    pub async fn record_poll(
        &self,
        started_at: DateTime<Utc>,
        outcome: &str,
        snapshot_id: Option<&str>,
        message: &str,
    ) -> Result<(), StoreError> {
        db::query(
            "INSERT INTO poll_runs (id, started_at, finished_at, outcome, snapshot_id, message) VALUES (?, ?, ?, ?, ?, ?)"
        )
        .bind(Uuid::new_v4().to_string())
        .bind(started_at)
        .bind(Utc::now())
        .bind(outcome)
        .bind(snapshot_id)
        .bind(message)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn last_poll(&self) -> Result<Option<PollRunSummary>, StoreError> {
        let row = db::query(
            "SELECT started_at, finished_at, outcome, snapshot_id, message FROM poll_runs ORDER BY started_at DESC LIMIT 1"
        ).fetch_optional(&self.pool).await?;
        row.map(|row| -> Result<PollRunSummary, db::Error> {
            Ok(PollRunSummary {
                started_at: row.try_get("started_at")?,
                finished_at: row.try_get("finished_at")?,
                outcome: row.try_get("outcome")?,
                snapshot_id: row.try_get("snapshot_id")?,
                message: row.try_get("message")?,
            })
        })
        .transpose()
        .map_err(StoreError::Database)
    }

    pub async fn counts(&self) -> Result<(i64, i64, i64, i64), StoreError> {
        let row = db::query_as::<CountsRow>(
            r#"SELECT
                 (SELECT COUNT(*) FROM station_snapshots) AS snapshots,
                 (SELECT COUNT(*) FROM swap_events WHERE status = 'observed_candidate') AS candidates,
                 (SELECT COUNT(*) FROM swap_events WHERE status = 'confirmed') AS confirmed,
                 (SELECT COUNT(*) FROM service_orders) AS service_orders"#,
        )
        .fetch_one(&self.pool)
        .await?;
        Ok((
            row.snapshots,
            row.candidates,
            row.confirmed,
            row.service_orders,
        ))
    }

    pub async fn insert_vehicle_snapshot(
        &self,
        snapshot: &VehicleSnapshot,
    ) -> Result<bool, StoreError> {
        let timestamp_millis = snapshot.sampled_at.timestamp_millis();
        let snapshot_key = format!(
            "{}:{timestamp_millis}:{:.4}:{:.4}",
            snapshot.vehicle_id, snapshot.latitude, snapshot.longitude
        );
        let result = db::query(
            r#"INSERT INTO vehicle_snapshots (
                 snapshot_key, vehicle_id, sampled_at, latitude, longitude, soc,
                 remaining_range, remaining_actual_range, mileage,
                 inside_temperature, outside_temperature, created_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(snapshot_key) DO NOTHING"#,
        )
        .bind(snapshot_key)
        .bind(&snapshot.vehicle_id)
        .bind(snapshot.sampled_at)
        .bind(snapshot.latitude)
        .bind(snapshot.longitude)
        .bind(snapshot.soc)
        .bind(snapshot.remaining_range)
        .bind(snapshot.remaining_actual_range)
        .bind(snapshot.mileage)
        .bind(snapshot.inside_temperature)
        .bind(snapshot.outside_temperature)
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected() > 0)
    }

    pub async fn list_vehicle_snapshots(
        &self,
        limit: u32,
    ) -> Result<Vec<VehicleSnapshot>, StoreError> {
        let rows = db::query(
            r#"SELECT vehicle_id, sampled_at, latitude, longitude, soc,
                      remaining_range, remaining_actual_range, mileage,
                      inside_temperature, outside_temperature
               FROM vehicle_snapshots ORDER BY sampled_at DESC LIMIT ?"#,
        )
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                Ok(VehicleSnapshot {
                    vehicle_id: row.try_get("vehicle_id")?,
                    sampled_at: row.try_get("sampled_at")?,
                    latitude: row.try_get("latitude")?,
                    longitude: row.try_get("longitude")?,
                    soc: row.try_get("soc")?,
                    remaining_range: row.try_get("remaining_range")?,
                    remaining_actual_range: row.try_get("remaining_actual_range")?,
                    mileage: row.try_get("mileage")?,
                    inside_temperature: row.try_get("inside_temperature")?,
                    outside_temperature: row.try_get("outside_temperature")?,
                })
            })
            .collect::<Result<Vec<_>, db::Error>>()
            .map_err(StoreError::Database)
    }

    pub async fn insert_vehicle_charging_sample(
        &self,
        sample: &VehicleChargingSample,
    ) -> Result<bool, StoreError> {
        let result = db::query(
            r#"INSERT INTO vehicle_charging_samples (
                 vehicle_id, sampled_at, soc, charge_state,
                 charging_current, charging_power, charging_voltage, created_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(vehicle_id, sampled_at) DO UPDATE SET
                 soc = excluded.soc,
                 charge_state = excluded.charge_state,
                 charging_current = excluded.charging_current,
                 charging_power = excluded.charging_power,
                 charging_voltage = excluded.charging_voltage
               WHERE vehicle_charging_samples.soc IS DISTINCT FROM excluded.soc
                  OR vehicle_charging_samples.charge_state IS DISTINCT FROM excluded.charge_state
                  OR vehicle_charging_samples.charging_current IS DISTINCT FROM excluded.charging_current
                  OR vehicle_charging_samples.charging_power IS DISTINCT FROM excluded.charging_power
                  OR vehicle_charging_samples.charging_voltage IS DISTINCT FROM excluded.charging_voltage"#,
        )
        .bind(&sample.vehicle_id)
        .bind(sample.sampled_at)
        .bind(sample.soc)
        .bind(sample.charge_state)
        .bind(sample.charging_current)
        .bind(sample.charging_power)
        .bind(sample.charging_voltage)
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;

        Ok(result.rows_affected() > 0)
    }

    pub async fn latest_vehicle_charging_session(
        &self,
        limit: u32,
    ) -> Result<Vec<VehicleChargingSample>, StoreError> {
        let samples = self.list_vehicle_charging_samples(limit).await?;
        let mut session = split_charging_sessions(samples)
            .into_iter()
            .next()
            .unwrap_or_default();
        session.reverse();
        Ok(session)
    }

    pub async fn latest_vehicle_charging_session_page(
        &self,
        limit: u32,
    ) -> Result<crate::models::VehicleChargingSamplePage, StoreError> {
        let full_items = self.latest_vehicle_charging_session_full().await?;
        let Some(first) = full_items.first() else {
            return Ok(crate::models::VehicleChargingSamplePage {
                items: Vec::new(),
                energy_kwh: None,
                energy_finalized: false,
            });
        };
        let session_id = charging_session_id(first);
        let mut cached = self.charging_session_energy(&session_id).await?;
        if cached.is_none()
            && full_items
                .last()
                .is_some_and(|last| Utc::now() - last.sampled_at > chrono::Duration::minutes(15))
        {
            self.persist_charging_session_energy(&full_items).await?;
            cached = self.charging_session_energy(&session_id).await?;
        }
        let keep_from = full_items.len().saturating_sub(limit as usize);
        let items = full_items[keep_from..].to_vec();
        Ok(crate::models::VehicleChargingSamplePage {
            energy_kwh: cached
                .or_else(|| crate::analytics::integrated_charging_power_kwh(&full_items)),
            energy_finalized: cached.is_some(),
            items,
        })
    }

    pub async fn finalize_latest_vehicle_charging_session(&self) -> Result<(), StoreError> {
        let items = self.latest_vehicle_charging_session_full().await?;
        self.persist_charging_session_energy(&items).await
    }

    async fn latest_vehicle_charging_session_full(
        &self,
    ) -> Result<Vec<VehicleChargingSample>, StoreError> {
        let Some(summary) = self
            .list_vehicle_charging_sessions(1)
            .await?
            .into_iter()
            .next()
        else {
            return Ok(Vec::new());
        };
        Ok(self
            .vehicle_charging_session(&summary.id)
            .await?
            .unwrap_or_default())
    }

    async fn charging_session_energy(&self, session_id: &str) -> Result<Option<f64>, StoreError> {
        Ok(db::query_as::<ChargingSessionEnergyRow>(
            "SELECT energy_kwh FROM vehicle_charging_session_energy WHERE session_id = ?",
        )
        .bind(session_id)
        .fetch_optional(&self.pool)
        .await?
        .map(|row| row.energy_kwh))
    }

    async fn persist_charging_session_energy(
        &self,
        items: &[VehicleChargingSample],
    ) -> Result<(), StoreError> {
        let (Some(first), Some(last), Some(energy_kwh)) = (
            items.first(),
            items.last(),
            crate::analytics::integrated_charging_power_kwh(items),
        ) else {
            return Ok(());
        };
        let session_id = charging_session_id(first);
        db::query(
            r#"INSERT INTO vehicle_charging_session_energy (
                 session_id, vehicle_id, started_at, ended_at,
                 energy_kwh, sample_count, calculated_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(session_id) DO UPDATE SET
                 ended_at = excluded.ended_at,
                 energy_kwh = excluded.energy_kwh,
                 sample_count = excluded.sample_count,
                 calculated_at = excluded.calculated_at"#,
        )
        .bind(&session_id)
        .bind(&first.vehicle_id)
        .bind(first.sampled_at)
        .bind(last.sampled_at)
        .bind(energy_kwh)
        .bind(items.len() as i64)
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_vehicle_charging_sessions(
        &self,
        limit: u32,
    ) -> Result<Vec<VehicleChargingSession>, StoreError> {
        let mut sessions: Vec<Vec<VehicleChargingSample>> = Vec::new();
        let mut cursor: Option<(DateTime<Utc>, String)> = None;
        loop {
            let page = if let Some((sampled_at, vehicle_id)) = &cursor {
                db::query_as::<VehicleChargingSample>(
                    "SELECT vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage FROM vehicle_charging_samples WHERE (sampled_at, vehicle_id) < (?, ?) ORDER BY sampled_at DESC, vehicle_id DESC LIMIT 2048"
                ).bind(*sampled_at).bind(vehicle_id).fetch_all(&self.pool).await?
            } else {
                db::query_as::<VehicleChargingSample>(
                    "SELECT vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage FROM vehicle_charging_samples ORDER BY sampled_at DESC, vehicle_id DESC LIMIT 2048"
                ).fetch_all(&self.pool).await?
            };
            let page_len = page.len();
            if page_len == 0 {
                break;
            }
            cursor = page
                .last()
                .map(|sample| (sample.sampled_at, sample.vehicle_id.clone()));
            for sample in page {
                let starts_new = sessions
                    .last()
                    .and_then(|session| session.last())
                    .is_some_and(|previous| {
                        previous.vehicle_id != sample.vehicle_id
                            || previous.sampled_at - sample.sampled_at
                                > chrono::Duration::minutes(15)
                    });
                if sessions.is_empty() || starts_new {
                    sessions.push(Vec::new());
                }
                sessions.last_mut().expect("session exists").push(sample);
            }
            // One extra session closes the last requested session at a page boundary.
            if sessions.len() > limit as usize || page_len < 2048 {
                break;
            }
        }
        let mut summaries = sessions
            .into_iter()
            .take(limit as usize)
            .filter_map(|samples| charging_session_summary(&samples))
            .collect::<Vec<_>>();
        for summary in &mut summaries {
            summary.energy_kwh = self.charging_session_energy(&summary.id).await?;
        }
        Ok(summaries)
    }

    pub async fn vehicle_charging_session(
        &self,
        session_id: &str,
    ) -> Result<Option<Vec<VehicleChargingSample>>, StoreError> {
        let Some((millis, vehicle_id)) = session_id.split_once(':') else {
            return Ok(None);
        };
        let Ok(millis) = millis.parse::<i64>() else {
            return Ok(None);
        };
        let Some(start) = Utc.timestamp_millis_opt(millis).single() else {
            return Ok(None);
        };
        let mut samples = Vec::new();
        let mut cursor = start;
        loop {
            let page = if samples.is_empty() {
                db::query_as::<VehicleChargingSample>(
                    "SELECT vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage FROM vehicle_charging_samples WHERE vehicle_id = ? AND sampled_at >= ? ORDER BY sampled_at LIMIT 2048"
                ).bind(vehicle_id).bind(cursor).fetch_all(&self.pool).await?
            } else {
                db::query_as::<VehicleChargingSample>(
                    "SELECT vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage FROM vehicle_charging_samples WHERE vehicle_id = ? AND sampled_at > ? ORDER BY sampled_at LIMIT 2048"
                ).bind(vehicle_id).bind(cursor).fetch_all(&self.pool).await?
            };
            let page_len = page.len();
            if page_len == 0 {
                break;
            }
            if samples.is_empty() && page[0].sampled_at.timestamp_millis() != millis {
                return Ok(None);
            }
            let mut ended = false;
            for sample in page {
                if samples
                    .last()
                    .is_some_and(|previous: &VehicleChargingSample| {
                        sample.sampled_at - previous.sampled_at > chrono::Duration::minutes(15)
                    })
                {
                    ended = true;
                    break;
                }
                cursor = sample.sampled_at;
                samples.push(sample);
            }
            if ended || page_len < 2048 {
                break;
            }
        }
        if samples
            .first()
            .is_none_or(|sample| sample.sampled_at.timestamp_millis() != millis)
        {
            return Ok(None);
        }
        Ok(Some(samples))
    }

    pub async fn vehicle_charging_session_page(
        &self,
        session_id: &str,
    ) -> Result<Option<crate::models::VehicleChargingSamplePage>, StoreError> {
        let Some(items) = self.vehicle_charging_session(session_id).await? else {
            return Ok(None);
        };
        let mut cached = self.charging_session_energy(session_id).await?;
        if cached.is_none()
            && items
                .last()
                .is_some_and(|last| Utc::now() - last.sampled_at > chrono::Duration::minutes(15))
        {
            self.persist_charging_session_energy(&items).await?;
            cached = self.charging_session_energy(session_id).await?;
        }
        Ok(Some(crate::models::VehicleChargingSamplePage {
            energy_kwh: cached.or_else(|| crate::analytics::integrated_charging_power_kwh(&items)),
            energy_finalized: cached.is_some(),
            items,
        }))
    }

    async fn list_vehicle_charging_samples(
        &self,
        limit: u32,
    ) -> Result<Vec<VehicleChargingSample>, StoreError> {
        db::query_as::<VehicleChargingSample>(
            r#"SELECT vehicle_id, sampled_at, soc, charge_state,
                      charging_current, charging_power, charging_voltage
               FROM vehicle_charging_samples
               ORDER BY sampled_at DESC LIMIT ?"#,
        )
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await
        .map_err(StoreError::Database)
    }
}

fn split_charging_sessions(
    samples_descending: Vec<VehicleChargingSample>,
) -> Vec<Vec<VehicleChargingSample>> {
    let mut sessions: Vec<Vec<VehicleChargingSample>> = Vec::new();
    for sample in samples_descending {
        let starts_new_session = sessions
            .last()
            .and_then(|session| session.last())
            .is_some_and(|previous| {
                previous.vehicle_id != sample.vehicle_id
                    || previous.sampled_at.signed_duration_since(sample.sampled_at)
                        > chrono::Duration::minutes(15)
            });
        if sessions.is_empty() || starts_new_session {
            sessions.push(Vec::new());
        }
        if let Some(session) = sessions.last_mut() {
            session.push(sample);
        }
    }
    sessions
}

fn charging_session_summary(
    samples_descending: &[VehicleChargingSample],
) -> Option<VehicleChargingSession> {
    let latest = samples_descending.first()?;
    let earliest = samples_descending.last()?;
    let start_soc = samples_descending
        .iter()
        .rev()
        .find_map(|sample| sample.soc);
    let end_soc = samples_descending.iter().find_map(|sample| sample.soc);
    let peak_power_watts = samples_descending
        .iter()
        .filter_map(|sample| sample.charging_power)
        .filter(|value| value.is_finite())
        .reduce(f64::max);
    Some(VehicleChargingSession {
        id: format!(
            "{}:{}",
            earliest.sampled_at.timestamp_millis(),
            earliest.vehicle_id
        ),
        vehicle_id: earliest.vehicle_id.clone(),
        started_at: earliest.sampled_at,
        ended_at: latest.sampled_at,
        duration_seconds: latest
            .sampled_at
            .signed_duration_since(earliest.sampled_at)
            .num_seconds()
            .max(0),
        start_soc,
        end_soc,
        peak_power_watts,
        energy_kwh: None,
        sample_count: samples_descending.len(),
    })
}

fn charging_session_id(first: &VehicleChargingSample) -> String {
    format!(
        "{}:{}",
        first.sampled_at.timestamp_millis(),
        first.vehicle_id
    )
}

fn candidate_matches(candidate: &EventRow, order: &ImportedOrder) -> bool {
    if let Some(station_key) = order.station_key.as_deref()
        && candidate.station_key.as_deref() != Some(station_key)
    {
        return false;
    }
    if order.station_key.is_none()
        && let Some(station_name) = order.station_name.as_deref()
        && candidate.station_name.as_deref() != Some(station_name)
    {
        return false;
    }
    if let Some(incoming_id) = order
        .incoming_battery
        .as_ref()
        .and_then(|battery| battery.battery_id.as_deref())
        && candidate.incoming_battery_id.as_deref() != Some(incoming_id)
    {
        return false;
    }
    if let Some(outgoing_id) = order
        .outgoing_battery
        .as_ref()
        .and_then(|battery| battery.battery_id.as_deref())
        && candidate.outgoing_battery_id.as_deref() != Some(outgoing_id)
    {
        return false;
    }
    true
}

fn battery_observation_from_row(row: &db::Row) -> Result<BatteryObservation, db::Error> {
    Ok(BatteryObservation {
        battery_id: row.try_get("battery_id")?,
        slot_id: row.try_get("slot_id")?,
        battery_type: row.try_get("battery_type")?,
        capacity_kwh: row.try_get("capacity_kwh")?,
        soc_percent: row.try_get("soc_percent")?,
        occupied: row.try_get::<i64, _>("occupied")? != 0,
        production_date: row.try_get("production_date")?,
    })
}

fn optional_u32(value: Option<i64>) -> Result<Option<u32>, StoreError> {
    value
        .map(|value| {
            u32::try_from(value).map_err(|_| {
                StoreError::InvalidStoredData(
                    "queue value is outside the supported range".to_owned(),
                )
            })
        })
        .transpose()
}

fn event_from_row(row: EventRow) -> Result<SwapEvent, StoreError> {
    let evidence = row
        .evidence
        .map(|value| serde_json::from_str(&value))
        .transpose()
        .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?;
    let payment_items = row
        .payment_items_json
        .map(|value| serde_json::from_str::<Vec<SwapPaymentItem>>(&value))
        .transpose()
        .map_err(|error| StoreError::InvalidStoredData(error.to_string()))?
        .unwrap_or_default();
    Ok(SwapEvent {
        id: row.id,
        status: row.status,
        occurred_at: row.occurred_at,
        station_key: row.station_key,
        station_name: row.station_name,
        station_address: row.station_address,
        order_no: row.order_no,
        order_status_name: row.order_status_name,
        price_amount: row.price_amount,
        price_currency: row.price_currency,
        price_description: row.price_description,
        payment_items,
        exact_energy_kwh: row.exact_energy_kwh,
        estimated_energy_kwh: row.estimated_energy_kwh,
        energy_source: row.energy_source,
        outgoing_battery_id: row.outgoing_battery_id,
        outgoing_production_date: row.outgoing_production_date,
        outgoing_capacity_kwh: row.outgoing_capacity_kwh,
        outgoing_soc_percent: row.outgoing_soc_percent,
        incoming_battery_id: row.incoming_battery_id,
        incoming_production_date: row.incoming_production_date,
        incoming_capacity_kwh: row.incoming_capacity_kwh,
        incoming_soc_percent: row.incoming_soc_percent,
        battery_source: row.battery_source,
        confidence: row.confidence,
        evidence,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn swap_station_from_row(row: SwapStationRow) -> Result<SwapStation, StoreError> {
    Ok(SwapStation {
        station_id: row.station_id,
        station_name: row.station_name,
        station_address: row.station_address,
        latitude: row.latitude,
        longitude: row.longitude,
        operator_id: row.operator_id,
        operator_name: row.operator_name,
        source_order_no: row.source_order_no,
        first_seen_at: row.first_seen_at,
        last_seen_at: row.last_seen_at,
        updated_at: row.updated_at,
    })
}

async fn insert_track_rows(
    conn: &mut AsyncPgConnection,
    vehicle_id: &str,
    rows: &[(&VehicleTripTrack, usize)],
) -> Result<(), db::Error> {
    let placeholders = std::iter::repeat_n("(?, ?, ?, ?, ?, ?, ?, ?, ?)", rows.len())
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "INSERT INTO vehicle_trip_tracks \
         (vehicle_id, journey_id, seq, sampled_at, latitude, longitude, \
          speed_kph, power_consumption, np_status) VALUES {placeholders} \
         ON CONFLICT (vehicle_id, journey_id, seq) DO NOTHING"
    );
    let mut query = db::query(&sql);
    for (track, seq) in rows {
        let point = &track.points[*seq];
        query = query
            .bind(vehicle_id)
            .bind(track.journey_id.as_str())
            .bind(*seq as i64)
            .bind(point.sampled_at)
            .bind(point.latitude)
            .bind(point.longitude)
            .bind(point.speed_kph)
            .bind(point.power_consumption)
            .bind(point.np_status);
    }
    query.execute_conn(conn).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detector::detect_swap;
    use crate::models::ImportedBattery;
    use crate::models::StationSnapshot;
    use chrono::TimeZone;

    #[tokio::test]
    async fn vehicle_profile_keeps_cached_image_when_a_refresh_lacks_it() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let fetched_at = Utc.with_ymd_and_hms(2026, 11, 11, 0, 0, 0).unwrap();
        let profile = VehicleProfile {
            vehicle_id: "v1".to_owned(),
            display_name: Some("我的ET5T".to_owned()),
            model_type: Some("ET5T".to_owned()),
            color: Some("tech_grey".to_owned()),
            image_url: Some("https://cdn-app.nio.com/a.png".to_owned()),
            image_content_type: Some("image/png".to_owned()),
            image_bytes: Some(vec![0x89, b'P', b'N', b'G']),
            image_sha256: Some("deadbeef".to_owned()),
            image_fetched_at: Some(fetched_at),
        };
        store.upsert_vehicle_profile(&profile).await.unwrap();
        let stored = store.vehicle_profile("v1").await.unwrap().unwrap();
        assert_eq!(stored.display_name.as_deref(), Some("我的ET5T"));
        assert!(stored.image_available);
        assert_eq!(stored.image_sha256.as_deref(), Some("deadbeef"));
        let image = store.vehicle_profile_image("v1").await.unwrap().unwrap();
        assert_eq!(image.content_type, "image/png");
        assert_eq!(image.sha256.as_deref(), Some("deadbeef"));
        assert_eq!(image.bytes, vec![0x89, b'P', b'N', b'G']);

        // A refresh whose download failed must not erase the cached bytes.
        let mut retry = profile.clone();
        retry.image_bytes = None;
        retry.image_content_type = None;
        retry.image_sha256 = None;
        retry.image_fetched_at = None;
        retry.color = Some("black".to_owned());
        store.upsert_vehicle_profile(&retry).await.unwrap();
        let stored = store.vehicle_profile("v1").await.unwrap().unwrap();
        assert_eq!(stored.color.as_deref(), Some("black"));
        assert!(stored.image_available);
        assert_eq!(
            store
                .vehicle_profile_image("v1")
                .await
                .unwrap()
                .unwrap()
                .bytes,
            vec![0x89, b'P', b'N', b'G']
        );

        // A different URL can never retain bytes belonging to the old URL.
        let mut changed_url = retry.clone();
        changed_url.image_url = Some("https://cdn-app.nio.com/b.png".to_owned());
        store.upsert_vehicle_profile(&changed_url).await.unwrap();
        let stored = store.vehicle_profile("v1").await.unwrap().unwrap();
        assert_eq!(
            stored.image_url.as_deref(),
            Some("https://cdn-app.nio.com/b.png")
        );
        assert!(!stored.image_available);
        assert!(store.vehicle_profile_image("v1").await.unwrap().is_none());

        // Removing the upstream image clears all cached image metadata.
        changed_url.image_url = None;
        store.upsert_vehicle_profile(&changed_url).await.unwrap();
        let stored = store.vehicle_profile("v1").await.unwrap().unwrap();
        assert!(stored.image_url.is_none());
        assert!(!stored.image_available);

        assert!(store.vehicle_profile("v2").await.unwrap().is_none());
        assert!(store.vehicle_profile_image("v2").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn bulk_track_insert_is_idempotent_per_journey() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let point = |seq: usize| VehicleTripTrackPoint {
            sampled_at: Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, seq as u32).unwrap(),
            latitude: 39.1,
            longitude: 117.7,
            speed_kph: Some(10.0),
            power_consumption: None,
            np_status: None,
        };
        let track = |id: &str, count: usize| VehicleTripTrack {
            journey_id: id.to_owned(),
            points: (0..count).map(point).collect(),
        };
        let tracks = vec![track("a", 3), track("b", 2)];
        store
            .insert_vehicle_trip_tracks("vehicle-1", &tracks)
            .await
            .unwrap();
        assert_eq!(
            store
                .vehicle_trip_track("vehicle-1", "a")
                .await
                .unwrap()
                .len(),
            3
        );
        // A concurrent sync may have stored the same journey; re-inserting must
        // not fail on the primary key or duplicate points.
        store
            .insert_vehicle_trip_tracks("vehicle-1", &tracks)
            .await
            .unwrap();
        assert_eq!(
            store
                .vehicle_trip_track("vehicle-1", "b")
                .await
                .unwrap()
                .len(),
            2
        );
        assert!(
            store
                .vehicle_trip_track("vehicle-2", "a")
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn track_backfill_selects_only_unscanned_trips_without_points() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let location = crate::models::VehicleTripLocation {
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
        let trip = |id: &str, hour: u32| VehicleTrip {
            id: id.to_owned(),
            trip_id: Some(id.to_owned()),
            started_at: Utc.with_ymd_and_hms(2026, 10, 1, hour, 0, 0).unwrap(),
            ended_at: Utc.with_ymd_and_hms(2026, 10, 1, hour, 10, 0).unwrap(),
            distance_kilometers: 5.0,
            duration_minutes: 10,
            start_location: location.clone(),
            end_location: location.clone(),
            average_speed_kph: Some(30.0),
            average_energy_consumption_kwh_per_100km: None,
            energy_consumed_kwh: None,
            maximum_speed_kph: None,
            odometer_kilometers: None,
            rapid_acceleration_count: None,
            rapid_deceleration_count: None,
            rapid_swerve_count: None,
            is_combined: false,
        };
        store
            .upsert_vehicle_trips("vehicle-1", &[trip("older", 8), trip("newer", 9)])
            .await
            .unwrap();

        // Newest first, and scoped to the vehicle.
        assert_eq!(
            store
                .vehicle_trip_ids_missing_tracks("vehicle-1", 10)
                .await
                .unwrap(),
            vec!["newer".to_owned(), "older".to_owned()]
        );
        assert!(
            store
                .vehicle_trip_ids_missing_tracks("vehicle-2", 10)
                .await
                .unwrap()
                .is_empty()
        );

        // A journey with points is no longer pending even without a scan mark.
        let point = VehicleTripTrackPoint {
            sampled_at: Utc.with_ymd_and_hms(2026, 10, 1, 9, 0, 0).unwrap(),
            latitude: 39.1,
            longitude: 117.7,
            speed_kph: Some(10.0),
            power_consumption: None,
            np_status: None,
        };
        store
            .store_vehicle_trip_tracks(
                "vehicle-1",
                &[VehicleTripTrack {
                    journey_id: "newer".to_owned(),
                    points: vec![point],
                }],
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .vehicle_trip_ids_missing_tracks("vehicle-1", 10)
                .await
                .unwrap(),
            vec!["older".to_owned()]
        );

        // Marking a scanned-but-empty journey removes it from the pending list.
        store
            .mark_trips_track_scanned("vehicle-1", &["older".to_owned()])
            .await
            .unwrap();
        assert!(
            store
                .vehicle_trip_ids_missing_tracks("vehicle-1", 10)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn vehicle_trip_tracks_rewrite_when_content_changes() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let point = |offset: u32| VehicleTripTrackPoint {
            sampled_at: Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, offset).unwrap(),
            latitude: 39.1 + f64::from(offset) * 0.001,
            longitude: 117.7,
            speed_kph: Some(f64::from(offset) * 10.0),
            power_consumption: Some(-1.5),
            np_status: Some(0),
        };
        let track = VehicleTripTrack {
            journey_id: "journey-1".to_owned(),
            points: vec![point(0), point(1)],
        };
        store
            .store_vehicle_trip_tracks("vehicle-1", std::slice::from_ref(&track))
            .await
            .unwrap();
        // `row_to_json` renders float8 with the shortest round-tripping text, so
        // coordinates come back within floating-point epsilon, not bit-identical.
        let stored = store
            .vehicle_trip_track("vehicle-1", "journey-1")
            .await
            .unwrap();
        assert_eq!(stored.len(), 2);
        assert_eq!(stored[1].sampled_at, track.points[1].sampled_at);
        assert_eq!(stored[1].speed_kph, track.points[1].speed_kph);
        assert_eq!(stored[1].np_status, track.points[1].np_status);
        assert!((stored[1].latitude - track.points[1].latitude).abs() < 1e-9);

        // A steady-state sync must not duplicate the unchanged track.
        store
            .store_vehicle_trip_tracks("vehicle-1", std::slice::from_ref(&track))
            .await
            .unwrap();
        assert_eq!(
            store
                .vehicle_trip_track("vehicle-1", "journey-1")
                .await
                .unwrap()
                .len(),
            2
        );

        // Upstream may correct a point without changing the point count.
        let mut corrected = track.clone();
        corrected.points[1].latitude = 40.25;
        corrected.points[1].speed_kph = Some(42.0);
        store
            .store_vehicle_trip_tracks("vehicle-1", std::slice::from_ref(&corrected))
            .await
            .unwrap();
        let stored = store
            .vehicle_trip_track("vehicle-1", "journey-1")
            .await
            .unwrap();
        assert_eq!(stored.len(), 2);
        assert!((stored[1].latitude - 40.25).abs() < 1e-9);
        assert_eq!(stored[1].speed_kph, Some(42.0));

        // A growing journey is replaced, not appended to.
        let grown = VehicleTripTrack {
            journey_id: "journey-1".to_owned(),
            points: vec![point(0), point(1), point(2)],
        };
        store
            .store_vehicle_trip_tracks("vehicle-1", std::slice::from_ref(&grown))
            .await
            .unwrap();
        let stored = store
            .vehicle_trip_track("vehicle-1", "journey-1")
            .await
            .unwrap();
        assert_eq!(stored.len(), 3);
        assert_eq!(stored[2].sampled_at, grown.points[2].sampled_at);
        assert!((stored[2].latitude - grown.points[2].latitude).abs() < 1e-9);
        // Tracks stay vehicle-scoped.
        assert!(
            store
                .vehicle_trip_track("vehicle-2", "journey-1")
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn vehicle_trips_upsert_preserves_missing_metrics_and_isolates_vehicles() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let location = crate::models::VehicleTripLocation {
            address: Some("起点".to_owned()),
            poi: None,
            road_name: None,
            town: None,
            district: None,
            city: None,
            province: None,
            latitude: None,
            longitude: None,
        };
        let mut trip = VehicleTrip {
            id: "journey-1".to_owned(),
            trip_id: Some("trip-1".to_owned()),
            started_at: Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, 0).unwrap(),
            ended_at: Utc.with_ymd_and_hms(2026, 10, 1, 8, 10, 0).unwrap(),
            distance_kilometers: 5.6,
            duration_minutes: 10,
            start_location: location.clone(),
            end_location: location,
            average_speed_kph: Some(30.0),
            average_energy_consumption_kwh_per_100km: Some(0.9 / 5.6 * 100.0),
            energy_consumed_kwh: Some(0.9),
            maximum_speed_kph: Some(52.0),
            odometer_kilometers: Some(1234.5),
            rapid_acceleration_count: Some(1),
            rapid_deceleration_count: Some(2),
            rapid_swerve_count: Some(0),
            is_combined: false,
        };
        store
            .upsert_vehicle_trips("vehicle-1", &[trip.clone()])
            .await
            .unwrap();
        trip.start_location.address = None;
        trip.distance_kilometers = 5.0;
        trip.energy_consumed_kwh = None;
        trip.average_energy_consumption_kwh_per_100km = None;
        trip.maximum_speed_kph = None;
        trip.odometer_kilometers = None;
        trip.rapid_acceleration_count = Some(0);
        trip.rapid_deceleration_count = None;
        trip.rapid_swerve_count = None;
        store
            .upsert_vehicle_trips("vehicle-1", &[trip.clone()])
            .await
            .unwrap();
        store
            .upsert_vehicle_trips("vehicle-2", &[trip])
            .await
            .unwrap();

        let rows = db::query("SELECT * FROM vehicle_trips ORDER BY vehicle_id")
            .fetch_all(&store.pool)
            .await
            .unwrap();
        assert_eq!(rows.len(), 2);
        let row = &rows[0];
        assert_eq!(row.try_get::<f64, _>("distance_kilometers").unwrap(), 5.6);
        assert!(
            (row.try_get::<f64, _>("average_energy_consumption_kwh_per_100km")
                .unwrap()
                - 0.9 / 5.6 * 100.0)
                .abs()
                < 1e-9
        );
        assert_eq!(row.try_get::<f64, _>("maximum_speed_kph").unwrap(), 52.0);
        assert_eq!(
            row.try_get::<f64, _>("odometer_kilometers").unwrap(),
            1234.5
        );
        assert_eq!(
            row.try_get::<i64, _>("rapid_acceleration_count").unwrap(),
            1
        );
        assert_eq!(
            row.try_get::<i64, _>("rapid_deceleration_count").unwrap(),
            2
        );
        assert_eq!(row.try_get::<i64, _>("rapid_swerve_count").unwrap(), 0);
        assert_eq!(
            row.try_get::<serde_json::Value, _>("start_location")
                .unwrap()["address"],
            "起点"
        );
        assert_eq!(
            rows[1]
                .try_get::<Option<f64>, _>("maximum_speed_kph")
                .unwrap(),
            None
        );

        let mut refreshed = VehicleTrip {
            id: "journey-1".to_owned(),
            trip_id: None,
            started_at: Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, 0).unwrap(),
            ended_at: Utc.with_ymd_and_hms(2026, 10, 1, 8, 10, 0).unwrap(),
            distance_kilometers: 5.0,
            duration_minutes: 10,
            start_location: crate::models::VehicleTripLocation {
                address: None,
                poi: None,
                road_name: None,
                town: None,
                district: None,
                city: None,
                province: None,
                latitude: None,
                longitude: None,
            },
            end_location: crate::models::VehicleTripLocation {
                address: None,
                poi: None,
                road_name: None,
                town: None,
                district: None,
                city: None,
                province: None,
                latitude: None,
                longitude: None,
            },
            average_speed_kph: None,
            average_energy_consumption_kwh_per_100km: Some(20.0),
            energy_consumed_kwh: Some(1.0),
            maximum_speed_kph: None,
            odometer_kilometers: None,
            rapid_acceleration_count: None,
            rapid_deceleration_count: None,
            rapid_swerve_count: None,
            is_combined: false,
        };
        store
            .upsert_vehicle_trips("vehicle-1", &[refreshed.clone()])
            .await
            .unwrap();
        let row = db::query("SELECT distance_kilometers, average_energy_consumption_kwh_per_100km FROM vehicle_trips WHERE vehicle_id = 'vehicle-1'")
            .fetch_one(&store.pool).await.unwrap();
        assert_eq!(row.try_get::<f64, _>("distance_kilometers").unwrap(), 5.6);
        assert!(
            (row.try_get::<f64, _>("average_energy_consumption_kwh_per_100km")
                .unwrap()
                - 1.0 / 5.6 * 100.0)
                .abs()
                < 1e-9
        );
        refreshed.distance_kilometers = 5.8;
        refreshed.average_energy_consumption_kwh_per_100km = Some(1.0 / 5.8 * 100.0);
        store
            .upsert_vehicle_trips("vehicle-1", &[refreshed.clone()])
            .await
            .unwrap();
        let row = db::query("SELECT distance_kilometers, average_energy_consumption_kwh_per_100km FROM vehicle_trips WHERE vehicle_id = 'vehicle-1'")
            .fetch_one(&store.pool).await.unwrap();
        assert_eq!(row.try_get::<f64, _>("distance_kilometers").unwrap(), 5.8);
        assert!(
            (row.try_get::<f64, _>("average_energy_consumption_kwh_per_100km")
                .unwrap()
                - 1.0 / 5.8 * 100.0)
                .abs()
                < 1e-9
        );

        let page = store.vehicle_trips("vehicle-1", 20, None).await.unwrap();
        assert_eq!(page.items.len(), 1);
        assert!(!page.has_more);
        assert_eq!(page.server_time, None);
        assert_eq!(page.items[0].distance_kilometers, 5.8);
        assert_eq!(page.items[0].rapid_deceleration_count, Some(2));
        assert!(
            store
                .vehicle_trips("vehicle-2", 20, None)
                .await
                .unwrap()
                .items[0]
                .maximum_speed_kph
                .is_none()
        );
        let mut older = refreshed.clone();
        older.id = "older".into();
        older.started_at -= chrono::Duration::days(1);
        older.ended_at -= chrono::Duration::days(1);
        store
            .upsert_vehicle_trips("vehicle-1", &[older.clone()])
            .await
            .unwrap();
        let newest = store.vehicle_trips("vehicle-1", 1, None).await.unwrap();
        assert_eq!(newest.items[0].id, refreshed.id);
        assert!(newest.has_more);
        assert_eq!(
            newest.next_query_time,
            Some(refreshed.started_at.timestamp())
        );
        let previous = store
            .vehicle_trips("vehicle-1", 1, newest.next_query_time)
            .await
            .unwrap();
        assert_eq!(previous.items[0].id, older.id);
        assert!(!previous.has_more);

        let mut same_second = refreshed.clone();
        same_second.id = "same-second".into();
        store
            .upsert_vehicle_trips("vehicle-1", &[same_second])
            .await
            .unwrap();
        let tied = store.vehicle_trips("vehicle-1", 1, None).await.unwrap();
        assert_eq!(tied.items.len(), 2);
        assert!(tied.has_more);
        assert_eq!(tied.next_query_time, Some(refreshed.started_at.timestamp()));
        assert_eq!(
            store
                .vehicle_trips("vehicle-1", 1, tied.next_query_time)
                .await
                .unwrap()
                .items[0]
                .id,
            older.id
        );
    }

    #[tokio::test]
    async fn trip_sync_checkpoints_survive_reopening_store() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        assert!(
            !store
                .vehicle_trip_sync_state("vehicle-1")
                .await
                .unwrap()
                .backfill_completed
        );
        let state = VehicleTripSyncState {
            backfill_cursor: Some(100),
            backfill_completed: false,
            forward_cursor: Some(200),
            covered_before: Some(Utc.with_ymd_and_hms(2026, 10, 1, 8, 0, 0).unwrap()),
            forward_started_at: Some(Utc.with_ymd_and_hms(2026, 10, 2, 8, 0, 0).unwrap()),
        };
        store
            .save_vehicle_trip_sync_state("vehicle-1", &state)
            .await
            .unwrap();
        let restored = store.vehicle_trip_sync_state("vehicle-1").await.unwrap();
        assert_eq!(restored.backfill_cursor, Some(100));
        assert_eq!(restored.forward_cursor, Some(200));
        assert_eq!(restored.covered_before, state.covered_before);
        assert_eq!(restored.forward_started_at, state.forward_started_at);
        assert!(!restored.backfill_completed);
        store
            .save_vehicle_trip_sync_state(
                "vehicle-1",
                &VehicleTripSyncState {
                    backfill_cursor: None,
                    backfill_completed: true,
                    forward_cursor: None,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(
            store
                .vehicle_trip_sync_state("vehicle-1")
                .await
                .unwrap()
                .backfill_completed
        );
        assert!(
            !store
                .vehicle_trip_sync_state("vehicle-2")
                .await
                .unwrap()
                .backfill_completed
        );
    }

    #[tokio::test]
    async fn history_queries_use_targeted_indexes() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        for (sql, expected_index) in [
            (
                "SELECT indexname AS detail FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'vehicle_snapshots'",
                "idx_vehicle_snapshots_vehicle_time",
            ),
            (
                "SELECT indexname AS detail FROM pg_indexes WHERE schemaname = current_schema() AND tablename = 'swap_events'",
                "idx_swap_events_confirmed_time",
            ),
        ] {
            let rows = db::query(sql).fetch_all(&store.pool).await.unwrap();
            assert!(rows.iter().any(|row| {
                row.try_get::<String, _>("detail")
                    .unwrap()
                    .contains(expected_index)
            }));
        }
    }

    fn observed_battery(id: &str, capacity_kwh: f64, soc_percent: f64) -> BatteryObservation {
        BatteryObservation {
            battery_id: id.to_owned(),
            slot_id: None,
            battery_type: Some(format!("{capacity_kwh} kWh")),
            capacity_kwh: Some(capacity_kwh),
            soc_percent: Some(soc_percent),
            occupied: false,
            production_date: None,
        }
    }

    #[tokio::test]
    async fn upserts_and_queries_station_directory_by_stable_id() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let first_seen = Utc.with_ymd_and_hms(2026, 9, 1, 8, 0, 0).unwrap();
        let last_seen = Utc.with_ymd_and_hms(2026, 10, 9, 12, 0, 0).unwrap();
        let station = ObservedSwapStation {
            station_id: "PS-NIO-3606da31-f8539ae9".to_owned(),
            station_name: "天津红星美凯龙滨海店 蔚来换电站".to_owned(),
            station_address: Some("天津市滨海新区".to_owned()),
            operator_id: Some("NIO".to_owned()),
            operator_name: Some("NIO Power".to_owned()),
            source_order_no: "newer-order".to_owned(),
            observed_at: last_seen,
        };
        store.upsert_swap_station(&station).await.unwrap();
        let mut older_station = station.clone();
        older_station.station_name = "历史旧名称".to_owned();
        older_station.source_order_no = "older-order".to_owned();
        older_station.observed_at = first_seen;
        store.upsert_swap_station(&older_station).await.unwrap();

        let stored = store
            .swap_station_by_id(&station.station_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored.station_name, station.station_name);
        assert_eq!(stored.first_seen_at, first_seen);
        assert_eq!(stored.last_seen_at, last_seen);
        assert_eq!(stored.source_order_no.as_deref(), Some("newer-order"));
        assert_eq!(stored.latitude, None);
        assert_eq!(stored.longitude, None);
        assert_eq!(
            store
                .swap_stations_missing_coordinates()
                .await
                .unwrap()
                .len(),
            1
        );
        store
            .upsert_searched_swap_station(
                &station.station_id,
                &station.station_name,
                station.station_address.as_deref(),
                39.904213,
                116.407423,
            )
            .await
            .unwrap();
        let stored = store
            .swap_station_by_id(&station.station_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored.latitude, Some(39.904213));
        assert_eq!(stored.longitude, Some(116.407423));
        assert!(
            store
                .swap_stations_missing_coordinates()
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store.list_swap_stations(10, 0, None).await.unwrap(),
            vec![stored]
        );
        assert_eq!(
            store
                .list_swap_stations(10, 0, Some("红星美凯龙"))
                .await
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn imports_and_updates_same_order_idempotently() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let order = ImportedOrder {
            order_no: "order-1".to_owned(),
            occurred_at: Utc.with_ymd_and_hms(2026, 10, 9, 12, 0, 0).unwrap(),
            station_key: Some("station".to_owned()),
            station_name: Some("Station".to_owned()),
            station_address: None,
            order_status_name: None,
            price_amount: None,
            price_currency: None,
            price_description: None,
            payment_items: vec![],
            energy_kwh: Some(55.5),
            outgoing_battery: Some(ImportedBattery {
                battery_id: Some("outgoing".to_owned()),
                production_date: None,
                capacity_kwh: Some(75.0),
                soc_percent: Some(18.0),
            }),
            incoming_battery: Some(ImportedBattery {
                battery_id: Some("incoming".to_owned()),
                production_date: None,
                capacity_kwh: Some(100.0),
                soc_percent: Some(93.0),
            }),
            raw_payload: None,
        };
        let first = store
            .import_order(&order, Duration::from_secs(1800))
            .await
            .unwrap();
        let mut partial_retry = order.clone();
        partial_retry.outgoing_battery = None;
        partial_retry.incoming_battery = None;
        let second = store
            .import_order(&partial_retry, Duration::from_secs(1800))
            .await
            .unwrap();
        assert_eq!(first.id, second.id);
        assert_eq!(first.confidence, "exact");
        assert_eq!(second.confidence, "exact");
        assert_eq!(second.incoming_battery_id.as_deref(), Some("incoming"));
        assert_eq!(store.list_events(10, 0, true).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn matching_order_confirms_existing_station_candidate() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let previous_time = Utc.with_ymd_and_hms(2026, 10, 9, 11, 59, 0).unwrap();
        let current_time = Utc.with_ymd_and_hms(2026, 10, 9, 12, 0, 0).unwrap();
        let previous = StationSnapshot {
            station_key: "station".to_owned(),
            station_name: "Station".to_owned(),
            address: None,
            captured_at: previous_time,
            batteries: vec![
                observed_battery("kept", 75.0, 80.0),
                observed_battery("incoming", 100.0, 93.0),
            ],
            current_fees: vec![],
        };
        let current = StationSnapshot {
            station_key: "station".to_owned(),
            station_name: "Station".to_owned(),
            address: None,
            captured_at: current_time,
            batteries: vec![
                observed_battery("kept", 75.0, 81.0),
                observed_battery("outgoing", 75.0, 18.0),
            ],
            current_fees: vec![],
        };
        let previous_id = store.insert_snapshot(&previous).await.unwrap();
        let current_id = store.insert_snapshot(&current).await.unwrap();
        let detected = detect_swap(&previous.batteries, &current.batteries).unwrap();
        let candidate_id = store
            .insert_candidate(&previous_id, &current_id, &current, &detected)
            .await
            .unwrap();

        let order = ImportedOrder {
            order_no: "matched-order".to_owned(),
            occurred_at: current_time + chrono::Duration::minutes(2),
            station_key: Some("station".to_owned()),
            station_name: Some("Station".to_owned()),
            station_address: None,
            order_status_name: None,
            price_amount: None,
            price_currency: None,
            price_description: None,
            payment_items: vec![],
            energy_kwh: Some(55.2),
            outgoing_battery: None,
            incoming_battery: None,
            raw_payload: None,
        };
        let confirmed = store
            .import_order(&order, Duration::from_secs(1_800))
            .await
            .unwrap();

        assert_eq!(confirmed.id, candidate_id);
        assert_eq!(confirmed.status, "confirmed");
        assert_eq!(confirmed.order_no.as_deref(), Some("matched-order"));
        assert_eq!(confirmed.incoming_battery_id.as_deref(), Some("incoming"));
        assert_eq!(confirmed.outgoing_battery_id.as_deref(), Some("outgoing"));
        assert_eq!(confirmed.exact_energy_kwh, Some(55.2));
        assert_eq!(confirmed.estimated_energy_kwh, Some(79.5));
        assert_eq!(store.counts().await.unwrap(), (2, 0, 1, 0));
    }

    #[tokio::test]
    async fn service_order_baseline_is_idempotent_until_station_changes() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let mut order = ObservedServiceOrder {
            order_no: "active-order".to_owned(),
            order_type: "pe_shaman_change".to_owned(),
            order_status: Some("30".to_owned()),
            order_status_name: Some("进行中".to_owned()),
            created_at: Utc.with_ymd_and_hms(2026, 10, 9, 12, 0, 0).unwrap(),
            vehicle_id: Some("vehicle-1".to_owned()),
            vin_code: Some("VIN-1".to_owned()),
            station_key: Some("station-1".to_owned()),
            station_name: Some("Station 1".to_owned()),
            station_address: None,
            raw_payload: serde_json::json!({"orderNo": "active-order"}),
        };

        let first = store.observe_service_order(&order).await.unwrap();
        assert!(first.is_new_or_changed);
        assert!(first.needs_baseline);
        store
            .set_active_service_orders(&[order.order_no.clone()])
            .await
            .unwrap();
        let active = store.list_active_service_orders(20).await.unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].order_no, "active-order");

        let queue_observed_at = order.created_at + chrono::Duration::seconds(15);
        store
            .update_service_order_queue(&ObservedServiceOrderQueue {
                order_no: order.order_no.clone(),
                queue_number: Some(2),
                target_battery_cap_level: Some(1),
                vehicles_ahead: Some(1),
                estimated_wait_minutes: Some(5),
                estimated_wait_source: Some("station_queue_estimate".to_owned()),
                queue_status_text: Some("正在排队".to_owned()),
                observed_at: queue_observed_at,
            })
            .await
            .unwrap();
        let active = store.list_active_service_orders(20).await.unwrap();
        assert_eq!(active[0].queue_number, Some(2));
        assert_eq!(active[0].vehicles_ahead, Some(1));
        assert_eq!(active[0].estimated_wait_minutes, Some(5));
        assert_eq!(active[0].queue_updated_at, Some(queue_observed_at));

        let snapshot = StationSnapshot {
            station_key: "station-1".to_owned(),
            station_name: "Station 1".to_owned(),
            address: None,
            captured_at: order.created_at,
            batteries: vec![],
            current_fees: vec![],
        };
        let snapshot_id = store.insert_snapshot(&snapshot).await.unwrap();
        store
            .mark_service_order_baseline(&order.order_no, &snapshot_id)
            .await
            .unwrap();

        let unchanged = store.observe_service_order(&order).await.unwrap();
        assert!(!unchanged.is_new_or_changed);
        assert!(!unchanged.needs_baseline);

        let mut omitted_station = order.clone();
        omitted_station.station_key = None;
        omitted_station.station_name = None;
        omitted_station.station_address = None;
        let omitted = store.observe_service_order(&omitted_station).await.unwrap();
        assert!(!omitted.is_new_or_changed);
        assert!(!omitted.needs_baseline);
        let baselines = store
            .active_order_baselines_for_station("station-1")
            .await
            .unwrap();
        assert_eq!(baselines.len(), 1);
        assert_eq!(baselines[0].snapshot_id, snapshot_id);

        order.order_status = Some("31".to_owned());
        let status_changed = store.observe_service_order(&order).await.unwrap();
        assert!(status_changed.is_new_or_changed);
        assert!(!status_changed.needs_baseline);

        order.station_key = Some("station-2".to_owned());
        order.station_name = Some("Station 2".to_owned());
        let station_changed = store.observe_service_order(&order).await.unwrap();
        assert!(station_changed.is_new_or_changed);
        assert!(station_changed.needs_baseline);
        store.set_active_service_orders(&[]).await.unwrap();
        assert!(
            store
                .list_active_service_orders(20)
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(store.counts().await.unwrap(), (1, 0, 0, 1));
    }

    #[tokio::test]
    async fn vehicle_snapshots_are_idempotent_and_listed_newest_first() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let first = VehicleSnapshot {
            vehicle_id: "vehicle-1".to_owned(),
            sampled_at: Utc.with_ymd_and_hms(2026, 10, 9, 8, 0, 0).unwrap(),
            latitude: 31.2304,
            longitude: 121.4737,
            soc: Some(80.0),
            remaining_range: Some(400.0),
            remaining_actual_range: Some(360.0),
            mileage: Some(10_000.0),
            inside_temperature: Some(24.0),
            outside_temperature: Some(20.0),
        };
        assert!(store.insert_vehicle_snapshot(&first).await.unwrap());
        assert!(!store.insert_vehicle_snapshot(&first).await.unwrap());

        let mut second = first.clone();
        second.sampled_at += chrono::Duration::minutes(10);
        second.latitude = 31.231;
        assert!(store.insert_vehicle_snapshot(&second).await.unwrap());

        let items = store.list_vehicle_snapshots(20).await.unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].sampled_at, second.sampled_at);
        assert_eq!(items[1].sampled_at, first.sampled_at);
    }

    #[tokio::test]
    async fn charging_samples_are_idempotent_and_split_on_long_gap() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let first = VehicleChargingSample {
            vehicle_id: "vehicle-1".to_owned(),
            sampled_at: Utc.with_ymd_and_hms(2026, 10, 9, 8, 0, 0).unwrap(),
            soc: Some(40.0),
            charge_state: 1,
            charging_current: Some(31.0),
            charging_power: Some(11_000.0),
            charging_voltage: Some(358.0),
        };
        assert!(store.insert_vehicle_charging_sample(&first).await.unwrap());
        assert!(!store.insert_vehicle_charging_sample(&first).await.unwrap());

        let mut second = first.clone();
        second.sampled_at += chrono::Duration::minutes(1);
        second.soc = Some(41.0);
        store.insert_vehicle_charging_sample(&second).await.unwrap();

        let mut latest = second.clone();
        latest.sampled_at += chrono::Duration::hours(1);
        latest.soc = Some(60.0);
        store.insert_vehicle_charging_sample(&latest).await.unwrap();

        let session = store.latest_vehicle_charging_session(5_000).await.unwrap();
        assert_eq!(session, vec![latest.clone()]);

        let sessions = store.list_vehicle_charging_sessions(20).await.unwrap();
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].sample_count, 1);
        assert_eq!(sessions[0].start_soc, Some(60.0));
        assert_eq!(sessions[1].sample_count, 2);
        assert_eq!(sessions[1].start_soc, Some(40.0));
        assert_eq!(sessions[1].end_soc, Some(41.0));
        assert_eq!(sessions[1].duration_seconds, 60);

        let detail = store
            .vehicle_charging_session(&sessions[1].id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail, vec![first, second]);

        let detail_page = store
            .vehicle_charging_session_page(&sessions[1].id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(detail_page.energy_kwh, Some(0.18));
        assert!(detail_page.energy_finalized);
        let refreshed = store.list_vehicle_charging_sessions(20).await.unwrap();
        assert_eq!(refreshed[1].energy_kwh, Some(0.18));
    }

    #[tokio::test]
    async fn charging_statistics_stream_across_database_pages() {
        let Ok(store) = Store::in_memory().await else {
            return;
        };
        let from = Utc.with_ymd_and_hms(2026, 10, 1, 0, 0, 0).unwrap();
        let to = from + chrono::Duration::seconds(20_490);
        db::query(
            "INSERT INTO vehicle_charging_samples (vehicle_id, sampled_at, soc, charge_state, charging_current, charging_power, charging_voltage, created_at) SELECT 'stream-test', t, NULL, 1, NULL, 3600.0, NULL, now() FROM generate_series(?::timestamptz, ?::timestamptz, interval '10 seconds') t"
        ).bind(from).bind(to).execute(&store.pool).await.unwrap();
        let estimate = store
            .charging_estimate_between(from, to, vec![])
            .await
            .unwrap();
        let stats = crate::analytics::calculate(from, to, &[], &estimate, 0);
        assert_eq!(stats.charging_sample_count, 2_050);
        assert_eq!(stats.charging_energy_kwh_estimated, Some(20.49));
        assert_eq!(stats.charging_segments_from_power, 2_049);
    }
}
