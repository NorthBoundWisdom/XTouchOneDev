#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOneCoreMIDI
import XTouchOnePanel

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("连接") {
                    Picker("来源", selection: Binding(get: { model.link }, set: { model.configure(link: $0) })) {
                        Text("模拟设备").tag(XTouchOneConsole.Link.mock)
                        Text("实体端点").tag(XTouchOneConsole.Link.hardware)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("link")
                    Picker("模式", selection: Binding(get: { model.mode }, set: { model.configure(mode: $0) })) {
                        ForEach(XTouchOneMIDIMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("通道", selection: Binding(get: { model.channel }, set: { model.configure(channel: $0) })) {
                        ForEach(UInt8(1)...16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    if model.link == .hardware { hardware }
                }
                Section("显示测试") {
                    Toggle("演示联动（按键点灯、编码器带灯环、推子带电平表）", isOn: $model.demoLinks)
                    Toggle("在按键上显示地址", isOn: $model.showAddresses)
                    HStack {
                        TextField("上行", text: $model.lcdUpper)
                        TextField("下行", text: $model.lcdLower)
                    }
                    HStack {
                        Picker("颜色", selection: $model.lcdColor) {
                            ForEach(Self.colors, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Button("写 LCD") { model.showLCD() }.accessibilityIdentifier("show-lcd")
                    }
                    HStack {
                        TextField("分配", text: $model.assignment).frame(width: 56)
                        TextField("计数", text: $model.counter)
                        Button("写数码管") { model.showSegments() }.accessibilityIdentifier("show-segments")
                    }
                    Text("按键上右键可切换灯的状态。按键地址与数码管段位顺序是暂定的，等实机采样确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("电机召回") {
                    HStack {
                        Slider(value: $model.recallTarget, in: 0...127, step: 1)
                        Text("\(Int(model.recallTarget))").monospacedDigit().frame(width: 30)
                        Button("召回") { model.recall() }.accessibilityIdentifier("recall")
                    }
                    Text("需要先触摸并松开推子。触摸状态未知或正在触摸时拒绝。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20)
            }
            LogView(entries: model.console.log)
        }
    }

    @ViewBuilder private var hardware: some View {
        Picker("输入", selection: $model.sourceID) {
            Text("未选择").tag(Int32?.none)
            ForEach(model.sources, id: \.uniqueID) { Text(Self.name($0)).tag(Int32?.some($0.uniqueID)) }
        }
        .disabled(model.isConnected)
        Picker("输出", selection: $model.destinationID) {
            Text("不打开").tag(Int32?.none)
            ForEach(model.destinations, id: \.uniqueID) { Text(Self.name($0)).tag(Int32?.some($0.uniqueID)) }
        }
        .disabled(model.isConnected)
        HStack {
            Button(model.isConnected ? "断开" : "连接") { model.isConnected ? model.disconnect() : model.connect() }
                .disabled(!model.isConnected && model.sourceID == nil)
                .accessibilityIdentifier("connect")
            Button("刷新端点") { model.refreshEndpoints() }.disabled(model.isConnected)
            Spacer()
            Text(model.isConnected ? "已连接 · 代次 \(model.console.session.generation)" : "未连接").foregroundStyle(.secondary)
        }
        Toggle("允许向设备写显示", isOn: Binding(get: { model.allowWrite }, set: { model.configure(allowWrite: $0) }))
            .accessibilityIdentifier("allow-write")
        Toggle("允许电机召回", isOn: Binding(get: { model.allowRecall }, set: { model.configure(allowRecall: $0) }))
            .disabled(!model.allowWrite)
            .accessibilityIdentifier("allow-recall")
        Text("连接本身不发送任何字节。缺省只监听；面板上画的灯和显示是“已发送”的内容，不代表设备实际显示。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private static func name(_ endpoint: XTouchOneMIDIEndpoint) -> String {
        endpoint.name + (endpoint.isVirtual ? "（虚拟）" : "") + (endpoint.isOffline ? "（离线）" : "")
    }

    private static let colors: [(XTouchOneLCDColor, String)] = [
        (.black, "黑"), (.red, "红"), (.green, "绿"), (.yellow, "黄"), (.blue, "蓝"), (.magenta, "品红"), (.cyan, "青"), (.white, "白"),
    ]
}

struct LogView: View {
    let entries: [XTouchOneConsole.Entry]

    var body: some View {
        ScrollViewReader { proxy in
            List(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.kind == .input ? "IN" : entry.kind == .output ? "OUT" : "··")
                        .foregroundStyle(entry.kind == .input ? .green : entry.kind == .output ? .orange : .secondary)
                        .frame(width: 26, alignment: .leading)
                    Text(entry.bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                        + (entry.bytes.count > 8 ? " …" : ""))
                        .frame(width: 150, alignment: .leading)
                    Text(entry.text).lineLimit(1)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: entries.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(minHeight: 150)
        .accessibilityIdentifier("log")
    }
}
#endif
