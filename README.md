# XTouchOneDev

AstroController 的 Behringer X-Touch One 离线设备适配器，尚未连接过实机。使用 ControlSurfaceKit 的中性设备合同和 SurfacePlugins 的控制合同。协议依据是 [Behringer MIDI Mode Implementation](https://cdn.mediavalet.com/aunsw/musictribe/g9onGOWczEOY5jIl8xEyXw/ORt6XQvz_0Kn62IYtEmkRQ/Original/Document_BE_X-TOUCH-ONE-MIDI-Mode-Implementation.pdf) 和 [Quick Start Guide](https://cdn.mediavalet.com/aunsw/musictribe/vLVIKV3wOkCX1u1NKTU4AA/_6iHaVpROESvWvldLUtf-Q/Original/QSG_BE_0808-AAG_X-TOUCH%20ONE_WW.pdf) 的 MIDI 模式表。

## 构建与测试

使用 Swift 6、Python 3 和 Git。最低 macOS 版本为 14，CI 也在 Linux 上运行。

```sh
python3 -B configs/control_surface_kit_dependency.py ensure
python3 -B configs/surface_plugins_dependency.py ensure
swift test --scratch-path build/swiftpm
```

`ensure` 从锁指定的 Git remote 获取完整 SHA，并将干净检出物化到 `build/dependencies/` 下。`CONTROL_SURFACE_KIT_SOURCE`、`SURFACE_PLUGINS_SOURCE` 可指定含该提交的本地 Git 仓库作为获取源。修改锁后用 `update` 显式替换原受管检出。SurfacePlugins 的锁与 XTouchCompactDev 相同。

| 目标 | 内容 | 平台 |
|---|---|---|
| `XTouchOneAdapter` | 编解码、能力声明、分帧、覆盖统计、会话 | macOS、Linux |
| `XTouchOneSurface` | 接到 SurfacePlugins 控制合同的实体 surface | macOS、Linux |
| `XTouchOneCapture`、`xtouch-one-review` | 录制文件格式与离线审查 | macOS、Linux |
| `XTouchOneCoreMIDI`、`xtouch-one-monitor` | 数据包编解码（全平台）、CoreMIDI 端点与监听命令（仅 macOS） | 见左 |
| `XTouchOnePanel` | 面板布局、七段字形、应用背后的控制台状态 | macOS、Linux |
| `XTouchOneApp` | SwiftUI 面板应用 | 仅 macOS |
| `XTouchOneSimulator` | 按文档独立实现的设备模型，供测试和应用的模拟来源使用 | macOS、Linux |

## FreeCM

用 VS Code 打开仓库根目录，安装推荐的 `ethan-kang.freecm` 扩展，打开 **FreeCM: Show Workflow Panel**。先执行一次 **Config**，之后就可以直接 Build、Run、Test。命令清单是 `configs/freecm.commands.jsonc`（version 2）。

| 动作 | 变体 | 命令 | 结果 |
|---|---|---|---|
| Config | Local macOS Swift / Linux Swift | `python3 -B configs/setup_local_project.py` | 物化两个锁定的依赖，校验命令清单和 Swift 包，成功后写 `build/configured.json` |
| Build | Debug（缺省）、Release | `python3 -B configs/workflow.py build` | 全部库和命令行，产物在 `build/swiftpm/` |
| Build | Panel App Bundle（仅 macOS） | `python3 -B configs/workflow.py app --bundle-only` | `build/app/XTouchOneApp.app`，ad-hoc 签名 |
| Run | Panel App（macOS 缺省） | `python3 -B configs/workflow.py app` | 构建、打包并在终端里运行面板应用，Ctrl+C 结束。启动时是模拟设备，不打开任何 MIDI 端点 |
| Run | List MIDI Endpoints | `python3 -B configs/workflow.py run xtouch-one-monitor list` | 只读地列出 CoreMIDI 端点，不发送 |
| Run | Monitor Usage、Review Usage | `python3 -B configs/workflow.py run --usage <命令>` | 打印用法。`record` 和 `show` 需要端点 id，从终端运行 |
| Test | Swift Tests（缺省） | `python3 -B configs/workflow.py test` | 与硬件无关的全部测试，不打开任何 MIDI 端点 |
| Test | CoreMIDI Loopback（仅 macOS） | `python3 -B configs/workflow.py test --coremidi-loopback` | 另外运行回环测试，只用测试自建的虚拟端点 |

没有 Package 动作，因为还没有交付件。FreeCM 的命令本身都不向设备发送；面板应用里向实体端点写入需要在界面上显式打开。配置输入变化后面板显示 **Needs Config**，重新执行 Config 即可。

`configs/source_root_workflow.py` 提供插件的初始化与更新入口（`--initrepo`、`--update`，都执行同一个配置），`--initlock` 报告两份锁文件，`--cleanbuild [--dry-run]` 只删除 `build/configured.json`、`build/swiftpm` 和 `build/app`，保留 `build/dependencies`。`configs/_vendor/` 是从 XTouchCompactDev 原样复制的清单校验器（MIT，来源见其中的 `UPSTREAM.json`），不需要 FreeCM 检出，Swift 目标不使用它。无界面校验：`python3 -B configs/validate_repo_commands.py`。

## 离线适配器

- 调用方显式选择 `Midi`、`MidiRel`、`CChg` 或 `CChgRel`，并指定 1–16 的 MIDI 通道。模式和通道写进输入上下文。
- `decodeSimulatedInput` 每次接收一条已分帧的三字节消息，产出固定为 `simulation` 的 `DeviceInputEvent`，时间和代次由调用方提供。绝对值保留 MIDI 的 0–127，相对旋转使用每个报文 `+1` 或 `−1`。推子位置与触摸边沿分别报告。
- 按钮按文档地址 0–34 给出稳定的 `button.<地址>`。地址与面板按键的对应见官方贴纸模板（编码器按压是 0），到货采样时逐键确认。Note 模式按文档使用 Note On 127/0 表示按下和释放，CC 模式使用 CC 127/0。
- `encodeDisplay` 将按钮灯、灯环、电平表、LCD 和 12 位七段显示编码为完整消息。LCD 每行最多七个可打印 ASCII 字节，右侧补空格。所有候选负载仅在内存生成。`capabilities()` 描述当前适配范围，段码遮罩保留在设备原生负载中。

设备会把收到的 CC 70 当作电机目标。显示输出的类型里没有它，它只能经会话的本地召回入口产生。MC/HUI 和硬件资格待后续阶段。

## 会话

`XTouchOneSession` 是一个由调用方驱动的值类型，组合 ControlSurfaceKit 的连接状态、反馈计划、队列和请求状态。它不读时钟，也不做 I/O。时间、串行化和传输都由调用方提供。

- **来源与路由。** 来源（`simulation` 或 `hardware`）在创建时指定。`attach` 需要调用方实际选定的输入、输出端点标识，会话把它们写进每个事件和每份发送计划。
- **生命周期。** `attach`、`detach` 和 `selectProfile` 都不产生输出。路由、连接状态、模式或通道任一变化都开始新的代次，丢弃排队的显示、已接受缓存和推子观察，旧内容不重放。
- **观察。** 推子位置和触摸只来自设备报文。当前代次内未收到报文时为 `unknown`。发送成功只是发送证据。
- **输出策略。** 缺省为 `observe`，所有显示请求都被拒绝。`write` 下还需要已连接，并且请求来源（本地或某个远程客户端）持有显示授权。
- **重绘。** `requestDisplay` 按显示目标合并，同一目标保留最新值和最初的排队位置。`drainDisplay(at:)` 按速率取出。只有当前代次内、该目标最新一次发送的接受回执才会抑制相同的重复请求。失败或未尝试会让该目标的缓存失效。传输拒绝会启动冷却。
- **逐次写入。** `writeDisplay` 每次调用产生一次发送，不合并、不抑制，并取代同一目标排队中的重绘。
- **最终门禁。** 传输写入前调用 `preflight`，它按会话当前状态重新检查代次、端点、授权、输出策略，并确认字节属于显示报文（任何模式下都不会是 CC 70）。写入后用 `complete` 报告实际结果。旧代次的迟到回执保留原有证据，不计入当前状态。
- **电机召回。** `recallFader(to:)` 是唯一能产生 CC 70 的入口，只有本地调用，没有远程来源参数。会话须以 `mechanismPolicy: .localRecall` 创建（缺省 `disabled`），并且当前代次内收到过松手报文；触摸状态未知或正在触摸都拒绝。最终门禁在写入前再查一次触摸。只要对传输做过尝试，推子位置就回到 `unknown`，等设备重新报告。
- **撤销授权。** `withdrawDisplay` 取消该来源排队的重绘。重新授权不恢复之前的请求。

显示速率没有缺省值，因为硬件的吞吐预算尚未验证。测试用注入时间和 `.bucket(perSecond: 2, burst: 2, failureCooldown: 1)`。

## 采样辅助

- `XTouchOneMIDIFramer` 把原始字节流切成完整报文，处理 running status、夹在报文中间的实时字节和 SysEx，并统计无法归属的字节数。
- `XTouchOneInputCoverage` 统计一段录制覆盖了所选模式的哪些文档输入（共 80 项：每个按钮和脚踏的按下与释放、推子触摸两个边沿与两端位置、编码器和拨轮的两个方向），列出缺项、其他通道上的报文和未识别的报文。

## 实体 surface

`XTouchOneHardwareSurface` 把一个设备会话接到 SurfacePlugins 的 `SurfaceControlSession`，来源为 `hardware`（合同 1.4），形状与 XTouchCompactDev 的 `CompactHardwareSurface` 一致。

- 档案 `xtouch.one.midi.hardware` 有 41 个控件：35 个按钮、脚踏、推子、推子触摸、编码器、拨轮、电平表。所有控件都拒绝远程输入。编码器在相对模式下是 `relative`/`signedDelta`，换模式会换档案、映射修订和 epoch。
- 输入只来自设备报文，每条报文至多一个实体输入事件。
- 远程显示只能到按钮灯（`indicator`）、灯环和电平表（`value`）。推子没有反馈种类，LCD 和七段显示没有合同控件，所以远程请求到不了电机，也发不了原始 MIDI。
- `issueDisplay` 校验并发出一次发送，`completeDisplay` 只在传输接受且仍属于发出时的代次时才记录反馈事件。其余情况不记录并抛 `invalid_transition`。
- `transition` 连接或断开都换 epoch、清空观察，不产生输出。epoch 由调用方提供。

这里没有 HTTP 传输、凭据和进程入口。两个现有宿主各有一套，按工作区计划要先合并再复用，One 不再复制第三套。

## 面板应用

`XTouchOneApp` 的界面结构和配色与 XTouchCompactDev、BCR2000Dev 的控制台一致：顶部模式栏（Mock 设备 / Hardware，Hardware 下再分只监听 / 允许发送），标题栏（电机归位、设置、设备状态），下面三栏：左边是按设备正面布局画的面板，中间是工作区（数值、按键灯、MIDI 监视），右边是选中控件的检查器（状态、软件写入、MIDI 地址）。模式、通道、端点和“允许电机召回”在设置弹窗里。

- **模拟设备**（启动时的来源）：在面板上点按键、拖推子、上下拖编码器、绕圈拖拨轮，都会经文档模型产生设备字节，再走会话解码。“演示联动”打开时，按键切换自己的灯，编码器带灯环，推子带电平表和 LCD，拨轮带数码管计数。这些显示全部走正常的显示路径。按键上右键、“按键灯”标签或检查器都可以单独设置灯的状态。
- **实体端点**：选择输入端点后连接，连接本身不发送。缺省只监听，面板显示设备报告的按键、推子位置和触摸；推子位置未知时画虚线推子帽。顶部的“允许发送”和设置里的“允许电机召回”是两个单独的开关，缺省都关。面板上画的灯和显示是已被传输接受的发送内容，不是设备实际显示。实体来源下面板上的点击不产生任何输入。
- 改来源、模式、通道或任一开关都会新建会话，之前的排队显示和观察不保留。
- 按键上的小数字是地址。地址与面板按键的对应（`XTouchOnePanelLayout`）来自 Behringer 的贴纸模板：编码器按压是 0，CHANNEL 行 1–6，FUNCTION 行 7–12，TRANSPORT 上排 13–19，走带键 20–24，FADER BANK 25–26，CHANNEL 27–28，SCRUB 29，方向键上 30、左 31、中 32、右 33、下 34。数码管段位顺序按 MIDI 模式文档。两者都还没有在实机上确认。
- `XTouchOneApp --snapshot <png> [--sample] [--tab values|lights|monitor] [--hardware] [--size <宽>x<高>]` 在屏幕外排版整个窗口，写一张图后退出，不显示窗口，也不打开 MIDI 端点。宽高为正整数，每边上限 8192，总面积上限 16777216 平方点。

实体来源的显示速率用了一个保守的占位值（每秒 50 条），不是经过验证的设备预算。

## 命令行

```sh
swift run --scratch-path build/swiftpm xtouch-one-monitor list
swift run --scratch-path build/swiftpm xtouch-one-monitor record --input <id> --mode Midi --channel 1 \
    --source hardware --out capture.jsonl
swift run --scratch-path build/swiftpm xtouch-one-review --require-complete capture.jsonl
```

- `list` 列出 CoreMIDI 端点，`record` 只监听一个指定的输入端点。两者都不创建输出端口，不可能发送。`record` 把原始字节、连接事件、代次和时间写成 JSON Lines，结束时打印审查结果，已有文件不覆盖。`--source` 必须显式写明。
- `show` 向指定输出端点发一条显示报文（按钮灯、灯环、电平表、LCD），走会话的全部门禁。不加 `--write` 只打印字节。它没有电机命令。
- `xtouch-one-review` 离线读取录制文件：覆盖缺项、其他通道、未识别报文、每个代次最先到达的报文、序号与时间异常、输出方向里的电机目标数。加 `--require-complete` 时不完整则退出码为 1。

CoreMIDI 回环测试只使用测试自己创建的虚拟端点，缺省跳过，用 `XTOUCH_ONE_COREMIDI_TESTS=1` 开启。

## 模拟设备

`XTouchOneSimulator` 库里的 `XTouchOneSimulatedDevice` 按同一份文档独立实现设备一侧：操作者动作产生设备会发出的字节，收到的显示报文更新按钮灯、灯环、电平表、LCD 和七段显示的状态，收到的 CC 70 单独记录为电机目标。它与适配器的编解码不共享常量，端到端测试用它核对四种模式下 81 个输入事件和全部显示输出，并断言电机目标始终为空。它只代表文档，不代表实机行为，生产目标不得依赖它。

## 到货后采样

每一步都要用户在场。前四步只监听，不向设备发送任何字节。

1. 记录固件版本和面板上显示的模式与通道。`xtouch-one-monitor list` 记下设备输入、输出端点的 unique id、名称和厂商信息。
2. 先启动 `record`（`--source hardware`，`--firmware` 写上版本），再插上或打开设备，停手 10 秒。审查结果里该代次最先到达的报文就是初连时设备自己发出的内容，没有则说明初连静默。
3. 逐个按下并松开每个按钮（含编码器按压）和脚踏；触摸并松开推子，把推子推到两端；编码器和拨轮各向两个方向转。对照审查结果的缺项补齐，直到 `xtouch-one-review --require-complete` 通过。未识别的报文和其他通道上的报文都保留为证据，说明文档地址表与实机有差异，先补离线用例再继续。
4. 录制中拔线再插回。确认断开与重连事件、代次变化，以及重连后设备是否主动发报文。
5. 四种模式各录一份。相对模式下确认编码器每格的值是否确实只有 65 和 1，快转时是否出现其他增量。
6. 显示渲染另行安排，逐条进行：用 `show --write` 每次发一条，由人眼确认按钮灯三种状态、灯环、电平表、LCD 两行、颜色和反相。七段显示的命令行入口还没有做。
7. 电机行为不在采样范围内。`recallFader` 没有命令行入口，实机验证前需要单独的在场安排：先小幅、确认无手。

实机证据出来之前，下列内容都只来自文档：按钮地址与面板按键的对应、触摸是否只在边沿报告、推子位置是否在电机移动时回报、初连和重连是否静默、显示吞吐上限。
