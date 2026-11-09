ALTER TABLE service_orders
    ADD COLUMN is_active BIGINT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_service_orders_active_created
    ON service_orders(is_active, order_created_at DESC);
