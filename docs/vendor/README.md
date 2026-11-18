# Behringer 原厂资料

这里的文件是 Behringer（Music Tribe）发布的原厂资料，版权归其所有，**不在本仓库的 MIT 许可范围内**，只作为协议与面板布局的依据随仓库保存，内容未作任何修改。

| 文件 | 用途 | SHA-256 |
|---|---|---|
| `Document_BE_X-TOUCH-ONE-MIDI-Mode-Implementation.pdf` | MIDI 模式下全部输入、显示报文的地址与取值，适配器编解码的依据 | `f7d7bbac992f686454e42058bcc25e1568d7ccb539825dfe1a0fce34674bdf0b` |
| `X-TOUCH ONE OVERLAY TEMPLATE SHEETS.pdf` | 各模式的面板贴纸。MIDI/REL、CC/REL 两页印有每个按键的音符或控制器编号，`XTouchOnePanelLayout` 的地址据此而来 | `84d6e7a166b5103932ea7298a034e8b3cfac9e52ee9bf590d37c125b8527b887` |
| `QSG_BE_0808-AAG_X-TOUCH ONE_WW.pdf` | 快速入门指南：面板说明、切换工作模式的步骤、模式表 | `d49a0b7dfa4d854a7c99b5b41342014230fb537f55f775b0f5cca537c33ccbf8` |

## 固件

`firmware/` 目录不进 Git（见 `.gitignore`）。本机保存的是官方固件更新包：

| 文件 | SHA-256 |
|---|---|
| `X-TOUCH-ONE_sysex_update_1.11-0-ga7df6fe1.syx` | `95c215aa570c4bb6b9e494ba06f97f136ce5ef490cb4e60a343cf3feebdd7674` |

需要时从 Behringer 的 X-TOUCH ONE 产品页下载，并用上面的哈希核对。本仓库的任何代码和命令都不发送固件，工作区规则也不允许刷写固件；到货采样时只记录设备开机显示的固件版本。
