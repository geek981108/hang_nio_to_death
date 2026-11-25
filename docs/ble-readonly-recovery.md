# 完整只读通信链路恢复：证据与验收进度

日期：2026-11-25。目标保持为“恢复一条完整、可验证的只读通信链路”。用户当前不在车旁，本阶段先完成离线恢复；真实运行验证仍是目标的一部分。未发送无线请求，也未读取钥匙内容。

## 1. 当前进度与不能替代的验收项

| 环节 | 当前证据 | 验收状态 |
| --- | --- | --- |
| 目标设备发现与 GATT | 服务、通知常量和连接方法可见 | 未真实验证，写入属性等仍需核对 |
| 合法认证 | 有证书依赖、版本 handler 和认证结果标记 | 完整交互契约及运行证据未完成 |
| 外层消息与分片 | 方法体、长度函数、离线实现及合成测试 | 离线部分完成；无真实分片录制 |
| NT2 车辆明文通知 | LTV、19 字节 VehData、离线测试 | 离线部分完成；实际车辆协议版本未知 |
| 通知进入业务层 | 已补齐合成 Runnable 的 dispatch 方法体 | 静态路径已串联；未观察执行 |
| 真实值核对 | 无车旁样本 | 未完成 |

只读链路可能需要写 GATT 订阅描述符及合法认证消息；“只读”约束的是不触发车辆功能操作，不是宣称通信过程中绝无任何写入。每个拟发送项仍须先确认属于订阅/合法认证/状态查询，当前工具没有发送能力。

## 2. 本轮新增样本身份

从既有 `/private/tmp/nio-scudo.bin` 按 DEX class definitions 定位，不仅凭字符串命中挑选。没有重新 attach。

| 样本 | 转储偏移 / 长度 | SHA-256 | 用途 |
| --- | --- | --- | --- |
| nio-analysis-core.dex | 104411136 / 5469312 | aaa36ab29db5437f693db587ee280ff09f096b59bb937d86bcbad3e7e1773a5e | HexExtKt 长度与布尔转换 |
| nio-analysis-bridge.dex | 340676608 / 895416 | eb59362c77cbac865dc473d6b164e6c80c587f0bbcd19866a6612eaa246fed5e | cn.com.weilaihui3.w00 Runnable |

单类输出：`/private/tmp/nio-HexExtKt.java`、`/private/tmp/nio-w00.java`。对 engine 已有 VehData 又生成 fallback 输出 `/private/tmp/nio-VehData-fallback.java`。三个限定分析任务均退出 0，但这不消除原始 DEX 来源和热修复覆盖未知的限制。

## 3. 静态接收路径已补齐到业务消费

```text
NioAppBleClient.r：收到通知片段
  → NioRawCommandData / MessagePacketFactory：聚合外层包
  → w00.run 的分派分支：交给当前版本 handler
  → handler 返回 NotifyMessagePacket
  → handler.h(vehicleId, packet)：得到 BaseNotifyData
  → client.e callback
  → NioAppBleKit refreshService 创建时绑定的回调
  → BleKit 的通知回调
  → 核对当前车辆 ID
  → 车辆通知转换器
  → 更新当前车辆状态服务
```

证据：engine `client/NioAppBleClient.java:1025`、`/private/tmp/nio-w00.java:440`、engine `NioAppBleKit.java:348`、radio `com/nio/rb/virtual/key/BleKit.java:701`。

`w00` 并非只有通知分支：不同 handler 输出分别送到应答队列、后续写入或通知回调；认证失败也单独处理。此前缺失这份 Runnable 时不能声称调用链已闭合，现在只补齐了**静态分派路径**，尚未验证其中认证/解密算法及运行结果。

## 4. 长度与 LTV 契约

外层布局见 [线协议证据](ble-wire-protocol-evidence.md)。本轮补证：`HexExtKt.l` 明确调用 `BigInteger(byte[])`，长度为有符号大端。按该默认方法，最高位为 1 的两字节长度得到负数，不能直接实现成任意 0…65535 的 unsigned 长度。

NT2 明文 LTV：一字节 L、一字节 T、L−1 字节 V，总消耗 L+1 字节。`LtvParser.a` 的默认方法以 signed byte 判断 L，要求 2…127。type 按字节位模式识别；0x80 的 value 为 VehData。通知/响应区别还检查 type 0x01 的值，不能只凭外层类别就宣称异步通知。

原版遇到无法解析的 LTV 时可能停止循环并保留此前结果，VehData 构造器也没有本地长度 guard。离线工具选择拒绝损坏整体，并明确标注这是防御性差异。

## 5. VehData 19 字节映射

证据：engine `com/digitalkey/ble/data/VehData.java:161`，对构造器进行了 fallback 核对。

| 偏移 | 字段 | 默认方法转换 / 已知语义 |
| --- | --- | --- |
| 0 | vehState | signed byte；车辆状态原值 |
| 1 | comfEna | 非零为 true |
| 2 | cenLockUnlockSts | 0 解锁、1 锁车、2 驾驶员门解锁 |
| 3 / 4 | doorAjarFrntLeSts / FrntRi | 前左/前右；0 打开、1 关闭 |
| 5 / 6 | doorAjarReLeSts / ReRi | 后左/后右；0 打开、1 关闭 |
| 7 / 8 | hoodAjarSts / trAjarSts | 前舱盖/尾门开闭原值 |
| 9 | findMeStatus | 非零为 true |
| 10…13 | 四门窗位置 | signed byte 原值，物理显示需与 converter 核对 |
| 14 | sunroofPosnStsApp | 0 关闭、100 全开、126 翘起、127 未知 |
| 15 | bmsCustomerUsageSoc | signed byte × 0.5；高位为 1 时结果异常，尚未解释 |
| 16 | bmsChrgState | signed byte；0 未充电、1 充电、2 完成、3 故障、4 保温、7 无效 |
| 17…18 | vcuRemainingRng | BigInteger 有符号大端；单位本轮未独立证实 |

SOC 的疑点不是通过改变 Python 类型解决：fallback 仍显示先读取 signed byte 再转换浮点。工具保存 literal 和警告，不擅自把负值修成 unsigned。需要合法运行样本来判断实际使用版本/热修复与字段语义。

## 6. Android 实际消费范围

radio `utils/BleResponseConvertFactoryKt.java:64` 只合并 Exterior、Door、Window 三类结果。虽然通用 factory 可以创建 SocStatusConverter，此通知入口没有请求它。该 SOC converter 本身也没有读取 VehData 的 SOC/充电/续航字段。

因此当前有较清楚源码依据的只读业务结果是门锁、门窗等状态；不能说构造器出现 SOC 字段就已确认原版 App 用该通知刷新 SOC。

门转换保留缺失字段的旧值；窗转换把 2…100 之外的非空值折叠为 0，可能丢失未知语义。离线工具保留原值，不照搬这个压缩行为。外观状态转换存在 JADX PHI 警告，尚未固化为可信状态枚举。

## 7. 已执行验证及局限

新增 [离线工具](../tools/nio-ble-readonly/README.md)，当前共 17 项 unittest 全部通过。覆盖全部合法二片切分点、超长/截断、首片缺失、超时、旧连接回调、断开后的永久失效、LTV 边界、重复关键类型、19 字节状态、signedness 警告、合成加密通知的三片重组解码，以及用独立 OpenSSL 入口生成的固定合成密文。

样本为合成数据。它能验证工具实现与当前整理的局部契约是否一致，不能证明真实包已合法认证、解密正确、车型兼容或车辆状态准确。源码恢复与测试不是两个相互独立的实车证据。

## 8. 接下来不可跳过的工作

1. 核对新 stack 的通知/写入契约和连接身份，不混用旧 helper 常量。
2. 补全选定版本的合法认证与接收解码契约，确认哪些交互仅建立读取会话。
3. 找到具备合法来源、无钥匙材料的原始通知与对应解码结果，做独立离线比对。
4. 查明 SOC signedness、状态枚举与时间单位，而非用合理猜测替代。
5. 在具备车旁条件后核对真实连接、认证、状态读取及状态一致性；届时才审计整体目标是否完成。

最新状态：用户于 2026-11-25 确认目前没有真实 BLE 记录，等待车旁验证；目标暂停，未完成。下文保留各次离线恢复的证据，不能把这些记录视为运行验收。

## 9. 补充：GATT 与电池信息范围

bridge DEX 进一步恢复出新 stack。确认写入特征与旧 helper 候选一致；通知候选按顺序选第一个存在项，非同时订阅两个。详见线协议文档中的修正。MTU 与写入类型可配置，仍不能从常量推出全车型运行契约。

针对电池 ID：在已恢复的 engine 及 com/digitalkey/ble Java 树中检索 battery ID/code/serial/SN、pack ID/serial、BMS ID/serial、battery capacity 等字段，并核对 VehData 与车辆通知模型，尚未找到电池包唯一 ID、序列号或容量分级。已明确出现的是 SOC、充电状态、剩余续航；其中 SOC 的 signedness 尚有疑点。

此结论仅覆盖本次恢复的模型与解析，不排除其他版本、专门查询或未恢复代码存在电池标识；也不能用车辆 ID 或钥匙 ID 代替电池包 ID。

## 10. 新增：NT2 接收解码与认证验收边界

恢复 core DEX 的 `com.nio.lego.lib.core.utils.CryptoUtils`，限定类任务退出 0，输出 `/private/tmp/nio-CryptoUtils.java`。`e(ciphertext,key,iv):232` 调用 `d`，后者使用 AES/CBC/PKCS7Padding，DECRYPT_MODE，输入为会话 key 与 IV；空密文抛错。NT2 handler 的 `m():525` 读取自身会话字段后调用它。

离线工具新增对应的只读解码函数，外部提供会话材料，验证长度与填充，失败不记录材料。不提供材料提取、握手发送或动作请求。已用纯合成材料验证“密文分片 → 外层 → 解密 → LTV → 门锁等原值”，并显式标注它不验证认证。

合法认证审查还有两个尚未闭合的关键点：

- 某些失败返回 null，另一些长度/必需字段/密码异常可能抛出；需要逐项确认外层异常转换、停止后续处理和清理行为，不能把没有业务回调等同认证失败已妥善处理。
- NT2 handler 的 l() 可见的是停止广告与部分标记清理，未见会话材料全部清空；proxy 保留 handler，下一次协议辨识可替换它。重连是否严格在新会话完成前拒绝旧上下文数据尚未证实。工具按连接 generation 隔离数据，但这只是本工具的规则，不是原版行为证明。

此外，当前认证完成标记与写入回调有关；它不能独立替代车辆端成功确认和合法新通知的证据。完整目标仍需认证契约、独立样本及最终运行验证，不能把 AES 解密成功当作完成。

## 11. 认证完成回调的来源已确认

这次补齐的是回调事实，不是新建了真实认证会话：

1. stack `connect/LgBleConnector$gattCallback$1.java:56` 收到 `onCharacteristicWrite`。status 为成功但仍有分片时，继续发送下一片；没有剩余分片时调用 inner write callback 的成功方法。
2. `LgBleConnector$sendMessage$1.java` 中该 callback 向 Flow 发出 0 并结束。它来自 GATT 写入结果，不是此处另解析的一条车辆业务确认消息。
3. engine `NioAppBleClient$startNonBlockingCommandJob$1$1` 的 collector 在收到 0 后，按 packet 关联标识从待处理 write callback map 取出回调，调用 t(messageId)。该类用 simple 模式单独恢复，输出 `/private/tmp/nio-nonblocking-callback.java:53`。
4. `NioAppBleClient.t():1105` 判断 messageId 是否匹配 handler 的终结阶段；匹配后设置 true 并发布 auth success。

因此可以确认“原版 App 的这一认证成功标记由关联 GATT 写完成触发”。不能把它描述成单独验证了车端最终应用层成功应答。是否前面交互已提供足够认证保证，需要审核完整认证契约及合法会话结果，不能只看最后一个标记。

只读验收要分别记录：合法身份/会话来源、原版连接与认证结果、同一连接的新通知、独立解码结果、与原版/车辆显示的状态一致性。合成向量只覆盖解码，不覆盖前两项。

异常分支复核：`w00` 的已恢复分派中，handler 返回 null 会走非匹配类型后返回；局部没有把所有 null 自动转换为认证失败。最终调度器行为已在第 12.2 节补核，默认线程捕获并记录异常，不等于 BLE 连接清理。重连旧 handler 的清除与新版本辨识先后关系仍需补证。

## 12. 断开清理与调度器的补证

在现有 `NioAppBleClient` 方法体内，q 是构造时创建的 `NioRawCommandData`；接收入口会使用/重置它，断开 g()、主动断开及销毁路径未见明确 q.reset 调用。NT2 l() 停止 advertiser 并清其引用，proxy 委托这个清理但保留 handler。这里只是局部静态清理边界，不证明实际复用时一定发生旧数据串入。

恢复 `com.nio.lego.lib.core.utils.ThreadUtils` 单类，输出 `/private/tmp/nio-ThreadUtils.java`，任务退出 0。e(Runnable):155 直接把 Runnable 交给 `LgThreadPoolExecutor.g.execute`，这一层没有捕获并转成 BLE 失败事件。最终 executor 自身的包装/异常策略尚未复核，因此仍不声称异常一定导致进程退出或自动重连。

工具增加显式 `close()` 并测试：断开清空残片；完整旧包与旧续片均拒收；reset 不重新开启；新连接实例可独立解析。这个新增规则解决工具自身的连接寿命边界，不作为原版行为的替代证据。

现有样本目录做了有界名称检查（仅 `/private/tmp/nio*` 的 BLE/capture/trace/events 文件候选），未找到可明确识别为 BLE 通知录制的文件。找到的站点实况 WebSocket capture 不属于该通信链路，未拿来充当蓝牙证据。不能由此推断其他位置不存在样本。

### 12.1 线程池提交异常与解析异常的区别

从同一 core DEX 单类恢复 `com.nio.lego.lib.core.executor.LgThreadPoolExecutor`，JADX 退出 0，输出 `/private/tmp/nio-LgThreadPoolExecutor.java`。默认方法中：

- `execute():205–226` 在 shutdown 时直接返回；其 try/catch 包围 `super.execute(runnable)`，针对提交异常，不能当作后台 Runnable 内部解析异常的统一处理。
- `afterExecute():193–201` 只递减计数并调用父类方法，没有可见的 BLE 失败事件、连接清理或重连调用。
- `LgThreadFactory.newThread():166–169` 创建专用 Thread 子类，并设置 `cn.com.weilaihui3.w30` 为 uncaught exception handler。子类和 handler 的后续核对见下节；热修复可能替代以上默认方法。

对只读链路的影响：不能依赖此线程池证明认证或解码失败一定会通知上层。接收端需要独立记录失败结果与连接生命周期，且必须用真实会话验证。此项是新增静态证据，不是完整链路的运行验证。

### 12.2 默认线程异常处理已追到末端

继续从同一 core DEX 单类恢复，两个 JADX 任务均退出 0：

- `/private/tmp/nio-executor-thread.java`：`LgThreadPoolExecutor$LgThreadFactory$newThread$t$1.run()` 在未进入 PatchProxy 替换时，以 `try { super.run(); } catch (Throwable th)` 包住执行，catch 调用 `CoreLog.b.e("LgThreadFactory", "Request threw uncaught throwable", th)`，随后方法结束。
- `/private/tmp/nio-w30.java`：`uncaughtException` 在未进入 PatchProxy 替换时仅 `System.out.println(th)`。

因此默认可见的任务异常路径是记录异常，而非这里显式发送 BLE 认证失败、清空连接上下文或启动重连。不能把这个外层 catch 解释为恢复了原任务：它没有重新执行解析，也没有补发原业务回调。线程池后续补线程、其他连接计时器及运行时热修复的效果不在这一局部结论内。

到此，上一节“最终 executor 包装尚未复核”的静态缺口已补上；仍没有真实异常注入或车辆运行证据。对移植的具体要求是让每次接收解码都有可观察的成功/失败结果，并由连接状态机明确决定保留连接还是断开；不能通过等待全局线程异常处理器来驱动 BLE 状态流转。

## 13. 合法会话的输入依赖与尚缺的接入契约

本节只记录静态字段和调用来源，未读取账号存储、证书内容或私钥，也未执行认证。

| 输入 | 已核对的调用来源 | 对只读接入的要求 |
| --- | --- | --- |
| 车辆对应的数字钥匙记录 | `BleKeyMessageHandlerProxy.g():210–213` 调用 `BleDigitalKeyStorage.c(vehicleId)`；缺记录或 `bleKeyInfo` 返回 null | 先确认该车有合法钥匙记录；HTTP 登录成功不能代替这一步 |
| 记录与车辆的绑定 | `BleDigitalKeyStorage.c():175–185` 初始化后按 vehicleId 查 map；`shouldClearWhenLogOut():170` 返回 true | 不跨账号或车辆复用，退出登录时需失效；这里只证明存储类的声明，未验证全局退出流程 |
| 车辆、用户、设备身份 | `BleNt2MessageHandler` 构造器 457–462 从 `accessInfo` 获取 | 作为同一会话上下文绑定，不能仅传一个 bearer token |
| 车辆证书 | `BleNt2MessageHandler.g():206–210` 读取 `bgwCert` 并交给 ECC 公钥解析 | 证书的可信来源、有效性和轮换需由合法配置流程保证；当前未验证完整证书信任策略 |
| 设备证书提供器 | 同方法 215–256 优先使用 `LgBleCertUtils.a` 的回调，传入 vehicleId 与 newCertMode；模式缺省为 `ecc_v1` | 需要 iOS 上对应的合法提供器契约；不能把 Android 回调接口视为跨平台已可用 |
| 旧证书获取路径 | 无回调时调用 `IMessageHandler.e()`；其 lazy 默认指向 `NioCertData.Companion.b()` | 当前只确认来源方法，不证明现有项目的 HTTPS/mTLS 材料与其相同或可互换 |
| 授权属性 | NT2 handler 读取 keyId、certSerialNumber、startTime、endTime、accessMode、permList、accessSig | 必须保留合法授权的有效期和权限语义，字段存在不代表已恢复签发、更新和撤销流程 |

这把“缺认证契约”具体收敛为：合法授权记录的提供/更新接口、iOS 设备证书能力及车辆证书信任来源、同一真实会话的结果验证。当前离线 decoder 只接收已建立会话的材料，不能完成上述前置步骤。下一项应追踪证书提供器的注册和授权记录的写入调用，先确认正常业务入口；不要从缓存中复制材料来替代合法接入流程。

### 13.1 正常配置入口与两种存储作用域

已从 radio 恢复树补核以下默认方法：

1. `NioBleVirtualKeyManager` 构造器 1466–1475 注册 `LgBleCertUtils.a`。回调类 `NioBleVirtualKeyManager$registerBleCertCallback$1.a/b` 先解析 `DkCertMode`，未知模式返回 null；随后用当前 `AppContext.getUserId()` 获取 `RbCertSafeStorage`，再按证书模式取对应证书/私钥字段。**vehicleId 在这两个回调的可见默认方法中用于参数检查和日志，未作为存储查询键。** 因此上一节“传入 vehicleId”不能推导成“每车独立设备证书”；可见查询范围是当前用户及证书模式，底层存储实现仍未核对。
2. 正常钥匙准备入口 `NioKeyPrepareTask.h` 区分 owner/user。owner 的 lambda 调用 `KbApi.createKey`；user 的 lambda 先调用 `getAuth`，再把取得的 authId 传入对应 `createKey`。两者均传设备身份、证书序列号、设备类型与平台信息，当前恢复版本明确使用 Android 平台参数。这不是已经确认可用于 iOS 的接口契约。
3. 两个创建流程返回 `VirtualKeyData` 后，BLE 分支调用 `NioKeyPrepareTask.e`；其先通过内部解码路径得到数据，再解析成 `BleKeyInfo`，按返回对象的 vehicleId 调用 `BleDigitalKeyStorage.m`。另一条写入路径是 `NioBleVirtualKeyManager.B():1605–1672`，同样以 `VirtualKeyData` 为输入，经解码、JSON 解析后写入每车记录。这里没有调用网络或实际创建钥匙。
4. `NioKeyPrepareTask.j` 从 `VehicleSystemService` 的证书能力取得证书并计算序列号；为空或异常时返回 null。这使“先准备设备证书，再申请车辆授权记录”的依赖有了调用证据，但尚未证明证书签发和设备绑定在 iOS 的可用性。

接入时应区分两个生命周期：用户/模式对应的设备证书能力，以及车辆对应的授权记录。两者都参与会话，但不能相互替代；账号切换时还要保证异步结果仍属于发起时的用户。此处发现当前用户查询依赖，不足以断言原版存在账号串用问题，尚需检查上层取消/隔离逻辑。

剩余验证重点：证书准备能力的正常入口及平台支持、授权记录刷新/失效路径、真实已授权车辆会话。当前只读工具不调用 createKey，新增设备授权可能改变账号/车辆状态，不属于被动通知解析。

### 13.2 准备成功不等于钥匙可用；下载入口也可能创建授权

补核 radio `NioKeyPrepareTask$prepare$1.java:96–235` 的 BLE 分支：

- 按当前用户和 vehicleId 读取 `RbVirtualKeyPermanentStorage`。记录为空、状态为空或为 `UNCREATED` 时，日志写“不需要下载”，返回 `Observable.just(true)`。这条分支没有证明 `BleDigitalKeyStorage` 已有可用授权。
- 已有持久记录时，用服务端 `newCertMode` 获取设备证书序列号；序列号为空返回 false。
- 随后执行 calibration 数据调用，再进入 `NioKeyPrepareTask.h(..., TSP_BLE)`；该方法已在前节核对，会进入 owner/user 的 `createKey` 流程。因而不能因函数名含 download/prepare，就把它归类为纯查询或无状态变更。
- `doOnNext` 恢复本地记录中的设备标识和钥匙状态并报告成功；这段回调本身没有检查传入 Boolean 的真值。调用链最终成功语义仍需结合上游结果和独立钥匙记录验证，不能只依赖成功日志。
- `doOnError` 进入网络错误展示/上报路径；此局部代码未见因该错误自动删除所有旧钥匙材料。不能据此认定旧授权一定继续有效或一定已撤销。

只读接入验收必须分别核验：准备任务结果、目标车辆授权记录存在且身份一致、设备证书能力就绪、实际认证结果、同一连接的新通知。任何单独的 Boolean 或“download success”日志都不能代替这组证据。

本次对已恢复的 engine 及 radio key/virtual-key 树做了限定搜索，找到服务端模型 `KeyDetailBean.expired`、NT1/2/3 序列化授权起止时间等证据，但未闭合定时续期、撤销事件到当前连接失效的完整调用链。因此不声称已经恢复有效期校验与自动续期契约，也不自行设定刷新间隔。

## 14. 车旁验证前的交接状态

用户确认目前没有真实 BLE 通知记录，等待具备车旁条件。暂停前重新运行离线测试：17 项通过，全部是合成样本。目标仍未完成，工具也仍不是可连接车辆的客户端。

恢复工作时先确认已合法激活钥匙的手机与目标车辆在场，再核对实际协议版本、服务/通知特征和原版认证结果。需要把同一连接的新通知、原版对应解析结果、当时车辆可观察状态关联起来，先验证门锁/门窗等只读状态。无需将私钥或 token 放入项目、报告或聊天。

不能跳过的缺口包括实际会话来源与身份验证、真实密文到状态的独立比对，以及实现端的合法认证接入；SOC 有符号解释和部分授权生命周期也仍未闭合。恢复时从这些缺口推进，不把重复运行合成测试当作实车进展。
