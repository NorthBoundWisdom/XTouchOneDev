#if canImport(CoreMIDI)
import Darwin
import Foundation
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import XTouchOneAdapter
import XTouchOneCapture
import XTouchOneCoreMIDI
import XTouchOnePanel

enum ControlError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidRequest(String)
    case simulationOnly
    case displayUnavailable
    case recallRefused(String)

    var code: String {
        switch self {
        case .invalidArguments: "invalidArguments"
        case .invalidRequest: "invalidRequest"
        case .simulationOnly: "simulationOnly"
        case .displayUnavailable: "displayUnavailable"
        case .recallRefused: "recallRefused"
        }
    }

    var description: String {
        switch self {
        case .invalidArguments(let message), .invalidRequest(let message), .recallRefused(let message): message
        case .simulationOnly: "this operation is available only in a simulation session"
        case .displayUnavailable: "display writes require an active output binding; restart with --write after endpoint loss"
        }
    }
}

private struct Command: Decodable {
    let id: String
    let op: String
    let args: [String]
    let after: Int
    let invertUpper: Bool
    let invertLower: Bool

    enum CodingKeys: String, CodingKey { case id, op, args, after, invertUpper, invertLower }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        op = try fields.decode(String.self, forKey: .op)
        args = try fields.decodeIfPresent([String].self, forKey: .args) ?? []
        after = try fields.decodeIfPresent(Int.self, forKey: .after) ?? 0
        invertUpper = try fields.decodeIfPresent(Bool.self, forKey: .invertUpper) ?? false
        invertLower = try fields.decodeIfPresent(Bool.self, forKey: .invertLower) ?? false
    }
}

private struct Reply<Result: Encodable>: Encodable {
    let id: String?
    let ok: Bool
    var result: Result?
    var error: Failure?

    struct Failure: Encodable {
        let code: String
        let message: String
    }
}

private struct Status: Encodable {
    let source: String
    let mode: String
    let channel: UInt8
    let generation: UInt64
    let connected: Bool
    let inputID: Int32?
    let outputID: Int32?
    let displayWrite: Bool
    let pendingDisplayTargets: [String]
    let faderPosition: UInt8?
    let faderTouched: Bool?
    let pressed: [String]
    let cursor: Int
}

private struct EventPage: Encodable {
    let cursor: Int
    let truncated: Bool
    let entries: [Entry]

    struct Entry: Encodable {
        let id: Int
        let at: Double
        let generation: UInt64
        let kind: String
        let bytes: [UInt8]
        let detail: String
        var outcome: String?
        var reason: String?

        init(_ entry: XTouchOneConsole.Entry) {
            id = entry.id
            at = entry.at
            generation = entry.generation
            kind = entry.kind.rawValue
            bytes = entry.bytes
            detail = entry.text
            switch entry.result {
            case .accepted: outcome = "accepted"
            case .rejected(let reason): outcome = "rejected"; self.reason = reason
            case .notAttempted(let reason): outcome = "notAttempted"; self.reason = reason
            case nil: break
            }
        }
    }
}

private extension XTouchOneMIDIEndpoint {
    var isXTouchOneDeviceEndpoint: Bool {
        !isVirtual && manufacturer?.caseInsensitiveCompare("Behringer") == .orderedSame
            && model?.caseInsensitiveCompare("X-Touch One") == .orderedSame
    }
}

@MainActor
private final class ControlSession {
    private var console: XTouchOneConsole
    private let inputID: Int32?
    private let outputID: Int32?
    private let outputDeviceID: Int32?
    private var monitor: XTouchOneMIDISourceMonitor?
    private var output: XTouchOneMIDIOutput?
    private var eventError: (any Error)?
    private let start = ProcessInfo.processInfo.systemUptime
    private var stopped = false

    init(selection: Selection, inputID: Int32?, outputID: Int32?) throws {
        self.inputID = inputID
        self.outputID = outputID
        if let outputID {
            guard let endpoint = XTouchOneMIDIEndpoint.all(.destination).first(where: {
                $0.uniqueID == outputID && !$0.isOffline && $0.isXTouchOneDeviceEndpoint
            }), let deviceID = endpoint.deviceID else {
                throw ControlError.invalidArguments("--output requires an online X-Touch One destination")
            }
            outputDeviceID = deviceID
        } else {
            outputDeviceID = nil
        }
        let mock = selection.source == .simulation
        console = try XTouchOneConsole(
            link: mock ? .mock : .hardware, profile: selection.profile,
            displayRate: mock ? .unlimited : XTouchOneConsole.hardwareDisplayRate,
            outputPolicy: mock || outputID != nil ? .write : .observe,
            mechanismPolicy: mock ? .localRecall : .disabled, demoLinks: false)
        if let outputID {
            output = try XTouchOneMIDIOutput(destinationUniqueID: outputID, clientName: "xtouch-one-session")
        }
        if let inputID {
            monitor = try XTouchOneMIDISourceMonitor(sourceUniqueID: inputID, clientName: "xtouch-one-session") {
                [weak self] in self?.receive($0)
            }
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime - start }
    private var displayAvailable: Bool { console.link == .mock || (output?.isCurrent == true && monitor?.isCurrent == true) }

    private func receive(_ event: XTouchOneMIDISourceMonitor.Event) {
        do {
            switch event {
            case .connected(let endpoint):
                guard endpoint.isXTouchOneDeviceEndpoint, let deviceID = endpoint.deviceID else {
                    throw ControlError.invalidArguments("hardware sessions require an X-Touch One input source")
                }
                guard outputDeviceID == nil || outputDeviceID == deviceID else {
                    throw ControlError.invalidArguments("input and output must belong to the same MIDI device")
                }
                try console.attach(XTouchOneRoute(inputID: String(endpoint.uniqueID),
                                                  outputID: outputID.map(String.init) ?? "not-opened",
                                                  deviceID: String(deviceID), transportOrigin: .physicalUSB), at: now)
            case .disconnected:
                try console.detach(at: now)
                withdrawHardwareOutput()
            case .input(let bytes):
                try console.receive(bytes, at: now)
            }
        } catch { eventError = error }
    }

    private func withdrawHardwareOutput() {
        guard output != nil else { return }
        output = nil
        console.withdrawDisplay()
        console.note("display authorization withdrawn after endpoint loss", at: now)
    }

    private func pump() throws {
        if output?.isCurrent == false { withdrawHardwareOutput() }
        guard !console.session.queuedDisplayTargets.isEmpty else { return }
        let monitor = monitor
        let output = output
        try console.pump(at: now) { bytes in
            guard monitor?.isCurrent == true, let output else {
                return .notAttempted(reason: "endpoint unavailable")
            }
            do {
                try output.write(bytes)
                return .accepted
            } catch {
                return .rejected(reason: String(describing: error))
            }
        }
    }

    private func reply<T: Encodable>(_ result: T, to id: String) throws {
        try write(Reply(id: id, ok: true, result: result))
    }

    private func reject(_ error: ControlError, id: String? = nil) throws {
        try write(Reply<String>(id: id, ok: false, error: .init(code: error.code, message: error.description)))
    }

    private func write<T: Encodable>(_ reply: Reply<T>) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((XTouchOneCapture.line(reply) + "\n").utf8))
    }

    private func handle(_ line: Data?) throws {
        guard let line else {
            try reject(.invalidRequest("request exceeds 8192 bytes"))
            return
        }
        let command: Command
        do { command = try JSONDecoder().decode(Command.self, from: line) }
        catch {
            try reject(.invalidRequest("expected a JSON request with string id and op"))
            return
        }
        do { try handle(command) }
        catch let error as ControlError { try reject(error, id: command.id) }
        catch let error as XTouchOneMIDIError { try reject(.invalidArguments(String(describing: error)), id: command.id) }
    }

    private func handle(_ command: Command) throws {
        try pump()
        let cursor = console.log.last?.id ?? 0
        switch command.op {
        case "status":
            let session = console.session
            try reply(Status(source: session.source.rawValue, mode: session.profile.mode.rawValue, channel: session.profile.channel,
                             generation: session.generation, connected: session.isConnected,
                             inputID: inputID, outputID: outputID, displayWrite: displayAvailable,
                             pendingDisplayTargets: session.queuedDisplayTargets, faderPosition: console.faderPosition,
                             faderTouched: console.faderTouched, pressed: console.pressed.sorted(), cursor: cursor), to: command.id)
        case "events":
            guard (0...cursor).contains(command.after) else { throw ControlError.invalidArguments("invalid event cursor") }
            let entries = console.log.filter { $0.id > command.after }.map(EventPage.Entry.init)
            try reply(EventPage(cursor: cursor, truncated: (console.log.first?.id ?? 1) - 1 > command.after, entries: entries),
                      to: command.id)
        case "display":
            guard displayAvailable else { throw ControlError.displayUnavailable }
            let request = try display(command.args, invertUpper: command.invertUpper, invertLower: command.invertLower)
            let outcome = try console.request(request, at: now)
            let state: String
            switch outcome {
            case .queued: state = "queued"
            case .alreadyAccepted: state = "alreadyAccepted"
            case .refused: throw ControlError.displayUnavailable
            }
            try pump()
            try reply(["state": state, "target": request.targetID], to: command.id)
        case "act":
            guard console.link == .mock else { throw ControlError.simulationOnly }
            try console.operate(parseAction(command.args), at: now)
            try reply(["state": "applied"], to: command.id)
        case "recall":
            guard console.link == .mock else { throw ControlError.simulationOnly }
            guard command.args.count == 1, let position = UInt8(command.args[0]), position < 128 else {
                throw ControlError.invalidArguments("recall expects a simulated target from 0 to 127")
            }
            switch try console.recallFader(to: position, at: now) {
            case .send: try reply(["state": "applied"], to: command.id)
            case .refused(let reason): throw ControlError.recallRefused(String(describing: reason))
            }
        case "quit":
            try reply(["state": "closing"], to: command.id)
            stopped = true
        default:
            throw ControlError.invalidRequest("unknown operation: \(command.op)")
        }
    }

    func run() throws {
        let stdin = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        var stream = CommandLines()
        var buffer = [UInt8](repeating: 0, count: 4096)
        stdin.setEventHandler {
            MainActor.assumeIsolated {
                guard !self.stopped, self.eventError == nil else { return }
                let size = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if size < 0 {
                    if errno != EINTR {
                        self.eventError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    return
                }
                do {
                    if size == 0 {
                        if stream.hasRemainder { try self.handle(stream.takeLine()) }
                        self.stopped = true
                    } else {
                        for byte in buffer.prefix(size) {
                            if byte == 10 { try self.handle(stream.takeLine()) } else { stream.append(byte) }
                            if self.stopped { break }
                        }
                    }
                } catch { self.eventError = error }
            }
        }
        stdin.resume()
        defer { stdin.cancel(); monitor?.stop() }
        while !stopped, eventError == nil, monitor?.connectionError == nil {
            try pump()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        if let error = eventError ?? monitor?.connectionError { throw error }
    }
}

private struct CommandLines {
    private static let maximumBytes = 8192
    private var bytes = Data()
    private var overflowed = false
    var hasRemainder: Bool { !bytes.isEmpty || overflowed }

    mutating func append(_ byte: UInt8) {
        guard !overflowed else { return }
        guard bytes.count < Self.maximumBytes else { overflowed = true; return }
        bytes.append(byte)
    }

    mutating func takeLine() -> Data? {
        defer { bytes = Data(); overflowed = false }
        return overflowed ? nil : bytes
    }
}

private func parseAction(_ args: [String]) throws -> XTouchOnePanelAction {
    switch args.first {
    case "button" where args.count == 3:
        if let address = UInt8(args[1]), address <= 34, let pressed = Bool(args[2]) {
            return .button(address, pressed: pressed)
        }
    case "foot" where args.count == 2:
        if let pressed = Bool(args[1]) { return .footSwitch(pressed: pressed) }
    case "touch" where args.count == 2:
        if let touched = Bool(args[1]) { return .touch(touched) }
    case "fader" where args.count == 2:
        if let position = UInt8(args[1]), position < 128 { return .fader(position) }
    case "encoder", "jog":
        if args.count == 2, args[1] == "cw" || args[1] == "ccw" {
            return args[0] == "encoder" ? .encoder(clockwise: args[1] == "cw") : .jog(clockwise: args[1] == "cw")
        }
    default: break
    }
    throw ControlError.invalidArguments("invalid simulated action")
}

@MainActor
func runControlSession(_ arguments: [String]) throws {
    let (options, flags, rest) = parse(arguments, options: ["--input", "--output", "--mode", "--channel", "--source"],
                                      flags: ["--write"])
    guard rest.isEmpty else { fail(usage) }
    let selection = Selection(options)
    if selection.source == .simulation {
        guard options["--input"] == nil, options["--output"] == nil, flags.isEmpty else {
            fail("a simulation session takes no MIDI endpoints or --write")
        }
        try ControlSession(selection: selection, inputID: nil, outputID: nil).run()
    } else {
        let inputID = endpointID(options, "--input")
        let outputID: Int32?
        if flags.contains("--write") {
            outputID = endpointID(options, "--output")
        } else {
            guard options["--output"] == nil else { fail("--output requires --write") }
            outputID = nil
        }
        try ControlSession(selection: selection, inputID: inputID, outputID: outputID).run()
    }
}
#endif
