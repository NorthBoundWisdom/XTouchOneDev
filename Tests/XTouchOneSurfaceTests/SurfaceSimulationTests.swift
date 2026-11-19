import SurfaceControlContracts
import Testing
import XTouchOneAdapter
import XTouchOneSurface

struct SurfaceSimulationTests {
    @Test func sharedInputUsesTheMockAndKeepsFeedbackIndependent() throws {
        let profile = try XTouchOneMIDIProfile(mode: .midi, channel: 1)
        var surface = try XTouchOneSurfaceSimulation(instanceID: "one", epoch: "initial", profile: profile)
        let expected = surface.controls.expected
        let input = ControlInput(expected: expected, expectedSequence: "0", controlID: "encoder.turn",
                                 encoding: "scalar", value: .number(94))
        let event = try surface.input(input, at: 1)
        #expect(event.source.rawValue == "simulation" && event.mapped_value?.finiteNumber == 94)
        #expect(surface.console.encoderTicks == 94)
        let display = ControlFeedback(expected: expected, controlID: "encoder.turn", kind: "value", value: .number(7))
        _ = try surface.feedback(display, at: 2)
        #expect(surface.console.shown.encoderRing == 7 && surface.console.encoderTicks == 94)
        #expect(try surface.controls.snapshot(at: 2).inputs["encoder.turn"] == .number(94))
        #expect(surface.console.shown.faderTargets.isEmpty)
    }

    @Test func holdsExpireInTheSameMockPathAndResetInvalidatesIdentity() throws {
        let profile = try XTouchOneMIDIProfile(mode: .controlChangeRelative, channel: 9)
        var surface = try XTouchOneSurfaceSimulation(instanceID: "one", epoch: "initial", profile: profile)
        let old = surface.controls.expected
        let press = ControlInput(expected: old, expectedSequence: "0", controlID: "fader.touch",
                                 encoding: "boolean", value: .bool(true), holdSeconds: 0.5)
        _ = try surface.input(press, at: 1)
        #expect(surface.console.faderTouched == true)
        try surface.expireHolds(at: 1.5)
        #expect(surface.console.faderTouched == false)
        #expect(try surface.controls.snapshot(at: 2).inputs["fader.touch"] == .bool(false))
        try surface.reset(expected: old, sequence: "2", newEpoch: "new")
        #expect(surface.controls.expected.epoch == "new")
        #expect(throws: ControlContractError("stale_epoch")) { try surface.input(press, at: 3) }
    }
}
