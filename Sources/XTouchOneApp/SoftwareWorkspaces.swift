#if os(macOS)
import AgentPlugin
import SurfacePluginContracts
import SwiftUI
import UniformTypeIdentifiers
import XTouchOnePanel

struct ParametersWorkspace: View {
    let model: AppModel
    @State private var parameter: ParameterDraft?
    @State private var binding: BindingDraft?
    @State private var macro: MacroDraft?
    @State private var prepareRemoval: ParameterID?
    @State private var macroRemoval: String?

    var body: some View {
        OverflowScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle("参数", icon: "slider.horizontal.2.square")
                    Spacer()
                    Button("新建参数") { parameter = ParameterDraft() }.accessibilityIdentifier("parameters.add")
                    Button("分配控件") { binding = BindingDraft() }.accessibilityIdentifier("parameters.bind")
                }
                ForEach(model.workspace.configuration.parameters, id: \.id) { definition in
                    parameterRow(definition)
                }
                Divider()
                HStack {
                    SectionTitle("宏", icon: "list.number")
                    Spacer()
                    Button("新建宏") { macro = MacroDraft() }.accessibilityIdentifier("programs.add")
                }
                ForEach(model.workspace.configuration.programs.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("运行") { model.editWorkspace(feedback: true) { try $0.runProgram(named: name) } }
                        Button("编辑") {
                            macro = MacroDraft(originalName: name, name: name,
                                               actions: model.workspace.configuration.programs[name] ?? [])
                        }
                        Button("删除", role: .destructive) { macroRemoval = name }
                    }
                }
            }
        }
        .sheet(item: $parameter) { editor in
            ParameterEditor(draft: editor) { definition in
                var configuration = model.workspace.configuration
                if let index = configuration.parameters.firstIndex(where: { $0.id == definition.id }) {
                    if editor.existing == nil { throw XTouchOneWorkspaceError.duplicateParameter }
                    configuration.parameters[index] = definition
                } else {
                    configuration.parameters.append(definition)
                }
                try configuration.validate()
                model.applyConfiguration(configuration, preserveValues: true)
            }
        }
        .sheet(item: $binding) { AssignmentEditor(model: model, draft: $0) }
        .sheet(item: $macro) { MacroEditor(model: model, draft: $0) }
        .confirmationDialog("删除参数？", isPresented: Binding(get: { prepareRemoval != nil }, set: {
            if !$0 { prepareRemoval = nil }
        }), presenting: prepareRemoval) { id in
            Button("删除参数", role: .destructive) { removeParameter(id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("有分配或宏在使用时，请先解除引用。")
        }
        .confirmationDialog("删除宏？", isPresented: Binding(get: { macroRemoval != nil }, set: {
            if !$0 { macroRemoval = nil }
        }), presenting: macroRemoval) { name in
            Button("删除宏", role: .destructive) {
                model.editWorkspace { workspace in
                    var configuration = workspace.configuration
                    configuration.programs.removeValue(forKey: name)
                    try workspace.apply(configuration, preserveValues: true)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("有控件使用此宏时，请先解除分配。")
        }
    }

    private func parameterRow(_ definition: ParameterDefinition) -> some View {
        let current = model.workspace.values[definition.id] ?? definition.defaultValue
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(definition.nameKey).font(.callout.bold())
                if !definition.group.isEmpty { Text(definition.group).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(current.formatted(.number.precision(.fractionLength(0...3)))) \(definition.unit)")
                    .monospacedDigit().accessibilityIdentifier("parameters.value.\(definition.id.rawValue)")
                Menu {
                    Button("编辑") { parameter = ParameterDraft(definition) }
                    Button("删除", role: .destructive) { prepareRemoval = definition.id }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if definition.kind == .toggle {
                Toggle("值", isOn: Binding(get: { current == definition.maximum }, set: { active in
                    model.editWorkspace(feedback: true) { try $0.set(definition.id, to: active ? definition.maximum : definition.minimum) }
                }))
            } else {
                Slider(value: Binding(get: { model.workspace.values[definition.id] ?? definition.defaultValue }, set: { value in
                    model.editWorkspace(feedback: true) { try $0.set(definition.id, to: value) }
                }), in: definition.minimum...definition.maximum)
                .accessibilityIdentifier("parameters.slider.\(definition.id.rawValue)")
            }
            let assignments = model.workspace.configuration.bindings.filter { $0.value == .parameter(definition.id) }.keys.sorted()
            if !assignments.isEmpty { Text(assignments.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary) }
        }
        .insetStyle()
    }

    private func removeParameter(_ id: ParameterID) {
        model.editWorkspace { workspace in
            var configuration = workspace.configuration
            configuration.parameters.removeAll { $0.id == id }
            for name in Array(configuration.scenes.keys) { configuration.scenes[name]?.removeValue(forKey: id) }
            try workspace.apply(configuration, preserveValues: true)
        }
        prepareRemoval = nil
    }
}

private struct ParameterDraft: Identifiable {
    let id = UUID()
    var existing: ParameterID?
    var name = ""
    var group = ""
    var unit = ""
    var minimum = "0"
    var maximum = "127"
    var initial = "0"
    var step = "1"
    var kind = ParameterKind.continuous
    var agentWritable = true
    var externallyProtected = false

    init() {}
    init(_ definition: ParameterDefinition) {
        existing = definition.id
        name = definition.nameKey
        group = definition.group
        unit = definition.unit
        minimum = String(definition.minimum)
        maximum = String(definition.maximum)
        initial = String(definition.defaultValue)
        step = definition.step.map { String($0) } ?? ""
        kind = definition.kind
        agentWritable = definition.agentWritable
        externallyProtected = definition.externallyProtected
    }

    func build() throws -> ParameterDefinition {
        guard let min = Double(minimum), let max = Double(maximum), let value = Double(initial),
              step.isEmpty || Double(step) != nil else { throw XTouchOneWorkspaceError.invalidProgram }
        return try ParameterDefinition(id: existing ?? ParameterID(rawValue: id.uuidString.lowercased()),
                                       nameKey: name, group: group, unit: unit, minimum: min, maximum: max,
                                       defaultValue: value, kind: kind, agentWritable: agentWritable,
                                       externallyProtected: externallyProtected, step: step.isEmpty ? nil : Double(step))
    }
}

private struct ParameterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ParameterDraft
    @State private var error: String?
    let save: (ParameterDefinition) throws -> Void

    var body: some View {
        VStack(spacing: 14) {
            Form {
                TextField("名称", text: $draft.name)
                TextField("分组", text: $draft.group)
                TextField("单位", text: $draft.unit)
                TextField("最小值", text: $draft.minimum)
                TextField("最大值", text: $draft.maximum)
                TextField("默认值", text: $draft.initial)
                TextField("步长，可留空", text: $draft.step)
                Picker("类型", selection: $draft.kind) {
                    Text("连续").tag(ParameterKind.continuous)
                    Text("开关").tag(ParameterKind.toggle)
                }
                Toggle("允许模拟端写入", isOn: $draft.agentWritable)
                Toggle("保护外部写入", isOn: $draft.externallyProtected)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    do { try save(draft.build()); dismiss() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 380)
    }
}

private enum ActionKind: String, CaseIterable, Identifiable {
    case set, step, toggle, cycle, resetGroup
    var id: Self { self }
    var title: String {
        switch self {
        case .set: "设定"; case .step: "步进"; case .toggle: "切换"; case .cycle: "循环"; case .resetGroup: "重置分组"
        }
    }
}

private struct ActionDraft {
    var kind = ActionKind.set
    var target = ""
    var value = "1"

    func build() throws -> XTouchOneParameterAction {
        let id = ParameterID(rawValue: target)
        switch kind {
        case .toggle: return .toggle(id)
        case .resetGroup: return .resetGroup(target)
        case .set, .step:
            guard let number = Double(value) else { throw XTouchOneWorkspaceError.invalidProgram }
            return kind == .set ? .set(id, number) : .step(id, number)
        case .cycle:
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == parts.count else { throw XTouchOneWorkspaceError.invalidProgram }
            return .cycle(id, values)
        }
    }

    static func label(_ action: XTouchOneParameterAction, in configuration: XTouchOneConfiguration) -> String {
        func name(_ id: ParameterID) -> String {
            configuration.parameters.first { $0.id == id }?.nameKey ?? id.rawValue
        }
        switch action {
        case .set(let id, let value): return "设定 \(name(id)) · \(value)"
        case .step(let id, let value): return "步进 \(name(id)) · \(value)"
        case .toggle(let id): return "切换 \(name(id))"
        case .cycle(let id, let values): return "循环 \(name(id)) · " + values.map { String($0) }.joined(separator: ", ")
        case .resetGroup(let group): return "重置分组 \(group)"
        }
    }
}

private struct ActionFields: View {
    let configuration: XTouchOneConfiguration
    @Binding var draft: ActionDraft

    var body: some View {
        Picker("操作", selection: $draft.kind) {
            ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
        }
        if draft.kind == .resetGroup {
            Picker("分组", selection: $draft.target) {
                Text("选择分组").tag("")
                ForEach(Set(configuration.parameters.map(\.group)).subtracting([""]).sorted(), id: \.self) { Text($0).tag($0) }
            }
        } else {
            Picker("参数", selection: $draft.target) {
                Text("选择参数").tag("")
                ForEach(configuration.parameters, id: \.id) { Text($0.nameKey).tag($0.id.rawValue) }
            }
        }
        if draft.kind == .set || draft.kind == .step || draft.kind == .cycle {
            TextField(draft.kind == .cycle ? "多个值用逗号分隔" : "数值", text: $draft.value)
        }
    }
}

private struct BindingDraft: Identifiable {
    let id = UUID()
    var control = "fader"
    var type = "parameter"
    var parameter = ""
    var program = ""
    var agent = 1
    var action = ActionDraft()
    var label = ""
    var color: XTouchOneControlColor?
}

private struct AssignmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State var draft: BindingDraft
    @State private var error: String?
    private var valueControl: Bool { XTouchOneConfiguration.valueControls.contains(draft.control) }
    private var configuration: XTouchOneConfiguration { model.workspace.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("控件", selection: $draft.control) {
                    ForEach(XTouchOneConfiguration.controls, id: \.self) { Text(controlName($0)).tag($0) }
                }
                .onChange(of: draft.control, initial: true) { _, _ in populate() }
                TextField("控件别名，可留空", text: $draft.label)
                Picker("标签颜色", selection: $draft.color) {
                    Text("无").tag(XTouchOneControlColor?.none)
                    ForEach(XTouchOneControlColor.allCases, id: \.self) { color in
                        Label(color.title, systemImage: "circle.fill").foregroundStyle(color.color).tag(Optional(color))
                    }
                }
                Picker("分配", selection: $draft.type) {
                    Text("无").tag("none")
                    if valueControl { Text("参数").tag("parameter") }
                    else {
                        Text("参数操作").tag("action")
                        Text("宏").tag("program")
                        Text("模拟 Agent").tag("agent")
                    }
                }
                switch draft.type {
                case "parameter":
                    Picker("参数", selection: $draft.parameter) {
                        Text("选择参数").tag("")
                        ForEach(configuration.parameters, id: \.id) { Text($0.nameKey).tag($0.id.rawValue) }
                    }
                case "action": ActionFields(configuration: configuration, draft: $draft.action)
                case "program":
                    Picker("宏", selection: $draft.program) {
                        Text("选择宏").tag("")
                        ForEach(configuration.programs.keys.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                case "agent":
                    Picker("Agent 槽位", selection: $draft.agent) {
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                default: EmptyView()
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { apply() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 410)
    }

    private func populate() {
        let entry = configuration.labels[draft.control]
        draft.label = entry?.name ?? ""
        draft.color = entry?.color
        switch configuration.bindings[draft.control] {
        case .parameter(let id): draft.type = "parameter"; draft.parameter = id.rawValue
        case .agent(let slot): draft.type = "agent"; draft.agent = slot
        case .program(let name): draft.type = "program"; draft.program = name
        case .action(let action):
            draft.type = "action"
            switch action {
            case .set(let id, let value): draft.action = ActionDraft(kind: .set, target: id.rawValue, value: String(value))
            case .step(let id, let value): draft.action = ActionDraft(kind: .step, target: id.rawValue, value: String(value))
            case .toggle(let id): draft.action = ActionDraft(kind: .toggle, target: id.rawValue)
            case .cycle(let id, let values):
                draft.action = ActionDraft(kind: .cycle, target: id.rawValue, value: values.map { String($0) }.joined(separator: ","))
            case .resetGroup(let group): draft.action = ActionDraft(kind: .resetGroup, target: group)
            }
        case nil: draft.type = "none"
        }
    }

    private func apply() {
        do {
            var next = configuration
            switch draft.type {
            case "parameter": next.bindings[draft.control] = .parameter(ParameterID(rawValue: draft.parameter))
            case "action": next.bindings[draft.control] = .action(try draft.action.build())
            case "agent": next.bindings[draft.control] = .agent(draft.agent)
            case "program": next.bindings[draft.control] = .program(draft.program)
            default: next.bindings.removeValue(forKey: draft.control)
            }
            let name = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
            next.labels[draft.control] = name.isEmpty && draft.color == nil ? nil
                : XTouchOneControlLabel(name: name.isEmpty ? controlName(draft.control) : name, color: draft.color)
            try next.validate()
            model.applyConfiguration(next, preserveValues: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MacroDraft: Identifiable {
    let id = UUID()
    var originalName: String?
    var name = ""
    var actions: [XTouchOneParameterAction] = []
}

private struct MacroEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State var draft: MacroDraft
    @State private var action = ActionDraft()
    @State private var error: String?
    private var configuration: XTouchOneConfiguration { model.workspace.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("宏名称", text: $draft.name)
            List {
                ForEach(draft.actions.indices, id: \.self) { index in
                    HStack {
                        Text(ActionDraft.label(draft.actions[index], in: configuration))
                        Spacer()
                        Button { draft.actions.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("上移")
                        Button { draft.actions.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == draft.actions.count - 1).help("下移")
                        Button(role: .destructive) { draft.actions.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .help("移除步骤")
                    }
                    .buttonStyle(.borderless)
                }
            }.frame(height: 145)
            Form { ActionFields(configuration: configuration, draft: $action) }
            Button("添加步骤") {
                do { draft.actions.append(try action.build()); error = nil }
                catch { self.error = error.localizedDescription }
            }.disabled(draft.actions.count >= 64)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存宏") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 430)
    }

    private func save() {
        do {
            var next = configuration
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard next.programs[name] == nil || name == draft.originalName else {
                error = "该宏名称已被使用。"
                return
            }
            if let old = draft.originalName, old != name {
                next.programs.removeValue(forKey: old)
                next.bindings = next.bindings.mapValues { $0 == .program(old) ? .program(name) : $0 }
            }
            next.programs[name] = draft.actions
            try next.validate()
            model.applyConfiguration(next, preserveValues: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct OrganizeWorkspace: View {
    @Bindable var model: AppModel
    @State private var sceneName = ""
    @State private var configurationName = ""
    @State private var open = false
    @State private var export = false
    @State private var imported: XTouchOneConfiguration?
    @State private var armPreview = false
    @State private var pending: Pending?
    @State private var error: String?

    private enum Pending: Identifiable {
        case scene(String), deleteScene(String), config(String), applyConfig(String), deleteConfig(String), initial, importFile
        var id: Int {
            switch self { case .scene: 0; case .deleteScene: 1; case .config: 2; case .applyConfig: 3; case .deleteConfig: 4; case .initial: 5; case .importFile: 6 }
        }
        var prompt: String {
            switch self {
            case .scene(let name): "覆盖场景「\(name)」？"
            case .deleteScene(let name): "删除场景「\(name)」？"
            case .config(let name): "覆盖配置「\(name)」？"
            case .applyConfig(let name): "载入配置「\(name)」？"
            case .deleteConfig(let name): "删除配置「\(name)」？"
            case .initial: "使用默认配置？"
            case .importFile: "应用导入配置？"
            }
        }
        var deletes: Bool {
            switch self { case .deleteScene, .deleteConfig: true; default: false }
        }
    }

    var body: some View {
        OverflowScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("撤销") { model.editWorkspace(feedback: true) { $0.undo() } }.disabled(!model.workspace.canUndo)
                    Button("重做") { model.editWorkspace(feedback: true) { $0.redo() } }.disabled(!model.workspace.canRedo)
                    Spacer()
                    Picker("高亮分组", selection: $model.highlightedGroup) {
                        Text("全部分组").tag(String?.none)
                        ForEach(groups, id: \.self) { Text($0).tag(Optional($0)) }
                    }.fixedSize()
                }
                SectionTitle("场景", icon: "square.stack")
                HStack {
                    TextField("场景名称", text: $sceneName)
                    Button("保存") { saveScene() }.disabled(sceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.workspace.configuration.scenes.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("调用") { model.editWorkspace(feedback: true) { try $0.recallScene(named: name) } }
                        Button("删除", role: .destructive) { pending = .deleteScene(name) }
                    }
                }
                Divider()
                Button("参考机械臂预览…") { armPreview = true }.accessibilityIdentifier("organize.armPreview")
                SectionTitle("配置库", icon: "tray.full")
                HStack {
                    TextField("配置名称", text: $configurationName)
                    Button("保存") { saveConfiguration() }.disabled(configurationName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.configurationLibrary.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("载入") { pending = .applyConfig(name) }
                        Button("删除", role: .destructive) { pending = .deleteConfig(name) }
                    }
                }
                HStack {
                    Button("导入…") { open = true }
                    Button("导出…") { export = true }
                    Spacer()
                    Button("默认配置…") { pending = .initial }
                }
                if let error = error ?? model.storageError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .sheet(isPresented: $armPreview) { ReferenceArmView(model: model) }
        .fileImporter(isPresented: $open, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                imported = try XTouchOneConfiguration.decode(WorkspaceStore.read(url))
                pending = .importFile
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $export, document: ConfigurationDocument(configuration: model.workspace.configuration),
                      contentType: .json, defaultFilename: "X-Touch-One") { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .confirmationDialog(pending?.prompt ?? "", isPresented: Binding(get: { pending != nil }, set: {
            if !$0 { pending = nil }
        }), presenting: pending) { operation in
            Button(operation.deletes ? "删除" : "确认", role: operation.deletes ? .destructive : nil) { apply(operation) }
            Button("取消", role: .cancel) {}
        }
    }

    private var groups: [String] { Set(model.workspace.configuration.parameters.map(\.group)).subtracting([""]).sorted() }

    private func saveScene() {
        let name = sceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.workspace.configuration.scenes[name] == nil { apply(.scene(name)) } else { pending = .scene(name) }
    }

    private func saveConfiguration() {
        let name = configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.configurationLibrary[name] == nil { apply(.config(name)) } else { pending = .config(name) }
    }

    private func apply(_ operation: Pending) {
        switch operation {
        case .scene(let name): model.editWorkspace { try $0.saveScene(named: name) }; sceneName = ""
        case .deleteScene(let name): model.editWorkspace { $0.removeScene(named: name) }
        case .config(let name): model.saveConfiguration(named: name); configurationName = ""
        case .applyConfig(let name):
            if let configuration = model.configurationLibrary[name] { model.applyConfiguration(configuration, preserveValues: true) }
        case .deleteConfig(let name): model.removeConfiguration(named: name)
        case .initial: model.applyConfiguration(.standard, preserveValues: false)
        case .importFile:
            if let imported { model.applyConfiguration(imported, preserveValues: false) }
            imported = nil
        }
        pending = nil
    }
}

private struct ConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var configuration: XTouchOneConfiguration
    init(configuration: XTouchOneConfiguration) { self.configuration = configuration }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.configuration = try XTouchOneConfiguration.decode(bytes)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(self.configuration)
        guard bytes.count <= XTouchOneConfiguration.maximumBytes else { throw XTouchOneWorkspaceError.fileTooLarge }
        return FileWrapper(regularFileWithContents: bytes)
    }
}

struct AgentsWorkspace: View {
    let model: AppModel

    var body: some View {
        OverflowScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("模拟 Agent", isOn: Binding(get: { model.console.agents != nil }, set: { model.toggleAgents($0) }))
                    .accessibilityIdentifier("agents.enable")
                if let agent = model.console.agents {
                    ForEach(agent.slots, id: \.id) { slot in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Agent \(slot.id)").bold()
                                Text(status(slot.state)).foregroundStyle(.secondary)
                                Spacer()
                                if slot.state.isActive {
                                    Button("中止") { model.interruptAgent(slot.id) }
                                }
                                if !slot.state.isActive || slot.state == .waitingApproval {
                                    Button(slot.state == .waitingApproval ? "批准" : "启动") { model.runAgent(slot.id) }
                                        .accessibilityIdentifier("agents.primary.\(slot.id)")
                                }
                            }
                            ProgressView(value: slot.progress)
                        }.insetStyle()
                    }
                }
            }
        }
    }

    private func status(_ state: AgentRunState) -> String {
        switch state {
        case .idle: "空闲"; case .queued: "排队"; case .running: "运行中"; case .waitingApproval: "等待批准"
        case .completed: "完成"; case .interrupted: "已中止"; case .error: "错误"
        }
    }
}

@MainActor
private func controlName(_ id: String) -> String {
    if id == "fader" { return "推子" }
    if id == "encoder.turn" { return "编码器" }
    if id == "jog" { return "拨轮" }
    if id == "foot-switch" { return "脚踏" }
    if let address = UInt8(id.dropFirst(7)), let key = XTouchOnePanelLayout.key(at: address) {
        return "\(address) · \(key.label)"
    }
    return id
}

extension XTouchOneControlColor {
    var title: String {
        switch self {
        case .red: "红"; case .orange: "橙"; case .yellow: "黄"; case .green: "绿"
        case .cyan: "青"; case .blue: "蓝"; case .purple: "紫"; case .gray: "灰"
        }
    }
    var color: Color {
        switch self {
        case .red: .red; case .orange: .orange; case .yellow: .yellow; case .green: .green
        case .cyan: .cyan; case .blue: .blue; case .purple: .purple; case .gray: .gray
        }
    }
}
#endif
