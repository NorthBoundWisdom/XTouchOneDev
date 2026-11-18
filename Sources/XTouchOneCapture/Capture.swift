import Foundation
import XTouchOneAdapter

public enum XTouchOneCaptureError: Error, Equatable, Sendable {
    case empty
    case tooLarge
    case invalidHeader(String)
    /// One-based line number in the file.
    case invalidRecord(line: Int)
}

/// The first line of a capture file. Mode and channel are what the operator read off the device.
public struct XTouchOneCaptureHeader: Codable, Equatable, Sendable {
    public static let format = "xtouch-one-capture"
    public static let version = 1

    public var format = Self.format
    public var version = Self.version
    public var mode: String
    public var channel: UInt8
    public var source: String
    public var inputID: String?
    public var inputName: String?
    public var firmware: String?
    public var note: String?

    public init(mode: XTouchOneMIDIMode, channel: UInt8, source: String, inputID: String? = nil,
                inputName: String? = nil, firmware: String? = nil, note: String? = nil) {
        self.mode = mode.rawValue
        self.channel = channel
        self.source = source
        self.inputID = inputID
        self.inputName = inputName
        self.firmware = firmware
        self.note = note
    }

    public func profile() throws -> XTouchOneMIDIProfile {
        guard format == Self.format, version == Self.version else {
            throw XTouchOneCaptureError.invalidHeader("unsupported format or version")
        }
        guard let mode = XTouchOneMIDIMode(rawValue: mode) else { throw XTouchOneCaptureError.invalidHeader("mode") }
        guard source == "hardware" || source == "simulation" else { throw XTouchOneCaptureError.invalidHeader("source") }
        do { return try XTouchOneMIDIProfile(mode: mode, channel: channel) } catch {
            throw XTouchOneCaptureError.invalidHeader("channel")
        }
    }
}

/// One later line: either raw bytes in one direction or a connection event.
public struct XTouchOneCaptureRecord: Codable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case input([UInt8])
        case output([UInt8])
        case connected
        case disconnected
    }

    public let seq: Int
    public let at: Double
    public let generation: UInt64
    public let content: Content

    public init(seq: Int, at: Double, generation: UInt64, content: Content) {
        self.seq = seq
        self.at = at
        self.generation = generation
        self.content = content
    }

    enum CodingKeys: String, CodingKey { case seq, at, generation, direction, bytes, event }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decode(Double.self, forKey: .at)
        generation = try c.decode(UInt64.self, forKey: .generation)
        let event = try c.decodeIfPresent(String.self, forKey: .event)
        let direction = try c.decodeIfPresent(String.self, forKey: .direction)
        let hex = try c.decodeIfPresent(String.self, forKey: .bytes)
        func invalid(_ key: CodingKeys) -> DecodingError {
            .dataCorruptedError(forKey: key, in: c, debugDescription: "invalid \(key.rawValue)")
        }
        guard at.isFinite else { throw invalid(.at) }
        switch (event, direction, hex) {
        case ("connected", nil, nil): content = .connected
        case ("disconnected", nil, nil): content = .disconnected
        case (nil, let direction?, let hex?):
            let parts = hex.split(separator: " ")
            let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
            guard !bytes.isEmpty, bytes.count == parts.count else { throw invalid(.bytes) }
            switch direction {
            case "in": content = .input(bytes)
            case "out": content = .output(bytes)
            default: throw invalid(.direction)
            }
        default: throw invalid(.event)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(at, forKey: .at)
        try c.encode(generation, forKey: .generation)
        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: true) }.joined(separator: " ")
        }
        switch content {
        case .input(let bytes): try c.encode("in", forKey: .direction); try c.encode(hex(bytes), forKey: .bytes)
        case .output(let bytes): try c.encode("out", forKey: .direction); try c.encode(hex(bytes), forKey: .bytes)
        case .connected: try c.encode("connected", forKey: .event)
        case .disconnected: try c.encode("disconnected", forKey: .event)
        }
    }
}

/// A capture as JSON Lines: one header line, then one record per line. Reading and writing touch no files.
public struct XTouchOneCapture: Equatable, Sendable {
    public static let maximumBytes = 64 * 1024 * 1024

    public let header: XTouchOneCaptureHeader
    public let records: [XTouchOneCaptureRecord]

    public init(header: XTouchOneCaptureHeader, records: [XTouchOneCaptureRecord]) {
        self.header = header
        self.records = records
    }

    public init(jsonLines text: String) throws {
        guard text.utf8.count <= Self.maximumBytes else { throw XTouchOneCaptureError.tooLarge }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().filter { !$0.element.allSatisfy(\.isWhitespace) }
        guard let first = lines.first else { throw XTouchOneCaptureError.empty }
        let decoder = JSONDecoder()
        do { header = try decoder.decode(XTouchOneCaptureHeader.self, from: Data(first.element.utf8)) } catch {
            throw XTouchOneCaptureError.invalidHeader("not a capture header")
        }
        _ = try header.profile()
        records = try lines.dropFirst().map { index, line in
            do { return try decoder.decode(XTouchOneCaptureRecord.self, from: Data(line.utf8)) } catch {
                throw XTouchOneCaptureError.invalidRecord(line: index + 1)
            }
        }
    }

    public static func line<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public func jsonLines() throws -> String {
        try ([Self.line(header)] + records.map(Self.line)).joined(separator: "\n") + "\n"
    }
}
