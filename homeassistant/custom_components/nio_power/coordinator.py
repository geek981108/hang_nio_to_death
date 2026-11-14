"""DataUpdateCoordinator for NIO Power.

轮询后端（自建代理服务）：
- /api/v1/vehicle/status        车辆状态
- /api/v1/stations/{id}/live    换电站实时信息（配置了站点 ID 时）
- /api/v1/status                后端健康状态
"""
from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

import httpx
from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import (
    CONF_API_KEY,
    CONF_BACKEND_URL,
    CONF_SCAN_INTERVAL,
    CONF_STATION_ID,
    DOMAIN,
)

_LOGGER = logging.getLogger(__name__)


class NioPowerCoordinator(DataUpdateCoordinator[dict[str, Any]]):
    """Coordinator fetching data from the NIO backend proxy."""

    def __init__(self, hass: HomeAssistant, entry_data: dict[str, Any]) -> None:
        self.backend_url: str = str(entry_data[CONF_BACKEND_URL]).rstrip("/")
        self.api_key: str = str(entry_data.get(CONF_API_KEY, ""))
        raw_station = str(entry_data.get(CONF_STATION_ID, "")).strip()
        if raw_station and raw_station.lower() in ("auto", "nearest", "自动"):
            raw_station = ""
        self.station_id: str | None = raw_station or None
        # 未填站点 ID = 自动模式：根据车辆位置取最近换电站
        self.auto_station: bool = self.station_id is None
        interval = int(entry_data.get(CONF_SCAN_INTERVAL, 60))
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=interval),
        )

    @property
    def has_station(self) -> bool:
        return self.auto_station or self.station_id is not None

    @property
    def vehicle(self) -> dict[str, Any]:
        return self.data.get("vehicle", {}) if self.data else {}

    @property
    def station(self) -> dict[str, Any] | None:
        if not self.data:
            return None
        return self.data.get("station")

    async def _async_update_data(self) -> dict[str, Any]:
        headers = {"X-API-Key": self.api_key}
        async with httpx.AsyncClient(timeout=25) as client:
            try:
                status_resp = await client.get(
                    f"{self.backend_url}/api/v1/vehicle/status", headers=headers
                )
                status_resp.raise_for_status()
                vehicle = status_resp.json().get("data", {})
            except httpx.HTTPError as err:
                raise UpdateFailed(f"车辆状态请求失败: {err}") from err

            station = None
            if self.auto_station or self.station_id:
                station_path = (
                    "api/v1/stations/nearest"
                    if self.auto_station
                    else f"api/v1/stations/{self.station_id}/live"
                )
                try:
                    station_resp = await client.get(
                        f"{self.backend_url}/{station_path}",
                        headers=headers,
                    )
                    station_resp.raise_for_status()
                    payload = station_resp.json()
                    # live 接口返回顶层字段（无 data 包装），同时兼容带包装的情况
                    station = (
                        payload.get("data")
                        if isinstance(payload, dict)
                        and isinstance(payload.get("data"), dict)
                        else payload
                    )
                except httpx.HTTPError as err:
                    _LOGGER.warning("换电站请求失败（保留旧数据）: %s", err)
                    station = (self.data or {}).get("station")

        return {"vehicle": vehicle, "station": station}
