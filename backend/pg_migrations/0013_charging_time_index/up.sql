CREATE INDEX IF NOT EXISTS idx_vehicle_charging_samples_global_time
    ON vehicle_charging_samples(sampled_at DESC, vehicle_id DESC);
