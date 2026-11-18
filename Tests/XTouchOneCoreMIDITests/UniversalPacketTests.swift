import Testing
import XTouchOneCoreMIDI

struct UniversalPacketTests {
    typealias Packets = XTouchOneUniversalPackets

    @Test func channelMessagesUseOneWord() {
        #expect(Packets.words(for: [0xB3, 70, 127]) == [0x20B3_467F])
        #expect(Packets.words(for: [0x90, 110, 0]) == [0x2090_6E00])
        #expect(Packets.words(for: [0xC1, 5]) == [0x20C1_0500])
        for invalid: [UInt8] in [[], [0x90, 1], [0x90, 1, 2, 3], [0x90, 0x80, 0], [0x10, 1, 2], [0xF8], [0xF0, 1], [0xF0, 0x80, 0xF7]] {
            #expect(Packets.words(for: invalid) == nil)
        }
    }

    @Test func systemExclusiveSplitsIntoSixByteChunksAndReassembles() throws {
        let lcd: [UInt8] = [0xF0, 0, 0x20, 0x32, 0x41, 0x4C, 0, 3] + Array("Upper  Lower  ".utf8) + [0xF7]
        let words = try #require(Packets.words(for: lcd))
        #expect(words.count == 8 && words[0] == 0x3016_0020 && words[1] == 0x3241_4C00)
        #expect(words[2] >> 16 == 0x3026 && words[4] >> 16 == 0x3026 && words[6] >> 16 == 0x3033)
        #expect(Packets.words(for: [0xF0, 0xF7]) == [0x3000_0000, 0])
        #expect(Packets.words(for: [0xF0, 1, 2, 3, 4, 5, 6, 0xF7]) == [0x3006_0102, 0x0304_0506])

        var reader = Packets.Reader()
        #expect(reader.messages(from: Array(words.prefix(3))).isEmpty)
        #expect(reader.messages(from: Array(words.dropFirst(3)) + [0x2090_0A7F, 0x3000_0000, 0]) == [lcd, [0x90, 10, 127], [0xF0, 0xF7]])
        #expect(reader.droppedPacketCount == 0)
    }

    @Test func otherPacketTypesAreSkippedByTheirLength() {
        var reader = Packets.Reader()
        let words: [UInt32] = [0x10F8_0000, 0x4090_3C00, 0xFFFF_0000, 0x5000_0000, 1, 2, 3, 0x20C2_0900,
                               0x3026_0102, 0, 0x2000_0000, 0x3036_0102, 0, 0x3010_0000, 0, 0x3010_0000, 0, 0x3030_0000, 0]
        #expect(reader.messages(from: words) == [[0xC2, 9], [0xF0, 0xF7]])
        #expect(reader.droppedPacketCount == 7)
        let long = (0..<50).flatMap { _ -> [UInt32] in [0x3026_0101, 0x0101_0101] }
        #expect(reader.messages(from: [0x3016_0101, 0x0101_0101] + long + [0x3030_0000, 0]).isEmpty)
    }
}
