#if os(macOS)
import AppKit
import SwiftUI
import XTouchOneAdapter
import XTouchOnePanel

/// The lower half of the side panel: host-side values, key lights and the MIDI monitor.
struct WorkspaceTabsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("工作区", selection: $model.tab) {
                ForEach(WorkspaceTab.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("workspace.selection")
            switch model.tab {
            case .values: ValueListView(model: model)
            case .lights: LightListView(model: model)
            case .monitor: MIDIMonitorView(model: model)
            }
        }
    }
}

/// One card beside the device: the selected control above, the workspace tabs below, with a bar between
/// them that drags to resize. The upper part never takes more height than its content needs, so the split
/// only ever hides something when it is dragged smaller, and then the cut edge shows it. Double-clicking
/// the bar fits the upper part to its content.
struct SidePanelView: View {
    let model: AppModel
    @AppStorage("sidePanel.inspectorFraction") private var fraction = SidePanelView.defaultFraction
    @State private var dragStart: Double?
    @State private var hovering = false
    @State private var inspectorHeight: CGFloat = .infinity

    private static let defaultFraction = 0.5
    private static let handleHeight: CGFloat = 17
    private static let minPane: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            let available = max(proxy.size.height - Self.handleHeight, 1)
            let minPane = min(Self.minPane, available / 2)
            let split = min(max(available * fraction, minPane), available - minPane)
            let top = min(split, max(inspectorHeight, 1))
            VStack(spacing: 0) {
                ControlInspectorView(model: model, onContentHeight: { inspectorHeight = $0 }).frame(height: top).clipped()
                handle(top: top, available: available, minPane: minPane)
                WorkspaceTabsView(model: model).padding(.top, 4).frame(height: available - top).clipped()
            }
        }
        .panelStyle()
    }

    private func handle(top: CGFloat, available: CGFloat, minPane: CGFloat) -> some View {
        let active = hovering || dragStart != nil
        return ZStack {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Capsule().fill(active ? Theme.selection : Color(white: 0.4)).frame(width: 40, height: 4)
                .padding(.horizontal, 6).background(Color(red: 0.1, green: 0.105, blue: 0.118))
        }
        .frame(maxWidth: .infinity).frame(height: Self.handleHeight)
        .contentShape(Rectangle())
        .onHover(perform: setDividerHover)
        .onDisappear { setDividerHover(false) }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? top
                dragStart = start
                fraction = min(max(start + drag.translation.height, minPane), available - minPane) / available
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) {
            fraction = min(max(inspectorHeight, minPane), available - minPane) / available
        }
        .help("拖动调整上下两部分的高度，双击让上半部分正好容纳内容")
        .accessibilityIdentifier("sidePanel.divider")
    }

    private func setDividerHover(_ inside: Bool) {
        guard hovering != inside else { return }
        hovering = inside
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
}

private struct ValueRow<Content: View>: View {
    let badge: String
    let title: String
    let selected: Bool
    let onSelect: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(badge).font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(selected ? Theme.selection.opacity(0.35) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(title).font(.callout).frame(width: 78, alignment: .leading)
            content
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct ValueText: View {
    let text: String
    var color = Theme.value
    var body: some View {
        Text(text).font(.system(.callout, design: .monospaced).weight(.medium)).foregroundStyle(color)
            .frame(width: 44, alignment: .trailing)
    }
}

/// Sliders here are software writes through the display path. Inputs are read-only readouts.
private struct ValueListView: View {
    @Bindable var model: AppModel

    var body: some View {
        OverflowScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.link == .mock ? "模拟设备的显示值。滑块是软件写入：经会话排队、过门禁后送到模拟设备。"
                    : "滑块是软件写入。只监听时全部被拒绝；允许发送后经限速和最终门禁写到设备。")
                    .font(.caption).foregroundStyle(.secondary)
                group("显示") {
                    ValueRow(badge: "RING", title: "灯环", selected: model.selection == .encoder, onSelect: { model.selection = .encoder }) {
                        slider(model.console.shown.encoderRing, id: "values.ring") { model.show(.encoderRing($0)) }
                        ValueText(text: model.console.shown.encoderRing.map { String($0) } ?? "—")
                    }
                    ValueRow(badge: "MTR", title: "电平表", selected: model.selection == .meter, onSelect: { model.selection = .meter }) {
                        slider(model.console.shown.meter, id: "values.meter") { model.show(.meter($0)) }
                        ValueText(text: model.console.shown.meter.map { String($0) } ?? "—")
                    }
                    ValueRow(badge: "LCD", title: "液晶屏", selected: model.selection == .lcd, onSelect: { model.selection = .lcd }) {
                        TextField("上行", text: $model.lcdUpper).accessibilityIdentifier("values.lcdUpper")
                        TextField("下行", text: $model.lcdLower).accessibilityIdentifier("values.lcdLower")
                        Button("写入") { model.showLCD() }.accessibilityIdentifier("values.writeLCD")
                    }
                    ValueRow(badge: "7SEG", title: "数码管", selected: model.selection == .segments, onSelect: { model.selection = .segments }) {
                        TextField("分配", text: $model.assignment).frame(width: 52).accessibilityIdentifier("values.assignment")
                        TextField("计数", text: $model.counter).accessibilityIdentifier("values.counter")
                        Button("写入") { model.showSegments() }.accessibilityIdentifier("values.writeSegments")
                    }
                }
                group("输入") {
                    ValueRow(badge: "F", title: "推子", selected: model.selection == .fader, onSelect: { model.selection = .fader }) {
                        ProgressView(value: Double(model.console.faderPosition ?? 0), total: 127).tint(Theme.observed)
                        if model.console.faderTouched == true {
                            Text("触摸中").font(.caption2.bold()).foregroundStyle(Theme.touch)
                        }
                        ValueText(text: model.console.faderPosition.map { String($0) } ?? "—", color: Theme.observed)
                    }
                    ValueRow(badge: "ENC", title: "编码器", selected: model.selection == .encoder, onSelect: { model.selection = .encoder }) {
                        Text(model.mode.rawValue.hasSuffix("Rel") ? "相对，每格 ±1" : "绝对 0–127").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        ValueText(text: "\(model.console.encoderTicks)", color: Theme.observed)
                    }
                    ValueRow(badge: "JOG", title: "拨轮", selected: model.selection == .jog, onSelect: { model.selection = .jog }) {
                        Text("相对，每格 ±1").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        ValueText(text: "\(model.console.jogTicks)", color: Theme.observed)
                    }
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.bold())
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func slider(_ value: UInt8?, id: String, onChange: @escaping (UInt8) -> Void) -> some View {
        Slider(value: Binding(get: { Double(value ?? 0) }, set: { onChange(UInt8($0.rounded())) }), in: 0...127)
            .accessibilityIdentifier(id)
    }
}

private struct LightListView: View {
    let model: AppModel

    var body: some View {
        OverflowScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("每个按键的灯：熄灭、点亮、闪烁。地址与面板按键的对应来自官方贴纸模板，尚未在实机上确认。")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(XTouchOnePanelLayout.keys) { key in
                    let state = model.console.shown.buttonLEDs[key.address] ?? .off
                    ValueRow(badge: "B\(key.address)", title: key.label, selected: model.selection == .key(key.address),
                             onSelect: { model.selection = .key(key.address) }) {
                        Spacer()
                        Picker("", selection: Binding(get: { state }, set: { model.show(.buttonLED(key.button, $0)) })) {
                            Text("熄灭").tag(XTouchOneButtonLED.off)
                            Text("点亮").tag(XTouchOneButtonLED.on)
                            Text("闪烁").tag(XTouchOneButtonLED.flash)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                        .accessibilityIdentifier("lights.\(key.address)")
                    }
                }
            }
        }
    }
}

private struct MIDIMonitorView: View {
    let model: AppModel

    var body: some View {
        let entries = model.console.log
        VStack(alignment: .leading, spacing: 6) {
            Text("最近 \(XTouchOneConsole.logLimit) 条：IN 是设备发来的报文，OUT 是会话发出的显示或召回及传输结果。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.kind == .input ? "IN" : entry.kind == .output ? "OUT" : "··")
                                    .foregroundStyle(entry.kind == .input ? Theme.observed : entry.kind == .output ? Theme.ring : .secondary)
                                    .frame(width: 26, alignment: .leading)
                                Text(entry.bytes.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")
                                    + (entry.bytes.count > 6 ? " …" : ""))
                                    .frame(width: 128, alignment: .leading)
                                Text(entry.text).lineLimit(1)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("monitor")
    }
}
#endif
