import XTouchOneAdapter

public struct XTouchOneSimulatedLCD: Equatable, Sendable {
    public let upper: String
    public let lower: String
    public let color: XTouchOneLCDColor
    public let invertUpper: Bool
    public let invertLower: Bool

    public init(upper: String, lower: String, color: XTouchOneLCDColor, invertUpper: Bool, invertLower: Bool) {
        self.upper = upper
        self.lower = lower
        self.color = color
        self.invertUpper = invertUpper
        self.invertLower = invertLower
    }
}

/// A model of the documented MIDI mode tables, written independently of the adapter's codec.
/// It stands in for the device in offline tests. It is not evidence of how the hardware behaves.
public struct XTouchOneSimulatedDevice: Equatable, Sendable {
    public let mode: XTouchOneMIDIMode
    /// One-based, as shown on the device.
    public let channel: UInt8

    public private(set) var buttonLEDs: [UInt8: XTouchOneButtonLED] = [:]
    public private(set) var encoderRing: UInt8?
    public private(set) var meter: UInt8?
    public private(set) var lcd: XTouchOneSimulatedLCD?
    public private(set) var segments: [UInt8]?
    public private(set) var segmentDots: [UInt8]?
    /// Every CC 70 the device received. The documentation says the motor follows these.
    public private(set) var faderTargets: [UInt8] = []
    public private(set) var ignored: [[UInt8]] = []
    private var encoderValue: UInt8 = 0

    public init(mode: XTouchOneMIDIMode, channel: UInt8) {
        precondition((1...16).contains(channel))
        self.mode = mode
        self.channel = channel
    }

    private var usesNotes: Bool { mode == .midi || mode == .midiRelative }
    private var isRelative: Bool { mode == .midiRelative || mode == .controlChangeRelative }
    private var note: UInt8 { 0x90 | (channel - 1) }
    private var control: UInt8 { 0xB0 | (channel - 1) }

    // MARK: Operator actions. Each returns the bytes the device transmits.

    public func setButton(_ address: UInt8, pressed: Bool) -> [UInt8] {
        precondition(address <= 34)
        return [usesNotes ? note : control, address, pressed ? 127 : 0]
    }

    public func setFootSwitch(pressed: Bool) -> [UInt8] { [control, 64, pressed ? 127 : 0] }
    public func setFaderTouched(_ touched: Bool) -> [UInt8] { [note, 110, touched ? 127 : 0] }
    public func moveFader(to position: UInt8) -> [UInt8] { [control, 70, min(position, 127)] }
    public func turnJog(clockwise: Bool) -> [UInt8] { [control, 88, clockwise ? 65 : 1] }

    public mutating func setEncoder(to position: UInt8) -> [UInt8] {
        guard !isRelative else { return [] }
        encoderValue = min(position, 127)
        return [control, 80, encoderValue]
    }

    /// One detent. Absolute modes report the new value and stop at the ends of the range.
    public mutating func turnEncoder(clockwise: Bool) -> [UInt8] {
        if isRelative { return [control, 80, clockwise ? 65 : 1] }
        if clockwise, encoderValue < 127 { encoderValue += 1 }
        if !clockwise, encoderValue > 0 { encoderValue -= 1 }
        return [control, 80, encoderValue]
    }

    // MARK: Messages from the host.

    public mutating func receive(_ message: [UInt8]) {
        if message.first == 0xF0 {
            if !receiveSystemExclusive(message) { ignored.append(message) }
            return
        }
        guard message.count == 3, message[0] & 0x0F == channel - 1, message[1] < 0x80, message[2] < 0x80 else {
            ignored.append(message)
            return
        }
        let status = message[0] & 0xF0, address = message[1], value = message[2]
        if status == (usesNotes ? 0x90 : 0xB0), address <= 34 {
            // Documented ranges: 0–63 off, 64 flash, 65–127 on.
            buttonLEDs[address] = value < 64 ? .off : value == 64 ? .flash : .on
        } else if status == 0xB0, address == 70 {
            faderTargets.append(value)
        } else if status == 0xB0, address == 80 {
            encoderRing = value
        } else if status == 0xB0, address == 90 {
            meter = value
        } else {
            ignored.append(message)
        }
    }

    private mutating func receiveSystemExclusive(_ message: [UInt8]) -> Bool {
        guard message.count > 7, Array(message.prefix(5)) == [0xF0, 0x00, 0x20, 0x32, 0x41], message.last == 0xF7 else {
            return false
        }
        let body = Array(message[6..<(message.count - 1)])
        guard body.allSatisfy({ $0 < 0x80 }) else { return false }
        switch (message[5], body.count) {
        case (0x4C, 16):
            guard body[0] == 0, body[1] < 0x40, let color = XTouchOneLCDColor(rawValue: body[1] & 0x07) else { return false }
            let text = body[2...].map { Character(UnicodeScalar($0)) }
            lcd = XTouchOneSimulatedLCD(upper: String(text[0..<7]), lower: String(text[7..<14]), color: color,
                                        invertUpper: body[1] & 0x10 != 0, invertLower: body[1] & 0x20 != 0)
        case (0x37, 14):
            segments = Array(body[0..<12])
            segmentDots = Array(body[12...])
        default:
            return false
        }
        return true
    }
}
