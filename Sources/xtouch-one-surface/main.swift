import Foundation
import RemoteToolContracts
import SurfaceControlContracts
import SurfacePluginContracts
import XTouchOneAdapter
import XTouchOnePanel
import XTouchOneSurface

@MainActor
private struct ToolServer {
    var simulation: XTouchOneSurfaceSimulation
    let writes: Bool
    let admin: Bool
    var modules: SimulationModules
    #if canImport(CoreMIDI)
    var hardware: HardwareRuntime?
    #endif
    private let start = ProcessInfo.processInfo.systemUptime
    private var initialized = false
    private var ready = false

    init(simulation: XTouchOneSurfaceSimulation, writes: Bool, admin: Bool, modules: SimulationModules) {
        self.simulation = simulation
        self.writes = writes
        self.admin = admin
        self.modules = modules
    }

    private var isHardware: Bool {
        #if canImport(CoreMIDI)
        hardware != nil
        #else
        false
        #endif
    }
    private var descriptors: [RemoteToolDescriptor] {
        SurfaceControlTools.descriptors(source: isHardware ? .hardware : .simulation) + modules.tools
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime - start }

    mutating func handle(_ raw: String) -> JSONValue? {
        guard raw.utf8.count <= 64 * 1024,
              let request = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
            return failure(id: .null, code: -32700, message: "Parse error")
        }
        guard request.value(for: "jsonrpc") == .string("2.0"),
              let method = request.value(for: "method")?.stringValue else {
            return failure(id: .null, code: -32600, message: "Invalid request")
        }
        let id = request.value(for: "id")
        let params = request.value(for: "params") ?? .object([:])
        if id == nil {
            if method == "notifications/initialized", initialized { ready = true }
            return nil
        }
        guard let id, id.stringValue != nil || id.exactIntValue != nil else {
            return failure(id: .null, code: -32600, message: "Invalid request identifier")
        }
        guard params.objectValue != nil else { return failure(id: id, code: -32602, message: "Invalid parameters") }
        if method == "ping" { return success(id: id, result: .object([:])) }
        if method == "initialize", !initialized,
           params.value(for: "protocolVersion")?.stringValue != nil {
            initialized = true
            return success(id: id, result: .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("xtouch-one-surface"), "version": .string("0.1.0")]),
                "instructions": .string(isHardware ? "Read the X-Touch One input stream and write authorized display targets."
                    : "Drive an isolated X-Touch One simulation through stdio.")
            ]))
        }
        guard ready else { return failure(id: id, code: -32002, message: "Server not initialized") }
        switch method {
        case "tools/list":
            let tools: [JSONValue] = descriptors.map { descriptor in
                .object(["name": .string(descriptor.name), "inputSchema": descriptor.inputSchema,
                         "outputSchema": descriptor.outputSchema,
                         "annotations": .object(["readOnlyHint": .bool(!descriptor.isMutation)])])
            }
            return success(id: id, result: .object(["tools": .array(tools)]))
        case "tools/call":
            guard let name = params.value(for: "name")?.stringValue,
                  let descriptor = descriptors.first(where: { $0.name == name }) else {
                return failure(id: id, code: -32602, message: "Unknown tool")
            }
            do {
                let args = params.value(for: "arguments") ?? .object([:])
                if descriptor.isMutation && !writes { throw ControlContractError("permission_denied") }
                let value: JSONValue
                if SurfaceControlTools.descriptors.contains(where: { $0.name == name }) {
                    value = try call(SurfaceControlTools.parse(name, arguments: args))
                } else {
                    value = try modules.call(name, arguments: args, at: now)
                }
                return success(id: id, result: try toolResult(value, error: false))
            } catch {
                let code = (error as? ControlContractError)?.code ?? RemoteFailure.from(error).code
                let value = JSONValue.object(["code": .string(code)])
                return success(id: id, result: (try? toolResult(value, error: true)) ?? .object(["isError": .bool(true)]))
            }
        default: return failure(id: id, code: -32601, message: "Method not found")
        }
    }

    private mutating func call(_ request: ControlToolRequest) throws -> JSONValue {
        #if canImport(CoreMIDI)
        if let hardware { return try hardware.call(request) }
        #endif
        let time = now
        try simulation.expireHolds(at: time)
        switch request {
        case .discover: return try encode(simulation.controls.discovery())
        case .snapshot(let instanceID):
            guard instanceID == simulation.controls.expected.instance_id else { throw ControlContractError("instance_mismatch") }
            return try encode(simulation.controls.snapshot(at: time))
        case .events(let instanceID, let epoch, let sequence, let limit):
            return try encode(simulation.controls.events(instanceID: instanceID, epoch: epoch, afterSequence: sequence, limit: limit, at: time))
        case .input(let input): return try encode(simulation.input(input, at: time))
        case .feedback(let feedback): return try encode(simulation.feedback(feedback, at: time))
        case .renew(let renew): return try encode(simulation.renew(renew, at: time))
        case .reset(let expected, let sequence):
            guard admin else { throw ControlContractError("permission_denied") }
            try simulation.reset(expected: expected, sequence: sequence, newEpoch: UUID().uuidString.lowercased())
            return try encode(simulation.controls.discovery())
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func toolResult(_ value: JSONValue, error: Bool) throws -> JSONValue {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        var content: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(error),
        ]
        if !error { content["structuredContent"] = value }
        return .object(content)
    }

    private func success(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func failure(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(code), "message": .string(message)])])
    }
}

private let usage = "usage: xtouch-one-surface [--mode Midi|MidiRel|CChg|CChgRel] [--channel 1-16] [--configuration <json>] [--write [--admin]] [--agent-sim] [--robot-sim] [--chassis-sim] [--output-sim] [--hardware-input <id> [--hardware-output <id> --write]]"

@MainActor
private func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] { FileHandle.standardError.write(Data((usage + "\n").utf8)); return }
    var mode = XTouchOneMIDIMode.midi
    var channel: UInt8 = 1
    var configuration = XTouchOneConfiguration.standard
    var writes = false, admin = false
    var inputID: Int32?, outputID: Int32?
    var seen: Set<String> = []
    var modules: [SimulationModule] = []
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        guard seen.insert(flag).inserted else { throw ControlContractError("invalid_argument") }
        if let module = SimulationModule(rawValue: flag) { modules.append(module); continue }
        switch flag {
        case "--write": writes = true
        case "--admin": admin = true
        case "--mode", "--channel", "--configuration", "--hardware-input", "--hardware-output":
            guard !arguments.isEmpty else { throw ControlContractError("invalid_argument") }
            let value = arguments.removeFirst()
            switch flag {
            case "--mode":
                guard let selected = XTouchOneMIDIMode(rawValue: value) else { throw ControlContractError("invalid_argument") }
                mode = selected
            case "--channel":
                guard let selected = UInt8(value) else { throw ControlContractError("invalid_argument") }
                channel = selected
            case "--hardware-input", "--hardware-output":
                guard let id = Int32(value), id != 0 else { throw ControlContractError("invalid_argument") }
                if flag == "--hardware-input" { inputID = id } else { outputID = id }
            default:
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: value))
                defer { try? file.close() }
                configuration = try XTouchOneConfiguration.decode(file.read(upToCount: XTouchOneConfiguration.maximumBytes + 1) ?? Data())
            }
        default: throw ControlContractError("invalid_argument")
        }
    }
    guard writes || !admin, outputID == nil || inputID != nil else { throw ControlContractError("invalid_argument") }
    if inputID != nil {
        guard !admin, modules.isEmpty, !seen.contains("--configuration"), writes == (outputID != nil) else {
            throw ControlContractError("invalid_argument")
        }
        #if !canImport(CoreMIDI)
        throw ControlContractError("hardware_requires_macos")
        #endif
    }
    let profile = try XTouchOneMIDIProfile(mode: mode, channel: channel)
    let simulation = try XTouchOneSurfaceSimulation(instanceID: UUID().uuidString.lowercased(), epoch: UUID().uuidString.lowercased(),
                                                   profile: profile, configuration: configuration)
    var server = ToolServer(simulation: simulation, writes: writes, admin: admin, modules: try SimulationModules(modules))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func handle(_ line: String) throws {
        guard let response = server.handle(line) else { return }
        var bytes = try encoder.encode(response)
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
    #if canImport(CoreMIDI)
    if let inputID {
        let hardware = try HardwareRuntime(profile: profile, inputID: inputID, outputID: outputID)
        defer { hardware.stop() }
        server.hardware = hardware
        try runHardwareRequests(handle: handle, failure: { hardware.failure })
        return
    }
    #endif
    while let line = readLine() { try handle(line) }
}

do { try run() }
catch {
    FileHandle.standardError.write(Data(("xtouch-one-surface: \(error)\n" + usage + "\n").utf8))
    exit(2)
}
