ALTER TABLE service_orders
    ADD COLUMN swap_start_soc DOUBLE PRECISION;

ALTER TABLE service_orders
    ADD COLUMN swap_start_soc_observed_at TIMESTAMPTZ;
