#if canImport(CoreMIDI)
import CoreMIDI
import Foundation

public enum XTouchOneCoreMIDIError: Error, Equatable, Sendable {
    case status(String, Int32)
    case endpointNotFound(Int32)
    case notEncodable
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw XTouchOneCoreMIDIError.status(operation, status) }
}

/// Endpoint facts as CoreMIDI reports them. Reading them sends nothing to any device.
public struct XTouchOneMIDIEndpoint: Equatable, Sendable {
    public enum Direction: String, Sendable { case source, destination }

    public let uniqueID: Int32
    public let direction: Direction
    public let name: String
    public let manufacturer: String?
    public let model: String?
    public let isOffline: Bool
    /// True when no device entity owns the endpoint, as for endpoints created by software.
    public let isVirtual: Bool

    public static func all(_ direction: Direction) -> [XTouchOneMIDIEndpoint] {
        let count = direction == .source ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        return (0..<count).compactMap { index in
            let endpoint = direction == .source ? MIDIGetSource(index) : MIDIGetDestination(index)
            return endpoint == 0 ? nil : XTouchOneMIDIEndpoint(endpoint, direction)
        }
    }

    init?(_ endpoint: MIDIEndpointRef, _ direction: Direction) {
        var id: Int32 = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
        func string(_ property: CFString) -> String? {
            var value: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(endpoint, property, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
        var entity = MIDIEntityRef()
        uniqueID = id
        self.direction = direction
        name = string(kMIDIPropertyDisplayName) ?? string(kMIDIPropertyName) ?? ""
        manufacturer = string(kMIDIPropertyManufacturer)
        model = string(kMIDIPropertyModel)
        isOffline = offline != 0
        isVirtual = MIDIEndpointGetEntity(endpoint, &entity) != noErr || entity == 0
    }

    static func find(_ uniqueID: Int32, _ direction: Direction) throws -> MIDIEndpointRef {
        let count = direction == .source ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let endpoint = direction == .source ? MIDIGetSource(index) : MIDIGetDestination(index)
            var id: Int32 = 0
            if MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr, id == uniqueID {
                return endpoint
            }
        }
        throw XTouchOneCoreMIDIError.endpointNotFound(uniqueID)
    }
}

private final class ReaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reader = XTouchOneUniversalPackets.Reader()
    func messages(from words: [UInt32]) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return reader.messages(from: words)
    }
}

/// Listens to exactly one source chosen by unique ID. It creates no output port and cannot send.
public final class XTouchOneMIDIInput: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    /// `receive` runs on CoreMIDI's thread, one complete message per call.
    /// `setupChanged` runs on the creating thread's run loop whenever the MIDI setup changes.
    public init(sourceUniqueID: Int32, clientName: String, receive: @escaping @Sendable ([UInt8]) -> Void,
                setupChanged: @escaping @Sendable () -> Void = {}) throws {
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client) { notification in
            let id = notification.pointee.messageID
            if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved { setupChanged() }
        }, "MIDIClientCreate")
        do {
            let source = try XTouchOneMIDIEndpoint.find(sourceUniqueID, .source)
            let box = ReaderBox()
            try check(MIDIInputPortCreateWithProtocol(client, "input" as CFString, ._1_0, &port) { list, _ in
                for packet in list.unsafeSequence() {
                    let count = Int(packet.pointee.wordCount)
                    let words = withUnsafeBytes(of: packet.pointee.words) {
                        Array($0.bindMemory(to: UInt32.self).prefix(count))
                    }
                    for message in box.messages(from: words) { receive(message) }
                }
            }, "MIDIInputPortCreate")
            try check(MIDIPortConnectSource(port, source, nil), "MIDIPortConnectSource")
        } catch {
            MIDIClientDispose(client)
            throw error
        }
    }

    deinit { MIDIClientDispose(client) }
}

/// Writes complete messages to exactly one destination chosen by unique ID.
/// It applies no policy of its own: callers pass only what the session's final gate permitted.
public final class XTouchOneMIDIOutput: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let destinationUniqueID: Int32

    public init(destinationUniqueID: Int32, clientName: String) throws {
        self.destinationUniqueID = destinationUniqueID
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client, nil), "MIDIClientCreate")
        do {
            _ = try XTouchOneMIDIEndpoint.find(destinationUniqueID, .destination)
            try check(MIDIOutputPortCreate(client, "output" as CFString, &port), "MIDIOutputPortCreate")
        } catch {
            MIDIClientDispose(client)
            throw error
        }
    }

    deinit { MIDIClientDispose(client) }

    /// The destination is looked up again on every write, so a replaced endpoint is never written by a stale reference.
    public func write(_ message: [UInt8]) throws {
        guard let words = XTouchOneUniversalPackets.words(for: message), words.count <= 64 else {
            throw XTouchOneCoreMIDIError.notEncodable
        }
        let destination = try XTouchOneMIDIEndpoint.find(destinationUniqueID, .destination)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words)
        try check(MIDISendEventList(port, destination, &list), "MIDISendEventList")
    }
}
#endif
