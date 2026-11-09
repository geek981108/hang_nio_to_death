CREATE TABLE IF NOT EXISTS station_snapshots (
    id TEXT PRIMARY KEY NOT NULL,
    station_key TEXT NOT NULL,
    station_name TEXT NOT NULL,
    captured_at TIMESTAMPTZ NOT NULL,
    battery_count BIGINT NOT NULL,
    payload_sha256 TEXT,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_station_snapshots_station_time
    ON station_snapshots(station_key, captured_at DESC);

CREATE TABLE IF NOT EXISTS station_batteries (
    snapshot_id TEXT NOT NULL REFERENCES station_snapshots(id) ON DELETE CASCADE,
    battery_id TEXT NOT NULL,
    slot_id BIGINT,
    battery_type TEXT,
    capacity_kwh DOUBLE PRECISION,
    soc_percent DOUBLE PRECISION,
    occupied BIGINT NOT NULL DEFAULT 0,
    production_date DATE,
    PRIMARY KEY (snapshot_id, battery_id)
);

CREATE INDEX IF NOT EXISTS idx_station_batteries_id
    ON station_batteries(battery_id);

CREATE TABLE IF NOT EXISTS swap_events (
    id TEXT PRIMARY KEY NOT NULL,
    detection_key TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('observed_candidate', 'confirmed')),
    occurred_at TIMESTAMPTZ NOT NULL,
    station_key TEXT,
    station_name TEXT,
    order_no TEXT UNIQUE,
    exact_energy_kwh DOUBLE PRECISION,
    estimated_energy_kwh DOUBLE PRECISION,
    energy_source TEXT NOT NULL,
    outgoing_battery_id TEXT,
    outgoing_production_date DATE,
    outgoing_capacity_kwh DOUBLE PRECISION,
    outgoing_soc_percent DOUBLE PRECISION,
    incoming_battery_id TEXT,
    incoming_production_date DATE,
    incoming_capacity_kwh DOUBLE PRECISION,
    incoming_soc_percent DOUBLE PRECISION,
    battery_source TEXT NOT NULL,
    confidence TEXT NOT NULL CHECK (confidence IN ('low', 'medium', 'high', 'exact')),
    evidence TEXT,
    raw_order_json TEXT,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_swap_events_occurred_at
    ON swap_events(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_swap_events_station_time
    ON swap_events(station_key, occurred_at DESC);

CREATE TABLE IF NOT EXISTS poll_runs (
    id TEXT PRIMARY KEY NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('success', 'error', 'skipped')),
    snapshot_id TEXT,
    message TEXT
);

CREATE INDEX IF NOT EXISTS idx_poll_runs_started_at
    ON poll_runs(started_at DESC);

