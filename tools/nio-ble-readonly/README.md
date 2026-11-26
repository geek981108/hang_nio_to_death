# BLE 只读链路：离线解析验证

本目录是逐步恢复协议的可执行证据，不是可连接车辆的客户端。没有蓝牙、网络、凭据、认证绕过或车辆控制接口。

运行：

```sh
python3 -m unittest discover -s tools/nio-ble-readonly -v
```

当前 23 项测试（17 项解析、6 项回放）全部使用人工构造的合成字节，覆盖已恢复的方法体逻辑和明确标记的防御性处理。没有真实抓包，也没有证明实际车辆支持 NT2。**测试通过不代表完整目标完成。** 本轮验证环境为 Python 3.15.2、cryptography 50.0.2；未安装或更改依赖。纯解析部分仅用标准库，加密测试及接收解码需 cryptography。

## 离线记录回放

```sh
python3 tools/nio-ble-readonly/replay.py /absolute/path/recording.jsonl
```

输入每行一个 JSON 对象，仅支持以下事件：

```json
{"event":"connect","generation":"connection-1","timestamp":0}
{"event":"notification","generation":"connection-1","timestamp":1,"hex":"04b10020b2957c733126bfd1"}
{"event":"notification","generation":"connection-1","timestamp":2,"hex":"60abd9379cc977feb9a9a15acf2cc3c347498be51d867881"}
{"event":"disconnect","generation":"connection-1","timestamp":3}
```

以上是公开合成密文示例，绝非真实记录。timestamp 是整份记录共用的单调时间，单位秒；generation 是每次连接新分配的匿名标识，不使用账号、车辆 ID 或 MAC。保存每次通知原有边界，不重分片、不拼帧。

工具逐行读取并限制输入大小，拒绝重复 JSON 字段、跨连接数据、时间倒退、超时和不完整帧；首个错误终止，输出行号和固定诊断，退出码 2。成功退出码 0 仅代表记录通过该模式的检查，报告始终保留 `authentication_verified=false` 和 `vehicle_verified=false`。完整帧后记录结束可以保留连接开启状态，不能据此声称验证过断开。

命令行只做外层重组，输出包类别、长度、时间及连接序号，不输出原始包或连接标识，也不接收密钥文件。库函数 `replay(events, decode_packet=...)` 可注入进程内解码器，按 generation 选择已合法建立会话的上下文；测试用它回放 OpenSSL 合成向量并核对已知状态。回调须返回现有 decoder 的结构，不得返回凭据；错误内容不会回显。当前没有实际认证模块或真实录制器。

## 输入边界

- `decode_envelope` / `Reassembler`：只处理 BLE 外层包及分片，返回 payload 时不声称其已解密或认证。
- `decode_nt2_vehicle_plaintext`：只接受已经完成合法认证/解密后的 NT2 车辆通知明文；它本身无法验证输入来源。
- 两个入口刻意不自动串接。真实 B1 通知在原版 NT2 handler 中先经过版本相关处理，不能把加密 payload 直接传入明文解析器。
- 新增 `decode_nt2_encrypted_vehicle`：仅接收外部提供的合法会话 key/IV，按已核对的 AES-CBC/PKCS7 路径解密 B1，再调用明文解析。工具不获取会话材料、不执行握手，结果明确标记 `authentication_verified_by_decoder=false`。
- `decode_veh_data` 返回恢复代码的 literal 值与警告，不把未确认的 signedness 自动修成推测值。

测试文件中的 FRAME 虽带外层头，但内部放的是**合成明文**，只是测试外层分片；绝非真实可接收的加密链路录制。测试未把它当作认证成功证据。

另外的 encrypted synthetic 测试使用公开固定的合成 key/IV，以独立加密入口生成密文，经过三片重组后解密并校验门锁/SOC字段。它只验证管道组合，不是独立抓包比对，也不证明认证或完整性保护：CBC padding 正确本身不能证明发送方身份。

另有固定密文向量，由本机 OpenSSL 4.1.0 的 `enc -aes-128-cbc` 生成，再用 Python 解析器验证。它避免只依赖同一 Python 加密/解密往返；仍然是合成协议数据，不能代替原版 App 或车辆的样本。

## 忠实语义与防御性差异

忠实语义：首字节为 4，外层长度为 signed big endian；LTV 长度包含 type 和 value，不含长度字节自身；NT2 车辆通知取 type 0x80 的 19 字节 value；单字节值按恢复代码有符号转换；布尔值为非零即 true。

防御性差异：拒绝重复 discriminator/车辆状态块；拒绝尾部损坏，而非返回部分结果；拒绝超长/合并帧；要求精确 19 字节；错误清空分片；校验连接 generation 和时间顺序。这些是离线工具的确定性策略，不声称原版已经有同样的保护。

当前不解析额外 RPS 块、不生成任何请求，不假定 UWB 与该路径相同。

连接断开时调用 `Reassembler.close()`，清除残片并永久拒绝该实例后续输入；帧级 reset 不能重新开启连接。重连使用新 generation 的新实例。这是工具的明确规则，不是原版完整清理行为已经验证的声明。

## 新发现：有符号问题不能悄悄修正

`HexExtKt.l(byte[])` 使用 `new BigInteger(bytes).intValue()`，即有符号大端转换，已由 core DEX 单类恢复确认。

`VehData` 的 SOC 位置是偏移 15。普通与 fallback 输出都显示直接把 signed byte 转成浮点后乘 0.5。例如 0x96 在这份默认方法中得到 -53，而不是 75。可能需要进一步核对原版实际运行路径、热修复或样本完整性；当前不把任一猜测标记为事实。

因此该值只放在 `source_literal` 中，遇到高位为 1 时明确给出 `SOC_SIGNEDNESS_UNRESOLVED`。它不可直接作为 UI 的可信 SOC。

## 证据与下一步

方法体位置、19 字节布局、业务消费路径与剩余验收门槛见 [离线恢复进度](../../docs/ble-readonly-recovery.md)。后续必须补上合法认证及真实加密样本到状态的验证，不能将现有测试扩写成“已完成链路”的报告。
