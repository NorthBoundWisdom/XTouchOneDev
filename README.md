# XTouchOneDev

AstroController 的 Behringer X-Touch One 离线设备适配器，尚未连接过实机。Swift 6 library `XTouchOneAdapter` 使用 ControlSurfaceKit 的中性设备合同。协议依据是 [Behringer MIDI Mode Implementation](https://cdn.mediavalet.com/aunsw/musictribe/g9onGOWczEOY5jIl8xEyXw/ORt6XQvz_0Kn62IYtEmkRQ/Original/Document_BE_X-TOUCH-ONE-MIDI-Mode-Implementation.pdf) 和 [Quick Start Guide](https://cdn.mediavalet.com/aunsw/musictribe/vLVIKV3wOkCX1u1NKTU4AA/_6iHaVpROESvWvldLUtf-Q/Original/QSG_BE_0808-AAG_X-TOUCH%20ONE_WW.pdf) 的 MIDI 模式表。

## 构建与测试

使用 Swift 6、Python 3 和 Git。最低 macOS 版本为 14，CI 也在 Linux 上运行。

```sh
python3 -B configs/control_surface_kit_dependency.py ensure
swift test --scratch-path build/swiftpm
```

`ensure` 从锁指定的 Git remote 获取完整 SHA，并将干净检出物化到 `build/dependencies/ControlSurfaceKit`。`CONTROL_SURFACE_KIT_SOURCE` 可指定含该提交的本地 Git 仓库作为获取源。修改锁后用 `update` 显式替换原受管检出。

## 离线适配器

- 调用方显式选择 `Midi`、`MidiRel`、`CChg` 或 `CChgRel`，并指定 1–16 的 MIDI 通道。模式和通道写进输入上下文。
- `decodeSimulatedInput` 每次接收一条已分帧的三字节消息，产出固定为 `simulation` 的 `DeviceInputEvent`，时间和代次由调用方提供。绝对值保留 MIDI 的 0–127，相对旋转使用每个报文 `+1` 或 `−1`。推子位置与触摸边沿分别报告。
- 按钮按文档地址 0–34 给出稳定的 `button.<地址>`。面板标签和编码器按压对应哪个地址，留待到货采样确认。Note 模式按文档使用 Note On 127/0 表示按下和释放，CC 模式使用 CC 127/0。
- `encodeDisplay` 将按钮灯、灯环、电平表、LCD 和 12 位七段显示编码为完整消息。LCD 每行最多七个可打印 ASCII 字节，右侧补空格。所有候选负载仅在内存生成。`capabilities()` 描述当前适配范围，段码遮罩保留在设备原生负载中。

CC 70 只出现在输入解析中，因为设备会把收到的 CC 70 当作电机目标。当前库的输出类型只包含显示，工程没有 MIDI 传输入口。MC/HUI 和硬件资格待后续阶段。

## 会话

`XTouchOneSession` 是一个由调用方驱动的值类型，组合 ControlSurfaceKit 的连接状态、反馈计划、队列和请求状态。它不读时钟，也不做 I/O。时间、串行化和传输都由调用方提供。

- **来源与路由。** 来源（`simulation` 或 `hardware`）在创建时指定。`attach` 需要调用方实际选定的输入、输出端点标识，会话把它们写进每个事件和每份发送计划。
- **生命周期。** `attach`、`detach` 和 `selectProfile` 都不产生输出。路由、连接状态、模式或通道任一变化都开始新的代次，丢弃排队的显示、已接受缓存和推子观察，旧内容不重放。
- **观察。** 推子位置和触摸只来自设备报文。当前代次内未收到报文时为 `unknown`。发送成功只是发送证据。
- **输出策略。** 缺省为 `observe`，所有显示请求都被拒绝。`write` 下还需要已连接，并且请求来源（本地或某个远程客户端）持有显示授权。
- **重绘。** `requestDisplay` 按显示目标合并，同一目标保留最新值和最初的排队位置。`drainDisplay(at:)` 按速率取出。只有当前代次内、该目标最新一次发送的接受回执才会抑制相同的重复请求。失败或未尝试会让该目标的缓存失效。传输拒绝会启动冷却。
- **逐次写入。** `writeDisplay` 每次调用产生一次发送，不合并、不抑制，并取代同一目标排队中的重绘。
- **最终门禁。** 传输写入前调用 `preflight`，它按会话当前状态重新检查代次、端点、授权、输出策略，并确认字节属于显示报文（任何模式下都不会是 CC 70）。写入后用 `complete` 报告实际结果。旧代次的迟到回执保留原有证据，不计入当前状态。
- **撤销授权。** `withdrawDisplay` 取消该来源排队的重绘。重新授权不恢复之前的请求。

显示速率没有缺省值，因为硬件的吞吐预算尚未验证。测试用注入时间和 `.bucket(perSecond: 2, burst: 2, failureCooldown: 1)`。

## 采样辅助

- `XTouchOneMIDIFramer` 把原始字节流切成完整报文，处理 running status、夹在报文中间的实时字节和 SysEx，并统计无法归属的字节数。
- `XTouchOneInputCoverage` 统计一段录制覆盖了所选模式的哪些文档输入（共 80 项：每个按钮和脚踏的按下与释放、推子触摸两个边沿与两端位置、编码器和拨轮的两个方向），列出缺项、其他通道上的报文和未识别的报文。

## 模拟设备

`XTouchOneSimulator` 库里的 `XTouchOneSimulatedDevice` 按同一份文档独立实现设备一侧：操作者动作产生设备会发出的字节，收到的显示报文更新按钮灯、灯环、电平表、LCD 和七段显示的状态，收到的 CC 70 单独记录为电机目标。它与适配器的编解码不共享常量，端到端测试用它核对四种模式下 81 个输入事件和全部显示输出，并断言电机目标始终为空。它只代表文档，不代表实机行为，生产目标不得依赖它。

## 到货后采样

先在用户在场时记录固件版本、面板模式和 USB MIDI 端点身份，从接收侧确认实际通道、逐键地址（含编码器按压）、编码器与拨轮双向值、脚踏、推子边沿和位置，用 `XTouchOneInputCoverage` 核对缺项。分别记录初连及断开重连时的静默和报文顺序，保留来源、代次、时间和原始字节。有差异时先补离线用例。显示渲染、传输吞吐和电机行为各需独立的在场证据。
