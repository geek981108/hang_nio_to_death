-- Local bookkeeping for the one-shot track backfill. Upstream returns an empty
-- track for some journeys, so the command must remember which trips it already
-- asked about instead of re-fetching them on every run.
ALTER TABLE vehicle_trips ADD COLUMN track_scanned_at TIMESTAMPTZ;

-- The backfill reads only unscanned trips, newest first.
CREATE INDEX idx_vehicle_trips_track_scan
    ON vehicle_trips (vehicle_id, started_at DESC)
    WHERE track_scanned_at IS NULL;
