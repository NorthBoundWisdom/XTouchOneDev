import AgentPlugin
import AgentRemoteBinding
import ChassisPlugin
import ChassisRemoteBinding
import Foundation
import OutputRemoteBinding
import ParameterOutputPlugin
import RemoteToolContracts
import RobotPlugin
import RobotRemoteBinding
import SurfacePluginContracts

enum SimulationModule: String {
    case agent = "--agent-sim"
    case robot = "--robot-sim"
    case chassis = "--chassis-sim"
    case output = "--output-sim"
}

struct SimulationModules {
    private var registry: RemoteRegistry
    private let instanceIDs: [String]

    init(_ selections: [SimulationModule]) throws {
        let lifetime = UUID().uuidString.lowercased()
        var registry = try RemoteRegistry(epoch: lifetime)
        var ids: [String] = []
        for module in selections {
            let binding: any RemoteBinding
            switch module {
            case .agent:
                binding = AgentRemoteBinding(instanceID: "agent.default", plugin: try AgentPlugin(approvalPolicy: .interfaceOnly))
            case .robot:
                binding = RobotRemoteBinding(instanceID: RobotRemoteBinding.defaultInstanceID,
                    plugin: try RobotPlugin(instanceID: lifetime + ".robot"))
            case .chassis:
                binding = ChassisRemoteBinding(instanceID: ChassisRemoteBinding.defaultInstanceID,
                    plugin: try ChassisPlugin(instanceID: lifetime + ".chassis"))
            case .output:
                binding = OutputRemoteBinding(instanceID: OutputRemoteBinding.defaultInstanceID,
                    plugin: try ParameterOutputPlugin(limits: [.init(id: "output.value", minimum: 0, maximum: 1,
                        maximumChange: 0.1, maximumVelocity: 0.25)], precision: .float32))
            }
            try registry.install(binding)
            _ = try registry.handle(instanceID: binding.instanceID, input: .start, at: 0)
            ids.append(binding.instanceID)
        }
        self.registry = registry
        instanceIDs = ids
    }

    var tools: [RemoteToolDescriptor] { instanceIDs.isEmpty ? [] : registry.tools }

    mutating func call(_ name: String, arguments: JSONValue, at time: Double) throws -> JSONValue {
        for id in instanceIDs { _ = try registry.handle(instanceID: id, input: .advance, at: time) }
        return try registry.call(name, arguments: arguments,
                                 context: .init(time: time, controlToken: UUID().uuidString, permitsOutputEnable: false))
    }
}
