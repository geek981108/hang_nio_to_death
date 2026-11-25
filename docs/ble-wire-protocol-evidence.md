# BLE 线协议：当前已确认的传输契约

日期：2026-11-25。本文补充实际 UUID、包布局、重组与版本分派，不重复业务功能规格。证据是 `/private/tmp/nio-analysis-engine-src/sources` 下的恢复代码；DEX 身份和部分反编译失败情况见 [BLE 详细分析](android-ble-lifecycle-detailed-analysis.md)。未做无线抓包或实车验证，尚非完整可运行协议。

## 1. GATT 入口

| 用途 | UUID | 证据 |
| --- | --- | --- |
| engine client 用于订阅的服务 | `9F0891D0-03C9-127E-76F5-5B915ABF4927` | `com/nio/lego/digitalkey/engine/client/NioAppBleClient.java:622`，A 方法 |
| 通知特征之一 | `9AAD8F27-53E5-EBDB-89A1-9DD026DC21FC` | 同文件 `:978`，连接成功后的订阅列表 |
| 通知特征之二 | `DE3DD60E-2E90-9880-B253-DD158632A23E` | 同一列表 |
| 新 stack 的写入特征 | `7B83297F-600D-690F-B4B0-E895F5D5C803` | stack `LgBleManager.java:288` 的 n 方法；旧 helper 中也有相同值 |

后续从 bridge DEX 恢复了新 stack（输出 `/private/tmp/nio-analysis-stack-src/sources/com/nio/lego/digitalkey/stack`），确认 `LgBleManager.n` 使用上述服务及写入特征并转给 connector 的 sendMessage。具体 engine 调用方和全车型覆盖仍需核对，真实服务属性未验证。

**两个通知 UUID 是有顺序的候选，不是同时订阅两个特征。** `connect/LgBleConnector.java:374` 依次调用 getCharacteristic，找到第一个存在项即结束查找。随后启用通知并向 CCCD 写 ENABLE_NOTIFICATION_VALUE。不能把候选列表复制成两个独立订阅。

`LgBleConnector.h` 根据可空 writeType 覆盖特征默认类型；API 33+ 使用带数据和类型的写入调用，较旧系统先设置 value/type。局部返回值表示提交是否成功，不等于业务应答成功。具体写入模式仍需追踪构造参数，不能仅凭 UUID 固定。

`LgBleConnector$gattCallback$1.onMtuChanged` 更新分片大小为 `min(mtu,512)−c`；sendMessage 的 forceMtu 非空时又覆盖分片大小。c 的来源和覆盖行为仍需核对，不能直接用某个固定 MTU 作为所有连接的分片长度。

进一步确认 `NioAppBleClient.v():1154` 向连接层传入 requested MTU 512、额外开销 3、writeType=null；connector 构造器保存这些参数，初始分片大小为 512−3，随后可被协商结果或 forceMtu 覆盖。writeType=null 的这一入口沿用特征默认写入类型，而不是从 Java 代码硬指定某种写模式。

`NioAppBleClient$startNonBlockingCommandJob$1` 的恢复指令明确调用 `LgBleManager.n(deviceUuid, packet.g, handler.getN())`，因此新 engine 至上述写入入口已有调用证据。普通命令管线的所有协程与错误传播尚未完整核对。

connector 把完整 packet 字节按分片大小连续切片，不为每片重加业务包头；串行队列、写入回调与业务响应是不同阶段。这里没有实际发送数据。

## 2. 外层消息布局

证据：`com/nio/lego/com/digitalkey/ble/data/MessagePacket.java` 构造器，以及新链路实际 import 的 `com/nio/lego/digitalkey/engine/utils/MessagePacketFactory.java`。另有旧包同名 factory，必须区分。

| 偏移 | 长度 | 已确认内容 |
| --- | ---: | --- |
| 0 | 1 | factory 接受的固定首字节为 `0x04`；含义未正式命名 |
| 1 | 1 | handler 分派使用的消息类别字节；不是已确认的车辆动作码 |
| 2 | 2 | 声明的 payload 长度；构造器按高字节、低字节写出 |
| 4 | 可变 | payload，可能还需要按版本解码 |

构造器的输出关系是 `首字节 + 类别字节 + 长度高字节 + 长度低字节 + payload`。这里没有看到外层额外的 checksum 字段，不代表内部 payload 没有加密、签名或完整性校验。

接收 factory 的局部条件：原始片段长度大于 4；首字节为 4；声明 payload 长度大于或等于当前已收到的 payload 长度。它可以接受不完整首片，因此返回 MessagePacket 不意味着完整消息已到齐。

接收端长度值通过 `HexExtKt.l` 转换；后续已恢复该函数，实际使用 `BigInteger(byte[])`，为有符号大端。不能未经验证扩展为 unsigned 16 位长度。详见 [只读链路恢复进度](ble-readonly-recovery.md)。不要把该布局视为所有其他 NFC/keyfob 同名 packet 的格式。

## 3. 通知分片重组

证据：`NioAppBleClient.java:1025`，`r(ParcelUuid, byte[])` 的 `NioRawCommandData` 处理分支。

可见算法：

1. 通知为空直接返回。
2. 缓冲为空时尝试解析首片的外层头。失败则清理重组状态。
3. 记录声明长度、已收到的 payload 长度、剩余长度与首片时间。
4. 若首片已完整，直接进入合并后的解析路径；否则缓冲首片并等待后续通知。
5. 缓冲非空时，后续通知按续片处理，扣减剩余长度并追加到列表。
6. 首片起超过 30 秒时清理当前重组。这个时间是接收重组窗口，**不是泊车心跳或车辆失联停车门槛**。
7. 到齐后按顺序拼接缓冲，再调用 factory；成功则清理状态并调度后续处理。

这段逻辑没有表现为“每条 BLE 通知都带独立的 4 字节业务头”。实现接收端时，必须区分首片和续片。

尚需核对：超长续片时的清理、丢片后的重新同步、通知通道是否可能交错、同一次通知是否允许包含多帧。当前输出在部分失败路径上的缓冲清理不充分明确，不能直接复制为完整健壮的 parser。离线解析测试应覆盖截断、超长、缺首片、超时、重复片及跨连接残留。

## 4. 协议版本选择

证据：`com/nio/lego/digitalkey/engine/handler/BleKeyMessageHandlerProxy.java:200`，g 方法。

先从当前车辆的本地钥匙记录取得 BleKeyInfo。没有记录则返回 null。在特定消息类别下，把 payload 与 `BleKeyConst` 中的版本标识逐一比较，分别创建 `BleNt1MessageHandler`、`BleNt2MessageHandler` 或 `BleNt3MessageHandler`；随后由选中的 handler 处理该 packet。

因此外层头一致不代表内部协议一致。实际实现应保存与当前连接绑定的协议上下文，未知版本不能按默认车型猜测。当前源码如何处理后续未知标识与旧 handler 保留问题还需继续核对，不将“返回 null”一概解释为已断开连接。

## 5. 已确定的编解码职责

`IMessageHandler` 定义以下边界：

- 原始 MessagePacket 的版本相关处理；
- BaseCmdRequest 转为 WriteMessagePacket；
- ReadMessagePacket 转为 BaseCmdResponse；
- NotifyMessagePacket 转为 BaseNotifyData；
- 认证相关状态、清理及 RSSI 回调。

这明确了实现顺序：先完成传输与重组，再处理版本与合法认证，再解释请求/响应及异步通知。不能直接将请求对象字段序列化成 JSON 写入 GATT，也不能把外层类别字节当成泊车操作码。

## 6. 目前不能宣称已经实现的部分

| 项目 | 当前证据状态 |
| --- | --- |
| GATT 服务与两个通知特征 | 新 engine 调用位置已确认；真实属性未验证 |
| 写入特征、写入模式与分片 | 新 stack 写入常量及配置行为已确认；调用参数和真实属性待核对 |
| 外层头与接收重组 | 已有方法体；需完善长度函数及失败路径验证 |
| NT1/NT2/NT3 分派 | 已确认；各版本载荷契约尚未完整恢复 |
| 合法认证交互 | 仅有 handler/钥匙依赖及成功标记；完整契约未交付 |
| 请求与响应关联、消息内部结构 | 部分对象和处理入口存在；尚无完整协议表 |
| RPS 状态 | 已有解析对象到 UI 的映射；不等于原始字节解析已完成 |
| UWB 空口协议与 iOS 测距接入 | 未恢复；Android OEM SDK 编排不能替代 |

具体可交付的是以上传输层证据，而不是“已经能移植运行的 BLE/UWB 协议”。下一步应沿新 stack 的写入/通知入口与各 handler 逐项核对，并建立脱敏、离线的解析样本验证。不能以功能规格或方法清单替代这些工作。
