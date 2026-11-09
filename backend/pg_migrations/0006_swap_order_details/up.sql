ALTER TABLE swap_events ADD COLUMN station_address TEXT;
ALTER TABLE swap_events ADD COLUMN order_status_name TEXT;
ALTER TABLE swap_events ADD COLUMN price_amount DOUBLE PRECISION;
ALTER TABLE swap_events ADD COLUMN price_currency TEXT;
ALTER TABLE swap_events ADD COLUMN price_description TEXT;
ALTER TABLE swap_events ADD COLUMN payment_items_json TEXT;
