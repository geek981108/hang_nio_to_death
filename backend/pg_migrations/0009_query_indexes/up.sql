-- Keep history without retention; this index serves vehicle-scoped pages.
CREATE INDEX IF NOT EXISTS idx_vehicle_snapshots_vehicle_time
    ON vehicle_snapshots(vehicle_id, sampled_at DESC);

-- The default history endpoint reads only confirmed orders. Keep candidate
-- detection and the include_candidates query unchanged.
CREATE INDEX IF NOT EXISTS idx_swap_events_confirmed_time
    ON swap_events(occurred_at DESC) WHERE status = 'confirmed';
