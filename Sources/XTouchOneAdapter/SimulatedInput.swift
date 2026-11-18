import SurfaceDeviceContracts

extension XTouchOneMIDIProfile {
    /// Decodes one complete MIDI 1.0 channel message from an offline fixture.
    /// The generation and time come from the simulation caller.
    public func decodeSimulatedInput(_ message: [UInt8], generation: UInt64, at: Double,
                                     mappingRevision: String? = nil) throws -> DeviceInputEvent? {
        guard let input = decodeInput(message) else { return nil }
        let context = try DeviceContext(id: contextID,
                                        generation: String(generation), mappingRevision: mappingRevision)
        let endpoint = try EndpointProvenance(endpointID: nil, deviceID: nil,
                                              connectionGeneration: generation, transportOrigin: .unknown)
        return try DeviceInputEvent(elementID: input.id, kind: input.kind, value: input.value,
                                    context: context, endpoint: endpoint, source: .simulation, at: at)
    }

    /// Device facts only. Callers attach context, endpoint, source and time.
    func decodeInput(_ message: [UInt8]) -> (id: String, kind: InputKind, value: DeviceValue)? {
        guard message.count == 3, message[0] & 0x0F == channelNibble,
              message[1] < 0x80, message[2] < 0x80 else { return nil }
        let status = message[0] & 0xF0
        let address = message[1]
        let data = message[2]

        if status == mode.buttonStatus, let button = XTouchOneButton(rawValue: address),
           let pressed = Self.switchState(data) {
            return (button.elementID, pressed ? .press : .release, .flag(pressed))
        }
        switch (status, address) {
        case (0x90, Address.touch):
            guard let touched = Self.switchState(data) else { return nil }
            return (Element.fader, touched ? .contactBegan : .contactEnded, .flag(touched))
        case (0xB0, Address.fader):
            return (Element.fader, .absolute, .number(Double(data)))
        case (0xB0, Address.encoder):
            if mode.encoderKind == .absolute { return (Element.encoder, .absolute, .number(Double(data))) }
            guard let delta = Self.turnDelta(data) else { return nil }
            return (Element.encoder, .relative, .number(delta))
        case (0xB0, Address.jog):
            guard let delta = Self.turnDelta(data) else { return nil }
            return (Element.jog, .relative, .number(delta))
        case (0xB0, Address.footSwitch):
            guard let pressed = Self.switchState(data) else { return nil }
            return (Element.footSwitch, pressed ? .press : .release, .flag(pressed))
        default:
            return nil
        }
    }

    private static func switchState(_ data: UInt8) -> Bool? {
        switch data {
        case 0: false
        case 127: true
        default: nil
        }
    }

    private static func turnDelta(_ data: UInt8) -> Double? {
        switch data {
        case 65: 1
        case 1: -1
        default: nil
        }
    }
}
