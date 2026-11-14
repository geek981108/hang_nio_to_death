"""Config flow for NIO Power.

配置项（全部由用户输入）：
- 后端地址（自建代理服务）
- API Key（个人账户生成）
- 车控 Key（可选，留空则没有车控实体）
- 换电站 ID（可选，留空则没有站点实体）
"""
from __future__ import annotations

import logging
from typing import Any

import httpx
import voluptuous as vol

from homeassistant.config_entries import ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.core import callback
import homeassistant.helpers.config_validation as cv

from .const import (
    CONF_API_KEY,
    CONF_BACKEND_URL,
    CONF_CONTROL_KEY,
    CONF_SCAN_INTERVAL,
    CONF_STATION_ID,
    DEFAULT_BACKEND_URL,
    DEFAULT_SCAN_INTERVAL,
    DOMAIN,
)

_LOGGER = logging.getLogger(__name__)

STEP_USER_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_BACKEND_URL, default=DEFAULT_BACKEND_URL): cv.string,
        vol.Required(CONF_API_KEY): cv.string,
        vol.Optional(CONF_CONTROL_KEY): cv.string,
        vol.Optional(CONF_STATION_ID): cv.string,
        vol.Required(CONF_SCAN_INTERVAL, default=DEFAULT_SCAN_INTERVAL): vol.All(
            vol.Coerce(int), vol.Range(min=15, max=3600)
        ),
    }
)


class NioPowerConfigFlow(ConfigFlow, domain=DOMAIN):
    """Handle a config flow for NIO Power."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                await self._validate(user_input)
            except (httpx.HTTPError, ValueError) as err:
                _LOGGER.warning("配置校验失败: %s", err)
                errors["base"] = "cannot_connect"
            else:
                title = f"NIO Power ({user_input[CONF_BACKEND_URL].rstrip('/')})"
                return self.async_create_entry(title=title, data=user_input)

        return self.async_show_form(
            step_id="user", data_schema=STEP_USER_SCHEMA, errors=errors
        )

    async def _validate(self, user_input: dict[str, Any]) -> None:
        url = str(user_input[CONF_BACKEND_URL]).rstrip("/")
        if not url.startswith(("http://", "https://")):
            raise ValueError("后端地址必须以 http:// 或 https:// 开头")
        headers = {"X-API-Key": str(user_input[CONF_API_KEY])}
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{url}/api/v1/status", headers=headers)
            resp.raise_for_status()
            if resp.json().get("vehicle_configured") is not True:
                raise ValueError("后端未配置车辆凭据（vehicle_configured=false）")

    @staticmethod
    @callback
    def async_get_options_flow(
        config_entry,
    ) -> OptionsFlow:
        return NioPowerOptionsFlow(config_entry)


class NioPowerOptionsFlow(OptionsFlow):
    """Options flow：改站点 ID 或刷新间隔，不重建 Key。"""

    def __init__(self, config_entry) -> None:
        self.config_entry = config_entry

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        if user_input is not None:
            return self.async_create_entry(title="", data=user_input)

        data = self.config_entry.data
        schema = vol.Schema(
            {
                vol.Optional(
                    CONF_STATION_ID, default=data.get(CONF_STATION_ID, "")
                ): cv.string,
                vol.Required(
                    CONF_SCAN_INTERVAL,
                    default=int(data.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL)),
                ): vol.All(vol.Coerce(int), vol.Range(min=15, max=3600)),
            }
        )
        return self.async_show_form(step_id="init", data_schema=schema)
