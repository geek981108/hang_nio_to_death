ALTER TABLE daily_checkin_runs
    DROP CONSTRAINT IF EXISTS daily_checkin_runs_result_check;

ALTER TABLE daily_checkin_runs
    ADD CONSTRAINT daily_checkin_runs_result_check
    CHECK (result IN ('scheduled', 'started', 'succeeded', 'failed', 'not_sent', 'already_completed'));

ALTER TABLE daily_checkin_runs
    ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_checkin_runs
    ADD COLUMN last_error TEXT;
