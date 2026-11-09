CREATE TABLE IF NOT EXISTS service_orders (
    order_no TEXT PRIMARY KEY NOT NULL,
    order_type TEXT NOT NULL,
    order_status TEXT,
    order_status_name TEXT,
    order_created_at TIMESTAMPTZ NOT NULL,
    vehicle_id TEXT,
    vin_code TEXT,
    station_key TEXT,
    station_name TEXT,
    station_address TEXT,
    raw_order_json TEXT NOT NULL,
    baseline_snapshot_id TEXT REFERENCES station_snapshots(id),
    baseline_captured_at TIMESTAMPTZ,
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_service_orders_last_seen
    ON service_orders(last_seen_at DESC);
