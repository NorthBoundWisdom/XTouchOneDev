import SurfaceControlContracts
import SurfaceFeedbackPlanning
import SurfacePluginContracts
import Testing
import XTouchOneAdapter
import XTouchOneSimulator
import XTouchOneSurface

private let route = try! XTouchOneRoute(inputID: "in", outputID: "out", deviceID: "one", transportOrigin: .physicalUSB)

private func makeSurface(_ mode: XTouchOneMIDIMode = .midi, policy: XTouchOneOutputPolicy = .write,
                         connected: Bool = true) throws -> XTouchOneHardwareSurface {
    var surface = try XTouchOneHardwareSurface(instanceID: "one.test", epoch: "e0",
                                               profile: XTouchOneMIDIProfile(mode: mode, channel: 1),
                                               displayRate: .unlimited, outputPolicy: policy,
                                               hardwareWriterID: "hardware", remoteWriterID: "remote")
    if connected { try surface.transition(epoch: "e1", route: route, at: 1) }
    return surface
}

private func feedback(_ surface: XTouchOneHardwareSurface, _ control: String, _ kind: String, _ value: JSONValue) -> ControlFeedback {
    ControlFeedback(expected: surface.controls.expected, controlID: control, kind: kind, value: value)
}

struct HardwareSurfaceTests {
    @Test(arguments: XTouchOneMIDIMode.allCases)
    func theProfileIsAValidHardwareProfileThatRefusesRemoteInput(_ mode: XTouchOneMIDIMode) throws {
        let profile = try XTouchOneMIDIProfile(mode: mode, channel: 7).hardwareControlProfile
        try profile.validate()
        #expect(profile.controls.count == 41 && profile.controls.allSatisfy { $0.accepts_input == false && $0.hold == nil })
        #expect(profile.capabilities.contains("x.xtouch-one.\(mode.rawValue).ch7") && !profile.capabilities.contains("simulation"))
        let withFeedback = profile.controls.filter { !$0.feedback_kinds.isEmpty }.map(\.id)
        #expect(withFeedback == (0...34).map { "button.\($0)" } + ["encoder.turn", "meter"])
        let relative = mode == .midiRelative || mode == .controlChangeRelative
        #expect(profile.controls.first { $0.id == "encoder.turn" }?.input_kind == (relative ? .relative : .absolute))

        let surface = try makeSurface(mode)
        let discovery = surface.controls.discovery()
        #expect(discovery.source == .hardware && discovery.contract_version == "1.4")
        let input = ControlInput(expected: surface.controls.expected, expectedInputSequence: "0", controlID: "button.0",
                                 encoding: "boolean", value: .bool(true))
        #expect(throws: ControlContractError("permission_denied")) { try surface.controls.validateInput(input) }
    }

    @Test(arguments: XTouchOneMIDIMode.allCases)
    func everyOperatorActionBecomesOneHardwareEvent(_ mode: XTouchOneMIDIMode) throws {
        var surface = try makeSurface(mode)
        var device = XTouchOneSimulatedDevice(mode: mode, channel: 1)
        var events: [ControlEvent] = []
        func feed(_ bytes: [UInt8]) throws { if let event = try surface.receive(bytes, at: 2) { events.append(event) } }
        for address in UInt8(0)...34 {
            try feed(device.setButton(address, pressed: true))
            try feed(device.setButton(address, pressed: false))
        }
        try feed(device.setFootSwitch(pressed: true))
        try feed(device.setFaderTouched(true))
        try feed(device.moveFader(to: 99))
        try feed(device.turnJog(clockwise: false))
        try feed(device.turnEncoder(clockwise: true))
        try feed([0xE0, 0, 0])

        #expect(events.count == 75 && surface.unrecognizedCount == 1)
        #expect(events.allSatisfy { $0.origin == .hardware && $0.source == .hardware && $0.writer_id == "hardware"
            && $0.disposition == .accepted && $0.expected.epoch == "e1" })
        #expect(events.map(\.input_sequence) == (1...75).map { String($0) })
        let relative = mode == .midiRelative || mode == .controlChangeRelative
        #expect(events.suffix(5).map(\.control_id) == ["foot-switch", "fader.touch", "fader", "jog", "encoder.turn"])
        #expect(events.suffix(5).map(\.value) == [.bool(true), .bool(true), .number(99), .number(-1), .number(1)])
        #expect(events.last?.encoding == (relative ? "signedDelta" : "scalar"))
        let snapshot = try surface.controls.snapshot(at: 3)
        #expect(snapshot.inputs["fader"] == .number(99) && snapshot.inputs["button.34"] == .bool(false))
        #expect(snapshot.link?.state == .connected && snapshot.feedback.isEmpty)
    }

    @Test func lifecycleChangesEpochClearsObservationsAndSendsNothing() throws {
        var surface = try makeSurface(connected: false)
        #expect(try surface.receive([0x90, 0, 127], at: 1) == nil && surface.controls.link?.state == .disconnected)
        try surface.transition(epoch: "e1", route: route, at: 1)
        _ = try surface.receive([0xB0, 70, 5], at: 2)
        let old = surface.controls.expected
        #expect(throws: ControlContractError("invalid_transition")) { try surface.transition(epoch: "e1", route: nil, at: 3) }
        #expect(surface.device.isConnected, "a refused transition changes nothing")

        try surface.transition(epoch: "e2", route: nil, at: 3)
        #expect(try surface.controls.snapshot(at: 3).inputs.isEmpty && surface.controls.link?.state == .disconnected)
        #expect(throws: ControlContractError("stale_epoch")) { try surface.controls.validateExpected(old) }
        try surface.transition(epoch: "e3", route: route, at: 4)
        #expect(surface.device.generation == 3 && surface.device.queuedDisplayTargets.isEmpty)

        let before = surface.controls.expected.mapping_revision
        try surface.selectProfile(XTouchOneMIDIProfile(mode: .midiRelative, channel: 1), epoch: "e4", at: 5)
        #expect(surface.controls.expected.mapping_revision != before && surface.device.generation == 4)
        #expect(surface.controls.link?.state == .connected)
        #expect(try surface.receive([0xB0, 80, 1], at: 6)?.value == .number(-1))
    }

    @Test func remoteDisplayIsRecordedOnlyAfterTheTransportAcceptedIt() throws {
        var surface = try makeSurface()
        var device = XTouchOneSimulatedDevice(mode: .midi, channel: 1)
        let requests = [feedback(surface, "button.3", "indicator", .string("blink")),
                        feedback(surface, "encoder.turn", "value", .number(64)),
                        feedback(surface, "meter", "value", .double(12))]
        for request in requests {
            let send = try surface.issueDisplay(request, allowed: true, at: 2)
            #expect(surface.preflight(send) == .permitted)
            device.receive(send.bytes)
            let event = try surface.completeDisplay(send, for: request, result: .accepted, at: 2)
            #expect(event.kind == .feedback && event.origin == .remote && event.writer_id == "remote")
        }
        #expect(device.buttonLEDs == [3: .flash] && device.encoderRing == 64 && device.meter == 12)
        #expect(device.faderTargets.isEmpty && device.ignored.isEmpty)
        #expect(try surface.controls.snapshot(at: 3).feedback == ["button.3": ["indicator": .string("blink")],
                                                                   "encoder.turn": ["value": .number(64)],
                                                                   "meter": ["value": .number(12)]])

        let failing = feedback(surface, "meter", "value", .number(1))
        let send = try surface.issueDisplay(failing, allowed: true, at: 4)
        #expect(throws: ControlContractError("invalid_transition")) {
            try surface.completeDisplay(send, for: failing, result: .rejected(reason: "transport"), at: 4)
        }
        #expect(surface.controls.discovery().latest_sequence == "3", "a failed write records no feedback")
    }

    @Test func remoteDisplayIsRefusedOutsideItsVocabularyPolicyAndLifecycle() throws {
        var surface = try makeSurface()
        let cases: [(String, String, JSONValue, String)] = [
            ("fader", "value", .number(64), "unsupported_feedback"),
            ("fader.touch", "indicator", .string("on"), "unsupported_feedback"),
            ("jog", "value", .number(1), "unsupported_feedback"),
            ("lcd", "value", .number(1), "unsupported_control"),
            ("button.35", "indicator", .string("on"), "unsupported_control"),
            ("button.1", "indicator", .string("dim"), "invalid_value"),
            ("button.1", "value", .bool(true), "unsupported_feedback"),
            ("meter", "value", .number(128), "invalid_value"),
            ("meter", "value", .double(1.5), "invalid_value"),
        ]
        for (control, kind, value, code) in cases {
            #expect(throws: ControlContractError(code), "\(control) \(kind)") {
                try surface.issueDisplay(feedback(surface, control, kind, value), allowed: true, at: 2)
            }
        }
        let request = feedback(surface, "button.1", "indicator", .string("on"))
        #expect(throws: ControlContractError("permission_denied")) { try surface.issueDisplay(request, allowed: false, at: 2) }

        let issued = try surface.issueDisplay(request, allowed: true, at: 2)
        #expect(throws: ControlContractError("permission_denied")) { try surface.issueDisplay(request, allowed: false, at: 2) }
        #expect(surface.preflight(issued) == .rejected(.authorizationDenied(reason: "display-not-granted")))

        let pending = try surface.issueDisplay(request, allowed: true, at: 2)
        try surface.transition(epoch: "e2", route: route, at: 3)
        #expect(surface.preflight(pending) == .rejected(.staleScope))
        #expect(throws: ControlContractError("invalid_transition")) {
            try surface.completeDisplay(pending, for: request, result: .accepted, at: 3)
        }
        #expect(throws: ControlContractError("stale_epoch")) { try surface.issueDisplay(request, allowed: true, at: 3) }
        #expect(surface.controls.discovery().latest_sequence == "0")

        var observing = try makeSurface(policy: .observe)
        #expect(throws: ControlContractError("permission_denied")) {
            try observing.issueDisplay(feedback(observing, "meter", "value", .number(1)), allowed: true, at: 2)
        }
        var offline = try makeSurface(connected: false)
        #expect(throws: ControlContractError("invalid_transition")) {
            try offline.issueDisplay(feedback(offline, "meter", "value", .number(1)), allowed: true, at: 2)
        }
        #expect(throws: ControlContractError("invalid_argument")) {
            try XTouchOneHardwareSurface(instanceID: "one", epoch: "e", profile: XTouchOneMIDIProfile(mode: .midi, channel: 1),
                                         displayRate: .unlimited, hardwareWriterID: "same", remoteWriterID: "same")
        }
    }
}
