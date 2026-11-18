/// Splits a raw MIDI 1.0 byte stream into complete messages. It holds no clock and performs no I/O.
/// Real-time bytes are dropped without disturbing the message around them.
public struct XTouchOneMIDIFramer: Equatable, Sendable {
    public static let maximumSystemExclusiveLength = 256

    private var pending: [UInt8] = []
    private var expectedLength = 0
    private var runningStatus: UInt8?
    /// Bytes that could not be attributed to a complete message, for capture review.
    public private(set) var discardedByteCount = 0

    public init() {}

    /// Forgets partial data, as required when the connection changes.
    public mutating func reset() { self = Self() }

    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if byte >= 0x80 {
                if byte == 0xF7, pending.first == 0xF0 {
                    messages.append(pending + [byte])
                    pending = []
                } else {
                    begin(byte)
                }
            } else if pending.first == 0xF0 {
                pending.append(byte)
                if pending.count >= Self.maximumSystemExclusiveLength { discardPending() }
            } else {
                if pending.isEmpty {
                    guard let runningStatus else { discardedByteCount += 1; continue }
                    pending = [runningStatus]
                }
                pending.append(byte)
                if pending.count == expectedLength {
                    if pending[0] < 0xF0 { messages.append(pending) } else { discardedByteCount += pending.count }
                    pending = []
                }
            }
        }
        return messages
    }

    private mutating func begin(_ status: UInt8) {
        discardPending()
        runningStatus = status < 0xF0 ? status : nil
        switch status {
        case 0xC0...0xDF, 0xF1, 0xF3: expectedLength = 2
        case 0xF0: expectedLength = 0
        case 0xF4...0xF7: discardedByteCount += 1; return
        default: expectedLength = 3
        }
        pending = [status]
    }

    private mutating func discardPending() {
        discardedByteCount += pending.count
        pending = []
    }
}
