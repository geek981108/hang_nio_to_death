//! PostgreSQL connection pool and embedded Diesel migrations.
use diesel::Connection;
use diesel::pg::PgConnection;
use diesel_async::AsyncPgConnection;
use diesel_async::pooled_connection::{AsyncDieselConnectionManager, deadpool::Pool};
use diesel_migrations::{EmbeddedMigrations, MigrationHarness, embed_migrations};

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!("pg_migrations");
pub type PgPool = Pool<AsyncPgConnection>;

pub async fn connect(
    database_url: &str,
) -> Result<PgPool, Box<dyn std::error::Error + Send + Sync>> {
    let url = database_url.to_owned();
    tokio::task::spawn_blocking(
        move || -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
            let mut conn = PgConnection::establish(&url)?;
            conn.run_pending_migrations(MIGRATIONS)?;
            Ok(())
        },
    )
    .await??;
    let manager = AsyncDieselConnectionManager::<AsyncPgConnection>::new(database_url);
    Ok(Pool::builder(manager).max_size(8).build()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use diesel::{QueryableByName, sql_types::BigInt};
    use diesel_async::RunQueryDsl;

    #[derive(QueryableByName)]
    struct TableCount {
        #[diesel(sql_type = BigInt)]
        count: i64,
    }

    #[tokio::test]
    async fn embedded_migrations_create_all_tables() {
        let Ok(url) = std::env::var("NIO_TEST_POSTGRES_URL") else {
            return;
        };
        let pool = connect(&url).await.unwrap();
        let mut conn = pool.get().await.unwrap();
        let result: TableCount = diesel::sql_query(
            "SELECT count(*)::bigint AS count FROM information_schema.tables WHERE table_schema = current_schema() AND table_name IN ('station_snapshots', 'station_batteries', 'swap_events', 'poll_runs', 'service_orders', 'vehicle_snapshots', 'vehicle_charging_samples', 'swap_stations')",
        ).get_result(&mut conn).await.unwrap();
        assert_eq!(result.count, 8);
    }
}
