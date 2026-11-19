import Foundation
import SurfaceDeviceContracts
import SurfacePluginContracts

public enum XTouchOneWorkspaceError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleConfiguration, invalidName, duplicateParameter, unknownParameter, invalidBinding, invalidProgram
    case invalidScene, missingEntry, fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .incompatibleConfiguration: "配置的版本或设备型号不匹配。"
        case .invalidName: "请输入名称。"
        case .duplicateParameter: "参数 ID 重复。"
        case .unknownParameter: "参数不存在。"
        case .invalidBinding: "此控件和分配方式无法配对。"
        case .invalidProgram: "宏或按键操作中有无效的步骤。"
        case .invalidScene: "场景包含无效的参数值。"
        case .missingEntry: "找不到所选条目。"
        case .fileTooLarge: "配置文件超过 4 MiB。"
        }
    }
}

public enum XTouchOneParameterAction: Equatable, Codable, Sendable {
    case set(ParameterID, Double)
    case step(ParameterID, Double)
    case toggle(ParameterID)
    case cycle(ParameterID, [Double])
    case resetGroup(String)

    var parameterID: ParameterID? {
        switch self {
        case .set(let id, _), .step(let id, _), .toggle(let id), .cycle(let id, _): id
        case .resetGroup: nil
        }
    }
}

public enum XTouchOneBinding: Equatable, Codable, Sendable {
    case parameter(ParameterID)
    case action(XTouchOneParameterAction)
    case program(String)
    case agent(Int)
}

public struct XTouchOneControlLabel: Equatable, Codable, Sendable {
    public var name: String
    public var color: XTouchOneControlColor?
    public init(name: String, color: XTouchOneControlColor? = nil) { self.name = name; self.color = color }
}

public enum XTouchOneControlColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, gray
}

public struct XTouchOneConfiguration: Equatable, Codable, Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public static let deviceName = "X-TOUCH ONE"
    public var version: Int = 1
    public var device: String = Self.deviceName
    public var parameters: [ParameterDefinition]
    public var bindings: [String: XTouchOneBinding]
    public var labels: [String: XTouchOneControlLabel]
    public var programs: [String: [XTouchOneParameterAction]]
    public var scenes: [String: [ParameterID: Double]]

    public init(parameters: [ParameterDefinition] = [], bindings: [String: XTouchOneBinding] = [:],
                labels: [String: XTouchOneControlLabel] = [:], programs: [String: [XTouchOneParameterAction]] = [:],
                scenes: [String: [ParameterID: Double]] = [:]) {
        self.parameters = parameters
        self.bindings = bindings
        self.labels = labels
        self.programs = programs
        self.scenes = scenes
    }

    public static var standard: Self {
        let ids: [ParameterID] = ["level", "encoder", "jog"]
        let names = ["推子", "编码器", "拨轮"]
        let definitions = zip(ids, names).map { id, name in
            try! ParameterDefinition(id: id, nameKey: name, group: "主控", minimum: 0, maximum: 127, defaultValue: 0, step: 1)
        }
        return Self(parameters: definitions, bindings: ["fader": .parameter("level"),
            "encoder.turn": .parameter("encoder"), "jog": .parameter("jog")])
    }

    public static let valueControls = ["fader", "encoder.turn", "jog"]
    public static var triggerControls: [String] { (0...34).map { "button.\($0)" } + ["foot-switch"] }
    public static var controls: [String] { valueControls + triggerControls }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw XTouchOneWorkspaceError.fileTooLarge }
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate()
        return configuration
    }

    public func validate() throws {
        guard version == 1, device == Self.deviceName else { throw XTouchOneWorkspaceError.incompatibleConfiguration }
        let ids = Set(parameters.map(\.id))
        guard ids.count == parameters.count else { throw XTouchOneWorkspaceError.duplicateParameter }
        for (name, actions) in programs {
            guard Self.valid(name), (1...64).contains(actions.count),
                  actions.allSatisfy({ valid($0, parameters: ids) }) else { throw XTouchOneWorkspaceError.invalidProgram }
        }
        for (control, binding) in bindings {
            switch binding {
            case .parameter(let id):
                guard Self.valueControls.contains(control), ids.contains(id) else { throw XTouchOneWorkspaceError.invalidBinding }
            case .action(let action):
                guard Self.triggerControls.contains(control), valid(action, parameters: ids) else {
                    throw XTouchOneWorkspaceError.invalidBinding
                }
            case .program(let name):
                guard Self.triggerControls.contains(control), programs[name] != nil else { throw XTouchOneWorkspaceError.invalidBinding }
            case .agent(let slot):
                guard Self.triggerControls.contains(control), (1...8).contains(slot) else { throw XTouchOneWorkspaceError.invalidBinding }
            }
        }
        guard labels.allSatisfy({ Self.controls.contains($0.key) && Self.valid($0.value.name) }) else {
            throw XTouchOneWorkspaceError.invalidBinding
        }
        for (name, values) in scenes {
            guard Self.valid(name), values.allSatisfy({ ids.contains($0.key) && $0.value.isFinite }) else {
                throw XTouchOneWorkspaceError.invalidScene
            }
        }
    }

    private func valid(_ action: XTouchOneParameterAction, parameters ids: Set<ParameterID>) -> Bool {
        if let id = action.parameterID, !ids.contains(id) { return false }
        switch action {
        case .set(_, let value), .step(_, let value): return value.isFinite
        case .toggle: return true
        case .cycle(_, let values): return (2...64).contains(values.count) && values.allSatisfy(\.isFinite)
        case .resetGroup(let group): return parameters.contains { $0.group == group }
        }
    }

    static func valid(_ name: String) -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Entirely host-side values. A binding, scene, or program never expresses an actuator command.
public struct XTouchOneWorkspace: Sendable {
    public private(set) var configuration: XTouchOneConfiguration
    public private(set) var values: [ParameterID: Double]
    private var undoStack: [[ParameterID: Double]] = []
    private var redoStack: [[ParameterID: Double]] = []
    private var previousControl: String?

    public init(configuration: XTouchOneConfiguration = .standard, savedValues: [ParameterID: Double] = [:]) throws {
        try configuration.validate()
        self.configuration = configuration
        guard Set(savedValues.keys).isSubset(of: Set(configuration.parameters.map(\.id))) else {
            throw XTouchOneWorkspaceError.unknownParameter
        }
        values = try Self.canonicalValues(configuration, preferred: savedValues)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public mutating func endInputGroup() { previousControl = nil }

    public func definition(_ id: ParameterID) -> ParameterDefinition? { configuration.parameters.first { $0.id == id } }

    public mutating func apply(_ configuration: XTouchOneConfiguration, preserveValues: Bool) throws {
        try configuration.validate()
        let next = try Self.canonicalValues(configuration, preferred: preserveValues ? values : [:])
        self.configuration = configuration
        values = next
        undoStack = []
        redoStack = []
        previousControl = nil
    }

    public mutating func set(_ id: ParameterID, to value: Double) throws {
        try run([.set(id, value)])
    }

    /// Apply all steps on a candidate state. Even very large or nonfinite inputs cannot commit a partial macro.
    public mutating func run(_ actions: [XTouchOneParameterAction]) throws {
        guard (1...64).contains(actions.count) else { throw XTouchOneWorkspaceError.invalidProgram }
        var next = values
        for action in actions { try apply(action, to: &next) }
        commit(next)
    }

    public mutating func runProgram(named name: String) throws {
        guard let actions = configuration.programs[name] else { throw XTouchOneWorkspaceError.missingEntry }
        try run(actions)
    }

    public mutating func saveScene(named name: String) throws {
        guard XTouchOneConfiguration.valid(name) else { throw XTouchOneWorkspaceError.invalidName }
        configuration.scenes[name] = values
    }

    public mutating func recallScene(named name: String) throws {
        guard let scene = configuration.scenes[name] else { throw XTouchOneWorkspaceError.missingEntry }
        commit(try Self.canonicalValues(configuration, preferred: values.merging(scene) { _, scene in scene }))
    }

    public mutating func removeScene(named name: String) { configuration.scenes.removeValue(forKey: name) }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(values)
        values = previous
        previousControl = nil
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(values)
        values = next
        previousControl = nil
    }

    /// Accept a decoded One input. The caller filters button repeats and untrusted fader movement.
    /// Agent actions are returned to the existing plugin host.
    public mutating func receive(_ event: DeviceInputEvent) throws -> Int? {
        guard let binding = configuration.bindings[event.elementID] else { return nil }
        switch (binding, event.kind, event.value) {
        case (.parameter(let id), .absolute, .number(let raw)):
            guard let definition = definition(id) else { throw XTouchOneWorkspaceError.unknownParameter }
            let scaled = raw == 127 ? definition.maximum
                : definition.minimum + (definition.maximum - definition.minimum) * (raw / 127)
            try inputValue(id, value: scaled, element: event.elementID)
        case (.parameter(let id), .relative, .number(let delta)):
            guard let definition = definition(id), let current = values[id] else { throw XTouchOneWorkspaceError.unknownParameter }
            let step = definition.step ?? (definition.maximum - definition.minimum) / 127
            let target = definition.kind == .toggle
                ? (delta > 0 ? definition.maximum : definition.minimum)
                : (current + step * delta)
            try inputValue(id, value: target, element: event.elementID)
        case (.action(let action), .press, _): try run([action])
        case (.program(let name), .press, _): try runProgram(named: name)
        case (.agent(let slot), .press, _): return slot
        default: break
        }
        return nil
    }

    private mutating func inputValue(_ id: ParameterID, value: Double, element: String) throws {
        var next = values
        try apply(.set(id, value), to: &next)
        commit(next, coalescing: element)
    }

    private func apply(_ action: XTouchOneParameterAction, to next: inout [ParameterID: Double]) throws {
        if case .resetGroup(let group) = action {
            let members = configuration.parameters.filter { $0.group == group }
            guard !members.isEmpty else { throw XTouchOneWorkspaceError.invalidProgram }
            for definition in members { next[definition.id] = try definition.clamp(definition.defaultValue) }
            return
        }
        guard let id = action.parameterID, let definition = definition(id), let current = next[id] else {
            throw XTouchOneWorkspaceError.unknownParameter
        }
        let value: Double
        switch action {
        case .set(_, let target): value = target
        case .step(_, let delta): value = current + delta
        case .toggle: value = current >= definition.midpoint ? definition.minimum : definition.maximum
        case .cycle(_, let options):
            guard (2...64).contains(options.count) else { throw XTouchOneWorkspaceError.invalidProgram }
            let canonical = try options.map(definition.clamp)
            value = canonical.firstIndex(of: current).map { canonical[($0 + 1) % canonical.count] } ?? canonical[0]
        case .resetGroup: return
        }
        next[id] = try definition.clamp(value)
    }

    private mutating func commit(_ next: [ParameterID: Double], coalescing element: String? = nil) {
        guard next != values else { return }
        if element == nil || previousControl != element {
            undoStack.append(values)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        previousControl = element
        values = next
    }

    private static func canonicalValues(_ configuration: XTouchOneConfiguration, preferred: [ParameterID: Double]) throws
        -> [ParameterID: Double] {
        try Dictionary(uniqueKeysWithValues: configuration.parameters.map {
            ($0.id, try $0.clamp(preferred[$0.id] ?? $0.defaultValue))
        })
    }
}
