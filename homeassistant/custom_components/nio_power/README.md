# 蔚来 NIO Power Home Assistant 集成

把自建后端代理（`nio-swap-history-backend`）的能力移植进 Home Assistant：

- **车辆传感器**：电量、剩余续航、实际续航、总里程、车外温度、充电功率、状态更新时间
- **车辆开关量**：已锁车、车辆在线、充电中、换电中、空调开启、车门开启
- **车控**：锁车 / 解锁车门（PIN 在服务端）/ 寻车 / 停止寻车 / 关闭座椅加热 按钮 + 空调开关
- **换电站**（可选）：排队车辆、可换电池（目标档位 / 全部）、电池总数、充电中电池、电费/服务费、站点更新时间

## 安装

把 `custom_components/nio_power` 整个目录放到 Home Assistant 配置目录的
`custom_components/` 下，重启 HA。

```
/config/custom_components/nio_power/
├── manifest.json
├── strings.json
├── translations/
│   ├── zh-Hans.json
│   └── en.json
├── __init__.py
├── config_flow.py
├── coordinator.py
├── sensor.py
├── binary_sensor.py
├── button.py
└── switch.py
```

## 配置（设置 → 设备与服务 → 添加集成 → 搜索 "NIO Power"）

| 输入项 | 说明 |
|---|---|
| 后端地址 | 自建后端的地址，如 `http://<HA 主机 IP>:8080`（使用本仓库的 HA 加载项时即加载项映射的端口） |
| API Key | 后端 `.env` 里的 `API_KEY` |
| 车控 Key（可选） | 后端 `.env` 里的 `NIO_CONTROL_API_KEY`；留空则不创建车控实体 |
| 换电站 ID（可选） | 形如 `PS-NIO-xxxxxxxx-xxxxxxxx`；留空则不创建站点实体 |
| 刷新间隔 | 默认 60 秒 |

> 解锁车门会触达真车（服务端已存 PIN），请在 HA 里谨慎暴露该按钮。

## 实体示例

- `sensor.dian_liang`（电量 %）、`sensor.sheng_yu_xu_hang`（km）
- `binary_sensor.yi_suo_che`、`binary_sensor.chong_dian_zhong`
- `button.suo_che`、`button.xun_che`
- `switch.kong_tiao`
- `sensor.pai_dui_che_liang`、`sensor.ke_huan_dian_chi_102kwh`
