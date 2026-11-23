# NIO 原版 App 与 NIOPowerSwapAssist：上游协议综合分析记录

更新日期：2026-11-23

## 1. 目的

本记录汇总围绕 NIO 原版 App、上游接口、Rust 后端和 `NIOPowerSwapAssist` iOS 新版 App 已做的分析、使用的方法、当前证据和仍未解决的问题。BLE/UWB/RPS 是当前重点，同时保留此前登录、mTLS、行程、充电、车辆图片、换电站与电池容量等分析：

- BLE 数字钥匙证书与认证流程；
- BLE GATT 服务及加密协议；
- RPS/RPA 激活、移动、暂停与退出；
- 泊车状态、轨迹和障碍物数据；
- 高频安全心跳；
- UWB 在数字钥匙和离车泊入中的实际职责。

本轮工作的性质是**只读逆向分析和离线设计准备**，尚未向实车发送任何泊车或数字钥匙命令。

## 2. 安全边界

本轮始终遵守以下边界：

1. 不尝试绕过车辆所有权、账号权限、数字钥匙授权或 Apple/NIO 的正式开通流程。
2. 不导出、记录或提交数字钥匙私钥、账号 Token、手机号、验证码、车辆 ID 或控制 PIN。
3. 不在协议字段、UUID、操作码或加密方式未知时构造猜测数据并发送。
4. 不调用实车的激活、移动、暂停、退出、解锁或启动接口。
5. Frida 仅用于读取原版 App 的类、字段、方法签名和内存布局。
6. iOS 移植在协议完全确认前必须保持“发送禁用”，测试只能使用 mock transport 或离线录制数据。
7. `tools/.env`、证书私钥目录和现有本地凭据没有作为本轮分析输入，也没有复制到报告中。

## 3. 分析对象

### 3.1 静态安装包

- 文件：`tools/apk/NIO_CN_latest.apk`
- 包名：`cn.com.weilaihui3`
- 版本：6.9.6
- versionCode：60906
- SHA-256：`6cd7ba9d9b76c56217df723583e9edf47939d79bd6b40f6062b4045828b6db6f`

同时保留了旧版 `tools/apk/NIO_3.9.0_APKPure.apk`，但本轮 BLE/RPS 结论主要来自 6.9.x。

### 3.2 运行时 App

- 模拟器内版本：6.9.0
- versionCode：60900
- Android 包名：`cn.com.weilaihui3`
- AVD：`NIO_Root_API33`
- Android：API 33，arm64
- Frida：16.5.9

静态资源来自 6.9.6，运行时类反射来自 6.9.0。两类证据分别标记，不能假定两个版本的每个实现细节完全相同。

## 4. 使用的方法

### 4.1 APK 静态检查

使用 `aapt`、`apktool`、`jadx`、`rg` 和标准归档工具完成：

- Manifest 权限、Activity、Service、Deep Link 清单；
- RPS/RPA、BLE 数字钥匙和 UWB 页面资源检索；
- 布局、Navigation Graph、字符串和 Kotlin module 元数据检查；
- native library 与壳特征检查。

示例命令：

```bash
aapt dump badging tools/apk/NIO_CN_latest.apk
apktool d -f -o /private/tmp/nio696_resources tools/apk/NIO_CN_latest.apk
jadx -d /private/tmp/nio696_jadx tools/apk/NIO_CN_latest.apk
rg -n 'uwb|rps|rpa|digitalkey|BleDigitalKeyService' /private/tmp/nio696_resources
```

### 静态分析限制

APK 使用 SecNeo/Bangcle 类保护：

- 壳类主要位于 `com.secneo.apkwrapper.*`；
- APK 包含 `libDexHelper.so` 和 `libDexHelper-x86.so`；
- 直接 JADX 反编译只能得到少量壳和路由类，不能得到完整业务方法体。

因此，资源和 Manifest 可作为直接静态证据，但完整 BLE/RPS 代码需要运行时反射或解密 DEX。

### 4.2 Android 模拟器与 Frida 只读反射

启动 AVD 后，通过 ADB 启动原版 App，再附加 Frida。原版 App 对 Frida 有检测，附加后存在短暂观察窗口，随后进程可能退出或重启。

在观察窗口内执行了：

- 已加载类枚举；
- 指定类的 superclass、interface、field、constructor、method 反射；
- ClassLoader 检查；
- DEX 内存区域搜索；
- 未调用目标类的车辆控制方法。

本轮生成的临时脚本位于：

```text
/private/tmp/nio-enumerate-runtime.py
/private/tmp/nio-classloaders.py
/private/tmp/nio-app-class-inventory.py
/private/tmp/nio-reflect-targets.py
/private/tmp/nio-reflect-rps.py
/private/tmp/nio-find-rps-dex.py
/private/tmp/nio-locate-rps-dex-header.py
```

这些是临时分析文件，不属于项目交付物，系统清理 `/private/tmp` 后可能消失。

### 4.3 VDEX 与内存 DEX 调查

`frida-dexdump` 在附加窗口内找到了约 129 个候选 DEX 区域，但 App 在首个完整内存转储前退出，因此没有通过该工具得到可用 DEX 文件。

随后采用了两条路径：

1. 通过 root ADB 只读复制 ART 生成的 `base.vdex`；
2. 用 Frida 搜索类描述符，定位包含 RPS 字符串的匿名内存范围和 VDEX 映射。

临时文件：

```text
/private/tmp/nio-base.vdex
/private/tmp/nio-base.dex
```

观察结果：

- `base.vdex` 大约 320 MiB，格式版本为 `vdex027`；
- VDEX 中能找到 `RpsService`、`BaseRpsSessionViewModel` 等字符串；
- VDEX 中嵌入的标准 DEX 只声明约 40 个壳/路由类，大量业务类只以共享字符串或 ART 数据形式存在；
- 直接用 JADX 指定 `BaseRpsSessionViewModel` 或 `RpsService` 会报告 class not found；
- 这说明复制出的 VDEX 不是完整、可直接反编译的解密业务 DEX。

一次扩大的 Frida 内存扫描因范围过大触发 transport timeout。该失败没有产生车辆操作，但说明后续应改用更小范围、分段和明确停止条件的扫描，而不是重复同一大范围请求。

## 5. 已确认的 Android 架构

以下结论来自运行时类和方法反射，置信度高。

### 5.1 BLE 数字钥匙是常驻能力

已观察类：

- `com.nio.lego.com.digitalkey.ble.LgBle`
- `com.nio.lego.digitalkey.engine.NioAppBleKit`
- `com.nio.lego.digitalkey.engine.utils.BluetoothSwitchReceiver`
- `com.nio.lego.digitalkey.stack.utils.LgBle`
- `com.nio.rb.virtual.key.BleKit`
- `com.nio.rb.virtual.key.manager.BleKeyManager`
- `com.nio.rb.virtual.key.nio.ble.NioBleVirtualKeyManager`
- `com.nio.rb.virtual.key.service.BleDigitalKeyService2`

`BleDigitalKeyService2` 是 `LifecycleService`，具有：

- 当前车辆 ID；
- 运行状态；
- 上次 BLE 状态；
- `registerKeyFlow()`；
- `startScanJob()`；
- 前台 Service 生命周期处理。

这说明 BLE 数字钥匙不是某个页面临时扫描，而是持续维护的本地服务。

### 5.2 BLE 客户端按车辆管理

`NioAppBleKit` 持有：

- `ConcurrentHashMap<String, NioAppBleClient>`；
- `ConcurrentHashMap<String, MutableStateFlow<Boolean>>`；
- `BleDetailedKeyInfo` 列表；
- BLE 激活结果回调。

因此，多车辆情况下 BLE client 和连接状态按车辆键管理，而不是一个全局裸连接。

### 5.3 数字钥匙管理器包含身份与证书模式

`BleKeyManager` 实现 `IBleVirtualKeyManager`。其初始化入口包含：

- Android Context；
- 车辆标识；
- 设备标识；
- `VirtualKeyCertMode`；
- `DkCertMode`；
- 协议 Platform；
- 成功、失败和异常回调。

当前只确认接口形状，尚未得到：

- 证书申请 URL；
- 证书正文格式；
- 私钥生成和存储规则；
- 挑战应答算法；
- GATT authentication frame 格式。

这些未知项不能通过名称猜测后实现。

### 5.4 BLE 是 RPS 泊车控制主链

`BaseRpsSessionViewModel` 持有：

- `RpsService`；
- `bleStateLd`；
- `directionLd`；
- `rpsStateLd`；
- `lastHeartbeatTimestamp`；
- `moveJob`；
- `vehicleId`。

已观察方法：

- `sendMoveCommand(RpsDirection)`；
- `sendPauseCommand()`；
- `stopRpsService()`；
- `onRpsMessage(RpsSessionData)`；
- `onNbsMessage(NbsData)`。

`BleKit` 提供：

- 发送 `BaseCmdRequest`；
- 返回 Kotlin Flow；
- callback 形式的命令发送；
- 按车辆取得 `BleService`。

这证明泊车会话、控制命令、状态通知和心跳位于 BLE 数字钥匙通道，而不是当前 Rust 后端的云端 HTTP 车控通道。

### 5.5 RPA 激活使用拦截器链

`RbRpsImmoViewModel` 包含：

- `RpsImmoChain`；
- `isBleActivate`；
- `isSupportConcurrencyCmd`；
- 激活成功、失败、处理中和唤醒提示 Flow/LiveData。

已观察方法：

- `createInterceptors(...)`；
- `createRpaInPreConditionCheckInterceptor(...)`；
- `createRpaOutPreConditionCheckInterceptor(...)`；
- `createNbsPreConditionCheckInterceptor(...)`；
- `createRbRpsActivateInterceptor(...)`；
- `realBleActivateStart()`；
- `sendActivateRpa(vehicleId, type)`；
- `deactivate(vehicleId)`；
- `switchRpsFunction(...)`。

`RbRpsActivateInterceptor` 明确处理 `BleException`。因此启动泊车并非一条裸命令，而是“前置条件检查 → 唤醒/连接 → 激活 → 会话”的链式流程。

### 5.6 移动与暂停

已观察到的方向枚举：

- `MOVE_PARK_IN`
- `MOVE_FORWARD`
- `MOVE_BACKWARD`
- `MOVE_PARALLEL_LEFT`
- `MOVE_PARALLEL_RIGHT`
- `MOVE_VERTICAL_FORWARD`
- `MOVE_VERTICAL_LEFT`
- `MOVE_VERTICAL_RIGHT`
- `STAND_STILL`

`RbRpsRpaInSessionViewModel` 与 `RbRpsRpaOutSessionViewModel` 均有：

- `start()`；
- `pause()`；
- `onRpsMessage(RpsSessionData)`；
- `isStarting`；
- `vehicleIsMoving`。

泊出还包含：

- `setCurrentDirection(RpsDirection)`；
- `switchParkingType()`；
- `setMirrorState()`。

### 5.7 高频心跳与失联保护

`BaseRpsSessionViewModel` 的 `lastHeartbeatTimestamp` 和 `moveJob` 证明会话会持续发送或监控数据，而不是一次请求。

`RpsSessionDisconnectViewModel` 监听：

- `onPause`；
- 来电/电话状态；
- 音量上、下键；
- 超时；
- 生命周期创建与销毁。

状态常量包括：

- `STATE_ON_PAUSE`
- `STATE_RECEIVER_PHONE`
- `STATE_TIME_OUT`
- `STATE_VOLUME_DOWN`
- `STATE_VOLUME_UP`

资源还说明锁屏或打开车门可紧急终止召唤。iOS 实现必须把 App inactive/background、蓝牙断开、心跳超时和用户松手统一映射到立即暂停/终止，不允许仅依赖 UI 状态。

### 5.8 泊车状态与障碍物显示

`RpsSessionData` 运行时可见约 40 个整数字段、2 个浮点字段和多个布尔字段，但字段名被混淆，当前不能安全解释各字段含义。

`RbRpaInSurfaceView` 已观察到：

- `RpaLocationBean`；
- `ParkAttrBean`；
- `CarAttrBean`；
- `tireAngle`；
- 预测轨迹；
- 普通、警告、危险障碍物绘制；
- 车辆、车位、箭头和完成动画；
- `sendTrack(RpaLocationBean)`。

由此可以确认 App 接收并绘制车辆位置、轮胎角度、车位、预测轨迹和分级障碍物，但尚未确认 `RpsSessionData` 每个字段到 UI bean 的精确映射。

## 6. UWB 的当前结论

### 已观察事实

Android Manifest 和资源中存在：

- `RbUwbManagerActivity`；
- UWB key 创建和转移页面；
- 三星钱包钥匙入口；
- “UWB Bluetooth key”；
- 靠近自动解锁、离开自动上锁；
- 感应距离“近一些/远一些”设置。

但：

- APK 未声明标准 Android `android.permission.UWB_RANGING`；
- RPS ViewModel、Service 和命令接口均直接引用 BLE/RpsService；
- RPS 资源反复要求激活和连接“蓝牙钥匙”。

### 当前推断

更可能的职责划分是：

- UWB 或 OEM 钱包数字钥匙：提供可信的近车/离车关系和被动进入体验；
- BLE：承载 RPS 激活、移动、暂停、心跳和状态数据；
- 车辆：负责路径规划、驱动控制和障碍物检测。

BLE 配置类存在 `nearTheVehicle` 字段，但该值究竟来自 BLE RSSI、UWB、车辆端融合还是 OEM 钱包服务，仍未证实。

## 7. iOS 工程现状

当前 `NIOPowerSwapAssist`：

- 未导入 `CoreBluetooth` 或 `NearbyInteraction`；
- `Info.plist` 没有 Bluetooth 或 Nearby Interaction usage description；
- Entitlements 目前只有 Keychain access groups；
- Rust 后端只实现云端 mTLS 车控，不申请 digital-key 证书；
- 后端没有 BLE transport、RPS/RPA 本地协议和高频心跳。

因此，现有 HTTP 车控不能被复用为泊车控制 transport。

## 8. 已做的项目隔离

为避免污染当前 `fix/swap_station_refresh_cancellation` 分支以及用户已有的未跟踪 `backend/scripts/`，已从当前 HEAD 创建独立分支和临时 worktree：

```text
branch: feature/ios-ble-rps
worktree: /private/tmp/NIOPowerSwapAssist-ios-ble-rps
base commit: 10796c9
```

目前尚未在该功能分支写入 BLE/RPS Swift 实现；先完成协议证据收集，避免把猜测协议固化进应用。

## 9. 尚未完成和不能声称已完成的内容

以下项目仍未知：

- BLE service UUID、characteristic UUID 和 properties；
- 扫描过滤条件和广播 manufacturer data 格式；
- MTU、分片、序号、ACK 和重传规则；
- 数字钥匙证书申请及续期协议；
- challenge/response 密码算法和会话密钥派生；
- 帧头、长度、校验、加密、认证标签与 nonce 格式；
- RPS activate/move/pause/deactivate 的数值 opcode；
- 心跳准确周期、超时门槛和容错次数；
- `RpsSessionData` 字段含义及障碍物数据编码；
- iOS 原版是否使用 Apple Car Key、Nearby Interaction 或 NIO 自有数字钥匙 SDK。

没有这些证据，不能宣称 iOS 已经能连接车辆或执行离车泊入。

## 10. 后续安全分析顺序

1. 将内存扫描缩小到命中类描述符周围的映射，分段定位真实 DEX header，避免再次执行超大同步扫描。
2. 优先反编译以下类的方法体：
   - `RpsService`
   - `BleService`
   - `NioAppBleClient`
   - `BaseCmdRequest`
   - `RbRpsActivateInterceptor`
   - `BaseRpsSessionViewModel`
3. 静态提取 UUID、opcode、heartbeat 和 codec，不调用方法。
4. 对证书和加密代码只记录算法、输入输出类型与密钥存储位置，不读取实际密钥材料。
5. 建立脱离实车的离线 test vector，并交叉验证 Android encoder/decoder。
6. iOS 先实现：
   - transport protocol abstraction；
   - Keychain/Secure Enclave credential interface；
   - frame codec；
   - RPS safety state machine；
   - mock BLE transport；
   - recorded-frame decoder tests。
7. 只有在 UUID、认证和帧格式全部被证实，且测试向量通过后，才允许增加真机扫描；发送能力继续由单独 feature flag 和现场确认保护。

## 11. 证据等级说明

- **已观察**：来自 Manifest、资源文件、运行时反射或工具直接输出。
- **推断**：由多个已观察事实支持，但尚未捕获实际运行数据。
- **未知**：当前证据不足，不能通过常识或命名补全。

后续实现与评审必须继续保持这三个等级，尤其不能把类名、字符串或 UI 文案当作已验证的线协议。

## 12. 手机号与短信验证码登录分析

### 12.1 已确认的请求流程

原版 6.9.0 登录流程使用两个 POST：

```text
/n/a/user/encryption/access/verification_code
/n/a/user/encryption/access/app/login
```

已确认的主要行为：

- 手机号先经过 AES-256-CBC/PKCS#7 和 Base64 转换；
- 请求查询参数和 form 字段共同参与排序签名；
- 短信响应下发新的 `tgw_l7_route` Cookie；
- 登录请求必须使用本次短信响应的新路由 Cookie；
- 短信和登录共用一次 request session ID；
- 登录成功返回 access token、refresh token、token key、token type 和过期信息；
- token 响应必须使用 `Cache-Control: no-store`；
- 验证码 challenge 在登录请求发出前即被消费，网络结果不明确时不能自动重放。

手机号转换使用 App 内静态材料，因此只是协议字段混淆，不是端到端保密；真正的传输安全边界仍是 TLS。报告不记录实际手机号、密文、验证码或 token。

### 12.2 Black-Box 风控字段

原版 App 的 `TdInterceptor` 会对远程配置命中的接口调用 TrustDecision/Tongdun MobileRisk 的 `TDRisk.getBlackBox()`。成功抓包中，短信和登录阶段的 Black-Box 不同，说明它不是简单固定常量。

随后进行了受控测试：

- 请求中省略 Black-Box；
- 每次短信和登录只提交一次；
- 保留并检查原始业务响应；
- 账号解除限制后，一次手机号加验证码登录成功。

当前 Rust 后端因此实现了“不带 Black-Box”的流程。但结论范围仅是该账号、版本和当时服务端策略，不代表风控字段永久可省略。未来若返回风控拒绝，应原样报告并停止，不能自动重试或伪造设备指纹。

### 12.3 Rust 登录实现的安全门

当前实现：

- 一个进程只保留一个未完成 challenge；
- challenge 有效期 600 秒；
- 新短信请求覆盖旧 challenge；
- 登录请求发送前消费 challenge；
- 响应字段做长度、空白字符和 token type 校验；
- 单租户模式只返回新 token，不自动覆盖 `.env`；
- PostgreSQL 租户模式可将新 token 加密回写对应租户配置。

尚未闭环 token refresh。保存 refresh token 不等于已经实现刷新，过期后必须失败关闭，不能猜测续期接口。

## 13. mTLS、bootstrap 身份与证书签发分析

### 13.1 原版 Android bootstrap TLS 上下文

静态和受限运行时分析确认：

```text
CHNNetKitInternal
  -> LgChamber.generateSslContext2()
  -> liblgchamber.so:nioSSLContext
  -> 两个内存 PKCS#12
  -> KeyManagerFactory + trust material
  -> TLSv1.2 SSLContext
```

运行时只观察了调用顺序、容器长度、协议和证书非秘密元数据。没有导出 PKCS#12、密码、私钥或证书容器。

native 方法在磁盘上是受保护内容，加载后才变为有效 AArch64 代码。对恢复出的函数体分析显示它从受保护的进程内常量选择并 Base64 解码两组字节，再交给 Java `KeyStore` 和 `SSLContext` 构造流程。

这支持“原版 bootstrap 客户端身份随官方 App 受保护分发”的判断，而不是由普通证书下载接口临时取得。

### 13.2 安全边界

复刻或导出官方 App 自带 bootstrap 私钥会越过项目边界，因此没有进行。项目使用的是用户单独授权的 bootstrap 身份或服务端允许的独立签发流程。

### 13.3 独立 TLS 证书签发

独立客户端的安全流程为：

1. 在本地生成 P-256 私钥；
2. 验证服务端 CA、主机名和固定叶证书指纹；
3. 使用授权 bootstrap 身份建立 mTLS；
4. 获取新的 PIN 加密公钥；
5. 发送一次证书签发请求；
6. 校验证书公钥与本地私钥匹配；
7. 拒绝非空的服务端 TLS 私钥字段；
8. owner-only 保存证书和私钥；
9. 用新身份做只读车辆状态验证。

生产观察中，独立 TLS 身份完成过签发和只读状态请求。此前守卫模式和一次仅车门解锁也在单独用户确认、一次发送和只读回查下得到验证；这些历史测试不构成未来车控的持续授权。

### 13.4 TLS 证书不等于 digital-key 证书

必须区分：

- TLS client identity：用于 `icar.nio.com:4430` 的客户端认证；
- digital-key identity：用于需要数字钥匙/E2E 的车辆本地或远程能力；
- BLE 数字钥匙身份：还涉及本地 BLE challenge/response 和会话密钥。

独立 digital-key enrollment 曾观察到返回证书不匹配提交的本地公钥，且响应包含非空私钥，因此该分支拒绝保存并被判定为未闭环。Rust 后端只采用已验证的 TLS-only 路径，不能拿 mTLS 证书冒充 BLE 数字钥匙。

## 14. 远程车控分析与验收边界

当前 Rust 车控覆盖：

- 仅解锁车门；
- 解锁并释放防启动锁；
- 锁车；
- 守卫模式开关；
- 展开后视镜；
- 寻车开始/停止；
- 空调开关；
- 关闭座椅加热。

设计原则：

- 普通 API Key 与车控 Key 默认独立；
- 每个动作有精确确认文字；
- POST 不自动重试；
- PIN 不通过 API 请求体上传，而从 owner-only 配置读取；
- 需要 PIN 时每次获取新的加密公钥；
- 命令接受不等于物理状态完成；
- 可验证动作随后通过只读状态轮询；
- 无法验证的动作只能报告“上游接受”。

已知限制：

- 门锁状态不能证明防启动锁已经释放；
- 车辆状态响应不能完整证明现场安全；
- 座椅加热开启缺少可靠 `posn_map`；
- 座椅通风缺少独立、确定的线协议；
- BLE/RPS 控制不能由远程 HTTP 车控替代。

## 15. 换电接口与下单流程分析

### 15.1 国内版与国际版是两套实现

国内 6.9.6 主要使用：

```text
/app/api/pe/*
```

国际 3.9.0 主要使用：

```text
/pe/mp/backend/swap/v1/*
```

二者路径、Deep Link 和页面组织不同，不能把国际版的 `occupy` 接口直接套到国内版。

### 15.2 国内版关键接口

静态字符串和 H5 代码确认：

```text
/app/api/pe/v1/swap/scan
/app/api/pe/v2/power/swap/battery-list
/app/api/pe/v3/swap/knowledge-infos
/app/api/pe/v4/swap/{swapId}
/app/api/pe/v6/power/around
/app/api/pe/v7/power/{groupId}
/app/api/pe/map/resources/v1/scene/{around,detail,filter,search,poi-detail}
```

扫码接口只带 `spot_id`、扫码内容和车辆 ID。换电 H5 的开始换电请求才包含 action、service type、车辆/站点、手机定位、目标电池档位、车型和年款。

客户端 H5 没有自行执行明确的距离阈值判断；服务端是否同时使用车辆 GPS 交叉校验仍未知。

### 15.3 下单必须视为有副作用

`/app/api/pe/v1/swap/scan` 在原版逻辑里会创建或继续订单，并打开后续 H5，不是普通资格查询。因此项目将其与只读站点详情分离，要求独立车控 Key、精确确认、单次发送且不自动重试。

## 16. 换电站响应、维护状态和最近站点

### 16.1 加密响应与签名

iOS 早期直接保存一条站点请求模板：

- 仅允许 HTTPS；
- 从模板替换已验证的站点 ID；
- 自动刷新时间戳和签名；
- 使用 AES 解密响应；
- 对非支持路径不应用未验证的改写规则。

Rust 后端随后承担签名、解密、查询和缓存，App 不再需要直接访问 NIO 上游。

### 16.2 维护状态

对维护中的站点响应分析发现，不能只看电池数量。可用信号包括：

- `is_scannable = false`；
- notification 中的临时下线/维修说明；
- `rich_tags` 中的状态标签；
- 站点业务状态字段。

适配原则是保留上游维护状态和说明，不把“接口成功、仍有电池数组”误判为可下单。

### 16.3 最近站点

最近站点由后端使用车辆位置查询和计算，App 只接收选中站点及直线距离，不返回车辆原始坐标。曾有保护逻辑因 position sample 过旧或缺失返回 HTTP 503；后来按实际需求允许使用最后一个结构有效的位置样本，但位置缺失或非法仍须失败。

这属于便利性查询，不应把“最近”解释为可下单、在线或不在维护。

## 17. 电池容量与站内电池分析

### 17.1 上游不再稳定提供 battery ID

站点 `battery_list` 中部分电池不再有 `battery_id`。旧逻辑依赖 ID 前缀区分 70/75 kWh，会把空 ID 错判或丢弃。

当前策略：

- 优先使用 `battery_cap_series`；
- 保留 capacity level 和描述作为兼容信号；
- 不要求 battery ID 才能展示和计数；
- 不把 station battery metadata 当作车辆当前 BMS 遥测。

已观察的主要分级包括 70、75、100、102 和 150 kWh。102 kWh 同时要求换电下单的目标档位和车型年款配置正确。

### 17.2 BaaS 电池信息边界

原版仍有 BaaS 账户接口，模型包含 battery ID、国标 ID 和容量字段。但它更接近账户/订单元数据，除非跨一次真实换电做关联，不能宣称它就是当前车上物理电池的实时身份。

当前消费者模型也没有确认车辆单体电压或动力电池温度；不能用手机温度、站内仓位电池或总包电压推导这些值。

## 18. 车辆状态轮询与充电分析

### 18.1 快慢轮询规则

目标规则为：

```text
充电中：3 秒，不考虑锁车状态
未锁或锁车状态未知：3 秒
已锁且未充电：20 秒
请求失败：20 秒后重试
```

代码实现为只有 `locked == true && charging == false` 才选慢间隔，其余均使用快间隔。

`charging` 当前从 `data.status.soc_status.charge_state == 1` 解析。源码正确不代表线上一定正确；仍应通过运行日志中的 `locked`、`charging`、`interval_seconds` 验证上游字段形状和部署版本。

### 18.2 充电电量积分

车辆充电时按轮询样本保存：

- SOC；
- charge state；
- charging current；
- charging power；
- charging voltage；
- sample time。

充电详情请求会对完整会话样本按功率积分计算 kWh。行为分三层：

1. 充电中：按已有样本实时计算，但不标记 finalized；
2. 充电结束：对完整会话积分并写入 `vehicle_charging_session_energy`；
3. 历史缺失：下次请求详情或批量回填时计算并补库。

只有能够形成有效时间区间和功率样本时才写电量，不能用 SOC 差机械替代功率积分并称为精确电量。

### 18.3 UI 与 hydration

充电列表曾出现日期、SOC 和右侧能量列互相挤压。修复方向包括文本压缩比例、固定图标槽和减少固定宽度。

能量 hydration 必须先确认后端配置有效，再将 session ID 放入 in-flight 集合；否则配置缺失会留下永久“正在加载”的标记。

历史验证中，设备构建和安装成功，但最终视觉确认曾被锁屏设备阻断，不能把“可构建”写成“视觉验收通过”。

## 19. 行程、驾驶事件与轨迹分析

### 19.1 为什么急加速、急减速和急转弯曾为空

行程列表接口包含：

```text
rapid_acceleration
rapid_deceleration
rapid_swerve
```

但部分列表响应不提供这些字段，详情接口才可能提供。当前实现会对每条行程并发请求详情，并用详情中的同名字段补充列表模型。

因此空值的正确解释是“本次上游列表/详情没有提供”，不能默认写成 0；0 代表明确没有事件，null 代表未知。

### 19.2 行程详情和 GPS 轨迹

详情还补充：

- 行程耗电 `trip_eng`；
- 起止里程；
- 最高速度；
- trip odometer；
- 急加速、急减速、急转弯；
- GPS track。

轨迹按上游原始样本保存，不插值、不平滑。每个点可包含时间、经纬度、速度、功耗和 NP 状态。为防止异常响应，单行程最多接受 5,000 点。

### 19.3 全量同步

行程同步使用独立 checkpoint：

- 历史 backfill 和新行程 forward cursor 分离；
- checkpoint 持久化，服务重启后续传；
- 每页落行程和轨迹；
- pagination 不后退时判定 stalled，不推进 checkpoint；
- 完成历史覆盖后转为周期性前向同步。

不能因为 App 已请求最近一页，就认为历史区间已经完整覆盖。

## 20. 车辆身份、图片下载与缓存分析

### 20.1 profile 与图片必须解耦

车辆 profile 请求成功后，图片超时、HTTP 非 200/304 或内容校验失败，不应阻断昵称、车型和颜色更新。当前客户端将图片结果区分为：

- downloaded；
- not modified；
- unavailable；
- failed。

图片失败时仍返回成功 profile。

### 20.2 缓存必须绑定 vehicle ID

缓存不能只按后端 URL 匹配。同一后端切换车辆 A → B 时，应立即使旧 profile、图片和 ETag 失效；否则 B 图片失败时可能继续显示 A。

当前边界包括：

- 缓存记录 backend address 和 vehicle ID；
- 只有 vehicle ID 相同时才发送旧 ETag；
- 同车刷新失败可保留已有有效图片；
- 换车先清理内存图、磁盘图和 ETag；
- 图片字节由后端缓存，App 使用 ETag/`If-None-Match`；
- 后端限制 PNG/JPEG 和最大尺寸，避免把任意响应当图片。

### 20.3 车型、颜色和显示尺寸

动态图片接入后曾出现车辆图片比例变小/裁切不一致，以及英文颜色代码直接展示。适配包括：

- 对已知颜色代码做中文映射；
- 图片按固定设计容器和缩放策略展示；
- 无动态图时保留车型内置图；
- 昵称为空时依次回退车型名和“我的蔚来”。

## 21. 多租户配置分析

目标是一个 Rust 服务同时服务多个 NIO 账号，而不是每租户单独进程。

当前设计：

- PostgreSQL `tenant_configs` 保存 API key 摘要和加密配置；
- 配置密文使用 AES-256-GCM；
- master key 只放服务私有环境，不入库；
- `default` 租户沿用 public schema 和原路径；
- 其他租户使用 `tenant_<slug>` schema 和 `/t/<slug>` 路径前缀；
- 每租户独立 API key、NIO token、vehicle/device ID、站点配置和后台任务；
- 登录成功只更新当前租户；
- iOS 基础 URL 可以包含租户路径前缀。

租户隔离必须覆盖数据库、缓存、后台轮询、车辆图片、事件流和登录 challenge，不能只在 HTTP 路径上加前缀。

## 22. iOS 下拉刷新取消分析

用户看到的“换电站获取失败：已取消”不是普通上游失败，而是 Swift 并发取消可能以两种形式出现：

- `CancellationError`；
- `NSURLErrorDomain / NSURLErrorCancelled`。

处理原则：

- 两种取消都不展示失败 Toast；
- 用 refresh token 丢弃过期结果；
- 取消时结束 loading，但保留上一次成功数据；
- `.refreshable`、页面生命周期 task 和 URLSession 的取消链要分开验证；
- detached task 可能继续网络工作，不能只看 UI 已结束就认为请求已停。

历史验证中 workspace build-for-testing 成功，但完整模拟器测试受 Keychain `-34018` 和 Simulator Busy 影响；一次过滤命令没有实际执行目标测试。因此当时只能确认构建，不应声称焦点测试或手工下拉刷新已经验收。

## 23. 其他已分析能力

### 23.1 卡券

静态 APK 和只读请求确认了国内版卡券分类、排序和实际可用卡券列表路径。响应包含数量、卡券、分页状态。真实 token、签名和账号信息未写入分析记录。

### 23.2 每日签到

签到为带 `event=checkin` 的 POST，签名覆盖查询和 form 字段。响应包含是否已签到、提示、积分、服务端时间和连续签到统计。连接失败且请求确定未发出时可有限重试；业务结果或不明确网络结果不能自动重放。

### 23.3 服务订单与换电历史

服务订单用于确认换电结果、费用和精确换电电量。站点快照、车辆 SOC 变化和订单是不同证据源，应保留 energy source 和 confidence，不能把估算值升级为精确值。

### 23.4 iOS 到自建后端的 mTLS PR

PR #10 的目标不是把 NIO 私有车辆证书放进 iOS App，而是让 iOS App 在连接用户自己的后端时出示用户导入的客户端证书：

- 导入 PKCS#12；
- 将证书身份安全保存到 Keychain；
- URLSession challenge 时只对匹配的自建后端出示身份；
- 后端可以用客户端证书限制访问。

这里的证书属于用户部署的 App ↔ Backend 信任域，与 `icar.nio.com` 的 NIO mTLS 身份、BLE digital-key 身份完全独立。不能混用或把任意私有证书称为 NIO 数字钥匙。

### 23.5 Home Assistant PR

PR #11 包含三层：

- Home Assistant Add-on：运行 Rust 后端并提供 Ingress 侧边栏页面；
- 独立 Web UI：车辆、站点、记录和统计页面；
- Custom Integration：sensor、binary sensor、button、switch 和 coordinator。

历史评审的主要合并风险不是功能数量，而是分支基线：该 PR 在旧基线上同时修改后端 API/model/provider/swap-order，并新增约 5,000 行 HA 代码。如果直接合并到较新的 main，可能回退最近站点、电池容量、图片、取消处理等已合入变化。因此应先把 HA 新目录与对现有后端的必要改动拆开，rebase 后逐项验证 API contract、Ingress 路径、鉴权、敏感配置和车控确认门。

HA button/switch 暴露车控时仍必须保留后端双 Key、精确确认和不自动重试的安全语义；不能因为 Home Assistant 实体看起来像普通开关，就弱化真实车辆动作的确认边界。

## 24. 综合方法论

此前各项分析共同采用以下方法：

1. 先固定目标版本、包名、hash、分支和运行环境；
2. 静态资源、源码、运行时反射、真实请求和数据库回读分别记录；
3. 加固 APK 中“字符串没找到”只算有边界的负面结果；
4. HTTP 200 只说明请求到达某层，不代表业务成功；
5. 命令 accepted 不代表物理状态已完成；
6. 源码实现不代表部署版本正在运行；
7. 构建成功不代表测试执行或实机视觉通过；
8. null、0、false 和字段缺失必须分开；
9. 所有有副作用 POST 默认只发一次、不自动重试；
10. 凭据、私钥、PIN、验证码和 token 不进入 Git、日志或分析文档。

## 25. 相关项目内资料

- `tools/apk/NIO-swap-api-notes.md`：国内/国际换电接口、H5 流程、卡券和签到。
- `tools/nio-native-analysis/FINDINGS.md`：原版 Android bootstrap mTLS native 路径。
- `tools/nio-cert-flow-client/STATUS_AND_COMPLIANCE.md`：独立证书、登录与历史生产验证边界。
- `tools/nio-cert-flow-client/README.md`：离线/生产命令分层和安全门。
- `tools/nio-cert-flow-verifier/README.md`：不采集凭据的证书流程验证方法。
- `backend/README.md`：Rust 后端配置、登录、多租户、车控和 API 行为。
