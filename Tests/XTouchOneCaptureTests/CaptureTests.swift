import Testing
import XTouchOneAdapter
import XTouchOneCapture
import XTouchOneSimulator

private func header(_ mode: XTouchOneMIDIMode = .midi) -> XTouchOneCaptureHeader {
    XTouchOneCaptureHeader(mode: mode, channel: 1, source: "simulation", inputID: "sim-in", inputName: "X-Touch One")
}

/// Every operator action of the model, a few bytes per record so messages straddle records.
private func fullCapture(_ mode: XTouchOneMIDIMode) -> XTouchOneCapture {
    var device = XTouchOneSimulatedDevice(mode: mode, channel: 1)
    var stream: [UInt8] = []
    for address in UInt8(0)...34 {
        stream += device.setButton(address, pressed: true) + device.setButton(address, pressed: false)
    }
    stream += device.setFootSwitch(pressed: true) + device.setFootSwitch(pressed: false)
    stream += device.setFaderTouched(true) + device.moveFader(to: 0) + device.moveFader(to: 127)
    stream += device.setFaderTouched(false) + device.turnJog(clockwise: true) + device.turnJog(clockwise: false)
    for clockwise in [true, true, false] { stream += device.turnEncoder(clockwise: clockwise) }
    var records = [XTouchOneCaptureRecord(seq: 1, at: 0, generation: 1, content: .connected)]
    for start in stride(from: 0, to: stream.count, by: 4) {
        records.append(XTouchOneCaptureRecord(seq: records.count + 1, at: Double(start) / 100, generation: 1,
                                              content: .input(Array(stream[start..<min(start + 4, stream.count)]))))
    }
    return XTouchOneCapture(header: header(mode), records: records)
}

struct CaptureTests {
    @Test func jsonLinesRoundTripAndStayReadable() throws {
        let capture = XTouchOneCapture(header: header(), records: [
            XTouchOneCaptureRecord(seq: 1, at: 0.5, generation: 1, content: .connected),
            XTouchOneCaptureRecord(seq: 2, at: 1, generation: 1, content: .input([0xB0, 70, 0x0A])),
            XTouchOneCaptureRecord(seq: 3, at: 2, generation: 1, content: .output([0x90, 1, 127])),
            XTouchOneCaptureRecord(seq: 4, at: 3, generation: 1, content: .disconnected),
        ])
        let text = try capture.jsonLines()
        #expect(try XTouchOneCapture(jsonLines: text) == capture)
        let lines = text.split(separator: "\n")
        #expect(lines[0] == #"{"channel":1,"format":"xtouch-one-capture","inputID":"sim-in","inputName":"X-Touch One","mode":"Midi","source":"simulation","version":1}"#)
        #expect(lines[2] == #"{"at":1,"bytes":"B0 46 0A","direction":"in","generation":1,"seq":2}"#)
        #expect(lines[4] == #"{"at":3,"event":"disconnected","generation":1,"seq":4}"#)
        #expect(try XTouchOneCapture(jsonLines: "\n" + text + "\n\n") == capture)
    }

    @Test func malformedFilesAreRejectedWithTheirLine() throws {
        let head = try XTouchOneCapture.line(header())
        #expect(throws: XTouchOneCaptureError.empty) { try XTouchOneCapture(jsonLines: " \n") }
        for bad in ["{}", head.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                    head.replacingOccurrences(of: "Midi", with: "MC"),
                    head.replacingOccurrences(of: "\"channel\":1", with: "\"channel\":17"),
                    head.replacingOccurrences(of: "simulation", with: "guess")] {
            #expect(throws: XTouchOneCaptureError.self) { try XTouchOneCapture(jsonLines: bad) }
        }
        for bad in [#"{"seq":1,"at":0,"generation":1}"#,
                    #"{"seq":1,"at":0,"generation":1,"event":"reset"}"#,
                    #"{"seq":1,"at":0,"generation":1,"event":"connected","bytes":"00"}"#,
                    #"{"seq":1,"at":0,"generation":1,"direction":"both","bytes":"00"}"#,
                    #"{"seq":1,"at":0,"generation":1,"direction":"in","bytes":""}"#,
                    #"{"seq":1,"at":0,"generation":1,"direction":"in","bytes":"B0 4 7F"}"#,
                    #"{"seq":1,"at":0,"generation":1,"direction":"in","bytes":"B0 GG 7F"}"#,
                    #"{"seq":1,"at":0,"generation":-1,"event":"connected"}"#, "not json"] {
            #expect(throws: XTouchOneCaptureError.invalidRecord(line: 3)) {
                try XTouchOneCapture(jsonLines: head + "\n\n" + bad + "\n")
            }
        }
    }

    @Test(arguments: XTouchOneMIDIMode.allCases)
    func aFullSamplingPassReviewsAsComplete(_ mode: XTouchOneMIDIMode) throws {
        let review = try XTouchOneCaptureReview(XTouchOneCapture(jsonLines: fullCapture(mode).jsonLines()))
        #expect(review.isComplete && review.inputMessageCount == 81 && review.outputMessageCount == 0)
        #expect(review.generations.count == 1 && review.generations[0].sawConnected)
        #expect(review.generations[0].firstInputs.count == 8 && review.generations[0].inputMessageCount == 81)
        let text = review.text()
        #expect(text.contains("coverage: 80/80 documented inputs") && text.hasSuffix("result: complete\n"))
        #expect(text.contains("mode \(mode.rawValue), channel 1") && text.contains("0 motor targets sent"))
    }

    @Test func theReviewReportsGapsReconnectsAndSuspiciousTraffic() throws {
        let records: [XTouchOneCaptureRecord] = [
            .init(seq: 1, at: 1, generation: 1, content: .input([0x90, 0, 127, 0x90])),
            .init(seq: 2, at: 2, generation: 1, content: .disconnected),
            .init(seq: 4, at: 1.5, generation: 2, content: .input([0, 0, 0xB5, 70, 3])),
            .init(seq: 5, at: 3, generation: 2, content: .connected),
            .init(seq: 6, at: 4, generation: 2, content: .output([0xB0, 70, 9, 0xB0, 90, 1])),
            .init(seq: 7, at: 5, generation: 1, content: .input([0xE0, 0, 0])),
        ]
        let review = try XTouchOneCaptureReview(XTouchOneCapture(header: header(), records: records))
        #expect(review.problems == ["seq 4 follows 2", "seq 4: time runs backwards", "seq 7: generation decreases"])
        #expect(review.generations.map(\.generation) == [1, 2, 1])
        #expect(review.generations.map(\.sawConnected) == [false, false, false])
        #expect(review.unframedByteCount == 3, "a partial message never continues into the next generation")
        #expect(review.motorTargetsSent == 1 && review.outputMessageCount == 2 && review.inputMessageCount == 3)
        #expect(review.coverage.seen == ["button.0:press"] && review.coverage.otherChannels == [6])
        #expect(!review.isComplete)
        let text = review.text()
        for expected in ["1/80 documented inputs", "other channels: 6", "  B5 46 03", "problem: seq 4 follows 2",
                         "1 motor targets sent", "3 unframed bytes", "result: incomplete"] {
            #expect(text.contains(expected), "\(expected)")
        }
    }

    @Test func reconnectDoesNotInventEncoderMovementAndMotorTargetsAreCountedOnEveryChannel() throws {
        let records: [XTouchOneCaptureRecord] = [
            .init(seq: 1, at: 0, generation: 1, content: .connected),
            .init(seq: 2, at: 0.5, generation: 1, content: .input([0xB0, 80, 100])),
            .init(seq: 3, at: 1, generation: 1, content: .disconnected),
            .init(seq: 4, at: 2, generation: 3, content: .connected),
            .init(seq: 5, at: 2.25, generation: 3, content: .input([0xB0, 80, 0, 0xC5, 1])),
            .init(seq: 6, at: 2.5, generation: 3, content: .input([0xB0, 80, 1])),
            .init(seq: 7, at: 3, generation: 3, content: .output([0xBF, 70, 10])),
        ]
        let review = try XTouchOneCaptureReview(XTouchOneCapture(header: header(), records: records))
        #expect(review.coverage.seen == ["encoder.turn:increase"])
        #expect(review.coverage.otherChannels == [6] && review.motorTargetsSent == 1)
        #expect(review.generations.map(\.connectedAt) == [0, 2])
        #expect(review.generations.map(\.disconnectedAt) == [1, nil])
        #expect(review.text().contains("first input 0.25 s after connection"))
    }

    @Test func anOutOfRangeSequenceGapCanBeReviewed() throws {
        let records: [XTouchOneCaptureRecord] = [
            .init(seq: Int.max, at: 0, generation: 1, content: .connected),
            .init(seq: Int.min, at: 1, generation: 1, content: .disconnected),
        ]
        let review = try XTouchOneCaptureReview(XTouchOneCapture(header: header(), records: records))
        #expect(review.problems == ["seq \(Int.min) follows \(Int.max)"])
    }
}
