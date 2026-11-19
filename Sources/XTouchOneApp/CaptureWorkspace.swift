#if os(macOS)
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import XTouchOneAdapter
import XTouchOneCapture
import XTouchOnePanel

@MainActor
final class LiveCaptureWriter {
    let location: URL
    private let handle: FileHandle
    private let start: Double
    private var cursor: Int
    private var lastConnectedGeneration: UInt64?
    private var byteCount = 0
    private(set) var events = 0

    init(at location: URL, model: AppModel) throws {
        self.location = location
        let fd = Darwin.open(location.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        start = model.now
        cursor = model.console.log.last?.id ?? 0
        let header = XTouchOneCaptureHeader(mode: model.mode, channel: model.channel, source: model.console.session.source.rawValue,
                                           inputID: model.console.session.route?.inputID,
                                           inputName: model.sources.first { $0.uniqueID == model.sourceID }?.name)
        try write(header)
        if model.isConnected {
            let generation = model.console.session.generation
            try append(.connected, at: start, generation: generation)
            lastConnectedGeneration = generation
        }
    }

    func collect(_ entries: [XTouchOneConsole.Entry]) throws {
        if let first = entries.first, first.id > cursor + 1 { throw XTouchOneCaptureError.invalidRecord(line: events + 2) }
        for entry in entries where entry.id > cursor {
            defer { cursor = entry.id }
            if let connected = entry.connection {
                let generation = connected ? entry.generation : lastConnectedGeneration ?? entry.generation
                try append(connected ? .connected : .disconnected, at: entry.at, generation: generation)
                lastConnectedGeneration = connected ? generation : nil
            } else if entry.kind == .input {
                try append(.input(entry.bytes), at: entry.at, generation: entry.generation)
            } else if entry.kind == .output, entry.result == .accepted {
                try append(.output(entry.bytes), at: entry.at, generation: entry.generation)
            }
        }
    }

    func close() throws { try handle.close() }

    private func append(_ content: XTouchOneCaptureRecord.Content, at time: Double, generation: UInt64) throws {
        try write(XTouchOneCaptureRecord(seq: events + 1, at: max(0, time - start), generation: generation, content: content))
        events += 1
    }

    private func write<T: Encodable>(_ value: T) throws {
        let data = Data((try XTouchOneCapture.line(value) + "\n").utf8)
        guard byteCount + data.count <= XTouchOneCapture.maximumBytes else { throw XTouchOneCaptureError.tooLarge }
        try handle.write(contentsOf: data)
        byteCount += data.count
    }
}

struct CaptureWorkspace: View {
    let model: AppModel
    @State private var open = false
    @State private var inspection: XTouchOneCaptureInspection?
    @State private var replay: XTouchOneCaptureReplay?
    @State private var name: String?
    @State private var error: String?
    @State private var testTarget = "led"
    @State private var testAddress: UInt8 = 23
    @State private var testState = XTouchOneButtonLED.on
    @State private var testValue = 64.0
    @State private var confirmSend = false

    var body: some View {
        OverflowScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if model.recording {
                        Button("结束录制") { model.stopCapture() }.accessibilityIdentifier("capture.stop")
                        Text("\(model.captureEvents) 条").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Button("开始录制…") { chooseCaptureFile() }.accessibilityIdentifier("capture.start")
                    }
                    Spacer()
                    Button("打开录制…") { open = true }.accessibilityIdentifier("capture.open")
                }
                if let url = model.captureLocation {
                    HStack {
                        Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                        Button("审查") { load(url) }.disabled(model.recording)
                    }
                }
                if let inspection {
                    SectionTitle(name ?? "录制审查", icon: "doc.text")
                    Text(inspection.text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    if case .native(let capture, _) = inspection {
                        Button("回放输入至隔离模拟器") {
                            do { replay = try XTouchOneCaptureReplay(capture); error = nil }
                            catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("capture.replay")
                    }
                    if let replay {
                        let position = replay.reportedPosition.map { String($0) } ?? "—"
                        Text("回放 \(replay.replayedMessages) 条 · 推子 \(position) · 拨轮 \(replay.console.jogTicks)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = error ?? model.captureError { Text(error).foregroundStyle(.red).font(.caption) }
                Divider()
                workbench
            }
        }
        .fileImporter(isPresented: $open, allowedContentTypes: [.text, .json, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                load(url)
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("发送这条显示报文？", isPresented: $confirmSend) {
            Button("发送显示") { model.show(testDisplay) }
            Button("取消", role: .cancel) {}
        }
    }

    private var workbench: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle("显示测试", icon: "lightbulb")
            Picker("目标", selection: $testTarget) {
                Text("按键灯").tag("led")
                Text("灯环").tag("ring")
                Text("电平表").tag("meter")
                Text("LCD").tag("lcd")
                Text("数码管").tag("segments")
            }
            if testTarget == "led" {
                Picker("按键", selection: $testAddress) {
                    ForEach(XTouchOnePanelLayout.keys) { Text("\($0.address) · \($0.label)").tag($0.address) }
                }
                Picker("状态", selection: $testState) {
                    Text("熄灭").tag(XTouchOneButtonLED.off)
                    Text("闪烁").tag(XTouchOneButtonLED.flash)
                    Text("点亮").tag(XTouchOneButtonLED.on)
                }
            } else if testTarget == "meter" || testTarget == "ring" {
                Slider(value: $testValue, in: 0...127, step: 1)
            }
            let bytes = (try? model.console.session.profile.encodeDisplay(testDisplay)) ?? []
            HStack {
                Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("发送…") { confirmSend = true }.disabled(!model.canWriteDisplay)
            }
        }.insetStyle()
    }

    private var testDisplay: XTouchOneDisplay {
        switch testTarget {
        case "ring": return .encoderRing(UInt8(testValue))
        case "meter": return .meter(UInt8(testValue))
        case "lcd": return .lcd(upper: "TOP1234", lower: "BOT5678", color: .cyan, invertUpper: true, invertLower: false)
        case "segments": return .segmentDisplay(segments: [0x3F, 6, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 7, 0x7F, 0x6F, 0x3F, 6],
                                                dotsLow: 1, dotsHigh: 16)
        default: return .buttonLED(XTouchOneButton(rawValue: testAddress)!, testState)
        }
    }

    private func chooseCaptureFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "X-Touch-One.jsonl"
        // The recorder uses exclusive creation, even if the user chose an existing name.
        if panel.runModal() == .OK, let url = panel.url { model.startCapture(at: url) }
    }

    private func load(_ url: URL) {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: XTouchOneCapture.maximumBytes + 1) ?? Data()
            guard bytes.count <= XTouchOneCapture.maximumBytes else { throw XTouchOneCaptureError.tooLarge }
            inspection = try XTouchOneCaptureInspection(jsonLines: String(decoding: bytes, as: UTF8.self))
            name = url.lastPathComponent
            replay = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
#endif
