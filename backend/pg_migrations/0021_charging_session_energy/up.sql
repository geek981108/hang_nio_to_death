CREATE TABLE vehicle_charging_session_energy (
    session_id TEXT PRIMARY KEY,
    vehicle_id TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    energy_kwh DOUBLE PRECISION NOT NULL,
    sample_count BIGINT NOT NULL,
    calculated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_vehicle_charging_session_energy_started
    ON vehicle_charging_session_energy(started_at DESC);
