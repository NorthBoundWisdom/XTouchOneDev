/// Converts between MIDI 1.0 byte messages and the Universal MIDI Packet words CoreMIDI exchanges.
/// Pure values, so the same code is tested on every platform.
public enum XTouchOneUniversalPackets {
    /// Words for one complete channel message or System Exclusive message on group 0.
    public static func words(for message: [UInt8]) -> [UInt32]? {
        guard let status = message.first else { return nil }
        if status == 0xF0 {
            guard message.count >= 2, message.last == 0xF7 else { return nil }
            let payload = Array(message[1..<(message.count - 1)])
            guard payload.allSatisfy({ $0 < 0x80 }) else { return nil }
            let chunks = payload.isEmpty ? [[]] : stride(from: 0, to: payload.count, by: 6).map {
                Array(payload[$0..<min($0 + 6, payload.count)])
            }
            return chunks.enumerated().flatMap { index, chunk -> [UInt32] in
                let form: UInt32 = chunks.count == 1 ? 0 : index == 0 ? 1 : index == chunks.count - 1 ? 3 : 2
                let bytes = chunk.map(UInt32.init) + Array(repeating: 0, count: 6 - chunk.count)
                return [0x3000_0000 | form << 20 | UInt32(chunk.count) << 16 | bytes[0] << 8 | bytes[1],
                        bytes[2] << 24 | bytes[3] << 16 | bytes[4] << 8 | bytes[5]]
            }
        }
        guard (0x80...0xEF).contains(status), message.dropFirst().allSatisfy({ $0 < 0x80 }) else { return nil }
        let length = (0xC0...0xDF).contains(status) ? 2 : 3
        guard message.count == length else { return nil }
        return [0x2000_0000 | UInt32(status) << 16 | UInt32(message[1]) << 8 | (length == 3 ? UInt32(message[2]) : 0)]
    }

    /// Reassembles byte messages from a stream of words. Packet types other than MIDI 1.0 channel
    /// messages and 7-bit System Exclusive are counted and dropped.
    public struct Reader: Equatable, Sendable {
        public static let maximumSystemExclusiveLength = 256
        private var skip = 0
        private var second: UInt32?
        private var systemExclusive: [UInt8]?
        public private(set) var droppedPacketCount = 0

        public init() {}

        public mutating func messages(from words: [UInt32]) -> [[UInt8]] {
            var messages: [[UInt8]] = []
            for word in words {
                if skip > 0 { skip -= 1; continue }
                if let first = second {
                    second = nil
                    if let message = systemExclusivePacket(first, word) { messages.append(message) }
                    continue
                }
                switch word >> 28 {
                case 0x2:
                    let status = UInt8(word >> 16 & 0xFF)
                    guard status >= 0x80 else { droppedPacketCount += 1; continue }
                    let data = [UInt8(word >> 8 & 0x7F), UInt8(word & 0x7F)]
                    messages.append([status] + ((0xC0...0xDF).contains(status) ? [data[0]] : data))
                case 0x3:
                    second = word
                case 0x0, 0x1, 0x6, 0x7:
                    droppedPacketCount += 1
                case 0x4, 0x8, 0x9, 0xA:
                    droppedPacketCount += 1; skip = 1
                case 0xB, 0xC:
                    droppedPacketCount += 1; skip = 2
                default:
                    droppedPacketCount += 1; skip = 3
                }
            }
            return messages
        }

        private mutating func systemExclusivePacket(_ first: UInt32, _ last: UInt32) -> [UInt8]? {
            let form = first >> 20 & 0xF, count = Int(first >> 16 & 0xF)
            let all = [first >> 8, first, last >> 24, last >> 16, last >> 8, last].map { UInt8($0 & 0x7F) }
            guard count <= 6, form <= 3 else { droppedPacketCount += 1; systemExclusive = nil; return nil }
            if form <= 1 {
                if systemExclusive != nil { droppedPacketCount += 1 }
                systemExclusive = [0xF0]
            }
            guard var bytes = systemExclusive else { droppedPacketCount += 1; return nil }
            bytes += all.prefix(count)
            guard bytes.count < Self.maximumSystemExclusiveLength else {
                droppedPacketCount += 1; systemExclusive = nil; return nil
            }
            if form == 0 || form == 3 {
                systemExclusive = nil
                return bytes + [0xF7]
            }
            systemExclusive = bytes
            return nil
        }
    }
}
