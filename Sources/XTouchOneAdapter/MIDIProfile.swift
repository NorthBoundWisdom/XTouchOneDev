import SurfaceDeviceContracts

public enum XTouchOneMIDIMode: String, CaseIterable, Sendable {
    case midi = "Midi"
    case midiRelative = "MidiRel"
    case controlChange = "CChg"
    case controlChangeRelative = "CChgRel"

    var buttonStatus: UInt8 {
        switch self {
        case .midi, .midiRelative: 0x90
        case .controlChange, .controlChangeRelative: 0xB0
        }
    }

    var encoderKind: InputKind {
        switch self {
        case .midi, .controlChange: .absolute
        case .midiRelative, .controlChangeRelative: .relative
        }
    }
}

public struct XTouchOneButton: RawRepresentable, Equatable, Sendable {
    static let addresses: ClosedRange<UInt8> = 0...34
    public let rawValue: UInt8

    public init?(rawValue: UInt8) {
        guard Self.addresses.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var elementID: String { "button.\(rawValue)" }
}

public enum XTouchOneMIDIError: Error, Equatable, Sendable {
    case invalidChannel
    case invalidDataByte
    case invalidLCDLine
    case invalidSegmentDisplay
    case invalidRoute
    case unknownSend
}

enum Address {
    static let fader: UInt8 = 70
    static let touch: UInt8 = 110
    static let encoder: UInt8 = 80
    static let jog: UInt8 = 88
    static let meter: UInt8 = 90
    static let footSwitch: UInt8 = 64
}

enum Element {
    static let fader = "fader"
    static let encoder = "encoder.turn"
    static let jog = "jog"
    static let footSwitch = "foot-switch"
    static let meter = "meter"
    static let lcd = "lcd"
    static let segments = "segment-display"
}

/// A selected fixed MIDI mode and a one-based channel. Selection has no device I/O.
public struct XTouchOneMIDIProfile: Equatable, Sendable {
    public let mode: XTouchOneMIDIMode
    public let channel: UInt8
    var channelNibble: UInt8 { channel - 1 }
    /// Mode and channel select the interpretation, so both belong to the context identity.
    public var contextID: String { "xtouch-one.\(mode.rawValue).ch\(channel)" }

    public init(mode: XTouchOneMIDIMode, channel: UInt8) throws {
        guard (1...16).contains(channel) else { throw XTouchOneMIDIError.invalidChannel }
        self.mode = mode
        self.channel = channel
    }

    /// The subset implemented by the offline adapter: inputs, display effects and the fader's motor target.
    public static func capabilities() throws -> DeviceCapabilities {
        let modes = try XTouchOneMIDIMode.allCases.map { mode in
            let buttonInputs = [InputCapability(kind: .press, valueKind: .flag),
                                InputCapability(kind: .release, valueKind: .flag)]
            let buttons = try XTouchOneButton.addresses.map { address in
                try displayElement(id: "button.\(address)", kind: "button-led", value: .text, inputs: buttonInputs)
            }
            let fader = try ElementCapability(elementID: Element.fader, inputs: [
                InputCapability(kind: .absolute, valueKind: .number),
                InputCapability(kind: .contactBegan, valueKind: .flag),
                InputCapability(kind: .contactEnded, valueKind: .flag),
            ], displays: [], effects: [EffectCapability(kind: "motor-target", classification: .mechanism,
                                                        sideEffects: [])])
            let jog = try ElementCapability(elementID: Element.jog, inputs: [
                InputCapability(kind: .relative, valueKind: .number),
            ], displays: [], effects: [])
            let foot = try ElementCapability(elementID: Element.footSwitch, inputs: buttonInputs,
                                             displays: [], effects: [])
            let encoder = try displayElement(id: Element.encoder, kind: "encoder-ring", value: .number, inputs: [
                InputCapability(kind: mode.encoderKind, valueKind: .number),
            ])
            let displays = try [
                displayElement(id: Element.meter, kind: "meter", value: .number),
                displayElement(id: Element.lcd, kind: "lcd", value: .text),
                displayElement(id: Element.segments, kind: "segment-display", value: .none),
            ]
            return try ProtocolModeCapability(id: mode.rawValue, elements: buttons + [fader, jog, foot, encoder] + displays)
        }
        return try DeviceCapabilities(profileID: "xtouch-one", modes: modes)
    }

    private static func displayElement(id: String, kind: String, value: DeviceValueKind,
                                       inputs: [InputCapability] = []) throws -> ElementCapability {
        try ElementCapability(elementID: id, inputs: inputs,
                              displays: [DisplayCapability(kind: kind, valueKind: value)],
                              effects: [EffectCapability(kind: kind, classification: .display, sideEffects: [])])
    }
}
