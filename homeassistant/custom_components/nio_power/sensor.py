"""Sensor platform for NIO Power."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import (
    PERCENTAGE,
    UnitOfLength,
    UnitOfTemperature,
)
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DEVICE_STATION, DEVICE_VEHICLE, DOMAIN
from .coordinator import NioPowerCoordinator


def _pick(data: dict[str, Any], path: str, default: Any = None) -> Any:
    node: Any = data
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node


@dataclass(frozen=True, kw_only=True)
class NioSensorDescription(SensorEntityDescription):
    path: str
    device: str = DEVICE_VEHICLE


VEHICLE_SENSORS = (
    NioSensorDescription(
        key="vehicle_soc",
        name="电量",
        path="soc_status.soc",
        native_unit_of_measurement=PERCENTAGE,
        device_class=SensorDeviceClass.BATTERY,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="vehicle_range",
        name="剩余续航",
        path="soc_status.remaining_range",
        native_unit_of_measurement=UnitOfLength.KILOMETERS,
        device_class=SensorDeviceClass.DISTANCE,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="vehicle_range_actual",
        name="实际续航",
        path="soc_status.remaining_actual_range",
        native_unit_of_measurement=UnitOfLength.KILOMETERS,
        device_class=SensorDeviceClass.DISTANCE,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="vehicle_mileage",
        name="总里程",
        path="exterior_status.mileage",
        native_unit_of_measurement=UnitOfLength.KILOMETERS,
        device_class=SensorDeviceClass.DISTANCE,
        state_class=SensorStateClass.TOTAL_INCREASING,
    ),
    NioSensorDescription(
        key="vehicle_outside_temperature",
        name="车外温度",
        path="hvac_status.outside_temperature",
        native_unit_of_measurement=UnitOfTemperature.CELSIUS,
        device_class=SensorDeviceClass.TEMPERATURE,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="vehicle_charging_power",
        name="充电功率",
        path="soc_status.charging_power",
        native_unit_of_measurement="kW",
        device_class=SensorDeviceClass.POWER,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="vehicle_updated_at",
        name="状态更新时间",
        path="soc_status.sample_time",
        device_class=SensorDeviceClass.TIMESTAMP,
    ),
)

STATION_SENSORS = (
    NioSensorDescription(
        key="station_name",
        name="换电站名称",
        path="station_name",
        device=DEVICE_STATION,
    ),
    NioSensorDescription(
        key="station_distance",
        name="距车距离",
        path="straight_line_distance_km",
        device=DEVICE_STATION,
        native_unit_of_measurement=UnitOfLength.KILOMETERS,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="station_queue",
        name="排队车辆",
        path="queue.vehicles_ahead",
        device=DEVICE_STATION,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="station_ready_102",
        name="可换电池（102kWh）",
        path="__compatible_ready__",
        device=DEVICE_STATION,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="station_ready_all",
        name="可换电池（全部）",
        path="__all_ready__",
        device=DEVICE_STATION,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="station_battery_total",
        name="电池总数",
        path="__battery_total__",
        device=DEVICE_STATION,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="station_charging_count",
        name="充电中电池",
        path="__charging_count__",
        device=DEVICE_STATION,
        state_class=SensorStateClass.MEASUREMENT,
    ),
    NioSensorDescription(
        key="station_electricity_fee",
        name="电费",
        path="__fee_electricity__",
        device=DEVICE_STATION,
        native_unit_of_measurement="¥/度",
    ),
    NioSensorDescription(
        key="station_service_fee",
        name="服务费",
        path="__fee_service__",
        device=DEVICE_STATION,
        native_unit_of_measurement="¥/度",
    ),
    NioSensorDescription(
        key="station_captured_at",
        name="站点更新时间",
        path="captured_at",
        device=DEVICE_STATION,
        device_class=SensorDeviceClass.TIMESTAMP,
    ),
)


def _battery_stats(station: dict[str, Any] | None) -> dict[str, Any]:
    if not station:
        return {}
    batteries = station.get("battery_readiness") or []
    ready_all = sum(
        1
        for b in batteries
        if not b.get("battery_occupied") and (b.get("progress_percent") or 0) >= 92
    )
    ready_102 = sum(
        1
        for b in batteries
        if not b.get("battery_occupied")
        and b.get("capacity_kwh") == 102.0
        and (b.get("progress_percent") or 0) >= 92
    )
    charging = sum(
        1
        for b in batteries
        if not b.get("battery_occupied") and (b.get("progress_percent") or 0) < 92
    )
    return {
        "__compatible_ready__": ready_102,
        "__all_ready__": ready_all,
        "__battery_total__": len(batteries),
        "__charging_count__": charging,
    }


def _fee(station: dict[str, Any] | None, fee_type: str) -> float | None:
    if not station:
        return None
    for item in station.get("current_fees") or []:
        if item.get("fee_type") == fee_type:
            try:
                return float(item["fee"])
            except (KeyError, TypeError, ValueError):
                return None
    return None


class NioPowerSensor(SensorEntity):
    _attr_has_entity_name = True

    def __init__(
        self,
        coordinator: NioPowerCoordinator,
        entry_id: str,
        description: NioSensorDescription,
    ) -> None:
        self.coordinator = coordinator
        self.entity_description = description
        self._attr_unique_id = f"{entry_id}_{description.key}"
        self._attr_device_info = {
            "identifiers": {(DOMAIN, f"{entry_id}_{description.device}")},
            "name": "蔚来汽车" if description.device == DEVICE_VEHICLE else "蔚来换电站",
            "manufacturer": "NIO",
        }

    @property
    def native_value(self):
        data = self.coordinator.data or {}
        desc = self.entity_description
        if desc.device == DEVICE_VEHICLE:
            value = _pick(data.get("vehicle", {}), desc.path)
            if (
                desc.device_class == SensorDeviceClass.TIMESTAMP
                and isinstance(value, (int, float))
            ):
                # 上游 sample_time 是毫秒时间戳
                seconds = value / 1000 if value > 10**12 else value
                try:
                    return datetime.fromtimestamp(seconds, tz=timezone.utc)
                except (OSError, OverflowError, ValueError):
                    return None
            return value
        station = data.get("station") or {}
        if desc.path.startswith("__"):
            if desc.path.startswith("__fee_"):
                return _fee(
                    station,
                    "electricity_fee" if "electricity" in desc.path else "service_fee",
                )
            return _battery_stats(station).get(desc.path)
        value = _pick(station, desc.path)
        if isinstance(value, str) and desc.device_class == SensorDeviceClass.TIMESTAMP:
            try:
                return datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                return None
        if desc.device_class == SensorDeviceClass.TIMESTAMP and isinstance(
            value, (int, float)
        ):
            seconds = value / 1000 if value > 10**12 else value
            try:
                return datetime.fromtimestamp(seconds, tz=timezone.utc)
            except (OSError, OverflowError, ValueError):
                return None
        return value

    @property
    def available(self) -> bool:
        if self.coordinator.data is None:
            return False
        desc = self.entity_description
        if desc.device == DEVICE_STATION:
            return self.coordinator.station is not None
        return True

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(
            self.coordinator.async_add_listener(self.async_write_ha_state)
        )


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: NioPowerCoordinator = hass.data[DOMAIN][entry.entry_id]
    entities = [NioPowerSensor(coordinator, entry.entry_id, d) for d in VEHICLE_SENSORS]
    if coordinator.has_station:
        entities += [
            NioPowerSensor(coordinator, entry.entry_id, d) for d in STATION_SENSORS
        ]
    async_add_entities(entities)
