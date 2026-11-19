#if os(macOS)
import SwiftUI
import XTouchOneAdapter
import XTouchOneCoreMIDI

/// Always-visible mode strip: which device, and whether output is armed.
struct ModeBar: View {
    let model: AppModel

    private var mode: ConsoleMode { model.consoleMode }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                modeButton("mode.mock", "Mock 设备", "cpu", Theme.value, selected: mode == .mock) { model.setMode(.mock) }
                modeButton("mode.hardware", "Hardware", "cable.connector", barColor, selected: mode != .mock) {
                    if mode == .mock { model.setMode(.hardwareListen) }
                }
            }
            .padding(BarMetrics.segmentInset)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: BarMetrics.radius))

            if mode != .mock {
                HStack(spacing: 4) {
                    modeButton("mode.listen", "只监听", "ear", Theme.touch, selected: mode == .hardwareListen) {
                        model.setMode(.hardwareListen)
                    }
                    modeButton("mode.send", "允许发送", "bolt.fill", .green, selected: mode == .hardwareSend) {
                        model.setMode(.hardwareSend)
                    }
                    .help("允许应用向设备发送按键灯、灯环、电平表、LCD 和数码管。电机召回另有单独的开关。")
                }
                .padding(BarMetrics.segmentInset)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: BarMetrics.radius))

                HStack(spacing: 5) {
                    Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.isConnected ? "已连接 · 代次 \(model.console.session.generation)" : "未连接")
                        .font(.caption.monospaced())
                        .foregroundStyle(model.isConnected ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                .frame(height: BarMetrics.height)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Toggle("演示联动", isOn: Binding(get: { model.demoLinks }, set: { model.demoLinks = $0 }))
                .toggleStyle(.switch).controlSize(.small)
                .help("按键点亮自己的灯，编码器带灯环，推子带电平表和 LCD，拨轮带数码管计数。全部走正常的显示路径。")
                .accessibilityIdentifier("mode.demoLinks")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(barColor.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(barColor.opacity(0.55)).frame(height: 2) }
    }

    private var barColor: Color {
        switch mode {
        case .mock: Theme.value
        case .hardwareListen: Theme.touch
        case .hardwareSend: .green
        }
    }

    private var explanation: String {
        switch mode {
        case .mock: "模拟设备。没有任何字节到达真实控制台。"
        case .hardwareListen: "只监听。显示请求全部被拒绝，不向设备发送。"
        case .hardwareSend: "发送已开启。面板上的灯和显示是已发送的内容，不是设备的实际显示。"
        }
    }

    private func modeButton(_ identifier: String, _ title: String, _ icon: String, _ color: Color, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(selected ? .bold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: BarMetrics.height - 2 * BarMetrics.segmentInset)
                .foregroundStyle(selected ? Color.black : Color.primary.opacity(0.8))
                .background(selected ? color : Color.clear,
                            in: RoundedRectangle(cornerRadius: BarMetrics.radius - BarMetrics.segmentInset + 1))
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HeaderBar: View {
    @Bindable var model: AppModel
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("X-TOUCH ONE CONSOLE")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(1.6)
                Text(model.profileSummary).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if let error = model.lastError {
                Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).lineLimit(1)
                    .accessibilityIdentifier("header.error")
            }
            Button { model.selection = .fader } label: { Label("推子", systemImage: "slider.vertical.3") }
            .accessibilityIdentifier("header.selectFader")
            .buttonStyle(BarButtonStyle())
            .help("打开推子检查器")
            Button { showsSettings = true } label: { Label("设置", systemImage: "gearshape") }
                .labelStyle(.iconOnly).buttonStyle(BarButtonStyle()).help("设置")
                .accessibilityIdentifier("header.settings")
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) { ConnectionSettingsView(model: model) }
            DeviceStatus(model: model)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct DeviceStatus: View {
    let model: AppModel

    var body: some View {
        let mock = model.link == .mock
        let color: Color = mock ? Theme.value : model.isConnected ? .green : .orange
        HStack(spacing: 8) {
            Image(systemName: mock ? "cpu" : model.isConnected ? "cable.connector.horizontal" : "cable.connector.slash")
                .foregroundStyle(color)
            Text(mock ? "Mock 设备运行中" : model.isConnected ? "X-TOUCH ONE 已连接" : "X-TOUCH ONE 未连接")
                .font(.callout.bold()).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: BarMetrics.height)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: BarMetrics.radius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("header.status")
    }
}

/// Mode, channel and endpoints. Every change builds a new session; connecting sends nothing.
struct ConnectionSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("设备模式", icon: "dial.medium")
                Picker("模式", selection: Binding(get: { model.mode }, set: { model.configure(mode: $0) })) {
                    ForEach(XTouchOneMIDIMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("settings.mode")
                Picker("通道", selection: Binding(get: { model.channel }, set: { model.configure(channel: $0) })) {
                    ForEach(UInt8(1)...16, id: \.self) { Text("\($0)").tag($0) }
                }
                .accessibilityIdentifier("settings.channel")
                Text("这里只记录你在设备面板上选的模式和通道，应用不会切换设备的模式。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .panelStyle()

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("实体端点", icon: "cable.connector")
                Toggle("自动连接（只监听）", isOn: Binding(get: { model.autoConnect }, set: { model.setAutoConnect($0) }))
                    .accessibilityIdentifier("settings.autoConnect")
                if model.autoConnect && model.autoConnectPaused {
                    Button("恢复自动连接") { model.resumeAutomaticConnection() }
                        .accessibilityIdentifier("settings.resumeAutoConnect")
                }
                Picker("输入", selection: $model.sourceID) {
                    Text("未选择").tag(Int32?.none)
                    if let id = model.sourceID, !model.sources.contains(where: { $0.uniqueID == id }) {
                        Text("离线 · \(id)").tag(Optional(id))
                    }
                    ForEach(model.sources, id: \.uniqueID) { Text(Self.name($0)).tag(Int32?.some($0.uniqueID)) }
                }
                .disabled(model.isConnected).accessibilityIdentifier("settings.input")
                Picker("输出", selection: $model.destinationID) {
                    Text("不打开").tag(Int32?.none)
                    if let id = model.destinationID, !model.destinations.contains(where: { $0.uniqueID == id }) {
                        Text("离线 · \(id)").tag(Optional(id))
                    }
                    ForEach(model.destinations, id: \.uniqueID) { Text(Self.name($0)).tag(Int32?.some($0.uniqueID)) }
                }
                .disabled(model.isConnected).accessibilityIdentifier("settings.output")
                HStack {
                    Button(model.isConnected ? "断开" : "连接") { model.isConnected ? model.disconnect() : model.connect() }
                        .disabled(model.link != .hardware || (!model.isConnected && !model.sources.contains {
                            $0.uniqueID == model.sourceID && !$0.isOffline
                        }))
                        .accessibilityIdentifier("settings.connect")
                    Button("刷新端点") { model.refreshEndpoints() }.disabled(model.isConnected)
                    Spacer()
                }
                Toggle("允许电机召回", isOn: Binding(get: { model.allowRecall }, set: { model.configure(allowRecall: $0) }))
                    .disabled(model.consoleMode != .hardwareSend)
                    .accessibilityIdentifier("settings.allowRecall")
                Text(model.link == .hardware ? "连接本身不发送任何字节。电机召回只在“允许发送”下可以打开。"
                    : model.autoConnect && !model.autoConnectPaused ? "找到设备后将进入只监听。"
                    : "先在顶部切到 Hardware，才能手动连接实体端点。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .panelStyle()

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("面板", icon: "square.grid.3x3")
                Toggle("在按键上显示地址", isOn: $model.showAddresses).accessibilityIdentifier("settings.showAddresses")
            }
            .panelStyle()
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshEndpoints() }
    }

    private static func name(_ endpoint: XTouchOneMIDIEndpoint) -> String {
        endpoint.name + (endpoint.isVirtual ? "（虚拟）" : "") + (endpoint.isOffline ? "（离线）" : "")
    }
}
#endif
