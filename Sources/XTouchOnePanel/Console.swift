import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import XTouchOneAdapter
import XTouchOneSimulator

public enum XTouchOnePanelAction: Equatable, Sendable {
    case button(UInt8, pressed: Bool)
    case footSwitch(pressed: Bool)
    case touch(Bool)
    case fader(UInt8)
    case encoder(clockwise: Bool)
    case jog(clockwise: Bool)
}

/// The app's state behind the panel: one session, the display state to draw, and a short log.
/// It is a value with injected time. The mock link plays the device from the documentation model;
/// the hardware link only reflects what a transport delivers and accepts.
public struct XTouchOneConsole: Sendable {
    public enum Link: Equatable, Sendable { case mock, hardware }

    public struct Entry: Identifiable, Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable { case input, output, note }
        public let id: Int
        public let at: Double
        public let generation: UInt64
        public let kind: Kind
        public let bytes: [UInt8]
        public let text: String
        public let result: FeedbackAttemptResult?
    }

    public static let logLimit = 200
    /// Placeholder for hardware display traffic until the real transport budget is measured.
    public static let hardwareDisplayRate = FeedbackQueueRate.bucket(perSecond: 50, burst: 10, failureCooldown: 1)
    static let mockRoute = try! XTouchOneRoute(inputID: "mock-in", outputID: "mock-out", transportOrigin: .localVirtual)

    public let link: Link
    public private(set) var session: XTouchOneSession
    /// Mock: the model device. Hardware: the last accepted sends, which is sent evidence and not what the device shows.
    public private(set) var shown: XTouchOneSimulatedDevice
    public private(set) var pressed: Set<String> = []
    public private(set) var jogTicks = 0
    public private(set) var encoderTicks = 0
    /// The mock fader's physical position. The hardware link has no such knowledge.
    public private(set) var mockFader: UInt8 = 0
    public private(set) var log: [Entry] = []
    /// Local demonstration: keys toggle their lights, the encoder drives the ring, the fader the meter and LCD,
    /// the jog wheel the counter. Every change goes through the normal display path.
    public var demoLinks: Bool
    private var nextEntry = 0
    private var lit: Set<UInt8> = []
    private var ring = 0

    public init(link: Link, profile: XTouchOneMIDIProfile, displayRate: FeedbackQueueRate,
                outputPolicy: XTouchOneOutputPolicy, mechanismPolicy: XTouchOneMechanismPolicy,
                demoLinks: Bool = true) throws {
        self.link = link
        self.demoLinks = demoLinks
        session = try XTouchOneSession(source: link == .mock ? .simulation : .hardware, profile: profile,
                                       displayRate: displayRate, outputPolicy: outputPolicy,
                                       mechanismPolicy: mechanismPolicy)
        session.grantDisplay(to: .local)
        shown = XTouchOneSimulatedDevice(mode: profile.mode, channel: profile.channel)
        if link == .mock { try session.attach(Self.mockRoute) }
    }

    public var faderPosition: UInt8? {
        if link == .mock { return mockFader }
        guard case .number(let value)? = (try? session.observation(of: .faderPosition, at: 0))?.value else { return nil }
        return UInt8(value)
    }

    public var faderTouched: Bool? {
        guard case .flag(let value)? = (try? session.observation(of: .faderContact, at: 0))?.value else { return nil }
        return value
    }

    // MARK: Connection (hardware link)

    public mutating func attach(_ route: XTouchOneRoute, at: Double) throws {
        let change = try session.attach(route)
        if change.startedNewGeneration { resetGeneration(at: at, "connected, generation \(change.generation)") }
    }

    public mutating func detach(at: Double) throws {
        let change = try session.detach()
        if change.startedNewGeneration { resetGeneration(at: at, "disconnected") }
    }

    private mutating func resetGeneration(at: Double, _ text: String) {
        pressed.removeAll()
        lit.removeAll()
        if link == .hardware { shown = XTouchOneSimulatedDevice(mode: session.profile.mode, channel: session.profile.channel) }
        note(text, at: at)
    }

    // MARK: Input

    /// A gesture on the drawn panel. Only the mock link turns it into device bytes.
    public mutating func operate(_ action: XTouchOnePanelAction, at: Double) throws {
        guard link == .mock else { return }
        let bytes: [UInt8]
        switch action {
        case .button(let address, let isPressed): bytes = shown.setButton(address, pressed: isPressed)
        case .footSwitch(let isPressed): bytes = shown.setFootSwitch(pressed: isPressed)
        case .touch(let touched): bytes = shown.setFaderTouched(touched)
        case .fader(let position):
            mockFader = min(position, 127)
            bytes = shown.moveFader(to: mockFader)
        case .encoder(let clockwise): bytes = shown.turnEncoder(clockwise: clockwise)
        case .jog(let clockwise): bytes = shown.turnJog(clockwise: clockwise)
        }
        try receive(bytes, at: at)
    }

    /// One framed message from the device, mock or real.
    public mutating func receive(_ message: [UInt8], at: Double) throws {
        switch try session.receive(message, at: at) {
        case .ignored(let reason):
            append(.input, message, "\(reason)", at)
        case .event(let event):
            append(.input, message, "\(event.elementID) \(event.kind.rawValue) \(Self.describe(event.value))", at)
            switch (event.kind, event.value) {
            case (.press, _): pressed.insert(event.elementID)
            case (.release, _): pressed.remove(event.elementID)
            case (.relative, .number(let delta)):
                if event.elementID == "jog" { jogTicks += Int(delta) } else { encoderTicks += Int(delta) }
            case (.absolute, .number(let value)) where event.elementID == "encoder.turn": encoderTicks = Int(value)
            default: break
            }
            if demoLinks { try demonstrate(event, at: at) }
        }
    }

    private mutating func demonstrate(_ event: DeviceInputEvent, at: Double) throws {
        switch (event.elementID, event.kind, event.value) {
        case (let id, .press, _) where id.hasPrefix("button."):
            guard let address = UInt8(id.dropFirst(7)), let button = XTouchOneButton(rawValue: address) else { return }
            if lit.remove(address) == nil { lit.insert(address) }
            try request(.buttonLED(button, lit.contains(address) ? .on : .off), at: at)
        case ("encoder.turn", .absolute, .number(let value)):
            try request(.encoderRing(UInt8(value)), at: at)
        case ("encoder.turn", .relative, .number(let delta)):
            ring = min(127, max(0, ring + Int(delta) * 5))
            try request(.encoderRing(UInt8(ring)), at: at)
        case ("fader", .absolute, .number(let value)):
            try request(.meter(UInt8(value)), at: at)
            try request(.lcd(upper: "Fader", lower: String(Int(value)), color: .cyan, invertUpper: true, invertLower: false), at: at)
        case ("jog", .relative, _):
            try request(XTouchOneSegmentFont.display(assignment: "Jo", counter: String(jogTicks)), at: at)
        default: break
        }
    }

    // MARK: Output

    /// Queues a local repaint. A refusal is logged and returned.
    @discardableResult
    public mutating func request(_ display: XTouchOneDisplay, at: Double) throws -> XTouchOneRepaintOutcome {
        let outcome = try session.requestDisplay(display, origin: .local)
        if case .refused(let refusal) = outcome { note("display \(display.targetID) refused: \(refusal)", at: at) }
        return outcome
    }

    public mutating func withdrawDisplay() { session.withdrawDisplay(from: .local) }

    /// Sends what the rate allows. `write` is the transport; the mock link delivers to its model device.
    public mutating func pump(at: Double, write: (([UInt8]) -> FeedbackAttemptResult)? = nil) throws {
        for send in try session.drainDisplay(at: at) { try deliver(send, at: at, write: write) }
    }

    /// The explicit local recall. Refusals are logged and returned.
    @discardableResult
    public mutating func recallFader(to position: UInt8, at: Double,
                                     write: (([UInt8]) -> FeedbackAttemptResult)? = nil) throws -> XTouchOneRecallOutcome {
        let outcome = try session.recallFader(to: position)
        switch outcome {
        case .refused(let refusal): note("recall refused: \(refusal)", at: at)
        case .send(let send):
            if try deliver(send, at: at, write: write), link == .mock { mockFader = position }
        }
        return outcome
    }

    @discardableResult
    private mutating func deliver(_ send: XTouchOneSend, at: Double,
                                  write: (([UInt8]) -> FeedbackAttemptResult)?) throws -> Bool {
        let result: FeedbackAttemptResult
        if case .rejected(let rejection) = session.preflight(send) {
            result = .notAttempted(reason: "\(rejection)")
        } else if link == .mock {
            result = .accepted
        } else {
            result = write?(send.bytes) ?? .notAttempted(reason: "no transport")
        }
        _ = try session.complete(send, result: result, at: at)
        if result.successfulSend { shown.receive(send.bytes) }
        append(.output, send.bytes, "\(send.targetID) \(result)", at, result: result)
        return result.successfulSend
    }

    public mutating func note(_ text: String, at: Double) { append(.note, [], text, at) }

    private mutating func append(_ kind: Entry.Kind, _ bytes: [UInt8], _ text: String, _ at: Double,
                                 result: FeedbackAttemptResult? = nil) {
        nextEntry += 1
        log.append(Entry(id: nextEntry, at: at, generation: session.generation, kind: kind, bytes: bytes, text: text, result: result))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private static func describe(_ value: DeviceValue) -> String {
        switch value {
        case .number(let number): String(Int(number))
        case .flag(let flag): String(flag)
        case .text(let text): text
        case .none: ""
        }
    }
}
