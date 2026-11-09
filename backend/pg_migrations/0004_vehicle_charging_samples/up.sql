ALTER TABLE vehicle_snapshots ADD COLUMN charge_state BIGINT;
ALTER TABLE vehicle_snapshots ADD COLUMN charging_current DOUBLE PRECISION;
ALTER TABLE vehicle_snapshots ADD COLUMN charging_power DOUBLE PRECISION;
ALTER TABLE vehicle_snapshots ADD COLUMN charging_voltage DOUBLE PRECISION;
