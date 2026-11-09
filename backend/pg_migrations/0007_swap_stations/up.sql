CREATE TABLE IF NOT EXISTS swap_stations (
    station_id TEXT PRIMARY KEY NOT NULL,
    station_name TEXT NOT NULL,
    station_address TEXT,
    operator_id TEXT,
    operator_name TEXT,
    source_order_no TEXT,
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_swap_stations_name
    ON swap_stations(station_name);
CREATE INDEX IF NOT EXISTS idx_swap_stations_last_seen
    ON swap_stations(last_seen_at DESC);
