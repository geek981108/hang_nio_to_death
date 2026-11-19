"""Binary sensor platform for NIO Power."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
    BinarySensorEntityDescription,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DEVICE_VEHICLE, DOMAIN
from .coordinator import NioPowerCoordinator


def _pick(data: dict[str, Any], path: str, default: Any = None) -> Any:
    node: Any = data
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node


@dataclass(frozen=True, kw_only=True)
class NioBinarySensorDescription(BinarySensorEntityDescription):
    path: str
    invert: bool = False


BINARY_SENSORS = (
    NioBinarySensorDescription(
        key="vehicle_locked",
        name="已锁车",
        path="door_status.vehicle_lock_status",
        device_class=BinarySensorDeviceClass.LOCK,
    ),
    NioBinarySensorDescription(
        key="vehicle_connected",
        name="车辆在线",
        path="connection_status.connected",
        device_class=BinarySensorDeviceClass.CONNECTIVITY,
    ),
    NioBinarySensorDescription(
        key="vehicle_charging",
        name="充电中",
        path="soc_status.charge_state",
        device_class=BinarySensorDeviceClass.BATTERY_CHARGING,
    ),
    NioBinarySensorDescription(
        key="vehicle_swapping",
        name="换电中",
        path="special_status.swapping",
    ),
    NioBinarySensorDescription(
        key="vehicle_ac_on",
        name="空调开启",
        path="hvac_status.air_conditioner_on",
    ),
    NioBinarySensorDescription(
        key="vehicle_door_open",
        name="车门开启",
        path="door_status.door_ajar_front_left_status",
        device_class=BinarySensorDeviceClass.DOOR,
        invert=True,
    ),
)


class NioPowerBinarySensor(BinarySensorEntity):
    _attr_has_entity_name = True

    def __init__(
        self,
        coordinator: NioPowerCoordinator,
        entry_id: str,
        description: NioBinarySensorDescription,
    ) -> None:
        self.coordinator = coordinator
        self.entity_description = description
        self._attr_unique_id = f"{entry_id}_{description.key}"
        self._attr_device_info = {
            "identifiers": {(DOMAIN, f"{entry_id}_{DEVICE_VEHICLE}")},
            "name": "蔚来汽车",
            "manufacturer": "NIO",
        }

    @property
    def available(self) -> bool:
        return self.coordinator.data is not None

    @property
    def is_on(self) -> bool | None:
        if self.coordinator.data is None:
            return None
        raw = _pick(self.coordinator.vehicle, self.entity_description.path)
        if raw is None:
            return None
        value = bool(raw)
        if self.entity_description.invert:
            value = not value
        return value

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
    async_add_entities(
        [
            NioPowerBinarySensor(coordinator, entry.entry_id, description)
            for description in BINARY_SENSORS
        ]
    )
