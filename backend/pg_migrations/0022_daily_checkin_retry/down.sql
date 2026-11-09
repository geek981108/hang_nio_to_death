UPDATE daily_checkin_runs SET result = 'failed' WHERE result = 'not_sent';

ALTER TABLE daily_checkin_runs
    DROP CONSTRAINT IF EXISTS daily_checkin_runs_result_check;

ALTER TABLE daily_checkin_runs
    ADD CONSTRAINT daily_checkin_runs_result_check
    CHECK (result IN ('scheduled', 'started', 'succeeded', 'failed', 'already_completed'));

ALTER TABLE daily_checkin_runs
    DROP COLUMN IF EXISTS last_error;

ALTER TABLE daily_checkin_runs
    DROP COLUMN IF EXISTS attempts;
