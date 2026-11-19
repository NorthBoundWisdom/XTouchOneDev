#if canImport(CoreMIDI)
import Darwin
import Dispatch
import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import XTouchOneAdapter
import XTouchOneCoreMIDI
import XTouchOnePanel
import XTouchOneSurface

/// Local stdio projection of the existing hardware adapter. No command here can address a fader motor.
@MainActor
final class HardwareRuntime {
    private var surface: XTouchOneHardwareSurface
    private let outputID: Int32?
    private let outputDeviceID: Int32?
    private var monitor: XTouchOneMIDISourceMonitor?
    private var output: XTouchOneMIDIOutput?
    private var lastWriteAt: Double?
    private(set) var error: (any Error)?

    init(profile: XTouchOneMIDIProfile, inputID: Int32, outputID: Int32?) throws {
        self.outputID = outputID
        if let outputID {
            guard let endpoint = XTouchOneMIDIEndpoint.all(.destination).first(where: {
                $0.uniqueID == outputID && !$0.isOffline && $0.isXTouchOne
            }), let owner = endpoint.deviceID else { throw ControlContractError("invalid_argument") }
            outputDeviceID = owner
            output = try XTouchOneMIDIOutput(destinationUniqueID: outputID, clientName: "xtouch-one-surface")
        } else {
            outputDeviceID = nil
        }

        surface = try XTouchOneHardwareSurface(instanceID: UUID().uuidString, epoch: UUID().uuidString, profile: profile,
            displayRate: XTouchOneConsole.hardwareDisplayRate, outputPolicy: outputID == nil ? .observe : .write,
            hardwareWriterID: "hardware.input", remoteWriterID: "hardware.stdio")
        monitor = try XTouchOneMIDISourceMonitor(sourceUniqueID: inputID, clientName: "xtouch-one-surface") { [weak self] event in
            self?.receive(event)
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func receive(_ event: XTouchOneMIDISourceMonitor.Event) {
        do {
            switch event {
            case .connected(let endpoint):
                guard endpoint.isXTouchOne, let owner = endpoint.deviceID,
                      outputDeviceID == nil || outputDeviceID == owner else { throw ControlContractError("invalid_argument") }
                let route = try XTouchOneRoute(inputID: String(endpoint.uniqueID), outputID: outputID.map(String.init) ?? "not-opened",
                                              deviceID: String(owner), transportOrigin: .physicalUSB)
                try surface.transition(epoch: UUID().uuidString, route: route, at: now)
            case .disconnected:
                output = nil
                try surface.transition(epoch: UUID().uuidString, route: nil, at: now)
            case .input(let message):
                try surface.receive(message, at: now)
            }
        } catch { self.error = error }
    }

    var failure: (any Error)? { error ?? monitor?.connectionError }

    func stop() {
        monitor?.stop()
        output = nil
    }

    func call(_ request: ControlToolRequest) throws -> JSONValue {
        if let failure { throw failure }
        let time = now
        if output?.isCurrent == false { output = nil }
        switch request {
        case .discover:
            return try .encoded(surface.controls.discovery())
        case .snapshot(let instanceID):
            guard instanceID == surface.controls.expected.instance_id else { throw ControlContractError("instance_mismatch") }
            return try .encoded(surface.controls.snapshot(at: time))
        case .events(let instanceID, let epoch, let sequence, let limit):
            return try .encoded(surface.controls.events(instanceID: instanceID, epoch: epoch, afterSequence: sequence, limit: limit, at: time))
        case .input, .renew, .reset:
            throw ControlContractError("permission_denied")
        case .feedback(let update):
            guard let output, output.isCurrent, monitor?.isCurrent == true else { throw ControlContractError("permission_denied") }
            // A direct request is one write. Unattended services pace writes independently of the display queue.
            guard lastWriteAt.map({ time - $0 >= 0.02 }) ?? true else { throw ControlContractError("rate_limited") }
            let send = try surface.issueDisplay(update, allowed: true, at: time)
            guard surface.preflight(send) == .permitted else {
                return try .encoded(surface.completeDisplay(send, for: update, result: .notAttempted(reason: "not permitted"), at: time))
            }
            lastWriteAt = time
            do {
                try output.write(send.bytes)
            } catch {
                return try .encoded(surface.completeDisplay(send, for: update, result: .rejected(reason: "transport failed"), at: time))
            }
            return try .encoded(surface.completeDisplay(send, for: update, result: .accepted, at: time))
        }
    }
}

/// Drain stdin on the CoreMIDI actor without blocking delivery of physical input.
@MainActor
func runHardwareRequests(handle: @escaping (String) throws -> Void, failure: () -> (any Error)?) throws {
    let reader = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    var bytes = [UInt8](repeating: 0, count: 4096)
    var line: [UInt8] = []
    var oversized = false
    var done = false
    var inputError: (any Error)?
    reader.setEventHandler {
        MainActor.assumeIsolated {
            guard !done, inputError == nil else { return }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno != EINTR { inputError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return
            }
            do {
                if count == 0 {
                    if !line.isEmpty || oversized { try handle(oversized ? "" : String(decoding: line, as: UTF8.self)) }
                    done = true
                } else {
                    for byte in bytes.prefix(count) {
                        if byte == 10 {
                            try handle(oversized ? "" : String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                            oversized = false
                        } else if line.count < 64 * 1024 {
                            line.append(byte)
                        } else {
                            oversized = true
                        }
                    }
                }
            } catch { inputError = error }
        }
    }
    reader.resume()
    defer { reader.cancel() }
    while !done, inputError == nil, failure() == nil {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if let error = inputError ?? failure() { throw error }
}
#endif
