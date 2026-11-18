import SurfaceDeviceContracts
import Testing
import XTouchOneAdapter

struct MIDIInputTests {
    @Test(arguments: [
        (XTouchOneMIDIMode.midi, UInt8(0x90), InputKind.absolute),
        (.midiRelative, 0x90, .relative),
        (.controlChange, 0xB0, .absolute),
        (.controlChangeRelative, 0xB0, .relative),
    ])
    func fixedMode(_ mode: XTouchOneMIDIMode, buttonStatus: UInt8, encoderKind: InputKind) throws {
        let profile = try XTouchOneMIDIProfile(mode: mode, channel: 1)
        for address in UInt8(0)...34 {
            let down = try #require(try input(profile, [buttonStatus, address, 127]))
            let up = try #require(try input(profile, [buttonStatus, address, 0]))
            #expect(down.elementID == "button.\(address)")
            #expect(down.elementID == up.elementID)
            #expect(down.kind == .press && down.value == .flag(true))
            #expect(up.kind == .release && up.value == .flag(false))
        }
        #expect(try input(profile, [buttonStatus ^ 0x20, 34, 127]) == nil)
        #expect(try input(profile, [buttonStatus, 35, 127]) == nil)
        let clockwise = try #require(try input(profile, [0xB0, 80, 65]))
        let counterclockwise = try #require(try input(profile, [0xB0, 80, 1]))
        #expect(clockwise.elementID == "encoder.turn" && clockwise.kind == encoderKind)
        #expect(clockwise.value == .number(encoderKind == .absolute ? 65 : 1))
        #expect(counterclockwise.value == .number(encoderKind == .absolute ? 1 : -1))
    }

    @Test func faderTravelAndContactAreIndependent() throws {
        let profile = try XTouchOneMIDIProfile(mode: .controlChangeRelative, channel: 16)
        let low = try #require(try input(profile, [0xBF, 70, 0]))
        let high = try #require(try input(profile, [0xBF, 70, 127]))
        let touched = try #require(try input(profile, [0x9F, 110, 127]))
        let released = try #require(try input(profile, [0x9F, 110, 0]))
        #expect([low, high, touched, released].map(\.elementID) == Array(repeating: "fader", count: 4))
        #expect(low.kind == .absolute && low.value == .number(0))
        #expect(high.kind == .absolute && high.value == .number(127))
        #expect(touched.kind == .contactBegan && touched.value == .flag(true))
        #expect(released.kind == .contactEnded && released.value == .flag(false))
    }

    @Test func jogAndFootSwitchUseTheirOwnRoles() throws {
        let profile = try XTouchOneMIDIProfile(mode: .midi, channel: 1)
        let right = try #require(try input(profile, [0xB0, 88, 65]))
        let left = try #require(try input(profile, [0xB0, 88, 1]))
        let down = try #require(try input(profile, [0xB0, 64, 127]))
        let up = try #require(try input(profile, [0xB0, 64, 0]))
        #expect(right.elementID == "jog" && right.kind == .relative && right.value == .number(1))
        #expect(left.elementID == "jog" && left.kind == .relative && left.value == .number(-1))
        #expect(down.elementID == "foot-switch" && down.kind == .press && down.value == .flag(true))
        #expect(up.elementID == "foot-switch" && up.kind == .release && up.value == .flag(false))
    }

    @Test func malformedAndUndocumentedMessagesAreIgnored() throws {
        let profile = try XTouchOneMIDIProfile(mode: .midiRelative, channel: 1)
        let messages: [[UInt8]] = [
            [], [0x90, 0], [0x90, 0, 127, 0], [0, 0, 127], [0x90, 0x80, 0], [0x90, 0, 0x80],
            [0x91, 0, 127], [0x80, 0, 0], [0x90, 0, 64], [0x90, 110, 1], [0xB0, 64, 1],
            [0xB0, 80, 0], [0xB0, 80, 66], [0xB0, 88, 2], [0xB0, 90, 127], [0xE0, 0, 64], [0xF0, 0, 0],
        ]
        for message in messages {
            #expect(try input(profile, message) == nil, "Unexpected input for \(message)")
        }
        #expect(throws: XTouchOneMIDIError.invalidChannel) { try XTouchOneMIDIProfile(mode: .midi, channel: 0) }
        #expect(throws: XTouchOneMIDIError.invalidChannel) { try XTouchOneMIDIProfile(mode: .midi, channel: 17) }
    }

    @Test func inputCarriesOnlySimulatedProvenance() throws {
        let profile = try XTouchOneMIDIProfile(mode: .controlChange, channel: 5)
        let event = try #require(try profile.decodeSimulatedInput([0xB4, 70, 21], generation: 42, at: 12.5,
                                                                  mappingRevision: "fixture-1"))
        #expect(event.source == .simulation && event.at == 12.5)
        #expect(event.context.id == "xtouch-one.CChg.ch5" && event.context.generation == "42")
        #expect(event.context.mappingRevision == "fixture-1")
        #expect(event.endpoint.endpointID == nil && event.endpoint.deviceID == nil)
        #expect(event.endpoint.connectionGeneration == 42 && event.endpoint.transportOrigin == .unknown)
        #expect(throws: DeviceContractError.nonFiniteValue) {
            try profile.decodeSimulatedInput([0xB4, 70, 21], generation: 42, at: .infinity)
        }
    }

    private func input(_ profile: XTouchOneMIDIProfile, _ bytes: [UInt8]) throws -> DeviceInputEvent? {
        try profile.decodeSimulatedInput(bytes, generation: 1, at: 0)
    }
}
