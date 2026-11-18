import Testing
import XTouchOneAdapter

struct FramingAndCoverageTests {
    @Test func framerSplitsRunningStatusRealTimeAndSystemExclusive() {
        var framer = XTouchOneMIDIFramer()
        #expect(framer.feed([0xB0, 70, 1, 70, 0xF8, 2, 0x90, 110]) == [[0xB0, 70, 1], [0xB0, 70, 2]])
        #expect(framer.feed([127, 0xF0, 0, 0x20, 0xFE, 0x32]) == [[0x90, 110, 127]])
        #expect(framer.feed([0xF7, 5, 0xC0, 9, 0xB0, 80, 65]) == [[0xF0, 0, 0x20, 0x32, 0xF7], [0xC0, 9], [0xB0, 80, 65]])
        #expect(framer.discardedByteCount == 1)
    }

    @Test func framerCountsWhatItCannotAttribute() {
        var framer = XTouchOneMIDIFramer()
        #expect(framer.feed([1, 2, 0xF7, 0xB0, 70, 0x90, 0, 127, 0xF2, 1, 2, 3]) == [[0x90, 0, 127]])
        #expect(framer.discardedByteCount == 9)
        let oversized = [0xF0] + [UInt8](repeating: 1, count: XTouchOneMIDIFramer.maximumSystemExclusiveLength) + [0xF7]
        #expect(framer.feed(oversized).isEmpty)
        #expect(framer.discardedByteCount == 9 + oversized.count)
        #expect(framer.feed([0xB0, 70]).isEmpty)
        framer.reset()
        #expect(framer.feed([3, 0xB0, 70, 3]) == [[0xB0, 70, 3]] && framer.discardedByteCount == 1)
    }

    @Test(arguments: XTouchOneMIDIMode.allCases)
    func coverageIsCompleteOnlyAfterEveryDocumentedInput(_ mode: XTouchOneMIDIMode) throws {
        let profile = try XTouchOneMIDIProfile(mode: mode, channel: 3)
        var coverage = XTouchOneInputCoverage(profile: profile)
        #expect(coverage.missing == coverage.required && coverage.required.count == 80)
        let button: UInt8 = mode == .midi || mode == .midiRelative ? 0x92 : 0xB2
        for address in UInt8(0)...34 {
            coverage.record([button, address, 127])
            coverage.record([button, address, 0])
        }
        for message: [UInt8] in [[0xB2, 64, 127], [0xB2, 64, 0], [0x92, 110, 127], [0x92, 110, 0],
                                 [0xB2, 70, 0], [0xB2, 70, 64], [0xB2, 88, 65], [0xB2, 88, 1], [0xB2, 80, 65]] {
            coverage.record(message)
        }
        let relative = mode == .midiRelative || mode == .controlChangeRelative
        #expect(coverage.missing == ["fader:max"] + (relative ? ["encoder.turn:-1"]
            : ["encoder.turn:increase", "encoder.turn:decrease"]))
        for message: [UInt8] in [[0xB2, 70, 127], [0xB2, 80, 66], [0xB2, 80, 1], [0xB2, 80, 65]] {
            coverage.record(message)
        }
        #expect(coverage.missing.isEmpty)
    }

    @Test func coverageKeepsEvidenceOfUndocumentedTraffic() throws {
        var coverage = XTouchOneInputCoverage(profile: try XTouchOneMIDIProfile(mode: .midi, channel: 1))
        for message: [UInt8] in [[0x95, 0, 127], [0x95, 0, 127], [0xBF, 70, 1], [0xE0, 0, 64], [0xF0, 0xF7], []] {
            coverage.record(message)
        }
        #expect(coverage.otherChannels == [6, 16] && coverage.unrecognizedCount == 6)
        #expect(coverage.unrecognized == [[0x95, 0, 127], [0xBF, 70, 1], [0xE0, 0, 64], [0xF0, 0xF7], []])
        #expect(coverage.seen.isEmpty)
        for value in 0..<200 { coverage.record([0xE0, UInt8(value % 128), UInt8(value / 128)]) }
        #expect(coverage.unrecognized.count == XTouchOneInputCoverage.unrecognizedLimit)
        #expect(coverage.unrecognizedCount == 206)
    }
}
