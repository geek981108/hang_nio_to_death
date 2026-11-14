"""Button platform for NIO Power 车辆控制。

按下按钮 → POST /api/v1/vehicle/action（需要车控 Key）。
解锁类动作由后端读取服务端 PIN 文件完成，无需在 HA 里存 PIN。
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import httpx
from homeassistant.components.button import ButtonEntity, ButtonEntityDescription
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


@dataclass(frozen=True, kw_only=True)
class NioButtonDescription(ButtonEntityDescription):
    action_key: str


BUTTONS = (
    NioButtonDescription(key="vehicle_lock", name="锁车", action_key="lock"),
    NioButtonDescription(
        key="vehicle_unlock", name="解锁车门", action_key="unlock_doors"
    ),
    NioButtonDescription(key="vehicle_find", name="寻车", action_key="find"),
    NioButtonDescription(
        key="vehicle_find_stop", name="停止寻车", action_key="find_stop"
    ),
    NioButtonDescription(
        key="vehicle_seat_heat_off", name="关闭座椅加热", action_key="seat_heat_off"
    ),
)


class NioPowerButton(ButtonEntity):
    _attr_has_entity_name = True

    def __init__(
        self,
        coordinator: NioPowerCoordinator,
        entry_id: str,
        entry_data: dict[str, Any],
        description: NioButtonDescription,
    ) -> None:
        self.coordinator = coordinator
        self.entry_data = entry_data
        self.entity_description = description
        self._attr_unique_id = f"{entry_id}_{description.key}"
        self._attr_device_info = {
            "identifiers": {(DOMAIN, f"{entry_id}_{DEVICE_VEHICLE}")},
            "name": "蔚来汽车",
            "manufacturer": "NIO",
        }

    async def async_press(self) -> None:
        action_name, confirmation = ACTIONS[self.entity_description.action_key]
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
            raise HomeAssistantError(f"车控请求失败: {err}") from err
        status = result.get("status", "unknown")
        verified = result.get("verified", False)
        _LOGGER.info("车控 %s -> status=%s verified=%s", action_name, status, verified)
        if status in ("unverified", "failed") or (
            status != "already_desired" and not verified and status != "accepted"
        ):
            raise HomeAssistantError(f"车控未确认: {result.get('message', status)}")
        await self.coordinator.async_request_refresh()


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: NioPowerCoordinator = hass.data[DOMAIN][entry.entry_id]
    if not str(entry.data.get(CONF_CONTROL_KEY, "")).strip():
        return
    async_add_entities(
        [
            NioPowerButton(coordinator, entry.entry_id, dict(entry.data), description)
            for description in BUTTONS
        ]
    )
