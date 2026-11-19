import Foundation

#if canImport(CoreMIDI)
import Darwin
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import XTouchOneAdapter
import XTouchOneCapture
import XTouchOneCoreMIDI

let usage = """
usage:
  xtouch-one-monitor list
  xtouch-one-monitor probe  --input <unique-id> [--seconds <n>]
  xtouch-one-monitor record --input <unique-id> --mode <Midi|MidiRel|CChg|CChgRel> --channel <1-16>
                            --source <hardware|simulation> --out <capture.jsonl>
                            [--seconds <n>] [--firmware <text>] [--note <text>]
  xtouch-one-monitor show   --mode <mode> --channel <1-16> --source <hardware|simulation>
                            [--input <unique-id> --output <unique-id>] [--write]
                            led <0-34> <off|flash|on> | ring <0-127> | meter <0-127>
                            lcd <upper> <lower> [color] [--invert-upper] [--invert-lower]
                            segments <24 hex digits> [<dots-low-hex> <dots-high-hex>]

list, probe and record never send. probe observes for 10 seconds by default.
show requires both endpoints with --write and sends one display message.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

/// Splits `--name value` options and bare flags from positional words.
func parse(_ arguments: [String], options allowed: Set<String>, flags: Set<String> = []) -> (options: [String: String], flags: Set<String>, rest: [String]) {
    var options: [String: String] = [:], seen: Set<String> = [], rest: [String] = []
    var index = 0
    while index < arguments.count {
        let word = arguments[index]
        if flags.contains(word) {
            guard seen.insert(word).inserted else { fail("duplicate flag \(word)") }
        } else if word.hasPrefix("--") {
            guard allowed.contains(word) else { fail("unknown option \(word)\n\(usage)") }
            guard options[word] == nil else { fail("duplicate option \(word)") }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                fail("missing value for \(word)\n\(usage)")
            }
            options[word] = arguments[index + 1]
            index += 1
        } else {
            rest.append(word)
        }
        index += 1
    }
    return (options, seen, rest)
}

struct Selection {
    let profile: XTouchOneMIDIProfile
    let source: DeviceSource

    init(_ options: [String: String]) {
        guard let mode = options["--mode"].flatMap(XTouchOneMIDIMode.init(rawValue:)),
              let channel = options["--channel"].flatMap({ UInt8($0) }),
              let profile = try? XTouchOneMIDIProfile(mode: mode, channel: channel) else {
            fail("--mode and --channel must match what the device shows\n\(usage)")
        }
        guard let source = options["--source"].flatMap(DeviceSource.init(rawValue:)) else {
            fail("--source must be stated as hardware or simulation\n\(usage)")
        }
        self.profile = profile
        self.source = source
    }
}

func endpoint(_ options: [String: String], _ name: String, _ direction: XTouchOneMIDIEndpoint.Direction) -> XTouchOneMIDIEndpoint {
    let id = endpointID(options, name)
    guard let found = XTouchOneMIDIEndpoint.all(direction).first(where: { $0.uniqueID == id && !$0.isOffline }) else {
        fail("\(name) must be the unique id of an online \(direction.rawValue); see `xtouch-one-monitor list`")
    }
    return found
}

func endpointID(_ options: [String: String], _ name: String) -> Int32 {
    guard let id = options[name].flatMap({ Int32($0) }), id != 0 else {
        fail("\(name) requires a nonzero signed 32-bit MIDI unique id; see `xtouch-one-monitor list`")
    }
    return id
}

func duration(_ options: [String: String]) -> Double? {
    guard let raw = options["--seconds"] else { return nil }
    guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
        fail("--seconds requires a finite positive number")
    }
    return seconds
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: true) }.joined(separator: " ")
}

func list() {
    for direction in [XTouchOneMIDIEndpoint.Direction.source, .destination] {
        print("\(direction.rawValue)s:")
        for item in XTouchOneMIDIEndpoint.all(direction) {
            let details = [item.manufacturer, item.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            print("  \(item.uniqueID)  \(item.name)" + (details.isEmpty ? "" : "  (\(details))")
                + (item.isVirtual ? "  virtual" : "") + (item.isOffline ? "  offline" : ""))
        }
    }
}

@MainActor
final class Recorder {
    private let file: FileHandle
    private var session: XTouchOneSession
    private var seq = 0

    init(file: FileHandle, selection: Selection) throws {
        self.file = file
        session = try XTouchOneSession(source: selection.source, profile: selection.profile, displayRate: .unlimited)
    }

    private func append(_ content: XTouchOneCaptureRecord.Content, at: Double) throws {
        seq += 1
        let record = XTouchOneCaptureRecord(seq: seq, at: at, generation: session.generation, content: content)
        try file.write(contentsOf: Data((XTouchOneCapture.line(record) + "\n").utf8))
    }

    func receive(_ event: XTouchOneMIDISourceMonitor.Event, at: Double) throws {
        switch event {
        case .connected(let endpoint):
            let route = try XTouchOneRoute(inputID: String(endpoint.uniqueID), outputID: "not-opened",
                                           transportOrigin: endpoint.isVirtual ? .localVirtual : .physicalUSB)
            try session.attach(route)
            try append(.connected, at: at)
            print("connected: \(endpoint.name) [\(endpoint.uniqueID)], generation \(session.generation)")
        case .disconnected:
            try append(.disconnected, at: at)
            try session.detach()
            print("disconnected")
        case .input(let message):
            try append(.input(message), at: at)
            switch try session.receive(message, at: at) {
            case .event(let event): print("\(hex(message))  \(event.elementID) \(event.kind.rawValue) \(event.value)")
            case .ignored(let reason): print("\(hex(message))  \(reason)")
            }
        }
    }
}

@MainActor
func runMonitor(inputID: Int32, seconds: Double?,
                receive: @escaping (Double, XTouchOneMIDISourceMonitor.Event) throws -> Void) throws -> Double {
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = seconds.map { start + $0 } ?? .infinity
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let stopped = Stop()
    interrupt.setEventHandler { stopped.set() }
    interrupt.resume()
    defer { interrupt.cancel() }

    var eventError: (any Error)?
    print("waiting for MIDI input [\(inputID)]; nothing is sent. Press Ctrl-C to finish.")
    let monitor = try XTouchOneMIDISourceMonitor(sourceUniqueID: inputID, clientName: "xtouch-one-monitor") { event in
        let now = ProcessInfo.processInfo.systemUptime
        guard now < deadline, !stopped.isSet, eventError == nil else { return }
        do { try receive(now - start, event) } catch { eventError = error }
    }
    defer { monitor.stop() }
    while !stopped.isSet, eventError == nil, monitor.connectionError == nil {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: min(remaining, 0.1)))
    }
    if let error = eventError ?? monitor.connectionError { throw error }
    return min(deadline, ProcessInfo.processInfo.systemUptime) - start
}

@MainActor
func probe(_ arguments: [String]) throws {
    let (options, _, rest) = parse(arguments, options: ["--input", "--seconds"])
    guard rest.isEmpty else { fail(usage) }
    let inputID = endpointID(options, "--input")
    var connections = 0
    var inputCount = 0
    var connectedAt: Double?
    var listening = 0.0
    let elapsed = try runMonitor(inputID: inputID, seconds: duration(options) ?? 10) { at, event in
        let time = String(format: "%.3f s", at)
        switch event {
        case .connected(let endpoint):
            connections += 1
            connectedAt = at
            print("\(time) connected: \(endpoint.name) [\(endpoint.uniqueID)]")
        case .disconnected:
            if let connectedAt { listening += at - connectedAt }
            connectedAt = nil
            print("\(time) disconnected")
        case .input(let message):
            inputCount += 1
            print("\(time)  \(hex(message))")
        }
    }
    if let connectedAt { listening += elapsed - connectedAt }
    print("observed: \(connections) connections, \(inputCount) input messages, \(String(format: "%.3f", listening)) s connected")
}

@MainActor
func record(_ arguments: [String]) throws {
    let (options, _, rest) = parse(arguments, options: ["--input", "--mode", "--channel", "--source", "--out", "--seconds",
                                                        "--firmware", "--note"])
    guard rest.isEmpty, let path = options["--out"] else { fail(usage) }
    let selection = Selection(options)
    let inputID = endpointID(options, "--input")
    let seconds = duration(options)
    let input = XTouchOneMIDIEndpoint.all(.source).first { $0.uniqueID == inputID }
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
    guard descriptor >= 0 else {
        if errno == EEXIST { fail("\(path) already exists; captures are never overwritten") }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

    let header = XTouchOneCaptureHeader(mode: selection.profile.mode, channel: selection.profile.channel,
                                        source: selection.source.rawValue, inputID: String(inputID),
                                        inputName: input?.name, firmware: options["--firmware"], note: options["--note"])
    try file.write(contentsOf: Data((XTouchOneCapture.line(header) + "\n").utf8))
    let recorder = try Recorder(file: file, selection: selection)
    _ = try runMonitor(inputID: inputID, seconds: seconds) { at, event in try recorder.receive(event, at: at) }
    try file.close()

    let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    print("\n" + (try XTouchOneCaptureReview(XTouchOneCapture(jsonLines: text))).text(), terminator: "")
}

final class Stop: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

func display(_ words: [String], invertUpper: Bool, invertLower: Bool) -> XTouchOneDisplay {
    guard words.first == "lcd" || (!invertUpper && !invertLower) else { fail("inversion flags require lcd") }
    func value(_ index: Int) -> UInt8 {
        guard index < words.count, let value = UInt8(words[index]), value < 128 else { fail(usage) }
        return value
    }
    switch words.first {
    case "led":
        let states: [String: XTouchOneButtonLED] = ["off": .off, "flash": .flash, "on": .on]
        guard words.count == 3, let button = XTouchOneButton(rawValue: value(1)), let state = states[words[2]] else { fail(usage) }
        return .buttonLED(button, state)
    case "ring" where words.count == 2: return .encoderRing(value(1))
    case "meter" where words.count == 2: return .meter(value(1))
    case "lcd" where words.count == 3 || words.count == 4:
        let colors: [String: XTouchOneLCDColor] = ["black": .black, "red": .red, "green": .green, "yellow": .yellow,
                                                   "blue": .blue, "magenta": .magenta, "cyan": .cyan, "white": .white]
        guard let color = colors[words.count == 4 ? words[3] : "white"] else { fail(usage) }
        return .lcd(upper: words[1], lower: words[2], color: color, invertUpper: invertUpper, invertLower: invertLower)
    case "segments" where words.count == 2 || words.count == 4:
        let digits = Array(words[1].utf8)
        guard digits.count == 24 else { fail("segments requires exactly 12 hexadecimal segment masks") }
        func mask(_ digits: ArraySlice<UInt8>, maximum: UInt8) -> UInt8 {
            guard digits.count == 2, digits.first != UInt8(ascii: "+"), digits.first != UInt8(ascii: "-"),
                  let value = UInt8(String(decoding: digits, as: UTF8.self), radix: 16), value <= maximum else { fail(usage) }
            return value
        }
        let segments = stride(from: 0, to: digits.count, by: 2).map { mask(digits[$0..<($0 + 2)], maximum: 0x7F) }
        let dotsLow = words.count == 4 ? mask(Array(words[2].utf8)[...], maximum: 0x7F) : 0
        let dotsHigh = words.count == 4 ? mask(Array(words[3].utf8)[...], maximum: 0x1F) : 0
        return .segmentDisplay(segments: segments, dotsLow: dotsLow, dotsHigh: dotsHigh)
    default: fail(usage)
    }
}

func show(_ arguments: [String]) throws {
    let (options, flags, rest) = parse(arguments, options: ["--input", "--output", "--mode", "--channel", "--source"],
                                      flags: ["--write", "--invert-upper", "--invert-lower"])
    let selection = Selection(options)
    let request = display(rest, invertUpper: flags.contains("--invert-upper"), invertLower: flags.contains("--invert-lower"))
    let inputID = options["--input"].map { _ in endpointID(options, "--input") }
    let outputID = options["--output"].map { _ in endpointID(options, "--output") }
    print("message: \(hex(try selection.profile.encodeDisplay(request))) for \(request.targetID)")
    guard flags.contains("--write") else {
        print("preview only: add --write and both endpoint IDs to send this one message")
        return
    }
    guard inputID != nil, outputID != nil else { fail("--write requires --input and --output") }
    let input = endpoint(options, "--input", .source), output = endpoint(options, "--output", .destination)
    var session = try XTouchOneSession(source: selection.source, profile: selection.profile, displayRate: .unlimited,
                                       outputPolicy: .write)
    try session.attach(XTouchOneRoute(inputID: String(input.uniqueID), outputID: String(output.uniqueID),
                                      transportOrigin: output.isVirtual ? .localVirtual : .physicalUSB))
    session.grantDisplay(to: .local)
    guard case .send(let send) = try session.writeDisplay(request, origin: .local) else {
        fail("the session refused this display request")
    }
    guard session.preflight(send) == .permitted else { fail("refused by the final gate: \(session.preflight(send))") }
    let result: FeedbackAttemptResult
    do {
        try XTouchOneMIDIOutput(destinationUniqueID: output.uniqueID, clientName: "xtouch-one-monitor").write(send.bytes)
        result = .accepted
    } catch {
        result = .rejected(reason: "\(error)")
    }
    let receipt = try session.complete(send, result: result, at: ProcessInfo.processInfo.systemUptime)
    print("transport: \(receipt.fact.result) to \(output.name) [\(output.uniqueID)]. This is sent evidence, not what the device shows.")
    if !receipt.fact.successfulSend { exit(1) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "list" where arguments.count == 1: list()
    case "probe": try probe(Array(arguments.dropFirst()))
    case "record": try record(Array(arguments.dropFirst()))
    case "show": try show(Array(arguments.dropFirst()))
    default: fail(usage)
    }
} catch {
    fail("xtouch-one-monitor: \(error)")
}
#else
FileHandle.standardError.write(Data("xtouch-one-monitor needs CoreMIDI and runs on macOS only.\n".utf8))
exit(2)
#endif
