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

/// Where each panel key sits and which documented address the app gives it.
/// The documentation lists addresses 0–34 without tying them to panel labels, so this assignment
/// follows panel order and is a placeholder until the arrival sampling records the real one.
public enum XTouchOnePanelLayout {
    public static let addressesAreProvisional = true

    public static let keys: [XTouchOnePanelKey] = {
        let rows: [(XTouchOnePanelGroup, XTouchOnePanelLight, [String])] = [
            (.channel, .amber, ["BPM/TIME", "MASTER", "SELECT", "MUTE", "SOLO", "REC"]),
            (.function, .amber, ["F1", "F2", "F3", "F4", "F5", "F6"]),
            (.transportModes, .red, ["MARKER", "NUDGE", "CYCLE", "DROP", "REPLACE", "CLICK", "SOLO"]),
            (.transport, .white, ["REW", "FWD", "STOP", "PLAY", "RECORD"]),
            (.bank, .white, ["BANK <", "BANK >", "CH <", "CH >"]),
            (.navigation, .blue, ["UP", "DOWN", "LEFT", "RIGHT", "ZOOM"]),
            (.scrub, .red, ["SCRUB"]),
            (.encoder, .white, ["ENCODER PUSH"]),
        ]
        var keys: [XTouchOnePanelKey] = []
        for (group, light, labels) in rows {
            for label in labels {
                let light: XTouchOnePanelLight = label == "SELECT" ? .green : label == "REC" || label == "RECORD" ? .red : light
                keys.append(.init(id: "\(group.rawValue).\(label)", label: label, group: group, light: light,
                                  address: UInt8(keys.count)))
            }
        }
        return keys
    }()

    public static func keys(in group: XTouchOnePanelGroup) -> [XTouchOnePanelKey] { keys.filter { $0.group == group } }
    public static func key(at address: UInt8) -> XTouchOnePanelKey? { keys.first { $0.address == address } }
}

/// Seven-segment glyphs for the app's own rendering and test patterns: bit 0 is segment a, bit 6 is g.
/// The documentation does not settle the bit order, so this is the app's convention until the device confirms it.
public enum XTouchOneSegmentFont {
    public static let digitCount = 12
    public static let assignmentDigits = 2

    private static let glyphs: [Character: UInt8] = [
        "0": 0x3F, "1": 0x06, "2": 0x5B, "3": 0x4F, "4": 0x66, "5": 0x6D, "6": 0x7D, "7": 0x07, "8": 0x7F, "9": 0x6F,
        " ": 0x00, "-": 0x40, "_": 0x08, "A": 0x77, "b": 0x7C, "C": 0x39, "c": 0x58, "d": 0x5E, "E": 0x79, "F": 0x71,
        "H": 0x76, "h": 0x74, "L": 0x38, "n": 0x54, "o": 0x5C, "P": 0x73, "r": 0x50, "t": 0x78, "U": 0x3E, "u": 0x1C, "y": 0x6E,
    ]

    public static func mask(for character: Character) -> UInt8 {
        glyphs[character] ?? glyphs[Character(character.uppercased())] ?? glyphs[Character(character.lowercased())] ?? 0
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
