CREATE TABLE daily_checkin_runs (
    china_day DATE PRIMARY KEY,
    scheduled_at TIMESTAMPTZ NOT NULL,
    attempted_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    result TEXT NOT NULL DEFAULT 'scheduled'
        CHECK (result IN ('scheduled', 'started', 'succeeded', 'failed', 'already_completed'))
);
