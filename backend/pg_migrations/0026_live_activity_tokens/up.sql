CREATE TABLE live_activity_tokens (
    token_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    token_kind TEXT NOT NULL,
    push_token TEXT NOT NULL,
    activity_id TEXT,
    session_key TEXT,
    activity_mode TEXT,
    bundle_id TEXT NOT NULL,
    apns_environment TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_pushed_at TIMESTAMPTZ,
    invalidated_at TIMESTAMPTZ
);

CREATE INDEX idx_live_activity_tokens_active
    ON live_activity_tokens (token_kind, invalidated_at, updated_at DESC);
