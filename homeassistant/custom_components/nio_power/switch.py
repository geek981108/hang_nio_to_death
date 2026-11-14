"""Switch platform for NIO Power：空调开关。

状态来自车辆状态 hvac_status.air_conditioner_on；
开关动作通过 /api/v1/vehicle/action 下发（需要车控 Key）。
"""
from __future__ import annotations

import logging
from typing import Any

import httpx
from homeassistant.components.switch import SwitchEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import (
    ACTIONS,
    CONF_API_KEY,
    CONF_BACKEND_URL,
    CONF_CONTROL_KEY,
    DEVICE_VEHICLE,
    DOMAIN,
)
from .coordinator import NioPowerCoordinator

_LOGGER = logging.getLogger(__name__)


class NioPowerAcSwitch(SwitchEntity):
    _attr_has_entity_name = True
    _attr_name = "空调"

    def __init__(
        self,
        coordinator: NioPowerCoordinator,
        entry_id: str,
        entry_data: dict[str, Any],
    ) -> None:
        self.coordinator = coordinator
        self.entry_data = entry_data
        self._attr_unique_id = f"{entry_id}_vehicle_ac"
        self._attr_device_info = {
            "identifiers": {(DOMAIN, f"{entry_id}_{DEVICE_VEHICLE}")},
            "name": "蔚来汽车",
            "manufacturer": "NIO",
        }

    @property
    def is_on(self) -> bool | None:
        if self.coordinator.data is None:
            return None
        hvac = self.coordinator.vehicle.get("hvac_status") or {}
        if "air_conditioner_on" not in hvac:
            return None
        return bool(hvac["air_conditioner_on"])

    async def _send_action(self, action_key: str) -> None:
        action_name, confirmation = ACTIONS[action_key]
        url = f"{str(self.entry_data[CONF_BACKEND_URL]).rstrip('/')}/api/v1/vehicle/action"
        headers = {
            "X-API-Key": str(self.entry_data[CONF_API_KEY]),
            "X-Vehicle-Control-Key": str(self.entry_data.get(CONF_CONTROL_KEY, "")),
        }
        payload = {"action": action_name, "confirmation": confirmation}
        try:
            async with httpx.AsyncClient(timeout=60) as client:
                resp = await client.post(url, headers=headers, json=payload)
                resp.raise_for_status()
                result = resp.json()
        except httpx.HTTPError as err:
            raise HomeAssistantError(f"空调指令失败: {err}") from err
        _LOGGER.info("空调 %s -> status=%s", action_name, result.get("status"))
        await self.coordinator.async_request_refresh()

    async def async_turn_on(self, **kwargs: Any) -> None:
        await self._send_action("ac_on")

    async def async_turn_off(self, **kwargs: Any) -> None:
        await self._send_action("ac_off")


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: NioPowerCoordinator = hass.data[DOMAIN][entry.entry_id]
    if not str(entry.data.get(CONF_CONTROL_KEY, "")).strip():
        return
    async_add_entities(
        [NioPowerAcSwitch(coordinator, entry.entry_id, dict(entry.data))]
    )
