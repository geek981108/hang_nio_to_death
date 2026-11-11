//! One-shot backfill of journey GPS tracks.
//!
//! The regular sync only fetches per-journey details for the pages it is still
//! walking through. Once `vehicle_trip_sync.backfill_completed` is set it only
//! polls the newest handful of journeys, so trips stored before the track
//! columns existed are never revisited and stay without a track. This command
//! closes that gap, and can be re-run later to fill new holes.
//!
//! Requests run in fixed-size batches: a whole batch is in flight, then its
//! results are written in one transaction. Batching keeps throughput high
//! without holding one enormous join set for the whole history.

use std::{
    future::Future,
    pin::Pin,
    sync::Arc,
    time::{Duration, Instant},
};

use tokio::task::JoinSet;

use crate::{
    config::Config,
    models::{VehicleTripTrack, VehicleTripTrackPoint},
    store::Store,
    tenant_config::{self, ConfigCipher},
    vehicle::NioVehicleClient,
};

/// Detail requests in flight per batch. Upstream tolerates this for a private
/// account; lower it with `--concurrency` if the API starts refusing requests.
const DEFAULT_CONCURRENCY: usize = 100;
const MAX_CONCURRENCY: usize = 256;
/// Pause between batches, so a long backfill is not one continuous burst.
const BATCH_PAUSE: Duration = Duration::from_millis(200);
const DEFAULT_LIMIT: usize = 5_000;

#[derive(Debug, Default, PartialEq)]
pub struct Options {
    pub tenant: Option<String>,
    pub limit: usize,
    pub concurrency: usize,
    pub dry_run: bool,
    pub verbose: bool,
}

impl Options {
    pub fn parse(args: &[String]) -> Result<Self, String> {
        let mut options = Options {
            limit: DEFAULT_LIMIT,
            concurrency: DEFAULT_CONCURRENCY,
            ..Options::default()
        };
        let mut iter = args.iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--dry-run" => options.dry_run = true,
                "--verbose" => options.verbose = true,
                "--tenant" => {
                    options.tenant = Some(
                        iter.next()
                            .ok_or("--tenant requires a tenant slug")?
                            .to_owned(),
                    );
                }
                "--limit" => {
                    let value = iter.next().ok_or("--limit requires a number")?;
                    options.limit = value
                        .parse::<usize>()
                        .map_err(|_| format!("--limit is not a number: {value}"))?;
                    if options.limit == 0 {
                        return Err("--limit must be at least 1".to_owned());
                    }
                }
                "--concurrency" => {
                    let value = iter.next().ok_or("--concurrency requires a number")?;
                    let concurrency = value
                        .parse::<usize>()
                        .map_err(|_| format!("--concurrency is not a number: {value}"))?;
                    if concurrency == 0 || concurrency > MAX_CONCURRENCY {
                        return Err(format!(
                            "--concurrency must be between 1 and {MAX_CONCURRENCY}"
                        ));
                    }
                    options.concurrency = concurrency;
                }
                other => return Err(format!("unrecognized argument: {other}")),
            }
        }
        Ok(options)
    }
}

/// Resolve one store and client per configured tenant, mirroring how `serve`
/// builds its per-tenant state without starting any background task.
async fn targets(
    database_url: &str,
    base: &Store,
    options: &Options,
) -> Result<Vec<(String, Store, NioVehicleClient)>, Box<dyn std::error::Error>> {
    let mut targets = Vec::new();
    match ConfigCipher::from_env()? {
        Some(cipher) => {
            let entries = tenant_config::load(&base.pool, &cipher).await?;
            for entry in entries {
                if options
                    .tenant
                    .as_deref()
                    .is_some_and(|slug| slug != entry.slug)
                {
                    continue;
                }
                let config = Config::from_overrides(
                    &entry.credentials.overrides(),
                    entry.slug == "default",
                )?;
                let store = if entry.schema_name == "public" {
                    base.clone()
                } else {
                    let url = tenant_config::schema_database_url(database_url, &entry.schema_name)?;
                    Store::connect(&url).await?
                };
                let Some(vehicle) = config.vehicle else {
                    println!("tenant {}: no vehicle credentials, skipped", entry.slug);
                    continue;
                };
                targets.push((entry.slug, store, NioVehicleClient::new(vehicle)?));
            }
            if targets.is_empty() && options.tenant.is_some() {
                return Err("the requested tenant has no vehicle credentials".into());
            }
        }
        None => {
            let config = Config::from_env()?;
            let Some(vehicle) = config.vehicle else {
                return Err(
                    "NIO_BEARER_TOKEN, NIO_VEHICLE_ID and NIO_DEVICE_ID must be configured".into(),
                );
            };
            targets.push((
                "default".to_owned(),
                base.clone(),
                NioVehicleClient::new(vehicle)?,
            ));
        }
    }
    Ok(targets)
}

/// One journey's detail request. Boxed so the batch driver stays testable
/// without a live upstream.
type TrackFetch = Arc<
    dyn Fn(
            String,
        )
            -> Pin<Box<dyn Future<Output = Result<Vec<VehicleTripTrackPoint>, String>> + Send>>
        + Send
        + Sync,
>;

fn track_fetcher(client: &NioVehicleClient) -> TrackFetch {
    let client = client.clone();
    Arc::new(move |journey_id: String| {
        let client = client.clone();
        Box::pin(async move {
            client
                .journey_track(&journey_id)
                .await
                .map_err(|error| error.to_string())
        })
    })
}

/// Run every request in the batch at once, then return the results in input
/// order so progress output stays stable and writes are deterministic.
async fn fetch_batch(
    journeys: &[String],
    fetch: TrackFetch,
) -> Vec<(String, Result<Vec<VehicleTripTrackPoint>, String>)> {
    let mut tasks = JoinSet::new();
    for (index, journey_id) in journeys.iter().enumerate() {
        let fetch = Arc::clone(&fetch);
        let journey_id = journey_id.clone();
        tasks.spawn(async move {
            let result = fetch(journey_id.clone()).await;
            (index, journey_id, result)
        });
    }
    let mut slots: Vec<Option<(String, Result<_, _>)>> =
        (0..journeys.len()).map(|_| None).collect();
    while let Some(joined) = tasks.join_next().await {
        match joined {
            Ok((index, journey_id, result)) => slots[index] = Some((journey_id, result)),
            Err(error) => println!("  batch task failed: {error}"),
        }
    }
    slots
        .into_iter()
        .enumerate()
        .filter_map(|(index, slot)| {
            slot.or_else(|| {
                journeys.get(index).map(|id| {
                    (
                        id.clone(),
                        Err("batch task did not return a result".to_owned()),
                    )
                })
            })
        })
        .collect()
}

pub async fn run(database_url: &str, args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let options = Options::parse(args)?;
    let base = Store::connect(database_url).await?;
    let targets = targets(database_url, &base, &options).await?;
    let mut total_failed = 0usize;

    for (slug, store, client) in targets {
        let vehicle_id = client.vehicle_id();
        let pending = store
            .vehicle_trip_ids_missing_tracks(vehicle_id, options.limit)
            .await?;
        println!(
            "[{slug}] {vehicle_id}: {} trip(s) without a stored track (concurrency {})",
            pending.len(),
            options.concurrency
        );
        if options.dry_run {
            for journey_id in &pending {
                println!("  would fetch {journey_id}");
            }
            continue;
        }

        let (mut stored, mut empty, mut failed) = (0usize, 0usize, 0usize);
        let fetch = track_fetcher(&client);
        let batches = pending.len().div_ceil(options.concurrency);
        let started = Instant::now();
        for (batch_index, batch) in pending.chunks(options.concurrency).enumerate() {
            let batch_started = Instant::now();
            let results = fetch_batch(batch, Arc::clone(&fetch)).await;
            let (mut batch_stored, mut batch_empty, mut batch_failed) = (0usize, 0usize, 0usize);
            let mut tracks = Vec::new();
            let mut scanned = Vec::new();
            for (journey_id, result) in results {
                match result {
                    Ok(points) if points.is_empty() => {
                        batch_empty += 1;
                        scanned.push(journey_id.clone());
                        if options.verbose {
                            println!("  {journey_id}: upstream returned no track");
                        }
                    }
                    Ok(points) => {
                        if options.verbose {
                            println!("  {journey_id}: {} point(s)", points.len());
                        }
                        batch_stored += 1;
                        scanned.push(journey_id.clone());
                        tracks.push(VehicleTripTrack { journey_id, points });
                    }
                    Err(error) => {
                        // Leave the trip unscanned so a later run retries it.
                        batch_failed += 1;
                        println!("  {journey_id}: failed: {error}");
                    }
                }
            }
            // One bulk statement set (one transaction) for the whole batch.
            store
                .insert_vehicle_trip_tracks(vehicle_id, &tracks)
                .await?;
            store.mark_trips_track_scanned(vehicle_id, &scanned).await?;
            stored += batch_stored;
            empty += batch_empty;
            failed += batch_failed;
            println!(
                "  batch {}/{batches}: {} trip(s) in {:.1}s | stored={batch_stored} empty={batch_empty} failed={batch_failed}",
                batch_index + 1,
                batch.len(),
                batch_started.elapsed().as_secs_f64()
            );
            if batch_index + 1 < batches {
                tokio::time::sleep(BATCH_PAUSE).await;
            }
        }
        total_failed += failed;
        println!(
            "[{slug}] scanned={} stored={stored} empty={empty} failed={failed} in {:.1}s",
            pending.len(),
            started.elapsed().as_secs_f64()
        );
    }

    if total_failed > 0 {
        return Err(format!(
            "{total_failed} journey track request(s) failed; re-run the command to retry them"
        )
        .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    /// Proves the batch driver really has every request in flight at once: 100
    /// requests that each sleep 100 ms finish far sooner than the 10 s a serial
    /// loop would need, and the peak in-flight count is measured directly.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn batch_requests_run_concurrently() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let in_flight = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let fetch: TrackFetch = {
            let in_flight = Arc::clone(&in_flight);
            let peak = Arc::clone(&peak);
            Arc::new(move |_journey_id: String| {
                let in_flight = Arc::clone(&in_flight);
                let peak = Arc::clone(&peak);
                Box::pin(async move {
                    let current = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(current, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    in_flight.fetch_sub(1, Ordering::SeqCst);
                    Ok(Vec::new())
                })
            })
        };
        let journeys: Vec<String> = (0..100).map(|index| index.to_string()).collect();
        let started = Instant::now();
        let results = fetch_batch(&journeys, fetch).await;
        let elapsed = started.elapsed();

        assert_eq!(results.len(), 100);
        assert_eq!(in_flight.load(Ordering::SeqCst), 0);
        println!(
            "peak in flight = {}, elapsed = {elapsed:?}",
            peak.load(Ordering::SeqCst)
        );
        assert!(
            peak.load(Ordering::SeqCst) >= 90,
            "only {} request(s) were in flight at once",
            peak.load(Ordering::SeqCst)
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "100 x 100 ms took {elapsed:?}; a serial loop needs 10 s"
        );
    }

    #[test]
    fn parses_tenant_limit_concurrency_and_flags() {
        let options = Options::parse(&args(&[
            "--tenant",
            "alice",
            "--limit",
            "50",
            "--concurrency",
            "8",
            "--dry-run",
            "--verbose",
        ]))
        .unwrap();
        assert_eq!(
            options,
            Options {
                tenant: Some("alice".to_owned()),
                limit: 50,
                concurrency: 8,
                dry_run: true,
                verbose: true,
            }
        );
        let defaults = Options::parse(&[]).unwrap();
        assert_eq!(defaults.limit, DEFAULT_LIMIT);
        assert_eq!(defaults.concurrency, DEFAULT_CONCURRENCY);
    }

    #[test]
    fn rejects_unknown_or_out_of_range_arguments() {
        assert!(Options::parse(&args(&["--limit"])).is_err());
        assert!(Options::parse(&args(&["--limit", "0"])).is_err());
        assert!(Options::parse(&args(&["--limit", "many"])).is_err());
        assert!(Options::parse(&args(&["--tenant"])).is_err());
        assert!(Options::parse(&args(&["--concurrency"])).is_err());
        assert!(Options::parse(&args(&["--concurrency", "0"])).is_err());
        assert!(Options::parse(&args(&["--concurrency", "257"])).is_err());
        assert!(Options::parse(&args(&["--force"])).is_err());
    }
}
