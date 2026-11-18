import SurfaceDeviceContracts

/// Tallies which documented inputs a capture actually contained, for the arrival sampling pass.
/// It reviews recorded messages only and concludes nothing about hardware qualification.
public struct XTouchOneInputCoverage: Equatable, Sendable {
    public static let unrecognizedLimit = 64

    public let profile: XTouchOneMIDIProfile
    public private(set) var seen: Set<String> = []
    /// One-based channels of channel messages that arrived outside the selected channel.
    public private(set) var otherChannels: Set<UInt8> = []
    /// The first distinct messages the selected mode does not document.
    public private(set) var unrecognized: [[UInt8]] = []
    public private(set) var unrecognizedCount = 0
    private var lastEncoderValue: Double?

    public init(profile: XTouchOneMIDIProfile) { self.profile = profile }

    /// Every item a complete sampling pass shows, in a stable order.
    public var required: [String] {
        let edges = ["press", "release"]
        let turns = profile.mode.encoderKind == .relative ? ["+1", "-1"] : ["increase", "decrease"]
        return XTouchOneButton.addresses.flatMap { address in edges.map { "button.\(address):\($0)" } }
            + edges.map { "\(Element.footSwitch):\($0)" }
            + ["contactBegan", "contactEnded", "min", "max"].map { "\(Element.fader):\($0)" }
            + turns.map { "\(Element.encoder):\($0)" }
            + ["+1", "-1"].map { "\(Element.jog):\($0)" }
    }

    public var missing: [String] { required.filter { !seen.contains($0) } }

    public mutating func record(_ message: [UInt8]) {
        guard let input = profile.decodeInput(message) else {
            unrecognizedCount += 1
            if message.count == 3, (0x80...0xEF).contains(message[0]), message[0] & 0x0F != profile.channel - 1 {
                otherChannels.insert((message[0] & 0x0F) + 1)
            }
            if unrecognized.count < Self.unrecognizedLimit, !unrecognized.contains(message) {
                unrecognized.append(message)
            }
            return
        }
        guard case .number(let number) = input.value else {
            seen.insert("\(input.id):\(input.kind.rawValue)")
            return
        }
        if input.kind == .relative {
            seen.insert("\(input.id):\(number > 0 ? "+1" : "-1")")
        } else if input.id == Element.fader {
            if number == 0 { seen.insert("\(input.id):min") }
            if number == 127 { seen.insert("\(input.id):max") }
        } else {
            if let last = lastEncoderValue, number != last {
                seen.insert("\(input.id):\(number > last ? "increase" : "decrease")")
            }
            lastEncoderValue = number
        }
    }
}
