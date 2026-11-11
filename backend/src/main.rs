mod analytics;
mod api;
mod certificate_issuance;
mod config;
mod daily_checkin;
mod detector;
mod diesel_query;
mod events;
mod models;
mod nearby_stations;
mod nio_login;
mod oauth_tokens;
mod openapi;
mod pg_store;
mod pin_secret;
mod poller;
mod provider;
mod rewards;
mod route_estimate;
mod service_order;
mod station_search;
mod store;
mod swap_monitor;
mod swap_order;
mod systemd;
mod tenant_config;
mod trip_backfill;
mod trip_energy;
mod trip_sync;
mod vehicle;
mod vehicle_control;
mod vehicle_profile;

use std::{path::Path, sync::Arc};

use actix_web::{App, HttpServer, middleware::Logger, web};
use api::AppState;
use config::{Config, StationConfig, StationTemplateConfig};
use events::EventHub;
use nearby_stations::NioNearbyStationClient;
use poller::{Poller, StationTarget};
use provider::NioStationProvider;
use rewards::NioRewardsClient;
use service_order::{ServiceOrderMonitor, ServiceOrderProvider};
use station_search::NioStationSearchClient;
use store::Store;
use swap_monitor::SwapMonitor;
use swap_order::SwapOrderRuntime;
use tracing::info;
use tracing_subscriber::EnvFilter;
use trip_energy::DailySchedule;
use vehicle::NioVehicleClient;
use vehicle_control::ControlRuntime;

#[actix_web::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli_args = std::env::args().skip(1).collect::<Vec<_>>();
    if cli_args.first().is_some_and(|arg| arg == "export-openapi") {
        let output = match cli_args.as_slice() {
            [_] => Path::new("openapi.json"),
            [_, path] => Path::new(path),
            _ => return Err("usage: export-openapi [output.json]".into()),
        };
        openapi::export(output)?;
        println!("OpenAPI JSON written to {}", output.display());
        return Ok(());
    }
    if let [command] = cli_args.as_slice() {
        if matches!(command.as_str(), "install" | "uninstall" | "status") {
            systemd::handle(command)?;
            return Ok(());
        }
    }
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("nio_swap_history_backend=info,actix_web=info")),
        )
        .init();
    if cli_args
        .first()
        .is_some_and(|arg| arg == "verify-bootstrap")
    {
        certificate_issuance::verify_bootstrap_cli(&cli_args[1..]).await?;
        return Ok(());
    }
    let database_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://localhost/nio_swap_history".to_owned());
    if cli_args.first().is_some_and(|arg| arg == "migrate-db") {
        pg_store::connect(&database_url)
            .await
            .map_err(|error| -> Box<dyn std::error::Error> { error })?;
        info!("PostgreSQL Diesel migrations applied");
        return Ok(());
    }
    if let [command, slug] = cli_args.as_slice()
        && command == "upsert-tenant"
    {
        use std::io::Read;
        let cipher =
            tenant_config::ConfigCipher::from_env()?.ok_or("NIO_CONFIG_MASTER_KEY is required")?;
        let schema = tenant_config::schema_for(slug)?;
        let mut input = String::new();
        std::io::stdin()
            .take(32 * 1024)
            .read_to_string(&mut input)?;
        let credentials = tenant_config::TenantCredentials::from_input(&input)?;
        let store = Store::connect(&database_url).await?;
        if schema != "public" {
            diesel_query::query(&format!("CREATE SCHEMA IF NOT EXISTS {schema}"))
                .execute(&store.pool)
                .await?;
            let tenant_url = tenant_config::schema_database_url(&database_url, &schema)?;
            Store::connect(&tenant_url).await?;
        }
        tenant_config::upsert(&store.pool, &cipher, slug, &credentials).await?;
        println!("tenant configuration saved; restart the service to load it");
        return Ok(());
    }
    if cli_args.as_slice() == ["validate-tenants"] {
        let cipher =
            tenant_config::ConfigCipher::from_env()?.ok_or("NIO_CONFIG_MASTER_KEY is required")?;
        let store = Store::connect(&database_url).await?;
        let entries = tenant_config::load(&store.pool, &cipher).await?;
        if entries.is_empty() || !entries.iter().any(|entry| entry.slug == "default") {
            return Err("tenant mode requires a default tenant config".into());
        }
        for entry in &entries {
            if entry.schema_name != "public" {
                let url = tenant_config::schema_database_url(&database_url, &entry.schema_name)?;
                Store::connect(&url).await?;
            }
        }
        println!(
            "validated {} tenant configurations and schemas",
            entries.len()
        );
        return Ok(());
    }
    if cli_args.first().is_some_and(|arg| arg == "backfill-tracks") {
        trip_backfill::run(&database_url, &cli_args[1..]).await?;
        return Ok(());
    }
    if cli_args.first().is_some_and(|arg| arg == "issue-identity") {
        let config = Config::from_env()?;
        certificate_issuance::run_cli(&cli_args[1..], config.vehicle.clone()).await?;
        return Ok(());
    }
    if !cli_args.is_empty() && cli_args.as_slice() != ["serve"] {
        return Err("unrecognized command-line arguments".into());
    }
    let store = Store::connect(&database_url).await?;
    let bind_addr: std::net::SocketAddr = std::env::var("BIND_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:8080".to_owned())
        .parse()?;
    let states: Vec<(String, web::Data<AppState>)>;
    let cipher = tenant_config::ConfigCipher::from_env()?.map(Arc::new);
    if let Some(cipher) = cipher {
        let entries = tenant_config::load(&store.pool, &cipher).await?;
        if entries.is_empty() || !entries.iter().any(|entry| entry.slug == "default") {
            return Err("tenant mode requires a default tenant config".into());
        }
        let mut built = Vec::new();
        for entry in entries {
            let is_default = entry.slug == "default";
            let route_prefix = if is_default {
                String::new()
            } else {
                format!("/t/{}", entry.slug)
            };
            let mut tenant_config =
                Config::from_overrides(&entry.credentials.overrides(), is_default)?;
            tenant_config.database_url =
                tenant_config::schema_database_url(&database_url, &entry.schema_name)?;
            let tenant_store = if is_default {
                store.clone()
            } else {
                Store::connect(&tenant_config.database_url).await?
            };
            let persistence = Arc::new(tenant_config::TenantPersistence::new(
                store.pool.clone(),
                cipher.clone(),
                entry.slug.clone(),
                entry.credentials,
            ));
            let state = build_state(
                tenant_config,
                tenant_store,
                is_default,
                true,
                Some(persistence),
                &route_prefix,
            )
            .await?;
            built.push((entry.slug, web::Data::new(state)));
        }
        states = built;
    } else {
        let config = Config::from_env()?;
        states = vec![(
            "default".into(),
            web::Data::new(build_state(config, store, true, false, None, "").await?),
        )];
    }
    for (slug, state) in &states {
        let Some(vehicle) = state.vehicle.clone() else {
            continue;
        };
        let store = state.store.clone();
        let slug = slug.clone();
        tokio::spawn(async move {
            tracing::debug!(tenant = %slug, "starting vehicle profile refresh");
            vehicle_profile::run_startup(store, vehicle).await
        });
    }
    let default_state = states
        .iter()
        .find(|(slug, _)| slug == "default")
        .unwrap()
        .1
        .clone();
    let scoped: Vec<_> = states
        .into_iter()
        .filter(|(slug, _)| slug != "default")
        .collect();
    info!(address = %bind_addr, tenants = scoped.len() + 1, "NIO swap history backend listening");
    HttpServer::new(move || {
        let mut app = App::new()
            .app_data(default_state.clone())
            .app_data(web::Data::new(default_state.mcp_oauth.clone()))
            .app_data(api::json_config())
            .wrap(Logger::default())
            .configure(api::configure);
        for (slug, state) in &scoped {
            app = app.service(
                web::scope(&format!("/t/{slug}"))
                    .app_data(state.clone())
                    .app_data(web::Data::new(state.mcp_oauth.clone()))
                    .app_data(api::json_config())
                    .configure(api::configure),
            );
        }
        app
    })
    .shutdown_timeout(10)
    .bind(bind_addr)?
    .run()
    .await?;
    Ok(())
}

async fn build_state(
    config: Config,
    store: Store,
    is_default: bool,
    tenant_mode: bool,
    tenant_persistence: Option<Arc<tenant_config::TenantPersistence>>,
    route_prefix: &str,
) -> Result<AppState, Box<dyn std::error::Error>> {
    let provider = config
        .station
        .clone()
        .map(NioStationProvider::new)
        .transpose()?;
    let poller = Poller::new(provider, store.clone());
    let events = EventHub::new(store.clone());
    let station_target = StationTarget::default();
    let vehicle = config
        .vehicle
        .clone()
        .map(NioVehicleClient::new)
        .transpose()?;
    let trip_sync = if let Some(vehicle_client) = vehicle.clone() {
        let schedule = DailySchedule::from_env()?;
        let cache_store = store.clone();
        let sync_store = store.clone();
        let sync_vehicle = vehicle_client.clone();
        let (trigger, requests) = tokio::sync::mpsc::channel(1);
        tokio::spawn(async move {
            trip_energy::run_forever(cache_store, vehicle_client, schedule).await
        });
        tokio::spawn(
            async move { trip_sync::run_forever(sync_store, sync_vehicle, requests).await },
        );
        Some(trigger)
    } else {
        None
    };
    let control = if is_default {
        ControlRuntime::from_env(config.vehicle.clone(), config.api_key.as_deref())?
    } else {
        None
    };
    let swap_order = if is_default {
        SwapOrderRuntime::from_env(config.vehicle.clone())?
    } else {
        None
    };
    let station_search = config
        .vehicle
        .clone()
        .map(NioStationSearchClient::new)
        .transpose()?;
    let nearby_stations = config
        .vehicle
        .clone()
        .map(NioNearbyStationClient::new)
        .transpose()?;
    let rewards = config
        .vehicle
        .clone()
        .map(NioRewardsClient::new)
        .transpose()?;
    if config.daily_checkin_enabled
        && let Some(rewards_client) = rewards.clone()
    {
        let checkin_store = store.clone();
        tokio::spawn(
            async move { daily_checkin::run_forever(checkin_store, rewards_client).await },
        );
    } else if !config.daily_checkin_enabled {
        info!("automatic daily check-in disabled by NIO_DAILY_CHECKIN_ENABLED");
    }
    let service_order_provider = config
        .service_orders
        .clone()
        .map(|service_orders| ServiceOrderProvider::new(service_orders, config.vehicle.clone()))
        .transpose()?;
    let station_template_configured = config.station_template.is_some();
    let station_template = config.station_template.clone();
    if let Some(template) = station_template.clone() {
        let backfill_store = store.clone();
        tokio::spawn(async move {
            backfill_station_coordinates(backfill_store, template).await;
        });
    }
    if let Some(vehicle_client) = vehicle.clone() {
        let monitor = SwapMonitor::new(
            vehicle_client,
            poller.clone(),
            store.clone(),
            station_target.clone(),
            config.vehicle_unlocked_poll_interval,
            config.vehicle_locked_poll_interval,
            config.post_swap_poll_count,
            events.clone(),
        );
        tokio::spawn(async move { monitor.run_forever().await });
    } else {
        let background_poller = poller.clone();
        let poll_interval = config.poll_interval;
        tokio::spawn(async move { background_poller.run_forever(poll_interval).await });
    }
    if let Some(provider) = service_order_provider {
        let monitor = ServiceOrderMonitor::new(
            provider,
            store.clone(),
            poller.clone(),
            station_target,
            config.service_order_poll_interval,
            events.clone(),
        );
        tokio::spawn(async move { monitor.run_forever().await });
    }

    let state = AppState {
        store: store.clone(),
        events,
        poller,
        api_key: config.api_key.map(Arc::from),
        tenant_mode,
        poll_interval: config.poll_interval,
        match_window: config.match_window,
        vehicle,
        nio_login: config
            .login_profile
            .map(nio_login::NioLogin::new)
            .transpose()?
            .map(Arc::new),
        tenant_persistence,
        trip_sync,
        control,
        swap_order,
        station_search,
        nearby_stations,
        rewards,
        service_order_configured: config.service_orders.is_some(),
        station_template_configured,
        station_template,
        station_provider_template: Arc::default(),
        service_order_poll_interval: config.service_order_poll_interval,
        mcp_client: reqwest::Client::builder()
            .no_proxy()
            .pool_max_idle_per_host(8)
            .timeout(std::time::Duration::from_secs(60))
            .build()?,
        mcp_origin: format!(
            "http://{}",
            if config.bind_addr.ip().is_unspecified() {
                std::net::SocketAddr::new(
                    if config.bind_addr.is_ipv6() {
                        std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)
                    } else {
                        std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
                    },
                    config.bind_addr.port(),
                )
            } else {
                config.bind_addr
            }
        ) + route_prefix,
        mcp_oauth: config
            .mcp_oauth_issuer
            .zip(config.mcp_oauth_login_secret)
            .map(|(issuer, secret)| {
                api::mcp_oauth::OAuthServer::new(issuer, secret, store.clone())
            }),
    };
    Ok(state)
}

async fn backfill_station_coordinates(store: Store, template: StationTemplateConfig) {
    let stations = match store.swap_stations_missing_identity().await {
        Ok(stations) => stations,
        Err(error) => {
            tracing::warn!(%error, "failed to load stations needing coordinate backfill");
            return;
        }
    };
    if !stations.is_empty() {
        backfill_station_rows(&store, &template, stations).await;
    }
    match store.backfill_swap_event_station_addresses().await {
        Ok(updated) => info!(updated, "swap event station addresses backfilled"),
        Err(error) => {
            tracing::warn!(%error, "failed to backfill swap event station addresses");
        }
    }
}

async fn backfill_station_rows(
    store: &Store,
    template: &StationTemplateConfig,
    stations: Vec<crate::models::SwapStation>,
) {
    let provider = match NioStationProvider::new(StationConfig {
        key: "coordinate-backfill".to_owned(),
        name: "Coordinate backfill".to_owned(),
        url: template.url_template.clone(),
        headers: template.headers.clone(),
    }) {
        Ok(provider) => provider,
        Err(error) => {
            tracing::warn!(%error, "failed to initialize station coordinate backfill");
            return;
        }
    };
    let total = stations.len();
    let mut updated = 0usize;
    for station in stations {
        if !station.station_id.starts_with("PS-NIO-") {
            continue;
        }
        let current = provider.retarget(
            station.station_id.clone(),
            station.station_name,
            template
                .url_template
                .replace("{station_id}", &station.station_id),
        );
        match current.fetch_identity().await {
            Ok((coordinates, address)) => {
                if let Err(error) = store
                    .update_swap_station_identity(
                        &station.station_id,
                        coordinates.latitude,
                        coordinates.longitude,
                        address.as_deref(),
                    )
                    .await
                {
                    tracing::warn!(station_id = %station.station_id, %error, "failed to save station identity");
                } else {
                    updated += 1;
                }
            }
            Err(error) => {
                tracing::warn!(station_id = %station.station_id, %error, "failed to backfill station identity");
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    info!(total, updated, "station identity backfill finished");
}
