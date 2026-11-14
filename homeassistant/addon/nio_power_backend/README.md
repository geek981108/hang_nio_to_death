# 蔚来 NIO Power 后端（Home Assistant 加载项）

把 `backend/`（Rust + PostgreSQL）打包成 Home Assistant 本地加载项，并附带一个通过
HA 侧边栏访问的 Web 前端。可单独使用，也可以给 `homeassistant/custom_components/nio_power`
集成提供数据。

- 内置 PostgreSQL，数据在加载项的 `/data/postgres`，随 HA 备份一起备份
- 车控证书、PIN 由加载项选项写入 `/data/control`（权限 0600）
- **Web 前端（Ingress）**：交互对齐 iOS App——车辆仪表、车控（面板 → 执行前确认 → 结果核对）、
  按天切段的位置轨迹、行程、充电曲线、换电记录与详情、离车最近换电站（分时费率、站点搜索与保存、
  电池档位过滤）、用车账本、卡券与签到。页面受 HA 登录保护，密钥由加载项内的代理注入，浏览器接触不到

## 准备后端二进制

加载项不在 HA 主机上编译 Rust，`Dockerfile` 直接复制同目录下预编译的
`nio-swap-history-backend`（Linux x86_64，glibc，与 `debian:bookworm-slim` 运行时匹配）。
该文件不进版本库，任选一种方式放到本目录：

- 下载 GitHub Actions `Rust` 工作流产物 `nio-swap-history-backend-linux-x86_64`
- 在 Linux x86_64 上于 `backend/` 执行 `cargo build --locked --release`，复制 `target/release/nio-swap-history-backend`
- 用 Docker 编译（任意装有 Docker 的 x86_64 主机）：

  ```sh
  docker run --rm -v "$PWD/backend:/src" -w /src rust:1-bookworm \
    sh -c 'apt-get update -qq && apt-get install -y -qq libpq-dev && cargo build --locked --release'
  cp backend/target/release/nio-swap-history-backend homeassistant/addon/nio_power_backend/
  ```

## 安装

1. 把本目录（含二进制）复制到 HA 的 `/addons/nio_power_backend/`
2. 设置 → 加载项 → 加载项商店 → 右上角「检查更新」，「本地加载项」里出现本加载项
3. 安装后在「配置」中填写车辆凭据（见下表），启动
4. 日志出现 `listening address=0.0.0.0:8080` 和 `[proxy] serving /www` 即成功
5. 打开「显示于侧边栏」，侧边栏出现「我的蔚来」入口

升级时替换文件后在加载项页面「重建」。新版本的数据库迁移会在启动时自动执行，建议先做一次备份。

## 配置项

| 项 | 说明 |
|---|---|
| `bearer_token` | 蔚来账号 Token（iOS 渠道）。过期后需重新获取并更新本项 |
| `vehicle_id` / `device_id` / `account_id` | 账号与车辆标识；`account_id` 可选。`device_id` 建议使用 iOS App 的 32 位十六进制设备 ID|
| `app_version` | 请求里携带的 App 版本，默认 `6.9.0`。请求签名按 iOS App 进行（`app_id=10002`），需使用 iOS 渠道的 Token |
| `swap_model_type` / `swap_model_type_year` | 换电下单使用的车型与年款，例如 `ET5T` / `G1.2`、`ES8` / `G1.1` |
| `target_battery_cap_level` | 换电目标电池档位：1、2，或 8（102 kWh） |
| `api_key` | 后端 API Key。留空时自动生成并保存在加载项的 `/data/generated/api_key` |
| `postgres_password` | 内置数据库密码。留空时自动生成；不能含引号或反斜杠 |
| `control_api_key` / `control_tls_cert` / `control_tls_key` / `control_ca` / `pin` | 车控所需的密钥、客户端证书、私钥、服务端 CA 与 PIN。`control_api_key` 留空即关闭车控和换电下单 |

## 与集成对接

`custom_components/nio_power` 的「后端地址」填 `http://<HA 主机 IP>:<映射端口>`（默认 8080），
API Key 填本加载项的 `api_key`，车控 Key 填 `control_api_key`。

## 安全提示

- `control_api_key` 加上车控证书就等于远程操作车辆的能力，不要外传，也不要提交到任何仓库
- 后端 API 端口只应在局域网内使用；需要外网访问时走 HA 侧边栏（Ingress），或在反向代理 / Cloudflare 隧道前加客户端证书校验
