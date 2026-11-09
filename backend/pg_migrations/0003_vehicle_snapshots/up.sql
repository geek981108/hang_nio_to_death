CREATE TABLE IF NOT EXISTS vehicle_snapshots (
    snapshot_key TEXT PRIMARY KEY NOT NULL,
    vehicle_id TEXT NOT NULL,
    sampled_at TIMESTAMPTZ NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    soc DOUBLE PRECISION,
    remaining_range DOUBLE PRECISION,
    remaining_actual_range DOUBLE PRECISION,
    mileage DOUBLE PRECISION,
    inside_temperature DOUBLE PRECISION,
    outside_temperature DOUBLE PRECISION,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vehicle_snapshots_vehicle_time
    ON vehicle_snapshots(vehicle_id, sampled_at DESC);
