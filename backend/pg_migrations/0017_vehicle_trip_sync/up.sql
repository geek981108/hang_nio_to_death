CREATE TABLE vehicle_trip_sync (
    vehicle_id TEXT PRIMARY KEY,
    backfill_cursor BIGINT,
    backfill_completed BOOLEAN NOT NULL DEFAULT FALSE,
    forward_cursor BIGINT,
    covered_before TIMESTAMPTZ,
    forward_started_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
