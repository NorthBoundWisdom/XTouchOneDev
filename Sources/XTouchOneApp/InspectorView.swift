#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOnePanel

/// The upper half of the side panel: what the selected control is, its state, and its MIDI addresses.
struct ControlInspectorView: View {
    @Bindable var model: AppModel
    var onContentHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        OverflowScrollView(onContentHeight: onContentHeight) {
            VStack(alignment: .leading, spacing: 12) {
                if let selection = model.selection {
                    identity(selection)
                    state(selection)
                    addresses(selection)
                    notes(selection)
                } else {
                    Text("在左侧面板选择一个控件").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160).insetStyle()
                }
            }
        }
    }

    private func names(_ selection: PanelSelection) -> (short: String, long: String) {
        switch selection {
        case .key(let address): ("B\(address)", model.controlLabel("button.\(address)")?.name ?? XTouchOnePanelLayout.key(at: address)?.label ?? "")
        case .fader: ("F", model.controlLabel("fader")?.name ?? "电动推子")
        case .encoder: ("ENC", model.controlLabel("encoder.turn")?.name ?? "编码器与灯环")
        case .jog: ("JOG", model.controlLabel("jog")?.name ?? "拨轮")
        case .meter: ("MTR", "电平表")
        case .lcd: ("LCD", "液晶屏")
        case .segments: ("7SEG", "数码管")
        }
    }

    private func identity(_ selection: PanelSelection) -> some View {
        let name = names(selection)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name.short).font(.system(size: 30, weight: .black, design: .rounded))
                Text(name.long).font(.callout).foregroundStyle(.secondary)
            }
            Text("\(model.profileSummary) · \(model.link == .mock ? "Mock 设备" : "实体设备")")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .insetStyle()
        .accessibilityIdentifier("inspector.identity")
    }

    @ViewBuilder
    private func state(_ selection: PanelSelection) -> some View {
        switch selection {
        case .key(let address): keyState(address)
        case .fader: faderState
        case .encoder:
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("编码器", icon: "dial.medium")
                HStack(spacing: 24) {
                    Readout(title: "灯环（已发送）", value: model.console.shown.encoderRing.map { String($0) } ?? "—", color: Theme.ring)
                    Readout(title: "输入累计", value: "\(model.console.encoderTicks)", color: Theme.observed)
                }
                softwareSlider(model.console.shown.encoderRing) { model.show(.encoderRing($0)) }
                Text("灯环与输入互不相干：转动编码器不会自己改变灯环，除非打开演示联动。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .insetStyle()
        case .jog:
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("拨轮", icon: "circle.dashed")
                HStack(spacing: 16) {
                    Readout(title: "输入累计", value: "\(model.console.jogTicks)", color: Theme.observed)
                        .accessibilityIdentifier("inspector.jogCount")
                    Button("清零") { model.resetJog() }.accessibilityIdentifier("inspector.resetJog")
                }
                Toggle("同步数码管", isOn: Binding(get: { model.console.jogDisplayLinked }, set: { model.setJogDisplayLinked($0) }))
                    .disabled(!model.canWriteDisplay)
                    .accessibilityIdentifier("inspector.jogDisplay")
                    .help("同步后，数码管左侧显示最后一步，右侧显示累计，STOP 键也可清零。")
            }
            .insetStyle()
        case .meter:
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("电平表", icon: "chart.bar.fill")
                Readout(title: "已发送", value: model.console.shown.meter.map { String($0) } ?? "—")
                softwareSlider(model.console.shown.meter) { model.show(.meter($0)) }
            }
            .insetStyle()
        case .lcd: lcdState
        case .segments:
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("数码管", icon: "textformat.123")
                HStack {
                    TextField("分配", text: $model.assignment).frame(width: 56)
                    TextField("计数", text: $model.counter)
                }
                Button("写入数码管") { model.showSegments() }.accessibilityIdentifier("inspector.writeSegments")
                Text("左边两位是分配区，右边十位是计数区。段位顺序按 MIDI 模式文档：bit 0 是 a 段，bit 6 是 g 段。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .insetStyle()
        }
    }

    private func keyState(_ address: UInt8) -> some View {
        let key = XTouchOnePanelLayout.key(at: address)
        let light = model.console.shown.buttonLEDs[address] ?? .off
        let down = key.map { model.console.pressed.contains($0.button.elementID) } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("按键", icon: "button.programmable")
            HStack(spacing: 24) {
                Readout(title: "输入", value: down ? "按下" : "松开", color: down ? Theme.touch : Theme.observed)
                Readout(title: "灯（已发送）", value: light == .on ? "点亮" : light == .flash ? "闪烁" : "熄灭",
                        color: light == .off ? .secondary : Theme.value)
            }
            if let key {
                Picker("软件写入", selection: Binding(get: { light }, set: { model.show(.buttonLED(key.button, $0)) })) {
                    Text("熄灭").tag(XTouchOneButtonLED.off)
                    Text("点亮").tag(XTouchOneButtonLED.on)
                    Text("闪烁").tag(XTouchOneButtonLED.flash)
                }
                .pickerStyle(.segmented).accessibilityIdentifier("inspector.light")
            }
        }
        .insetStyle()
    }

    private var faderState: some View {
        let position = model.console.faderPosition
        let touched = model.console.faderTouched
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("电动推子", icon: "slider.vertical.3")
            HStack(spacing: 24) {
                Readout(title: "目标", value: "\(Int(model.recallTarget))")
                Readout(title: "观察", value: position.map { String($0) } ?? "—", color: Theme.observed)
                Readout(title: "触摸", value: touched.map { $0 ? "是" : "否" } ?? "未知",
                        color: touched == true ? Theme.touch : .secondary)
            }
            HStack(spacing: 8) {
                Text("召回目标").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.recallTarget }, set: { model.recallTarget = $0.rounded() }), in: 0...127).accessibilityIdentifier("inspector.recallTarget")
                Button("发送位置") { model.sendFaderPosition() }
                    .disabled(!model.canSendFaderPosition)
                    .accessibilityIdentifier("inspector.sendFaderPosition")
            }
            Label(touched == true ? "推子被触摸：松手后再发送位置" : "触摸状态未知：先触摸并松开推子",
                  systemImage: "hand.raised.fill")
                .font(.caption).foregroundStyle(Theme.touch)
                .lineLimit(1)
                .frame(height: 18, alignment: .leading)
                .opacity(touched == false ? 0 : 1)
                .accessibilityHidden(touched == false)
            Text("虚线推子与召回目标同步。点「发送位置」提交，实线显示设备回报的位置。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .insetStyle()
    }

    private var lcdState: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("液晶屏", icon: "rectangle.and.text.magnifyingglass")
            TextField("上行（最多 7 个 ASCII 字符）", text: $model.lcdUpper)
            TextField("下行（最多 7 个 ASCII 字符）", text: $model.lcdLower)
            HStack(spacing: 6) {
                Text("颜色").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.colors, id: \.self) { color in
                    Circle().fill(Theme.lcd(color)).frame(width: 15, height: 15)
                        .overlay { Circle().stroke(model.lcdColor == color ? Color.white : Color.white.opacity(0.2), lineWidth: model.lcdColor == color ? 2 : 1) }
                        .onTapGesture { model.lcdColor = color }
                }
            }
            HStack {
                Toggle("上行反相", isOn: $model.lcdInvertUpper)
                Toggle("下行反相", isOn: $model.lcdInvertLower)
            }
            Button("写入液晶屏") { model.showLCD() }.accessibilityIdentifier("inspector.writeLCD")
        }
        .insetStyle()
    }

    private func softwareSlider(_ value: UInt8?, onChange: @escaping (UInt8) -> Void) -> some View {
        HStack(spacing: 8) {
            Text("软件写入").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(value ?? 0) }, set: { onChange(UInt8($0.rounded())) }), in: 0...127)
                .accessibilityIdentifier("inspector.slider")
        }
    }

    private func addresses(_ selection: PanelSelection) -> some View {
        let notes = model.mode == .midi || model.mode == .midiRelative
        let channel = "ch\(model.channel)"
        let pair: (input: String?, feedback: String?) = switch selection {
        case .key(let address): ("\(notes ? "Note" : "CC") \(channel) #\(address)", "\(notes ? "Note" : "CC") \(channel) #\(address)")
        case .fader: ("CC \(channel) #70 · 触摸 Note #110", "CC \(channel) #70（电机目标，仅本地召回）")
        case .encoder: ("CC \(channel) #80", "CC \(channel) #80（灯环）")
        case .jog: ("CC \(channel) #88", nil)
        case .meter: (nil, "CC \(channel) #90")
        case .lcd: (nil, "SysEx 00 20 32 41 4C")
        case .segments: (nil, "SysEx 00 20 32 41 37")
        }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("MIDI 地址", icon: "arrow.left.arrow.right")
            if let input = pair.input { LabeledContent("输入 (TX)") { Text(input).font(.callout.monospaced()) } }
            if let feedback = pair.feedback { LabeledContent("反馈 (RX)") { Text(feedback).font(.callout.monospaced()) } }
            Text("地址来自 Behringer 的 MIDI 模式文档。").font(.caption2).foregroundStyle(.secondary)
        }
        .insetStyle()
    }

    @ViewBuilder
    private func notes(_ selection: PanelSelection) -> some View {
        if case .key = selection {
            Label("地址与面板按键的对应来自 Behringer 的贴纸模板（MIDI/REL、CC/REL 页）。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).insetStyle()
        }
    }

    private static let colors: [XTouchOneLCDColor] = [.black, .red, .green, .yellow, .blue, .magenta, .cyan, .white]
}
#endif
