# Home Assistant

| 目录 | 作用 |
|---|---|
| `addon/nio_power_backend/` | 本地加载项：在 HA 主机上运行 `backend/`（内置 PostgreSQL），并通过 HA 侧边栏提供与 iOS App 交互一致的 Web 前端 |
| `custom_components/nio_power/` | 集成：把后端数据映射为 HA 传感器、开关量、车控按钮和空调开关，可用于自动化 |

两者可以单独使用：加载项本身就带完整前端；集成也可以连接部署在别处的后端。安装与配置见各目录的 README。

加载项需要的后端二进制与车辆凭据都不在版本库里：二进制按 `addon/nio_power_backend/README.md` 编译或下载，凭据只填在 HA 的加载项配置中。
