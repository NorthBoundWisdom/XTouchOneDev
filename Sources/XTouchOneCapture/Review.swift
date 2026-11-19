import XTouchOneAdapter

/// What an offline reading of one capture shows. It is a review of recorded bytes, not a qualification.
public struct XTouchOneCaptureReview: Equatable, Sendable {
    public struct Generation: Equatable, Sendable {
        public let generation: UInt64
        public var firstAt: Double
        public var lastAt: Double
        public var inputMessageCount = 0
        /// The first input messages after this generation began, in arrival order.
        public var firstInputs: [[UInt8]] = []
        /// True when the capture shows this generation's connection event before any input.
        public var sawConnected = false
        public var connectedAt: Double?
        public var firstInputAt: Double?
        public var disconnectedAt: Double?
    }

    public static let firstInputLimit = 8

    public let header: XTouchOneCaptureHeader
    public private(set) var coverage: XTouchOneInputCoverage
    public private(set) var generations: [Generation] = []
    public private(set) var inputMessageCount = 0
    public private(set) var outputMessageCount = 0
    /// CC 70 messages on any channel found in the output direction.
    public private(set) var motorTargetsSent = 0
    public private(set) var unframedByteCount = 0
    public private(set) var problems: [String] = []

    public init(_ capture: XTouchOneCapture) throws {
        header = capture.header
        let profile = try capture.header.profile()
        coverage = XTouchOneInputCoverage(profile: profile)
        var inputFramer = XTouchOneMIDIFramer(), outputFramer = XTouchOneMIDIFramer()
        var previous: XTouchOneCaptureRecord?

        for record in capture.records {
            if let previous {
                let (next, overflow) = previous.seq.addingReportingOverflow(1)
                if overflow || record.seq != next { problems.append("seq \(record.seq) follows \(previous.seq)") }
                if record.at < previous.at { problems.append("seq \(record.seq): time runs backwards") }
                if record.generation < previous.generation { problems.append("seq \(record.seq): generation decreases") }
            }
            previous = record
            if generations.last?.generation != record.generation {
                generations.append(Generation(generation: record.generation, firstAt: record.at, lastAt: record.at))
                for framer in [inputFramer, outputFramer] {
                    unframedByteCount += framer.discardedByteCount + framer.pendingByteCount
                }
                inputFramer.reset()
                outputFramer.reset()
                coverage.beginGeneration()
            }
            let index = generations.count - 1
            generations[index].lastAt = record.at
            switch record.content {
            case .connected:
                if generations[index].firstInputAt == nil, generations[index].connectedAt == nil {
                    generations[index].sawConnected = true
                    generations[index].connectedAt = record.at
                }
            case .disconnected:
                generations[index].disconnectedAt = record.at
                coverage.beginGeneration()
            case .input(let bytes):
                for message in inputFramer.feed(bytes) {
                    inputMessageCount += 1
                    generations[index].inputMessageCount += 1
                    if generations[index].firstInputAt == nil { generations[index].firstInputAt = record.at }
                    if generations[index].firstInputs.count < Self.firstInputLimit {
                        generations[index].firstInputs.append(message)
                    }
                    coverage.record(message)
                }
            case .output(let bytes):
                for message in outputFramer.feed(bytes) {
                    outputMessageCount += 1
                    if message.count == 3, message[0] & 0xF0 == 0xB0, message[1] == 70 {
                        motorTargetsSent += 1
                    }
                }
            }
        }
        for framer in [inputFramer, outputFramer] {
            unframedByteCount += framer.discardedByteCount + framer.pendingByteCount
        }
    }

    public var isComplete: Bool { coverage.missing.isEmpty && problems.isEmpty && unframedByteCount == 0 }

    public func text() -> String {
        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: true) }.joined(separator: " ")
        }
        var lines = [
            "capture: \(header.source), mode \(header.mode), channel \(header.channel)",
            "input: \(header.inputName ?? "unnamed") [\(header.inputID ?? "no id")], firmware \(header.firmware ?? "not recorded")",
            "messages: \(inputMessageCount) in, \(outputMessageCount) out, \(motorTargetsSent) motor targets sent, \(unframedByteCount) unframed bytes",
            "coverage: \(coverage.required.count - coverage.missing.count)/\(coverage.required.count) documented inputs",
        ]
        if !coverage.missing.isEmpty { lines.append("missing: " + coverage.missing.joined(separator: ", ")) }
        if !coverage.otherChannels.isEmpty {
            lines.append("other channels: " + coverage.otherChannels.sorted().map(String.init).joined(separator: ", "))
        }
        if coverage.unrecognizedCount > 0 {
            lines.append("unrecognized: \(coverage.unrecognizedCount) messages, first distinct:")
            lines += coverage.unrecognized.map { "  " + hex($0) }
        }
        for generation in generations {
            lines.append("generation \(generation.generation): \(generation.inputMessageCount) inputs from \(generation.firstAt) to \(generation.lastAt)"
                + (generation.sawConnected ? ", connection event recorded" : ""))
            if let connected = generation.connectedAt, let first = generation.firstInputAt {
                lines.append("  first input \(first - connected) s after connection")
            }
            if let disconnected = generation.disconnectedAt { lines.append("  disconnected at \(disconnected) s") }
            lines += generation.firstInputs.map { "  " + hex($0) }
        }
        lines += problems.map { "problem: " + $0 }
        lines.append(isComplete ? "result: complete" : "result: incomplete")
        return lines.joined(separator: "\n") + "\n"
    }
}
