ALTER TABLE service_orders ADD COLUMN queue_number BIGINT;
ALTER TABLE service_orders ADD COLUMN target_battery_cap_level BIGINT;
ALTER TABLE service_orders ADD COLUMN vehicles_ahead BIGINT;
ALTER TABLE service_orders ADD COLUMN estimated_wait_minutes BIGINT;
ALTER TABLE service_orders ADD COLUMN estimated_wait_source TEXT;
ALTER TABLE service_orders ADD COLUMN queue_status_text TEXT;
ALTER TABLE service_orders ADD COLUMN queue_updated_at TIMESTAMPTZ;
