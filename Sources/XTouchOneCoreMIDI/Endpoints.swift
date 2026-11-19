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

private func isSetupChange(_ id: MIDINotificationMessageID) -> Bool {
    switch id {
    case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged: true
    default: false
    }
}

/// Receives endpoint-catalogue changes even while no device input port is open.
public final class XTouchOneMIDISetupObserver {
    private var client = MIDIClientRef()

    public init(clientName: String, changed: @escaping @Sendable () -> Void) throws {
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client) { notification in
            if isSetupChange(notification.pointee.messageID) { changed() }
        }, "MIDIClientCreate")
    }

    deinit { if client != 0 { MIDIClientDispose(client) } }
}

/// Endpoint facts as CoreMIDI reports them. Reading them sends nothing to any device.
public struct XTouchOneMIDIEndpoint: Encodable, Equatable, Sendable {
    public enum Direction: String, Encodable, Sendable { case source, destination }

    public let uniqueID: Int32
    public let direction: Direction
    public let name: String
    public let manufacturer: String?
    public let model: String?
    public let deviceID: Int32?
    public let isOffline: Bool
    /// True when no device entity owns the endpoint, as for endpoints created by software.
    public let isVirtual: Bool

    public var isXTouchOne: Bool {
        !isVirtual && manufacturer?.caseInsensitiveCompare("Behringer") == .orderedSame
            && model?.caseInsensitiveCompare("X-Touch One") == .orderedSame
    }

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
        var entity = MIDIEntityRef()
        let hasEntity = MIDIEndpointGetEntity(endpoint, &entity) == noErr && entity != 0
        var device = MIDIDeviceRef()
        var ownerID: Int32 = 0
        uniqueID = id
        self.direction = direction
        name = string(kMIDIPropertyDisplayName) ?? string(kMIDIPropertyName) ?? ""
        manufacturer = string(kMIDIPropertyManufacturer)
        model = string(kMIDIPropertyModel)
        deviceID = hasEntity && MIDIEntityGetDevice(entity, &device) == noErr && device != 0
            && MIDIObjectGetIntegerProperty(device, kMIDIPropertyUniqueID, &ownerID) == noErr ? ownerID : nil
        isVirtual = !hasEntity
        isOffline = Self.offline(endpoint, entity: hasEntity ? entity : 0)
    }

    private static func offline(_ endpoint: MIDIEndpointRef, entity: MIDIEntityRef) -> Bool {
        func flagged(_ object: MIDIObjectRef) -> Bool {
            var value: Int32 = 0
            return MIDIObjectGetIntegerProperty(object, kMIDIPropertyOffline, &value) == noErr && value != 0
        }
        if flagged(endpoint) { return true }
        guard entity != 0 else { return false }
        var device = MIDIDeviceRef()
        return flagged(entity) || (MIDIEntityGetDevice(entity, &device) == noErr && device != 0 && flagged(device))
    }

    static func find(_ uniqueID: Int32, _ direction: Direction) throws -> MIDIEndpointRef {
        let count = direction == .source ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let endpoint = direction == .source ? MIDIGetSource(index) : MIDIGetDestination(index)
            var id: Int32 = 0
            guard endpoint != 0, MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr,
                  id == uniqueID else { continue }
            var entity = MIDIEntityRef()
            if MIDIEndpointGetEntity(endpoint, &entity) != noErr { entity = 0 }
            if !offline(endpoint, entity: entity) { return endpoint }
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
    private let source: MIDIEndpointRef
    private let sourceUniqueID: Int32

    /// Whether the port's original endpoint is still the online source for this ID.
    public var isCurrent: Bool { (try? XTouchOneMIDIEndpoint.find(sourceUniqueID, .source)) == source }

    /// `receive` runs on CoreMIDI's thread, one complete message per call.
    /// `setupChanged` runs on a thread chosen by CoreMIDI whenever the MIDI setup changes.
    public init(sourceUniqueID: Int32, clientName: String, receive: @escaping @Sendable ([UInt8]) -> Void,
                setupChanged: @escaping @Sendable () -> Void = {}) throws {
        self.sourceUniqueID = sourceUniqueID
        source = try XTouchOneMIDIEndpoint.find(sourceUniqueID, .source)
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client) { notification in
            if isSetupChange(notification.pointee.messageID) { setupChanged() }
        }, "MIDIClientCreate")
        do {
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
            client = 0
            throw error
        }
    }

    deinit { if client != 0 { MIDIClientDispose(client) } }
}

/// Follows one source ID even if it is absent at startup. All events run on the main actor.
/// A replacement source gets a fresh input port and packet reader. This class cannot send MIDI.
@MainActor
public final class XTouchOneMIDISourceMonitor {
    public enum Event: Equatable, Sendable {
        case connected(XTouchOneMIDIEndpoint)
        case disconnected
        case input([UInt8])
    }

    private let sourceID: Int32
    private let clientName: String
    private let event: (Event) -> Void
    private var client = MIDIClientRef()
    private var binding: (id: UUID, input: XTouchOneMIDIInput)?
    private var presenceCheck: Task<Void, Never>?
    private var stopped = false
    public private(set) var connectionError: (any Error)?
    public var isCurrent: Bool { binding?.input.isCurrent == true }

    public init(sourceUniqueID: Int32, clientName: String, event: @escaping (Event) -> Void) throws {
        sourceID = sourceUniqueID
        self.clientName = clientName
        self.event = event
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            if isSetupChange(notification.pointee.messageID) {
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        }, "MIDIClientCreate")
        refresh()
        // Notifications can arrive before endpoint properties are visible in enumeration.
        presenceCheck = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    deinit {
        presenceCheck?.cancel()
        if client != 0 { MIDIClientDispose(client) }
    }

    public func stop() {
        stopped = true
        presenceCheck?.cancel()
        binding = nil
    }

    private func refresh() {
        guard !stopped, connectionError == nil, binding?.input.isCurrent != true else { return }
        if binding != nil {
            binding = nil
            event(.disconnected)
        }
        guard !stopped, let endpoint = XTouchOneMIDIEndpoint.all(.source).first(where: {
            $0.uniqueID == sourceID && !$0.isOffline
        }) else { return }
        let id = UUID()
        do {
            let input = try XTouchOneMIDIInput(sourceUniqueID: sourceID, clientName: clientName + " input", receive: { [weak self] bytes in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.binding?.id == id else { return }
                    self.event(.input(bytes))
                }
            })
            binding = (id, input)
            event(.connected(endpoint))
        } catch {
            // A source can go offline while its port is being opened. Retry when the setup changes.
            if (try? XTouchOneMIDIEndpoint.find(sourceID, .source)) != nil { connectionError = error }
        }
    }
}

/// Writes complete messages to exactly one destination chosen by unique ID.
/// It applies no policy of its own: callers pass only what the session's final gate permitted.
public final class XTouchOneMIDIOutput: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let destinationUniqueID: Int32
    private let destination: MIDIEndpointRef

    public var isCurrent: Bool { (try? XTouchOneMIDIEndpoint.find(destinationUniqueID, .destination)) == destination }

    public init(destinationUniqueID: Int32, clientName: String) throws {
        self.destinationUniqueID = destinationUniqueID
        destination = try XTouchOneMIDIEndpoint.find(destinationUniqueID, .destination)
        try check(MIDIClientCreateWithBlock(clientName as CFString, &client, nil), "MIDIClientCreate")
        do {
            try check(MIDIOutputPortCreate(client, "output" as CFString, &port), "MIDIOutputPortCreate")
        } catch {
            MIDIClientDispose(client)
            client = 0
            throw error
        }
    }

    deinit { if client != 0 { MIDIClientDispose(client) } }

    /// Rejects an offline or replaced destination. A fresh binding is required to write again.
    public func write(_ message: [UInt8]) throws {
        guard let words = XTouchOneUniversalPackets.words(for: message), words.count <= 64 else {
            throw XTouchOneCoreMIDIError.notEncodable
        }
        guard isCurrent else { throw XTouchOneCoreMIDIError.endpointNotFound(destinationUniqueID) }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words)
        try check(MIDISendEventList(port, destination, &list), "MIDISendEventList")
    }
}
#endif
