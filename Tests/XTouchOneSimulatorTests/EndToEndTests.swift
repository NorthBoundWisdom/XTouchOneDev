import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import Testing
import XTouchOneAdapter
import XTouchOneSimulator

/// Carries bytes between a session and the simulated device, as a transport would.
private struct Bench {
    var device: XTouchOneSimulatedDevice
    var session: XTouchOneSession
    var framer = XTouchOneMIDIFramer()
    var written = 0

    init(_ mode: XTouchOneMIDIMode, channel: UInt8 = 4) throws {
        device = XTouchOneSimulatedDevice(mode: mode, channel: channel)
        session = try XTouchOneSession(source: .simulation, profile: XTouchOneMIDIProfile(mode: mode, channel: channel),
                                       displayRate: .unlimited, outputPolicy: .write)
        try session.attach(XTouchOneRoute(inputID: "sim-in", outputID: "sim-out", transportOrigin: .localVirtual))
        session.grantDisplay(to: .local)
    }

    mutating func fromDevice(_ bytes: [UInt8], at: Double = 0) throws -> [DeviceInputEvent] {
        try framer.feed(bytes).compactMap {
            if case .event(let event) = try session.receive($0, at: at) { return event }
            return nil
        }
    }

    /// Writes only what passes the final gate and reports the real outcome.
    mutating func flush(at: Double = 0) throws {
        for send in try session.drainDisplay(at: at) {
            guard session.preflight(send) == .permitted else {
                _ = try session.complete(send, result: .notAttempted(reason: "gate"), at: at)
                continue
            }
            device.receive(send.bytes)
            written += 1
            _ = try session.complete(send, result: .accepted, at: at)
        }
    }
}

struct EndToEndTests {
    @Test(arguments: XTouchOneMIDIMode.allCases)
    func everyOperatorActionReachesTheSessionAsOneDocumentedInput(_ mode: XTouchOneMIDIMode) throws {
        var bench = try Bench(mode)
        var coverage = XTouchOneInputCoverage(profile: bench.session.profile)
        var stream: [UInt8] = []
        for address in UInt8(0)...34 {
            stream += bench.device.setButton(address, pressed: true) + [0xF8] + bench.device.setButton(address, pressed: false)
        }
        stream += bench.device.setFootSwitch(pressed: true) + bench.device.setFootSwitch(pressed: false)
        stream += bench.device.setFaderTouched(true) + bench.device.moveFader(to: 0) + bench.device.moveFader(to: 127)
        stream += bench.device.setFaderTouched(false)
        stream += bench.device.turnJog(clockwise: true) + bench.device.turnJog(clockwise: false)
        for clockwise in [true, true, false] { stream += bench.device.turnEncoder(clockwise: clockwise) }

        var events: [DeviceInputEvent] = []
        for chunk in stride(from: 0, to: stream.count, by: 5) {
            events += try bench.fromDevice(Array(stream[chunk..<min(chunk + 5, stream.count)]))
        }
        for message in XTouchOneMIDIFramer().feedAll(stream) { coverage.record(message) }
        #expect(events.count == 81 && bench.framer.discardedByteCount == 0)
        #expect(coverage.missing.isEmpty && coverage.unrecognizedCount == 0)
        #expect(events.allSatisfy { $0.source == .simulation && $0.endpoint.endpointID == "sim-in" })
        #expect(try bench.session.observation(of: .faderPosition, at: 1).value == .number(127))
        #expect(try bench.session.observation(of: .faderContact, at: 1).value == .flag(false))
        let relative = mode == .midiRelative || mode == .controlChangeRelative
        #expect(events.suffix(3).map(\.value) == (relative ? [1, 1, -1] : [1, 2, 1]).map { .number($0) })
    }

    @Test(arguments: XTouchOneMIDIMode.allCases)
    func everyDisplayRendersOnTheModelAndTheMotorIsNeverAddressed(_ mode: XTouchOneMIDIMode) throws {
        var bench = try Bench(mode)
        for address in UInt8(0)...34 {
            let state: XTouchOneButtonLED = address % 2 == 0 ? .on : .flash
            _ = try bench.session.requestDisplay(.buttonLED(XTouchOneButton(rawValue: address)!, state), origin: .local)
        }
        _ = try bench.session.requestDisplay(.encoderRing(42), origin: .local)
        _ = try bench.session.requestDisplay(.meter(99), origin: .local)
        _ = try bench.session.requestDisplay(.lcd(upper: "Speed", lower: "1.25m/s", color: .yellow,
                                                  invertUpper: false, invertLower: true), origin: .local)
        let masks: [UInt8] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F, 0, 0x40]
        _ = try bench.session.requestDisplay(.segmentDisplay(segments: masks, dotsLow: 0x41, dotsHigh: 0x10), origin: .local)
        try bench.flush()

        #expect(bench.written == 39 && bench.device.ignored.isEmpty && bench.device.faderTargets.isEmpty)
        #expect(bench.device.buttonLEDs.count == 35)
        #expect(bench.device.buttonLEDs[0] == .on && bench.device.buttonLEDs[33] == .flash)
        #expect(bench.device.encoderRing == 42 && bench.device.meter == 99)
        #expect(bench.device.lcd == XTouchOneSimulatedLCD(upper: "Speed  ", lower: "1.25m/s", color: .yellow,
                                                          invertUpper: false, invertLower: true))
        #expect(bench.device.segments == masks && bench.device.segmentDots == [0x41, 0x10])

        _ = try bench.session.requestDisplay(.meter(99), origin: .local)
        try bench.flush()
        #expect(bench.written == 39, "an accepted value is not written twice")
    }

    @Test func reconnectAndModeChangeWriteNothingUntilANewRequest() throws {
        var bench = try Bench(.midi)
        _ = try bench.session.requestDisplay(.meter(10), origin: .local)
        try bench.flush()
        _ = try bench.session.requestDisplay(.meter(20), origin: .local)
        try bench.session.detach()
        try bench.flush()
        try bench.session.attach(XTouchOneRoute(inputID: "sim-in", outputID: "sim-out", transportOrigin: .localVirtual))
        try bench.flush(at: 5)
        #expect(bench.written == 1 && bench.device.meter == 10, "the device keeps what it last received")

        try bench.session.selectProfile(XTouchOneMIDIProfile(mode: .controlChange, channel: 4))
        try bench.flush(at: 6)
        #expect(bench.written == 1)
        _ = try bench.session.requestDisplay(.meter(10), origin: .local)
        try bench.flush(at: 7)
        #expect(bench.written == 2, "nothing accepted earlier suppresses a request in the new generation")
        #expect(try bench.fromDevice(bench.device.setButton(3, pressed: true)).isEmpty,
                "the model still transmits notes, which the newly selected mode does not document")
    }

    @Test func aSendWithdrawnBetweenDrainAndWriteNeverReachesTheDevice() throws {
        var bench = try Bench(.controlChangeRelative)
        _ = try bench.session.requestDisplay(.encoderRing(1), origin: .local)
        _ = try bench.session.requestDisplay(.meter(1), origin: .local)
        let sends = try bench.session.drainDisplay(at: 0)
        bench.session.withdrawDisplay(from: .local)
        for send in sends where bench.session.preflight(send) == .permitted { bench.device.receive(send.bytes) }
        #expect(bench.device.encoderRing == nil && bench.device.meter == nil)
    }

    @Test func theModelRecordsAMotorTargetAndRejectsOtherTraffic() {
        var device = XTouchOneSimulatedDevice(mode: .midi, channel: 1)
        let rejected: [[UInt8]] = [[0x91, 0, 127], [0x90, 35, 127], [0x90, 0, 1], [0xB0, 0, 127], [0xB0, 81, 1],
                                   [0xF0, 0, 0x20, 0x32, 0x41, 0x4C, 0, 0, 0xF7], [0xF0, 0x7E, 0x7F, 6, 1, 0xF7]]
        for message in [[0xB0, 70, 64]] + rejected { device.receive(message) }
        #expect(device.faderTargets == [64] && device.ignored == rejected && device.buttonLEDs.isEmpty)
    }
}

private extension XTouchOneMIDIFramer {
    func feedAll(_ bytes: [UInt8]) -> [[UInt8]] {
        var copy = self
        return copy.feed(bytes)
    }
}
