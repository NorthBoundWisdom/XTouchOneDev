import XTouchOneAdapter

public enum XTouchOnePanelGroup: String, CaseIterable, Sendable {
    case channel, function, transportModes, transport, bank, navigation, scrub, encoder
}

public enum XTouchOnePanelLight: Sendable { case amber, green, red, blue, white }

public struct XTouchOnePanelKey: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let group: XTouchOnePanelGroup
    public let light: XTouchOnePanelLight
    public let address: UInt8
    public var button: XTouchOneButton { XTouchOneButton(rawValue: address)! }
}

/// Where each panel key sits and its documented address.
/// The addresses follow Behringer's overlay template sheets (MIDI/REL and CC/REL pages), which print the
/// note or controller number beside every key. They are documentation, not yet confirmed on a device.
public enum XTouchOnePanelLayout {
    public static let keys: [XTouchOnePanelKey] = {
        // The encoder push is address 0; the rest run left to right, top to bottom.
        let rows: [(XTouchOnePanelGroup, XTouchOnePanelLight, [(String, UInt8)])] = [
            (.encoder, .white, [("ENCODER PUSH", 0)]),
            (.channel, .amber, [("BPM/TIME", 1), ("MASTER", 2), ("SELECT", 3), ("MUTE", 4), ("SOLO", 5), ("REC", 6)]),
            (.function, .amber, [("F1", 7), ("F2", 8), ("F3", 9), ("F4", 10), ("F5", 11), ("F6", 12)]),
            (.transportModes, .amber, [("MARKER", 13), ("NUDGE", 14), ("CYCLE", 15), ("DROP", 16), ("REPLACE", 17),
                                       ("CLICK", 18), ("SOLO", 19)]),
            (.transport, .white, [("REW", 20), ("FWD", 21), ("STOP", 22), ("PLAY", 23), ("RECORD", 24)]),
            (.bank, .white, [("BANK <", 25), ("BANK >", 26), ("CH <", 27), ("CH >", 28)]),
            (.scrub, .red, [("SCRUB", 29)]),
            (.navigation, .blue, [("UP", 30), ("LEFT", 31), ("ZOOM", 32), ("RIGHT", 33), ("DOWN", 34)]),
        ]
        let special: [String: XTouchOnePanelLight] = ["SELECT": .green, "REC": .red, "RECORD": .red, "DROP": .red,
                                                      "PLAY": .green, "MUTE": .red]
        return rows.flatMap { group, light, entries in
            entries.map { label, address in
                XTouchOnePanelKey(id: "\(group.rawValue).\(label)", label: label, group: group,
                                  light: special[label] ?? light, address: address)
            }
        }
    }()

    public static func keys(in group: XTouchOnePanelGroup) -> [XTouchOnePanelKey] { keys.filter { $0.group == group } }
    public static func key(at address: UInt8) -> XTouchOnePanelKey? { keys.first { $0.address == address } }
}

/// Seven-segment glyphs: bit 0 is segment a through bit 6 for segment g, as the MIDI mode document states.
public enum XTouchOneSegmentFont {
    public static let digitCount = 12
    public static let assignmentDigits = 2

    private static let glyphs: [String: UInt8] = [
        "0": 0x3F, "1": 0x06, "2": 0x5B, "3": 0x4F, "4": 0x66, "5": 0x6D, "6": 0x7D, "7": 0x07, "8": 0x7F, "9": 0x6F,
        " ": 0x00, "-": 0x40, "_": 0x08, "A": 0x77, "b": 0x7C, "C": 0x39, "c": 0x58, "d": 0x5E, "E": 0x79, "F": 0x71,
        "H": 0x76, "h": 0x74, "L": 0x38, "n": 0x54, "o": 0x5C, "P": 0x73, "r": 0x50, "t": 0x78, "U": 0x3E, "u": 0x1C, "y": 0x6E,
    ]

    public static func mask(for character: Character) -> UInt8 {
        let text = String(character)
        return glyphs[text] ?? glyphs[text.uppercased()] ?? glyphs[text.lowercased()] ?? 0
    }

    /// The assignment field is left aligned in the first two digits, the counter right aligned in the other ten.
    public static func display(assignment: String, counter: String) -> XTouchOneDisplay {
        let left = Array(assignment.prefix(assignmentDigits))
        let right = Array(counter.suffix(digitCount - assignmentDigits))
        var masks = [UInt8](repeating: 0, count: digitCount)
        for (index, character) in left.enumerated() { masks[index] = mask(for: character) }
        for (index, character) in right.enumerated() { masks[digitCount - right.count + index] = mask(for: character) }
        return .segmentDisplay(segments: masks, dotsLow: 0, dotsHigh: 0)
    }
}
