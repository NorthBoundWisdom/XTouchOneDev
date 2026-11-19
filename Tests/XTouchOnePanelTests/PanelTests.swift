import SurfaceFeedbackPlanning
import Testing
import XTouchOneAdapter
import XTouchOnePanel

private func console(_ link: XTouchOneConsole.Link = .mock, mode: XTouchOneMIDIMode = .midi,
                     output: XTouchOneOutputPolicy = .write, mechanism: XTouchOneMechanismPolicy = .localRecall,
                     demo: Bool = true) throws -> XTouchOneConsole {
    try XTouchOneConsole(link: link, profile: XTouchOneMIDIProfile(mode: mode, channel: 1), displayRate: .unlimited,
                         outputPolicy: output, mechanismPolicy: mechanism, demoLinks: demo)
}

private let route = try! XTouchOneRoute(inputID: "11", outputID: "22", transportOrigin: .physicalUSB)

struct PanelTests {
    @Test func theLayoutFollowsTheOverlayTemplateAddresses() {
        let keys = XTouchOnePanelLayout.keys
        #expect(keys.map(\.address).sorted() == Array(0...34) && Set(keys.map(\.id)).count == 35)
        #expect(XTouchOnePanelGroup.allCases.map { XTouchOnePanelLayout.keys(in: $0).count } == [6, 6, 7, 5, 4, 5, 1, 1])
        let labels = Dictionary(uniqueKeysWithValues: keys.map { ($0.address, $0.label) })
        #expect(labels[0] == "ENCODER PUSH" && labels[1] == "BPM/TIME" && labels[6] == "REC" && labels[7] == "F1")
        #expect(labels[13] == "MARKER" && labels[19] == "SOLO" && labels[20] == "REW" && labels[24] == "RECORD")
        #expect(labels[25] == "BANK <" && labels[28] == "CH >" && labels[29] == "SCRUB")
        #expect(labels[30] == "UP" && labels[31] == "LEFT" && labels[32] == "ZOOM" && labels[33] == "RIGHT" && labels[34] == "DOWN")
        #expect(XTouchOnePanelLayout.key(at: 35) == nil)
    }

    @Test func segmentTextFillsTheAssignmentAndCounterFields() {
        #expect(XTouchOneSegmentFont.mask(for: "ß") == 0)
        #expect(XTouchOneSegmentFont.mask(for: "你") == 0)
        guard case .segmentDisplay(let masks, 0, 0) = XTouchOneSegmentFont.display(assignment: "Pn", counter: "42") else {
            Issue.record("expected a segment display"); return
        }
        #expect(masks == [0x73, 0x54, 0, 0, 0, 0, 0, 0, 0, 0, 0x66, 0x5B])
        #expect(XTouchOneSegmentFont.mask(for: "?") == 0 && XTouchOneSegmentFont.mask(for: "p") == 0x73)
        guard case .segmentDisplay(let long, _, _) = XTouchOneSegmentFont.display(assignment: "ABC", counter: "123456789012") else { return }
        #expect(long.count == 12 && long[1] == 0x7C && long[2] == 0x4F)
    }

    @Test(arguments: XTouchOneMIDIMode.allCases)
    func mockGesturesDriveTheSessionAndTheDemoLights(_ mode: XTouchOneMIDIMode) throws {
        var console = try console(mode: mode)
        try console.operate(.button(3, pressed: true), at: 1)
        #expect(console.pressed == ["button.3"])
        try console.operate(.button(3, pressed: false), at: 2)
        try console.operate(.touch(true), at: 3)
        try console.operate(.fader(200), at: 4)
        try console.operate(.jog(clockwise: false), at: 5)
        try console.operate(.encoder(clockwise: true), at: 6)
        try console.pump(at: 7)
        #expect(console.pressed.isEmpty && console.mockFader == 127 && console.faderPosition == 127)
        #expect(console.faderTouched == true && console.jogTicks == -1 && console.encoderTicks == 1)
        #expect(console.shown.buttonLEDs == [3: .on] && console.shown.meter == 127)
        #expect(console.shown.lcd?.upper == "Fader  " && console.shown.lcd?.lower == "127    ")
        #expect(console.shown.encoderRing == (mode == .midi || mode == .controlChange ? 1 : 5))
        #expect(console.shown.segments?.suffix(2) == [0x40, 0x06] && console.shown.faderTargets.isEmpty)
        #expect(console.log.filter { $0.kind == .input }.count == 6 && console.log.filter { $0.kind == .output }.count == 5)

        try console.operate(.button(3, pressed: true), at: 8)
        try console.pump(at: 9)
        #expect(console.shown.buttonLEDs[3] == .off)
    }

    @Test func mockRecallNeedsAReleaseAndMovesTheMockFader() throws {
        var console = try console(demo: false)
        #expect(try console.recallFader(to: 90, at: 1) == .refused(.contactUnknown))
        try console.operate(.touch(true), at: 2)
        try console.operate(.fader(10), at: 3)
        #expect(try console.recallFader(to: 90, at: 4) == .refused(.touched) && console.mockFader == 10)
        try console.operate(.touch(false), at: 5)
        guard case .send = try console.recallFader(to: 90, at: 6) else { Issue.record("expected a send"); return }
        #expect(console.mockFader == 90 && console.shown.faderTargets == [90])
        #expect(console.log.last?.text == "fader accepted" && console.log.last?.bytes == [0xB0, 70, 90])
        #expect(console.shown.buttonLEDs.isEmpty, "without the demo links input changes no display")
    }

    @Test func faderTargetFollowsOnlyPhysicalTravelWhileTouched() throws {
        var console = try console(.hardware, demo: false)
        try console.attach(route, at: 0)
        console.setFaderTarget(127)

        try console.receive([0xB0, 70, 62], at: 1)
        try console.receive([0x90, 110, 127], at: 2)
        try console.receive([0xB0, 70, 62], at: 3)
        #expect(console.faderTarget == 127)
        try console.receive([0xB0, 70, 59], at: 4)
        #expect(console.faderPosition == 59 && console.faderTarget == 59)
        try console.receive([0x90, 110, 0], at: 5)
        try console.receive([0xB0, 70, 70], at: 6)
        #expect(console.faderPosition == 70 && console.faderTarget == 59)
        #expect(console.log.allSatisfy { $0.kind != .output })
    }

    @Test func unknownFaderPositionDoesNotReplaceAnExplicitTargetUntilTravelIsObserved() throws {
        var console = try console(.hardware, demo: false)
        try console.attach(route, at: 0)
        console.setFaderTarget(120)
        try console.receive([0x90, 110, 127], at: 1)
        try console.receive([0xB0, 70, 25], at: 2)
        #expect(console.faderTarget == 120)
        try console.receive([0xB0, 70, 27], at: 3)
        #expect(console.faderTarget == 27)
    }

    @Test func faderGhostShowsTheDraftAndSendingIsAnExplicitSeparateAction() throws {
        var console = try console(.hardware, demo: false)
        try console.attach(route, at: 0)
        try console.receive([0xB0, 70, 12], at: 1)
        try console.receive([0x90, 110, 0], at: 1)
        console.setFaderTarget(83)
        #expect(console.faderPosition == 12 && console.faderGhostPosition == 83)
        #expect(console.sentFaderTarget == nil && console.log.allSatisfy { $0.kind != .output })
        try console.recallFader(to: 83, at: 2) { bytes in
            #expect(bytes == [0xB0, 70, 83])
            return .accepted
        }
        #expect(console.faderPosition == nil && console.faderGhostPosition == 83 && console.sentFaderTarget == 83)
        console.setFaderTarget(24)
        #expect(console.faderGhostPosition == 24 && console.sentFaderTarget == 83)
        #expect(console.log.filter { $0.kind == .output }.count == 1)

        try console.receive([0xB0, 70, 81], at: 3)
        #expect(console.faderPosition == 81 && console.faderGhostPosition == 24 && console.sentFaderTarget == nil)
        console.setFaderTarget(81)
        #expect(console.faderGhostPosition == nil)
        console.setFaderTarget(17)
        try console.recallFader(to: 17, at: 4) { _ in .notAttempted(reason: "no transport") }
        #expect(console.faderGhostPosition == 17 && console.sentFaderTarget == nil)
        try console.recallFader(to: 17, at: 5) { _ in .rejected(reason: "transport") }
        #expect(console.faderPosition == nil && console.faderGhostPosition == 17 && console.sentFaderTarget == nil)
        try console.recallFader(to: 17, at: 6) { _ in .accepted }
        try console.detach(at: 7)
        #expect(console.faderGhostPosition == 17 && console.sentFaderTarget == nil)
    }

    @Test func jogClearResetsOnlyTheReadoutWhenListening() throws {
        var console = try console(.hardware, output: .observe, demo: false)
        try console.attach(route, at: 0)
        try console.receive([0xB0, 70, 44], at: 1)
        try console.receive([0xB0, 88, 65], at: 1)
        #expect(console.jogTicks == 1)
        try console.resetJog(at: 2, updateDisplay: false)
        try console.pump(at: 2) { _ in Issue.record("observe mode sent bytes"); return .accepted }
        #expect(console.jogTicks == 0 && console.jogStep == 0 && console.faderPosition == 44)
        #expect(console.shown.segments == nil)
    }

    @Test func jogClearAndStopSendTheSameZeroAndTheNextStepStartsFromZero() throws {
        var console = try console(.hardware, mode: .midiRelative, demo: false)
        try console.attach(route, at: 0)
        try console.setJogDisplayLinked(true, at: 1)
        var transmitted: [[UInt8]] = []
        func write(_ bytes: [UInt8]) -> FeedbackAttemptResult { transmitted.append(bytes); return .accepted }
        try console.pump(at: 1, write: write)
        let zero = try #require(transmitted.last)
        #expect(Array(zero[6..<18]) == [0, 0x3F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x3F])

        try console.receive([0xB0, 88, 65], at: 2)
        try console.pump(at: 2, write: write)
        try console.setJogDisplayLinked(false, at: 3)
        try console.resetJog(at: 3, updateDisplay: true)
        try console.pump(at: 3, write: write)
        #expect(console.jogTicks == 0 && console.jogDisplayLinked && transmitted.last == zero)

        try console.receive([0xB0, 88, 1], at: 4)
        try console.pump(at: 4, write: write)
        #expect(console.jogTicks == -1 && console.jogStep == -1)
        try console.receive([0x90, 22, 127], at: 5)
        try console.pump(at: 5, write: write)
        #expect(console.jogTicks == 0 && console.jogStep == 0 && transmitted.last == zero)
        try console.receive([0x90, 22, 0], at: 6)
        try console.receive([0xB0, 88, 65], at: 6)
        #expect(console.jogTicks == 1 && console.jogDisplayLinked)
    }

    @Test func theHardwareLinkIgnoresPanelGesturesAndShowsOnlyAcceptedSends() throws {
        var console = try console(.hardware, demo: false)
        try console.operate(.button(1, pressed: true), at: 0)
        #expect(console.log.isEmpty && console.faderPosition == nil && console.faderTouched == nil)
        #expect(try console.request(.meter(5), at: 1) == .refused(.notConnected))
        try console.attach(route, at: 2)
        try console.receive([0x90, 1, 127], at: 3)
        try console.receive([0xB0, 70, 44], at: 3)
        #expect(console.pressed == ["button.1"] && console.faderPosition == 44)

        _ = try console.request(.meter(5), at: 4)
        try console.pump(at: 4)
        #expect(console.shown.meter == nil && console.log.last?.text.contains("no transport") == true)
        _ = try console.request(.meter(6), at: 5)
        var written: [[UInt8]] = []
        try console.pump(at: 5) { written.append($0); return .rejected(reason: "io") }
        #expect(console.shown.meter == nil && written == [[0xB0, 90, 6]])
        _ = try console.request(.meter(7), at: 7)
        try console.pump(at: 7) { written.append($0); return .accepted }
        #expect(console.shown.meter == 7 && written.count == 2)

        try console.detach(at: 8)
        #expect(console.pressed.isEmpty && console.shown.meter == nil && console.faderPosition == nil)
        #expect(console.log.last?.text == "disconnected")
    }

    @Test func anObservingHardwareConsoleNeverCallsTheTransport() throws {
        var console = try console(.hardware, output: .observe, mechanism: .disabled)
        try console.attach(route, at: 0)
        try console.receive([0x90, 110, 127], at: 1)
        try console.receive([0x90, 110, 0], at: 1)
        try console.receive([0x90, 2, 127], at: 1)
        var calls = 0
        try console.pump(at: 2) { _ in calls += 1; return .accepted }
        #expect(try console.recallFader(to: 1, at: 3) { _ in calls += 1; return .accepted } == .refused(.observeOnly))
        #expect(calls == 0 && console.shown.buttonLEDs.isEmpty)
        #expect(console.log.contains { $0.text == "display button.2 refused: observeOnly" })
        for index in 0..<300 { console.note("n\(index)", at: 4) }
        #expect(console.log.count == XTouchOneConsole.logLimit && console.log.last?.text == "n299")
    }
}
