# 原版 Android：发送导航路线到车机

日期：2026-11-25。本轮为离线源码分析，没有实际发送导航，也未验证车机接收。这里只确认已找到的路线规划链路，不声称它是原版全部导航发送入口。

## 已确认的调用链

`RoutePlanRouteFragment.sendRouteToCar` → `generateRoutePlanSendCarParam` → 查询车辆权限、尝试补充车辆位置 → `requestSendCsar`（源码即此拼写）→ `RoutePlanV2ViewModel.sendRouteToCar` → `PEService.sendRouteToCar`。

这是云端 HTTP 路径，所见调用链没有 BLE/UWB 依赖。实现该功能不必先完成本地数字钥匙协议。

| 方法 | 路径 | 静态契约 |
| --- | --- | --- |
| GET | `/app/api/pe/v1/route/send-vehicle/switch` | query `vehicle_id`；返回 `PEResponse<RoutePlanSwitch>` |
| POST | `/app/api/pe/v1/route/send-vehicle` | JSON body `RoutePlanSendCarRequest`；返回 `PEResponse<RoutePlanSendCarResponse>` |

开关模型字段为可空 Boolean `expose_send_vehicle_button`。接口声明本身没有固定 host；本轮未重新验证该 service 实际 base URL、签名、认证 header 或 TLS 配置，不能仅凭路径直接认定现有后端请求封装兼容。

## 请求模型与构建规则

| JSON 字段 | 模型类型 | 原版构建来源 |
| --- | --- | --- |
| `btn_action` | Integer，可空 | 首次调用可空；后续由服务端弹窗的被选按钮提供 |
| `poi_list` | Poi 数组，模型非空 | 从规划结果按原顺序筛选；构建函数拒绝空列表 |
| `vehicle.vehicle_id` | String，可空 | 当前规划所选车辆；实际发送入口检查车辆 ID |
| `vehicle.location` | String，可空 | 有权限且位置有效时补充 |
| `driver.route_driver_duration` | Integer，可空 | summary.planDriveDuration |
| `driver.charge_times` | Integer，可空 | summary.planChargeCount |
| `driver.route_distance` | Integer，可空 | summary.driveDistance 转 int |
| `route_id` | String，可空 | 当前规划结果 route_id |

模型可空不等于服务端可省略。特别是“任意单点 POI、不带 route_id 能否发送”尚未验证。

Poi 字段为 `location`、`name`、`address`、`resource_id`、`clone_location`、`next_point_distance`、`station_type`；最后一个使用 `RoutePlan.RouteResource.NodeType`，不能凭名称自行指定数字枚举。

构建规则：

- 遍历 `resourcesAndPoints`，只保留 `need_send_vehicle == true` 且属于 candidate 或 POI 类型的节点。
- 普通 POI 使用节点位置与名称，地址为空时退回名称。
- 资源节点携带原始换电站资源 ID、下一候选点距离及类型；克隆站点分支还涉及 clone 信息。
- 克隆站点附近存在 JADX 生成的明显不合理空值分支，需用字节码或其他证据复核，不能照抄为业务代码。
- `new Vehicle(vehicleId, 2)` 的第二个值来自 Kotlin 默认参数合成构造器，不能解释为车种、坐标类型或请求字段值。

车辆位置回调中，源码把第二个 Double、逗号、第一个 Double 拼成字符串。仅凭这里无法确认经纬度参数名和坐标系；POI location 则直接沿用规划结果。距离/时长单位也不能仅凭字段名断定。移植时应优先保留原规划输出，补充坐标和单位证据后再接自建 POI。

车辆权限结果为 false/null 或位置不可用时，这条 UI 链仍会调用发送请求，只是不补充位置。这不表示服务器绕过权限；目标车辆访问权仍必须由后端验证。

## 响应与确认交互

外层 `PEResponse` 判断业务成功；内层包括：

- `toast_msg`：可空提示文字。
- `popup_message`：可空对象，含 `content`、`left_btn_text`、`left_btn_action`、`right_btn_text`、`right_btn_action`。

原版成功分支优先处理 popup：没有 popup 时展示非空 toast；有 popup 则显示服务端按钮。用户点击后，若对应 action 非空，把 action 写回**同一个请求**的 `btn_action`，再次调用发送接口；action 为空则不再次发送。左右按钮不能固定解释成取消/确认，也不能自动选择一个 action。

HTTP 成功、业务成功、出现提示、车机真正收到路线是不同证据层级。本轮仅确认静态调用与模型，没有车机回执证据。

## 接到本项目的建议（未实施）

Rust 后端封装开关查询与发送接口；使用当前租户的合法会话和车辆绑定，不能接受任意 vehicle_id 直接转发。先核对原版 service 的认证、公共参数与 host，再复用项目中适用的请求组件。

iOS 展示选定车辆与路线摘要，用户主动发送后展示业务提示或服务端确认弹窗。对需要确认的请求，后端可保存短期请求上下文，将确认 action 与租户、车辆和原始路线绑定，防止串车或误用旧弹窗。

发送超时但无法确定上游是否接收时，显示结果未知，不自动盲目重试；目前未发现可依赖的幂等字段。保留脱敏的业务码、request_id 和错误文字以便诊断，避免记录具体轨迹及凭据。

实施前应覆盖：开关关闭/缺失、空路线、车辆切换、位置缺失、业务失败、无 popup、有 popup、空 action、确认期间路线变更、超时结果未知。最终验收需单独验证车机收到的路线与选定路线一致。本轮没有改动 App 或后端代码。

## 源码证据索引

证据来自 `/private/tmp/nio-unity.dex`，SHA-256 `c6f965f8e87954fad3384fd0601134bd5d0e1e20785faf2f17768697d30e567d`；JADX 根目录 `/private/tmp/nio-unity-src/sources/cn/com/weilaihui3/chargingmap`。临时目录不作为永久文档依赖，关键契约与结论已记录在本文。

| 源码相对路径 | 定位 |
| --- | --- |
| `service/PEService.java` | `getSendRouteToCarSwitch`、`sendRouteToCar` 注解及签名 |
| `service/model/RoutePlanSwitch.java` | expose_send_vehicle_button |
| `service/repository/request/RoutePlanSendCarRequest.java` | SerializedName、Vehicle/Driver/Poi 构造器 |
| `service/repository/response/RoutePlanSendCarResponse.java` | Popup 与 toast 模型 |
| `routeplanning/RoutePlanRouteFragment.java` | 3436 附近响应处理；3756 附近位置回调；5411 附近请求构建；5996 附近发送入口 |
| `routeplanning/viewmodel/RoutePlanV2ViewModel.java` | 开关查询与发送协程入口 |

行号仅对本次反编译输出有效；存在热修复分派和反编译控制流失真，因此源码结论不能代替运行时验证。
