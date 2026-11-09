CREATE TABLE IF NOT EXISTS vehicle_charging_samples (
    vehicle_id TEXT NOT NULL,
    sampled_at TIMESTAMPTZ NOT NULL,
    soc DOUBLE PRECISION,
    charge_state BIGINT NOT NULL,
    charging_current DOUBLE PRECISION,
    charging_power DOUBLE PRECISION,
    charging_voltage DOUBLE PRECISION,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (vehicle_id, sampled_at)
);

CREATE INDEX IF NOT EXISTS idx_vehicle_charging_samples_time
    ON vehicle_charging_samples(vehicle_id, sampled_at DESC);
