CREATE TABLE vehicle_trips (
    vehicle_id TEXT NOT NULL,
    journey_id TEXT NOT NULL,
    trip_id TEXT,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    distance_kilometers DOUBLE PRECISION NOT NULL,
    duration_minutes BIGINT NOT NULL,
    start_location JSONB NOT NULL,
    end_location JSONB NOT NULL,
    average_speed_kph DOUBLE PRECISION,
    average_energy_consumption_kwh_per_100km DOUBLE PRECISION,
    energy_consumed_kwh DOUBLE PRECISION,
    maximum_speed_kph DOUBLE PRECISION,
    odometer_kilometers DOUBLE PRECISION,
    rapid_acceleration_count BIGINT,
    rapid_deceleration_count BIGINT,
    rapid_swerve_count BIGINT,
    is_combined BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (vehicle_id, journey_id)
);

CREATE INDEX idx_vehicle_trips_vehicle_started_at
    ON vehicle_trips (vehicle_id, started_at DESC);
