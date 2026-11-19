#if canImport(CoreMIDI)
import CoreMIDI
import Foundation
import Testing
import XTouchOneCoreMIDI

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[UInt8]] = []
    func add(_ message: [UInt8]) { lock.withLock { stored.append(message) } }
    func wait(for count: Int) async throws -> [[UInt8]] {
        for _ in 0..<200 {
            let current = lock.withLock { stored }
            if current.count >= count { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { stored }
    }
}

private func uniqueID(_ endpoint: MIDIEndpointRef) -> Int32 {
    var id: Int32 = 0
    MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
    return id
}

/// Uses only virtual endpoints this test creates. It never opens an endpoint it did not create.
/// Off by default because hosted runners do not guarantee a MIDI server.
@Test(.enabled(if: ProcessInfo.processInfo.environment["XTOUCH_ONE_COREMIDI_TESTS"] == "1"))
func ownedVirtualEndpointsCarryMessagesBothWays() async throws {
    let tag = "xtouch-one-test-\(ProcessInfo.processInfo.processIdentifier)"
    var client = MIDIClientRef()
    #expect(MIDIClientCreateWithBlock(tag as CFString, &client, nil) == noErr)
    defer { MIDIClientDispose(client) }

    let arrived = Collector()
    var destination = MIDIEndpointRef()
    #expect(MIDIDestinationCreateWithProtocol(client, "\(tag)-out" as CFString, ._1_0, &destination) { list, _ in
        var reader = XTouchOneUniversalPackets.Reader()
        for packet in list.unsafeSequence() {
            let words = withUnsafeBytes(of: packet.pointee.words) {
                Array($0.bindMemory(to: UInt32.self).prefix(Int(packet.pointee.wordCount)))
            }
            for message in reader.messages(from: words) { arrived.add(message) }
        }
    } == noErr)
    var source = MIDIEndpointRef()
    #expect(MIDISourceCreateWithProtocol(client, "\(tag)-in" as CFString, ._1_0, &source) == noErr)

    let listed = XTouchOneMIDIEndpoint.all(.destination).first { $0.uniqueID == uniqueID(destination) }
    #expect(listed?.name == "\(tag)-out" && listed?.isVirtual == true && listed?.direction == .destination)

    let lcd: [UInt8] = [0xF0, 0, 0x20, 0x32, 0x41, 0x4C, 0, 2] + Array("Hello  World  ".utf8) + [0xF7]
    let output = try XTouchOneMIDIOutput(destinationUniqueID: uniqueID(destination), clientName: "\(tag)-writer")
    try output.write([0x90, 3, 127])
    try output.write(lcd)
    #expect(try await arrived.wait(for: 2) == [[0x90, 3, 127], lcd])
    #expect(throws: XTouchOneCoreMIDIError.notEncodable) { try output.write([0xF8]) }

    let destinationID = uniqueID(destination)
    try checkStatus(MIDIEndpointDispose(destination))
    var replacement = MIDIEndpointRef()
    try checkStatus(MIDIDestinationCreateWithProtocol(client, "\(tag)-replacement" as CFString, ._1_0, &replacement) { _, _ in
        arrived.add([])
    })
    try checkStatus(MIDIObjectSetIntegerProperty(replacement, kMIDIPropertyUniqueID, destinationID))
    #expect(!output.isCurrent)
    #expect(throws: XTouchOneCoreMIDIError.endpointNotFound(destinationID)) { try output.write([0x90, 3, 0]) }
    let freshOutput = try XTouchOneMIDIOutput(destinationUniqueID: destinationID, clientName: "\(tag)-fresh")
    try freshOutput.write([0x90, 3, 127])
    #expect(try await arrived.wait(for: 3) == [[0x90, 3, 127], lcd, []])

    let received = Collector()
    let input = try XTouchOneMIDIInput(sourceUniqueID: uniqueID(source), clientName: "\(tag)-reader") { received.add($0) }
    for message: [UInt8] in [[0xB0, 70, 64], [0x90, 110, 127]] {
        let words = try #require(XTouchOneUniversalPackets.words(for: message))
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words)
        #expect(MIDIReceivedEventList(source, &list) == noErr)
    }
    #expect(try await received.wait(for: 2) == [[0xB0, 70, 64], [0x90, 110, 127]])
    withExtendedLifetime(input) {}

    #expect(throws: XTouchOneCoreMIDIError.endpointNotFound(1)) {
        try XTouchOneMIDIOutput(destinationUniqueID: 1, clientName: "\(tag)-missing")
    }
    #expect(throws: XTouchOneCoreMIDIError.endpointNotFound(1)) {
        try XTouchOneMIDIInput(sourceUniqueID: 1, clientName: "\(tag)-missing") { _ in }
    }
}

/// The CLI can start before a source is present and continue after CoreMIDI replaces its port.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["XTOUCH_ONE_COREMIDI_TESTS"] == "1"))
func monitorFollowsReplacementOfAnInitiallyMissingVirtualSource() async throws {
    let tag = "xtouch-one-hotplug-\(ProcessInfo.processInfo.processIdentifier)"
    var client = MIDIClientRef()
    try checkStatus(MIDIClientCreateWithBlock(tag as CFString, &client, nil))
    defer { MIDIClientDispose(client) }

    let usedIDs = Set(XTouchOneMIDIEndpoint.all(.source).map(\.uniqueID))
    let id = try #require((-1000 ... -1).first { !usedIDs.contains($0) })
    var events: [XTouchOneMIDISourceMonitor.Event] = []
    let monitor = try XTouchOneMIDISourceMonitor(sourceUniqueID: id, clientName: tag) { events.append($0) }
    defer { monitor.stop() }
    #expect(events.isEmpty)

    func makeSource(_ suffix: String) throws -> MIDIEndpointRef {
        var source = MIDIEndpointRef()
        try checkStatus(MIDISourceCreateWithProtocol(client, "\(tag)-\(suffix)" as CFString, ._1_0, &source))
        try checkStatus(MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, id))
        return source
    }

    func send(_ words: [UInt32], to source: MIDIEndpointRef) throws {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, words)
        try checkStatus(MIDIReceivedEventList(source, &list))
    }

    func wait(for count: Int) async throws {
        for _ in 0..<200 where events.count < count { try await Task.sleep(for: .milliseconds(10)) }
        try #require(events.count == count, "events: \(events), connection error: \(String(describing: monitor.connectionError))")
    }

    let first = try makeSource("first")
    try await wait(for: 1)
    let firstInfo = try #require(XTouchOneMIDIEndpoint.all(.source).first { $0.uniqueID == id })
    #expect(events == [.connected(firstInfo)])
    let press: [UInt8] = [0x90, 2, 127]
    try send(try #require(XTouchOneUniversalPackets.words(for: press)), to: first)
    try await wait(for: 2)
    try checkStatus(MIDIEndpointDispose(first))
    try await wait(for: 3)

    let second = try makeSource("second")
    defer { MIDIEndpointDispose(second) }
    try await wait(for: 4)
    let secondInfo = try #require(XTouchOneMIDIEndpoint.all(.source).first { $0.uniqueID == id })
    let release: [UInt8] = [0x90, 2, 0]
    try send(try #require(XTouchOneUniversalPackets.words(for: release)), to: second)
    try await wait(for: 5)
    #expect(events == [.connected(firstInfo), .input(press), .disconnected, .connected(secondInfo), .input(release)])
    #expect(monitor.connectionError == nil)
}

private func checkStatus(_ status: OSStatus) throws {
    try #require(status == noErr)
}
#endif
