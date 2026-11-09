CREATE TABLE trip_energy_daily_runs (
    china_day DATE PRIMARY KEY,
    scheduled_at TIMESTAMPTZ NOT NULL,
    attempted_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    outcome TEXT NOT NULL DEFAULT 'scheduled'
        CHECK (outcome IN ('scheduled', 'started', 'succeeded', 'failed')),
    result_json TEXT
);

CREATE INDEX idx_trip_energy_daily_success
    ON trip_energy_daily_runs (china_day DESC)
    WHERE outcome = 'succeeded';
