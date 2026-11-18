import Foundation

#if canImport(CoreMIDI)
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import XTouchOneAdapter
import XTouchOneCapture
import XTouchOneCoreMIDI

let usage = """
usage:
  xtouch-one-monitor list
  xtouch-one-monitor record --input <unique-id> --mode <Midi|MidiRel|CChg|CChgRel> --channel <1-16>
                            --source <hardware|simulation> --out <capture.jsonl>
                            [--seconds <n>] [--firmware <text>] [--note <text>]
  xtouch-one-monitor show   --input <unique-id> --output <unique-id> --mode <mode> --channel <1-16>
                            --source <hardware|simulation> [--write]
                            (led <0-34> <off|flash|on> | ring <0-127> | meter <0-127> | lcd <upper> <lower> [color])

list and record never send. show sends one display message, and only with --write.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

/// Splits `--name value` options and bare flags from positional words.
func parse(_ arguments: [String], flags: Set<String>) -> (options: [String: String], flags: Set<String>, rest: [String]) {
    var options: [String: String] = [:], seen: Set<String> = [], rest: [String] = []
    var index = 0
    while index < arguments.count {
        let word = arguments[index]
        if flags.contains(word) {
            seen.insert(word)
        } else if word.hasPrefix("--") {
            guard index + 1 < arguments.count else { fail("missing value for \(word)\n\(usage)") }
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
    guard let id = options[name].flatMap({ Int32($0) }),
          let found = XTouchOneMIDIEndpoint.all(direction).first(where: { $0.uniqueID == id }) else {
        fail("\(name) must be the unique id of a current \(direction.rawValue); see `xtouch-one-monitor list`")
    }
    return found
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

/// Serializes the capture file and the session across CoreMIDI's thread and the main run loop.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let start = ProcessInfo.processInfo.systemUptime
    private let route: XTouchOneRoute
    private let sourceID: Int32
    private var session: XTouchOneSession
    private var seq = 0

    init(file: FileHandle, selection: Selection, input: XTouchOneMIDIEndpoint) throws {
        self.file = file
        sourceID = input.uniqueID
        route = try XTouchOneRoute(inputID: String(input.uniqueID), outputID: "not-opened",
                                   transportOrigin: input.isVirtual ? .localVirtual : .physicalUSB)
        // Observe-only: this session can decode input but refuses every output request.
        session = try XTouchOneSession(source: selection.source, profile: selection.profile, displayRate: .unlimited)
    }

    private func append(_ content: XTouchOneCaptureRecord.Content) throws -> Double {
        seq += 1
        let at = ProcessInfo.processInfo.systemUptime - start
        let record = XTouchOneCaptureRecord(seq: seq, at: at, generation: session.generation, content: content)
        try file.write(contentsOf: Data((XTouchOneCapture.line(record) + "\n").utf8))
        return at
    }

    /// Follows the source's presence. A missing or offline source ends the generation.
    func refreshPresence() {
        lock.withLock {
            let present = XTouchOneMIDIEndpoint.all(.source).contains { $0.uniqueID == sourceID && !$0.isOffline }
            guard present != session.isConnected else { return }
            do {
                if present {
                    try session.attach(route)
                    _ = try append(.connected)
                } else {
                    _ = try append(.disconnected)
                    try session.detach()
                }
                print(present ? "connected, generation \(session.generation)" : "disconnected")
            } catch { fail("capture failed: \(error)") }
        }
    }

    func receive(_ message: [UInt8]) {
        lock.withLock {
            do {
                let at = try append(.input(message))
                switch try session.receive(message, at: at) {
                case .event(let event): print("\(hex(message))  \(event.elementID) \(event.kind.rawValue) \(event.value)")
                case .ignored(let reason): print("\(hex(message))  \(reason)")
                }
            } catch { fail("capture failed: \(error)") }
        }
    }
}

func record(_ arguments: [String]) throws {
    let (options, _, rest) = parse(arguments, flags: [])
    guard rest.isEmpty, let path = options["--out"] else { fail(usage) }
    let selection = Selection(options)
    let input = endpoint(options, "--input", .source)
    let seconds = options["--seconds"].flatMap(Double.init)
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; captures are never overwritten") }
    guard FileManager.default.createFile(atPath: path, contents: nil),
          let file = FileHandle(forWritingAtPath: path) else { fail("cannot create \(path)") }

    let header = XTouchOneCaptureHeader(mode: selection.profile.mode, channel: selection.profile.channel,
                                        source: selection.source.rawValue, inputID: String(input.uniqueID),
                                        inputName: input.name, firmware: options["--firmware"], note: options["--note"])
    try file.write(contentsOf: Data((XTouchOneCapture.line(header) + "\n").utf8))
    let recorder = try Recorder(file: file, selection: selection, input: input)
    let listener = try XTouchOneMIDIInput(sourceUniqueID: input.uniqueID, clientName: "xtouch-one-monitor",
                                          receive: { recorder.receive($0) }, setupChanged: { recorder.refreshPresence() })
    recorder.refreshPresence()

    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let stopped = Stop()
    interrupt.setEventHandler { stopped.set() }
    interrupt.resume()
    print("listening to \(input.name) [\(input.uniqueID)]; nothing is sent. Press Ctrl-C to finish.")
    let deadline = seconds.map { Date().addingTimeInterval($0) } ?? .distantFuture
    while !stopped.isSet, Date() < deadline {
        RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.1)))
    }
    withExtendedLifetime(listener) {}
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

func display(_ words: [String]) -> XTouchOneDisplay {
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
        return .lcd(upper: words[1], lower: words[2], color: color, invertUpper: false, invertLower: false)
    default: fail(usage)
    }
}

func show(_ arguments: [String]) throws {
    let (options, flags, rest) = parse(arguments, flags: ["--write"])
    let selection = Selection(options)
    let input = endpoint(options, "--input", .source), output = endpoint(options, "--output", .destination)
    let request = display(rest)
    let policy: XTouchOneOutputPolicy = flags.contains("--write") ? .write : .observe
    var session = try XTouchOneSession(source: selection.source, profile: selection.profile, displayRate: .unlimited,
                                       outputPolicy: policy)
    try session.attach(XTouchOneRoute(inputID: String(input.uniqueID), outputID: String(output.uniqueID),
                                      transportOrigin: output.isVirtual ? .localVirtual : .physicalUSB))
    session.grantDisplay(to: .local)
    print("message: \(hex(try selection.profile.encodeDisplay(request))) for \(request.targetID)")
    guard case .send(let send) = try session.writeDisplay(request, origin: .local) else {
        print("not sent: add --write to send this one message to \(output.name) [\(output.uniqueID)]")
        return
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
