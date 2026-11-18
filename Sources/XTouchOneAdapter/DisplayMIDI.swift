public enum XTouchOneButtonLED: UInt8, Sendable {
    case off = 0
    case flash = 64
    case on = 127
}

public enum XTouchOneLCDColor: UInt8, Sendable {
    case black, red, green, yellow, blue, magenta, cyan, white
}

public enum XTouchOneDisplay: Equatable, Sendable {
    case buttonLED(XTouchOneButton, XTouchOneButtonLED)
    case encoderRing(UInt8)
    case meter(UInt8)
    case lcd(upper: String, lower: String, color: XTouchOneLCDColor, invertUpper: Bool, invertLower: Bool)
    case segmentDisplay(segments: [UInt8], dotsLow: UInt8, dotsHigh: UInt8)
}

extension XTouchOneDisplay {
    /// The stable display target, also used as the repaint queue key.
    public var targetID: String {
        switch self {
        case .buttonLED(let button, _): button.elementID
        case .encoderRing: Element.encoder
        case .meter: Element.meter
        case .lcd: Element.lcd
        case .segmentDisplay: Element.segments
        }
    }
}

extension XTouchOneMIDIProfile {
    /// The final wire check: true only for the display messages this adapter encodes.
    /// A fader target (CC 70) is never a display payload in any mode.
    func isDisplayPayload(_ bytes: [UInt8]) -> Bool {
        if bytes.first == 0xF0 {
            let header: [UInt8] = [0xF0, 0x00, 0x20, 0x32, 0x41]
            guard bytes.count > 7, Array(bytes.prefix(5)) == header, bytes.last == 0xF7,
                  bytes.dropFirst().dropLast().allSatisfy({ $0 < 0x80 }) else { return false }
            return (bytes[5] == 0x4C && bytes.count == 23) || (bytes[5] == 0x37 && bytes.count == 21)
        }
        guard bytes.count == 3, bytes[0] & 0x0F == channelNibble, bytes[1] < 0x80, bytes[2] < 0x80 else { return false }
        let status = bytes[0] & 0xF0
        if status == mode.buttonStatus, XTouchOneButton(rawValue: bytes[1]) != nil { return true }
        return status == 0xB0 && (bytes[1] == Address.encoder || bytes[1] == Address.meter)
    }

    /// Builds a complete display message in memory for offline inspection.
    public func encodeDisplay(_ display: XTouchOneDisplay) throws -> [UInt8] {
        switch display {
        case .buttonLED(let button, let state):
            return [mode.buttonStatus | channelNibble, button.rawValue, state.rawValue]
        case .encoderRing(let value):
            return try displayCC(Address.encoder, value)
        case .meter(let value):
            return try displayCC(Address.meter, value)
        case .lcd(let upper, let lower, let color, let invertUpper, let invertLower):
            let flags = color.rawValue | (invertUpper ? 0x10 : 0) | (invertLower ? 0x20 : 0)
            let lines = try Self.lcdLine(upper) + Self.lcdLine(lower)
            return [0xF0, 0x00, 0x20, 0x32, 0x41, 0x4C, 0x00, flags] + lines + [0xF7]
        case .segmentDisplay(let segments, let dotsLow, let dotsHigh):
            guard segments.count == 12, segments.allSatisfy({ $0 < 0x80 }),
                  dotsLow < 0x80, dotsHigh < 0x20 else { throw XTouchOneMIDIError.invalidSegmentDisplay }
            return [0xF0, 0x00, 0x20, 0x32, 0x41, 0x37] + segments + [dotsLow, dotsHigh, 0xF7]
        }
    }

    private func displayCC(_ address: UInt8, _ value: UInt8) throws -> [UInt8] {
        guard value < 0x80 else { throw XTouchOneMIDIError.invalidDataByte }
        return [0xB0 | channelNibble, address, value]
    }

    private static func lcdLine(_ text: String) throws -> [UInt8] {
        let bytes = text.utf8.prefix(8)
        guard bytes.count <= 7, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw XTouchOneMIDIError.invalidLCDLine
        }
        return Array(bytes) + Array(repeating: 0x20, count: 7 - bytes.count)
    }
}
