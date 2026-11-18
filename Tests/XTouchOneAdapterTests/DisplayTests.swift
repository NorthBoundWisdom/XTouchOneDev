import SurfaceDeviceContracts
import Testing
import XTouchOneAdapter

struct DisplayTests {
    @Test func channelMessagesUseDocumentedDisplayAddresses() throws {
        let note = try XTouchOneMIDIProfile(mode: .midiRelative, channel: 1)
        let cc = try XTouchOneMIDIProfile(mode: .controlChange, channel: 16)
        let first = try #require(XTouchOneButton(rawValue: 0))
        let last = try #require(XTouchOneButton(rawValue: 34))
        #expect(XTouchOneButton(rawValue: 35) == nil)
        #expect(try note.encodeDisplay(.buttonLED(first, .off)) == [0x90, 0, 0])
        #expect(try note.encodeDisplay(.buttonLED(last, .flash)) == [0x90, 34, 64])
        #expect(try cc.encodeDisplay(.buttonLED(last, .on)) == [0xBF, 34, 127])
        #expect(try cc.encodeDisplay(.encoderRing(127)) == [0xBF, 80, 127])
        #expect(try note.encodeDisplay(.meter(0)) == [0xB0, 90, 0])
        for invalid in [XTouchOneDisplay.encoderRing(128), .meter(255)] {
            #expect(throws: XTouchOneMIDIError.invalidDataByte) { try cc.encodeDisplay(invalid) }
        }
    }

    @Test func lcdKeepsEachLineSevenBytesAndPlacesFlagsInOneByte() throws {
        let profile = try XTouchOneMIDIProfile(mode: .midi, channel: 1)
        let display = XTouchOneDisplay.lcd(upper: "One", lower: "abcdefg", color: .cyan,
                                         invertUpper: true, invertLower: true)
        #expect(try profile.encodeDisplay(display) == [0xF0, 0, 0x20, 0x32, 0x41, 0x4C, 0, 0x36,
                                                       79, 110, 101, 32, 32, 32, 32,
                                                       97, 98, 99, 100, 101, 102, 103, 0xF7])
        for invalid in ["Too long", "一", "a\n", "\u{7F}"] {
            #expect(throws: XTouchOneMIDIError.invalidLCDLine) {
                try profile.encodeDisplay(.lcd(upper: "", lower: invalid, color: .black,
                                               invertUpper: false, invertLower: false))
            }
        }
    }

    @Test func segmentDisplayKeepsMasksAndDotOrder() throws {
        let profile = try XTouchOneMIDIProfile(mode: .controlChangeRelative, channel: 7)
        let masks: [UInt8] = [1, 2, 4, 8, 16, 32, 64, 127, 0, 3, 5, 9]
        let display = try profile.encodeDisplay(.segmentDisplay(segments: masks, dotsLow: 0x7F, dotsHigh: 0x1F))
        #expect(display == [0xF0, 0, 0x20, 0x32, 0x41, 0x37, 1, 2, 4, 8, 16,
                            32, 64, 127, 0, 3, 5, 9, 0x7F, 0x1F, 0xF7])
        for invalid in [
            XTouchOneDisplay.segmentDisplay(segments: [], dotsLow: 0, dotsHigh: 0),
            .segmentDisplay(segments: Array(repeating: 128, count: 12), dotsLow: 0, dotsHigh: 0),
            .segmentDisplay(segments: masks, dotsLow: 128, dotsHigh: 0),
            .segmentDisplay(segments: masks, dotsLow: 0, dotsHigh: 32),
        ] {
            #expect(throws: XTouchOneMIDIError.invalidSegmentDisplay) { try profile.encodeDisplay(invalid) }
        }
    }

    @Test func publishedCapabilitiesMatchTheOfflineBoundary() throws {
        let caps = try XTouchOneMIDIProfile.capabilities()
        #expect(caps.profileID == "xtouch-one")
        #expect(caps.modes.map(\.id) == ["Midi", "MidiRel", "CChg", "CChgRel"])
        for mode in caps.modes {
            let elements = Dictionary(uniqueKeysWithValues: mode.elements.map { ($0.elementID, $0) })
            #expect(elements.count == 42)
            #expect(elements["fader"]?.inputs.map(\.kind) == [.absolute, .contactBegan, .contactEnded])
            #expect(elements["fader"]?.effects.isEmpty == true)
            let encoderKind = try #require(elements["encoder.turn"]?.inputs.first?.kind)
            #expect(encoderKind == (mode.id.hasSuffix("Rel") ? .relative : .absolute))
            let outputIDs = Set(mode.elements.filter { !$0.effects.isEmpty }.map(\.elementID))
            #expect(outputIDs == Set((0...34).map { "button.\($0)" } + ["encoder.turn", "meter", "lcd", "segment-display"]))
            #expect(mode.elements.flatMap(\.effects).allSatisfy { $0.requiredDirections == [.display] })
        }
    }
}
