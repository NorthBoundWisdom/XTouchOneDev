import SurfaceControlContracts
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import SurfacePluginContracts
import XTouchOneAdapter

extension XTouchOneMIDIProfile {
    /// The hardware-source control profile of one selected mode. Every control refuses remote input.
    /// The fader declares no feedback, and the LCD and segment display have no contract control,
    /// so a remote request can address button lights, the encoder ring and the meter only.
    public var hardwareControlProfile: ControlProfile {
        let span = ControlValueRange(minimum: 0, maximum: 127, step: 1)
        let detent = ControlValueRange(minimum: -1, maximum: 1, step: 1)
        let relative = mode == .midiRelative || mode == .controlChangeRelative
        func button(_ id: String, _ feedback: [ControlFeedbackKind] = []) -> ControlDescriptor {
            .init(id: id, inputKind: .button, encoding: .boolean, feedbackKinds: feedback, acceptsInput: false)
        }
        var controls = (0...34).map { button("button.\($0)", [.indicator]) }
        controls += [
            button("foot-switch"), button("fader.touch"),
            .init(id: "fader", inputKind: .absolute, encoding: .scalar, range: span, acceptsInput: false),
            relative
                ? .init(id: "encoder.turn", inputKind: .relative, encoding: .signedDelta, range: detent,
                        feedbackRange: span, feedbackKinds: [.value], acceptsInput: false)
                : .init(id: "encoder.turn", inputKind: .absolute, encoding: .scalar, range: span,
                        feedbackKinds: [.value], acceptsInput: false),
            .init(id: "jog", inputKind: .relative, encoding: .signedDelta, range: detent, acceptsInput: false),
            // Display only: the device never reports a meter value.
            .init(id: "meter", inputKind: .absolute, encoding: .scalar, range: span, feedbackKinds: [.value],
                  acceptsInput: false),
        ]
        return .init(id: "xtouch.one.midi.hardware", version: "1.4", controls: controls, capabilities: [
            "hardware", "controls.stable_ids", "controls.input_declared", "input.absolute", "input.relative",
            "input.button", "feedback.value", "feedback.indicator", "feedback.unsequenced",
            "input.independent_sequence", "events.writer_id", "x.xtouch-one.\(mode.rawValue).ch\(channel)",
        ])
    }
}

/// Joins one device session to one hardware-source control session.
/// Input comes only from device messages. Lifecycle and input produce no output, and this type has no
/// way to request the fader motor, a mode change or raw MIDI.
public struct XTouchOneHardwareSurface: Sendable {
    public private(set) var controls: SurfaceControlSession
    public private(set) var device: XTouchOneSession
    public private(set) var unrecognizedCount = 0
    public let hardwareWriterID: String
    public let remoteWriterID: String

    public init(instanceID: String, epoch: String, profile: XTouchOneMIDIProfile, displayRate: FeedbackQueueRate,
                outputPolicy: XTouchOneOutputPolicy = .observe, hardwareWriterID: String, remoteWriterID: String,
                eventCapacity: Int = 1024) throws {
        guard hardwareWriterID != remoteWriterID else { throw ControlContractError("invalid_argument") }
        controls = try SurfaceControlSession(instanceID: instanceID, epoch: epoch, profile: profile.hardwareControlProfile,
                                             eventCapacity: eventCapacity)
        try controls.validateWriterID(hardwareWriterID)
        try controls.validateWriterID(remoteWriterID)
        device = try XTouchOneSession(source: .hardware, profile: profile, displayRate: displayRate,
                                      outputPolicy: outputPolicy)
        self.hardwareWriterID = hardwareWriterID
        self.remoteWriterID = remoteWriterID
    }

    /// Connect to `route`, or disconnect with nil. Every call starts a new device generation and needs a fresh epoch.
    public mutating func transition(epoch: String, route: XTouchOneRoute?, at time: Double) throws {
        var next = self
        if next.device.isConnected { try next.device.detach() }
        if let route { try next.device.attach(route) }
        try next.controls.transitionHardware(epoch: epoch, linkState: route == nil ? .disconnected : .connected, at: time)
        self = next
    }

    /// Records the mode and channel the operator set on the device. The control profile follows the mode.
    public mutating func selectProfile(_ profile: XTouchOneMIDIProfile, epoch: String, at time: Double) throws {
        var next = self
        try next.controls.transitionHardware(epoch: epoch, linkState: device.isConnected ? .connected : .disconnected,
                                             profile: profile.hardwareControlProfile, at: time)
        try next.device.selectProfile(profile)
        self = next
    }

    /// One framed device message becomes at most one hardware input event.
    @discardableResult
    public mutating func receive(_ message: [UInt8], at time: Double) throws -> ControlEvent? {
        var next = self
        let event: DeviceInputEvent
        switch try next.device.receive(message, at: time) {
        case .event(let decoded): event = decoded
        case .ignored(.unrecognized): unrecognizedCount += 1; return nil
        case .ignored(.disconnected): return nil
        }
        let id: String, encoding: ControlEncoding, value: JSONValue
        switch (event.kind, event.value) {
        case (.press, .flag(let flag)), (.release, .flag(let flag)): (id, encoding, value) = (event.elementID, .boolean, .bool(flag))
        case (.contactBegan, .flag(let flag)), (.contactEnded, .flag(let flag)): (id, encoding, value) = ("fader.touch", .boolean, .bool(flag))
        case (.absolute, .number(let number)): (id, encoding, value) = (event.elementID, .scalar, .number(Int(number)))
        case (.relative, .number(let number)): (id, encoding, value) = (event.elementID, .signedDelta, .number(Int(number)))
        default: throw ControlContractError("invalid_value")
        }
        let input = ControlHardwareInput(expected: controls.expected, controlID: id, encoding: encoding.rawValue, value: value)
        let recorded = try next.controls.recordHardwareInput(input, disposition: .accepted, at: time, writerID: hardwareWriterID)
        self = next
        return recorded
    }

    /// Validates one remote display request and issues its send. Nothing is recorded yet:
    /// the caller runs `preflight`, writes, then calls `completeDisplay` with the real outcome.
    public mutating func issueDisplay(_ update: ControlFeedback, allowed: Bool, at time: Double,
                                      writerID: String? = nil) throws -> XTouchOneSend {
        let writer = writerID ?? remoteWriterID
        try controls.validateFeedback(update, at: time, writerID: writer)
        let origin = XTouchOneOrigin.remote(client: writer)
        guard allowed else {
            device.withdrawDisplay(from: origin)
            throw ControlContractError("permission_denied")
        }
        let display: XTouchOneDisplay
        if update.kind == ControlFeedbackKind.indicator.rawValue {
            let states: [String: XTouchOneButtonLED] = ["off": .off, "on": .on, "blink": .flash]
            guard let button = update.control_id.split(separator: ".").last.flatMap({ UInt8($0) }).flatMap(XTouchOneButton.init),
                  button.elementID == update.control_id, let state = update.value.stringValue.flatMap({ states[$0] }) else {
                throw ControlContractError("unsupported_feedback")
            }
            display = .buttonLED(button, state)
        } else {
            guard let number = update.value.exactIntValue, (0...127).contains(number) else { throw ControlContractError("invalid_value") }
            switch update.control_id {
            case "encoder.turn": display = .encoderRing(UInt8(number))
            case "meter": display = .meter(UInt8(number))
            default: throw ControlContractError("unsupported_feedback")
            }
        }
        var next = device
        next.grantDisplay(to: origin)
        switch try next.writeDisplay(display, origin: origin) {
        case .send(let send):
            device = next
            return send
        case .refused(.notConnected): throw ControlContractError("invalid_transition")
        case .refused: throw ControlContractError("permission_denied")
        }
    }

    public func preflight(_ send: XTouchOneSend) -> FeedbackPreflight { device.preflight(send) }

    /// Commits the feedback event only when the transport accepted the send in the generation that issued it.
    /// Any other outcome records nothing and throws `invalid_transition`.
    @discardableResult
    public mutating func completeDisplay(_ send: XTouchOneSend, for update: ControlFeedback, result: FeedbackAttemptResult,
                                         at time: Double, writerID: String? = nil) throws -> ControlEvent {
        var next = self
        guard try next.device.complete(send, result: result, at: time).creditedToCurrentScope else {
            device = next.device
            throw ControlContractError("invalid_transition")
        }
        let event = try next.controls.recordFeedback(update, origin: .remote, at: time, writerID: writerID ?? remoteWriterID)
        self = next
        return event
    }
}
