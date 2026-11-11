-- Vehicle identity and the image shown in the App. The image URL comes from
-- the upstream switch/cars endpoint; the bytes are cached here so a client only
-- ever talks to this backend, and so a per-tenant deployment keeps its own car.
CREATE TABLE vehicle_profile (
    vehicle_id TEXT PRIMARY KEY,
    display_name TEXT,
    model_type TEXT,
    color TEXT,
    image_url TEXT,
    image_content_type TEXT,
    image_sha256 TEXT,
    image_bytes BYTEA,
    image_fetched_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
