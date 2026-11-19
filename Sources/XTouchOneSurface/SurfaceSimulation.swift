import Foundation
import SurfaceControlContracts
import SurfaceFeedbackPlanning
import SurfacePluginContracts
import XTouchOneAdapter
import XTouchOnePanel

/// Shared control contract over the same isolated panel model used by the app.
public struct XTouchOneSurfaceSimulation: Sendable {
    public private(set) var controls: SurfaceControlSession
    public private(set) var console: XTouchOneConsole
    private let profile: XTouchOneMIDIProfile
    private let configuration: XTouchOneConfiguration
    private static let writer = "simulation.stdio"

    public init(instanceID: String, epoch: String, profile: XTouchOneMIDIProfile,
                configuration: XTouchOneConfiguration = .standard) throws {
        self.profile = profile
        self.configuration = configuration
        let workspace = try XTouchOneWorkspace(configuration: configuration)
        console = try XTouchOneConsole(link: .mock, profile: profile, displayRate: .unlimited,
                                      outputPolicy: .write, mechanismPolicy: .disabled, demoLinks: false, workspace: workspace)
        let base = profile.hardwareControlProfile
        let descriptors = base.controls.map { descriptor in
            let binding = configuration.bindings[descriptor.id]
            let parameter: ParameterDefinition?
            if case .parameter(let id) = binding { parameter = workspace.definition(id) }
            else { parameter = nil }
            let acceptsInput = descriptor.id != "meter" && (binding == nil ||
                parameter.map { $0.agentWritable && !$0.externallyProtected } == true)
            return ControlDescriptor(id: descriptor.id, inputKind: descriptor.input_kind, encoding: descriptor.encoding,
                range: descriptor.range, feedbackRange: descriptor.feedback_range, feedbackKinds: descriptor.feedback_kinds,
                mapping: parameter.map { ControlMapping(kind: .parameter, id: $0.id.rawValue) },
                hold: descriptor.id == "fader.touch" ? .init(restValue: .bool(false), maxHoldSeconds: 10) : nil,
                acceptsInput: acceptsInput)
        }
        let publicProfile = ControlProfile(id: "xtouch.one.midi.simulation", version: "1.3", controls: descriptors,
            capabilities: base.capabilities.filter { $0 != "hardware" } + ["simulation", "input.hold"])
        controls = try SurfaceControlSession(instanceID: instanceID, epoch: epoch, profile: publicProfile)
        var seed: [String: JSONValue] = [:]
        for descriptor in descriptors where descriptor.input_kind != .relative && descriptor.accepts_input == true {
            seed[descriptor.id] = descriptor.encoding == .boolean ? .bool(false) : .number(0)
        }
        try controls.seedInputs(seed, at: 0)
    }

    public mutating func expireHolds(at time: Double) throws {
        let due = controls.dueHoldExpiries(at: time)
        guard !due.isEmpty else { return }
        var next = self
        for expiry in due {
            guard expiry.controlID == "fader.touch" else { throw ControlContractError("unsupported_hold") }
            try next.console.operate(.touch(false), at: time)
            try next.controls.recordHoldExpiry(controlID: expiry.controlID, at: time, writerID: Self.writer)
        }
        self = next
    }

    public mutating func input(_ input: ControlInput, at time: Double) throws -> ControlEvent {
        let descriptor = try controls.validateInput(input, at: time, writerID: Self.writer)
        var next = self
        let unchanged = controls.isUnchanged(input)
        let mappedBefore = try controls.snapshot(at: time).inputs[input.control_id]
        if !unchanged, descriptor.input_kind == .relative || mappedBefore != SurfaceControlSession.normalized(input.value) {
            try next.console.operate(try action(for: input), at: time)
        }
        let mapped = descriptor.mapping.flatMap { next.console.workspace.values[ParameterID(rawValue: $0.id)] }.map(JSONValue.double)
        let recorded = try next.controls.recordInput(input, disposition: unchanged ? .ignored : .accepted,
            mappedValue: unchanged ? nil : mapped, reason: unchanged ? "no_change" : nil, origin: .remote, at: time, writerID: Self.writer)
        self = next
        return recorded
    }

    private func action(for input: ControlInput) throws -> XTouchOnePanelAction {
        switch input.control_id {
        case "fader.touch": return .touch(input.value.boolValue == true)
        case "foot-switch": return .footSwitch(pressed: input.value.boolValue == true)
        case "fader": return .fader(UInt8(input.value.exactIntValue!))
        case "jog": return .jog(clockwise: input.value.exactIntValue! > 0)
        case "encoder.turn":
            let value = input.value.exactIntValue!
            return input.encoding == ControlEncoding.signedDelta.rawValue ? .encoder(clockwise: value > 0) : .encoderPosition(UInt8(value))
        default:
            if input.control_id.hasPrefix("button."), let address = UInt8(input.control_id.dropFirst(7)) {
                return .button(address, pressed: input.value.boolValue == true)
            }
            throw ControlContractError("unsupported_control")
        }
    }

    public mutating func feedback(_ feedback: ControlFeedback, at time: Double) throws -> ControlEvent {
        try controls.validateFeedback(feedback, at: time, writerID: Self.writer)
        let display: XTouchOneDisplay
        switch feedback.control_id {
        case "encoder.turn": display = .encoderRing(UInt8(feedback.value.exactIntValue!))
        case "meter": display = .meter(UInt8(feedback.value.exactIntValue!))
        default:
            guard let address = UInt8(feedback.control_id.dropFirst(7)), let button = XTouchOneButton(rawValue: address),
                  let state = ["off": XTouchOneButtonLED.off, "on": .on, "blink": .flash][feedback.value.stringValue ?? ""] else {
                throw ControlContractError("unsupported_feedback")
            }
            display = .buttonLED(button, state)
        }
        var next = self
        try next.console.request(display, at: time)
        try next.console.pump(at: time)
        let event = try next.controls.recordFeedback(feedback, origin: .remote, at: time, writerID: Self.writer)
        self = next
        return event
    }

    public mutating func renew(_ request: ControlRenew, at time: Double) throws -> ControlRenewResult {
        try controls.renew(request, at: time)
    }

    public mutating func reset(expected: ControlExpected, sequence: String, newEpoch: String) throws {
        try controls.validateExpected(expected)
        try controls.validateSequence(sequence)
        guard newEpoch != expected.epoch else { throw ControlContractError("invalid_argument") }
        self = try Self(instanceID: expected.instance_id, epoch: newEpoch, profile: profile, configuration: configuration)
    }
}
