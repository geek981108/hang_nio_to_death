# BLE / UWB：方法体复核与 iOS 接入缺口

日期：2026-11-25。接续 [综合分析记录](android-ble-uwb-rps-analysis.md)。

本篇保留第一次方法体复核的范围。进一步展开见 [BLE 生命周期](android-ble-lifecycle-detailed-analysis.md)、[UWB 创建及设置](android-uwb-detailed-analysis.md)、[RPS 状态与数据映射](android-rps-state-detailed-analysis.md)；其中新增的证据优先于本篇早期未完成项。

## 证据范围与方法

本次仅处理既有本机内存转储和离线 JADX 输出，没有再次 attach Frida、读取登录凭据、创建数字钥匙或发送车辆命令。结论属于恢复代码的静态分析，未做实车验证。既有运行环境记录为 Android App 6.9.0；不能把工作区另外保存的 6.9.6 APK 当成这些方法体的来源。

在 `/private/tmp/nio-scudo.bin` 中搜索标准 DEX magic、检查头部 size 与文件边界，再按目标类名定位候选并提取。JADX 能恢复以下业务类；这不证明整个 APK 已完整恢复。此前 VDEX/壳入口无法直接恢复业务代码的结论仅适用于那些旧样本。

| 样本文件（位于 `/private/tmp`） | 转储偏移 | 长度 | SHA-256 |
| --- | ---: | ---: | --- |
| nio-analysis-ble.dex | 265183232 | 2569676 | 8480de96d26f7231d2558d283038e71cd1c24cf9bb66c211b895d0d55e24d65c |
| nio-analysis-uwb.dex | 243789824 | 4258204 | e3e4d65c1a98a59619c4ea2776c3788a4289ef5118a80ce6914e2aceec24faa9 |
| nio-analysis-rps.dex | 251191296 | 3715400 | d47d70b7217f20836211dcc8dbe9b7784eb6b7f3db445d1b949e41a6ef18219e |

这些文件名仅为分析标签，不代表各 DEX 只包含对应模块。输出目录为 `/private/tmp/nio-analysis-radio-src/sources`。本次 JADX 结束码为 3，报告 591 个错误；属于部分恢复，不是全量反编译成功。本文仅使用已检查的局部输出，失真分支和缺失方法不能据此补猜。下文给出类、方法及关键行为，便于临时文件清理后仍能追溯分析；原始内存可能含账号数据，不提交到仓库。

## UWB：已经确认系统数字钥匙 SDK 分支

证据类位于 `com.nio.rb.virtual.key.utils.ccc`：

- `RbUwbManager` 的懒加载工厂根据 `PlatformSource.a.g()` 选择 `SamsungUwbManager` 或 `DefaultUwbManager`。
- `impl.SamsungUwbManager` 引用 `org.carconnectivity.android.digitalkey.framework.sdk.DigitalKeyManager`，通过异步 callback 请求服务；成功缓存 manager，失败向 Observable 传播错误。
- `isSupport()` 在获取服务后检查系统 feature `samsung.hardware.uwb`。
- `hasUwbBleKey` 分支检查 SDK 返回的钥匙列表是否为空；`checkKeyAvailable` 按 `DigitalKeyDataListItem.getDigitalKeyId()` 匹配指定 keyId。
- 存在 `createDigitalKey` SDK 调用链。它属于钥匙生命周期管理证据，不是已取得创建权限或可复制钥匙的证据。
- `DefaultUwbManager` 的能力检测返回 false，其余部分方法返回空 Observable。这里只说明这个抽象层的默认行为，不能推断所有非三星手机都不支持 NIO UWB。

因此，至少这条 UWB 路径依赖 OEM 数字钥匙服务，并非页面直接使用通用测距 API。未发现这条路径输出距离、角度或将测距结果送入 RPS 的证据。不能把“支持 UWB 钥匙”与“UWB 离车泊入已经可复刻”画等号；`nearTheVehicle` 的真实来源仍待追踪。

## BLE：生命周期管理与协议层分开

`com.nio.rb.virtual.key.service.BleDigitalKeyService2` 方法体包含 `registerKeyFlow()`、`startScanJob()`、`checkAndScan` 以及销毁清理入口，与此前反射得到的字段和签名一致。它负责持续服务与钥匙状态订阅；仅凭这个类仍无法得到 GATT 服务 UUID、特征值、认证消息或加密帧。

后续应沿服务调用的 manager/client 边界继续追踪，分别记录连接状态、合法钥匙可用状态、通知订阅状态和业务会话状态。四者不能压成一个 `isConnected`。当前 Swift 主 App 源码搜索未见 `CoreBluetooth` 或 `NearbyInteraction` 引用；此检查只覆盖 `NIOPowerSwapAssist/**/*.swift`，不代表所有依赖和平台能力均已审计。

## RPS：纠正心跳误判

证据：`com.nio.rb.rps.viewmodel.BaseRpsSessionViewModel`。

1. `lastHeartbeatTimestamp` 所在协程比较时间差是否大于 250 ms，满足时调用 `getVibrateService().a()` 并更新时间戳。**这里是触觉反馈节流，不是无线安全心跳的证据。**
2. `sendMoveCommand` 的协程可见初始等待、在协程有效期间循环调用 `rpsService`、更新方向 LiveData、再等待的结构。它说明移动请求是持续会话；实际无线发送、应答、重传和超时需到下层验证，不能从 UI 协程直接定义通信协议。
3. 基类 `onRpsMessage` 是空实现，状态解释需查具体子类；不能把基类回调存在当作已完成障碍物字段映射。

原文关于生命周期中断、来电与用户操作中断的线索仍有效，但不能声称已经验证车辆端失联停止。手机主动发送暂停与车辆端独立失联保护是两个验收项目。

## iOS 后续工作边界

现在可做的是整理 transport、钥匙状态、会话状态和 UI 生命周期的接口，并用模拟 transport 验证状态切换。Android OEM 的 DigitalKeyManager 不能直接翻译为 iOS API；需要另行确认车辆支持的 iOS 数字钥匙接入、合法授权及平台接口。

尚缺：GATT 契约、合法钥匙认证流程、帧格式、状态字段单位、实际通信时序、失联行为、UWB 与 RPS 的关联证据。没有这些证据，不应把占位实现接到实车移动操作。

后续验证优先顺序：离线追踪 manager/client 与状态解析 → 核对 iOS 可用接入方式 → 模拟连接/断开/过期/后台状态 → 在具备完整协议与测试条件后单独安排受控验证。本轮未添加 Swift/Rust 功能代码。
