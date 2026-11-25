"""Constants for the NIO Power integration."""

DOMAIN = "nio_power"

CONF_BACKEND_URL = "backend_url"
CONF_API_KEY = "api_key"
CONF_CONTROL_KEY = "control_key"
CONF_STATION_ID = "station_id"
CONF_SCAN_INTERVAL = "scan_interval"

DEFAULT_BACKEND_URL = "http://homeassistant.local:8080"
DEFAULT_SCAN_INTERVAL = 60

PLATFORMS = ["sensor", "binary_sensor", "button", "switch"]

DEVICE_VEHICLE = "vehicle"
DEVICE_STATION = "station"

# 车辆动作 → 后端 confirmation 文本
ACTIONS = {
    "lock": ("lock", "LOCK VEHICLE"),
    "unlock_doors": ("unlock-doors", "UNLOCK DOORS"),
    "find": ("find", "FIND VEHICLE"),
    "find_stop": ("find-stop", "STOP FINDING"),
    "ac_on": ("ac-on", "START AC"),
    "ac_off": ("ac-off", "STOP AC"),
    "seat_heat_off": ("seat-heat-off", "STOP SEAT HEATING"),
}
