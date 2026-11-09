-- Tenant registry remains in public; tenant business tables live in separate schemas.
CREATE TABLE IF NOT EXISTS public.tenant_configs (
    slug TEXT PRIMARY KEY CHECK (slug ~ '^[a-z][a-z0-9_]{0,47}$'),
    schema_name TEXT NOT NULL UNIQUE CHECK (schema_name = 'public' OR schema_name ~ '^tenant_[a-z0-9_]+$'),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    api_key_sha256 TEXT NOT NULL UNIQUE CHECK (api_key_sha256 ~ '^[0-9a-f]{64}$'),
    config_nonce TEXT NOT NULL,
    config_ciphertext TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
