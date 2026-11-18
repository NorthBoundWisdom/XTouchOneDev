# XTouchOneDev

AstroController 的 Behringer X-Touch One 离线设备适配器。Swift 6 library `XTouchOneAdapter` 使用 ControlSurfaceKit 的中性设备合同。协议依据是 [Behringer MIDI Mode Implementation](https://cdn.mediavalet.com/aunsw/musictribe/g9onGOWczEOY5jIl8xEyXw/ORt6XQvz_0Kn62IYtEmkRQ/Original/Document_BE_X-TOUCH-ONE-MIDI-Mode-Implementation.pdf) 和 [Quick Start Guide](https://cdn.mediavalet.com/aunsw/musictribe/vLVIKV3wOkCX1u1NKTU4AA/_6iHaVpROESvWvldLUtf-Q/Original/QSG_BE_0808-AAG_X-TOUCH%20ONE_WW.pdf) 的 MIDI 模式表。

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

CC 70 只出现在输入解析中，因为设备会把收到的 CC 70 当作电机目标。当前库的输出类型只包含显示，工程没有 MIDI 传输入口。MC/HUI、实体会话和硬件资格待后续阶段。

## 到货后采样

先在用户在场时记录固件版本、面板模式和 USB MIDI 端点身份，从接收侧确认实际通道、逐键地址（含编码器按压）、编码器与拨轮双向值、脚踏、推子边沿和位置。分别记录初连及断开重连时的静默和报文顺序，保留来源、代次、时间和原始字节。有差异时先补离线用例。显示渲染、传输吞吐和电机行为各需独立的在场证据。
