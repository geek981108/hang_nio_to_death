CREATE TABLE mcp_oauth_tokens (
    token_hash TEXT PRIMARY KEY,
    issuer TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('code', 'access', 'refresh')),
    client_id TEXT NOT NULL,
    redirect_uri TEXT,
    challenge TEXT,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_mcp_oauth_tokens_expiry ON mcp_oauth_tokens (expires_at);
