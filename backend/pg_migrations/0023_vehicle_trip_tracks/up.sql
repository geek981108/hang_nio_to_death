-- Upstream journey detail returns one GPS sample per ~10 s. Store the polyline
-- per journey so the App can draw the official track instead of reconstructing
-- it from polled positions.
CREATE TABLE vehicle_trip_tracks (
    vehicle_id TEXT NOT NULL,
    journey_id TEXT NOT NULL,
    seq BIGINT NOT NULL,
    sampled_at TIMESTAMPTZ NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    speed_kph DOUBLE PRECISION,
    power_consumption DOUBLE PRECISION,
    np_status BIGINT,
    PRIMARY KEY (vehicle_id, journey_id, seq)
);
