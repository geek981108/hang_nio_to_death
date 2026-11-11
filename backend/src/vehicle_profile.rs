//! Per-tenant vehicle identity and image cache.
//!
//! The App needs the car's picture, and that picture only exists upstream at
//! `switch/cars`. It is fetched once when the process starts (retried until it
//! succeeds) and then left alone: the stored image is keyed by its upstream URL,
//! so an unchanged URL keeps the cached bytes indefinitely instead of polling
//! upstream every day.

use std::time::Duration;

use tracing::{info, warn};

use crate::{store::Store, vehicle::NioVehicleClient};

/// Startup failures are usually transient (upstream hiccup, token refresh).
const RETRY_DELAY: Duration = Duration::from_secs(5 * 60);

/// Fetch the profile once, reusing the cached image when upstream still reports
/// the same URL. Returns whether the stored bytes were reused.
pub async fn refresh(store: &Store, vehicle: &NioVehicleClient) -> Result<bool, String> {
    let vehicle_id = vehicle.vehicle_id();
    let cached = store
        .vehicle_profile(vehicle_id)
        .await
        .map_err(|error| error.to_string())?;
    let profile = vehicle
        .vehicle_profile(cached.as_ref())
        .await
        .map_err(|error| error.to_string())?;
    let reused = profile.image_bytes.is_none()
        && cached.as_ref().is_some_and(|cached| cached.image_available);
    store
        .upsert_vehicle_profile(&profile)
        .await
        .map_err(|error| error.to_string())?;
    info!(
        vehicle_id,
        image_reused = reused,
        image_cached = reused || profile.image_bytes.is_some(),
        "vehicle profile stored"
    );
    Ok(reused)
}

/// One startup pass, retrying until it succeeds. The image is never refreshed on
/// a timer: a changed upstream URL is picked up on the next start, or on demand
/// when the profile endpoint finds no stored row.
pub async fn run_startup(store: Store, vehicle: NioVehicleClient) {
    loop {
        match refresh(&store, &vehicle).await {
            Ok(_) => return,
            Err(error) => {
                warn!(
                    %error,
                    vehicle_id = vehicle.vehicle_id(),
                    retry_seconds = RETRY_DELAY.as_secs(),
                    "vehicle profile refresh failed"
                );
                tokio::time::sleep(RETRY_DELAY).await;
            }
        }
    }
}
