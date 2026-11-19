#if os(macOS)
import Foundation
import SurfacePluginContracts
import Observation
import SurfaceFeedbackPlanning
import XTouchOneAdapter
import XTouchOneCoreMIDI
import XTouchOnePanel

/// What the inspector shows. Keys are identified by their address.
enum PanelSelection: Hashable {
    case key(UInt8), fader, encoder, jog, meter, lcd, segments
}

/// The three states of the mode strip. Picking hardware always lands on listening.
enum ConsoleMode: Hashable { case mock, hardwareListen, hardwareSend }

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case values, lights, monitor, parameters, organize, agents, capture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .values: "数值"
        case .lights: "按键灯"
        case .monitor: "MIDI 监视"
        case .parameters: "参数"
        case .organize: "组织"
        case .agents: "Agent"
        case .capture: "录制"
        }
    }
    var systemImage: String {
        switch self {
        case .values: "slider.horizontal.3"
        case .lights: "lightbulb"
        case .monitor: "waveform"
        case .parameters: "slider.horizontal.2.square"
        case .organize: "rectangle.3.group"
        case .agents: "person.crop.circle"
        case .capture: "record.circle"
        }
    }
}

/// Owns the console value and the CoreMIDI objects on the main actor.
@MainActor
@Observable
final class AppModel {
    private(set) var console: XTouchOneConsole
    private(set) var link = XTouchOneConsole.Link.mock
    private(set) var mode = XTouchOneMIDIMode.midi
    private(set) var channel: UInt8 = 1
    private(set) var allowWrite = false
    private(set) var allowRecall = false
    private(set) var sources: [XTouchOneMIDIEndpoint] = []
    private(set) var destinations: [XTouchOneMIDIEndpoint] = []
    private(set) var lastError: String?
    private(set) var configurationLibrary: [String: XTouchOneConfiguration] = [:]
    private(set) var storageError: String?
    private(set) var captureLocation: URL?
    private(set) var captureError: String?
    private(set) var captureEvents = 0
    private(set) var recording = false
    @ObservationIgnored private var captureWriter: LiveCaptureWriter?
    var sourceID: Int32? { didSet { if sourceID != oldValue { savePending = true } } }
    var destinationID: Int32? { didSet { if destinationID != oldValue { savePending = true } } }
    var selection: PanelSelection? = .fader
    var tab = WorkspaceTab.values
    var highlightedGroup: String?
    var blink = false
    var showAddresses = true
    var lcdInvertUpper = false
    var lcdInvertLower = false
    var recallTarget = 64.0
    var lcdUpper = "Choir"
    var lcdLower = "36R"
    var lcdColor = XTouchOneLCDColor.blue
    var assignment = "Pn"
    var counter = " 42 2 1  1"

    @ObservationIgnored private var input: XTouchOneMIDIInput?
    @ObservationIgnored private var output: XTouchOneMIDIOutput?
    @ObservationIgnored private var connectionID: UUID?

    @ObservationIgnored private let workspaceStore: WorkspaceStore?
    @ObservationIgnored private var diskWritable = true
    @ObservationIgnored private var savePending = false
    @ObservationIgnored private var lastSaveAt = 0.0

    init(persistent: Bool = false) {
        let store = persistent ? WorkspaceStore.standard : nil
        workspaceStore = store
        var restored: XTouchOneWorkspace?
        var savedMIDI: MIDISelection?
        var profile = try! XTouchOneMIDIProfile(mode: .midi, channel: 1)
        do {
            if let saved = try store?.load() {
                restored = try XTouchOneWorkspace(configuration: saved.configuration, savedValues: saved.values)
                configurationLibrary = saved.library
                savedMIDI = saved.midi
                profile = try saved.midi?.profile() ?? profile
            }
        } catch {
            diskWritable = false
            storageError = "保留原工作区文件。\(error.localizedDescription)"
        }
        console = try! XTouchOneConsole(link: .mock, profile: profile,
                                        displayRate: .unlimited, outputPolicy: .write, mechanismPolicy: .localRecall,
                                        workspace: restored)
        mode = profile.mode
        channel = profile.channel
        sourceID = savedMIDI?.sourceID
        destinationID = savedMIDI?.destinationID
        savePending = false
    }

    var now: Double { ProcessInfo.processInfo.systemUptime }
    var isConnected: Bool { console.session.isConnected }
    var canWriteDisplay: Bool { link == .mock || (allowWrite && isConnected && output != nil) }
    var demoLinks: Bool {
        get { console.demoLinks }
        set { console.demoLinks = newValue }
    }

    var consoleMode: ConsoleMode { link == .mock ? .mock : allowWrite ? .hardwareSend : .hardwareListen }

    func setMode(_ mode: ConsoleMode) {
        guard mode != consoleMode else { return }
        switch mode {
        case .mock: configure(link: .mock)
        case .hardwareListen: configure(link: .hardware, allowWrite: false, allowRecall: false)
        case .hardwareSend: configure(link: .hardware, allowWrite: true)
        }
    }

    var profileSummary: String { "MIDI 模式 \(mode.rawValue) · 通道 \(channel)" }

    private func attempt(_ body: () throws -> Void) {
        defer { collectCapture() }
        do { try body(); lastError = nil } catch { lastError = "\(error)" }
    }

    // MARK: Configuration. Every change builds a new session, so nothing carries over.

    func configure(link: XTouchOneConsole.Link? = nil, mode: XTouchOneMIDIMode? = nil, channel: UInt8? = nil,
                   allowWrite: Bool? = nil, allowRecall: Bool? = nil) {
        let reconnect = isConnected && (link ?? self.link) == .hardware && self.link == .hardware
        if mode != nil || channel != nil { savePending = true }
        closeConnection()
        if recording { stopCapture() }
        self.link = link ?? self.link
        self.mode = mode ?? self.mode
        self.channel = channel ?? self.channel
        self.allowWrite = allowWrite ?? self.allowWrite
        self.allowRecall = (allowRecall ?? self.allowRecall) && self.allowWrite
        let demo = console.demoLinks
        let workspace = console.workspace
        attempt {
            let profile = try XTouchOneMIDIProfile(mode: self.mode, channel: self.channel)
            let mock = self.link == .mock
            console = try XTouchOneConsole(
                link: self.link, profile: profile, displayRate: mock ? .unlimited : XTouchOneConsole.hardwareDisplayRate,
                outputPolicy: mock || self.allowWrite ? .write : .observe,
                mechanismPolicy: mock || self.allowRecall ? .localRecall : .disabled, demoLinks: demo,
                workspace: workspace)
        }
        if self.link == .hardware { refreshEndpoints() }
        if reconnect { connect() }
    }

    func refreshEndpoints() {
        sources = XTouchOneMIDIEndpoint.all(.source)
        destinations = XTouchOneMIDIEndpoint.all(.destination)
    }

    /// Opens an input port and, with write permission, the selected output port. Opening sends nothing.
    func connect() {
        guard link == .hardware, !isConnected else { return }
        guard let source = sources.first(where: { $0.uniqueID == sourceID && !$0.isOffline }) else {
            disconnect()
            lastError = "所选 MIDI 输入端点当前离线。"
            return
        }
        let destination = destinations.first { $0.uniqueID == destinationID }
        let id = UUID()
        attempt {
            let route = try XTouchOneRoute(inputID: String(source.uniqueID),
                                           outputID: destination.map { String($0.uniqueID) } ?? "not-selected",
                                           transportOrigin: source.isVirtual ? .localVirtual : .physicalUSB)
            input = try XTouchOneMIDIInput(sourceUniqueID: source.uniqueID, clientName: "XTouchOneApp", receive: { [weak self] message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connectionID == id else { return }
                    self.received(message)
                }
            }, setupChanged: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connectionID == id else { return }
                    self.setupChanged()
                }
            })
            if allowWrite, let destination {
                output = try XTouchOneMIDIOutput(destinationUniqueID: destination.uniqueID, clientName: "XTouchOneApp")
            }
            try console.attach(route, at: now)
            connectionID = id
        }
        if lastError != nil {
            let error = lastError
            disconnect()
            lastError = error
        }
    }

    func disconnect() {
        closeConnection()
        if allowWrite || allowRecall { configure(allowWrite: false, allowRecall: false) }
    }

    private func closeConnection() {
        connectionID = nil
        input = nil
        output = nil
        if link == .hardware, isConnected { attempt { try console.detach(at: now) } }
    }

    private func setupChanged() {
        refreshEndpoints()
        if input?.isCurrent != true || output?.isCurrent == false { disconnect() }
    }

    private func received(_ message: [UInt8]) {
        guard isConnected else { return }
        let previous = console.workspace.values
        attempt { try console.receive(message, at: now) }
        noteInputValues(previous)
        flush()
    }

    // MARK: Panel and inspector actions

    func act(_ action: XTouchOnePanelAction) {
        let previous = console.workspace.values
        attempt { try console.operate(action, at: now) }
        noteInputValues(previous)
        flush()
    }

    func show(_ display: XTouchOneDisplay) {
        attempt { try console.request(display, at: now) }
        flush()
    }

    func cycleLight(_ key: XTouchOnePanelKey) {
        let next: XTouchOneButtonLED = switch console.shown.buttonLEDs[key.address] ?? .off {
        case .off: .on
        case .on: .flash
        case .flash: .off
        }
        show(.buttonLED(key.button, next))
    }

    func showLCD() {
        show(.lcd(upper: lcdUpper, lower: lcdLower, color: lcdColor, invertUpper: lcdInvertUpper, invertLower: lcdInvertLower))
    }

    func showSegments() { show(XTouchOneSegmentFont.display(assignment: assignment, counter: counter)) }

    func setJogDisplayLinked(_ linked: Bool) {
        guard !linked || canWriteDisplay else { return }
        attempt { try console.setJogDisplayLinked(linked, at: now) }
        flush()
    }

    func resetJog() {
        attempt { try console.resetJog(at: now, updateDisplay: canWriteDisplay) }
        flush()
    }

    func recall() {
        attempt { try console.recallFader(to: UInt8(recallTarget), at: now, write: transport) }
    }

    /// Drains again later when the rate held something back.
    func flush() {
        attempt { try console.pump(at: now, write: transport) }
    }

    private var transport: (([UInt8]) -> FeedbackAttemptResult)? {
        guard let input, let output else { return nil }
        return { bytes in
            guard input.isCurrent else { return .notAttempted(reason: "input endpoint is no longer online") }
            do { try output.write(bytes); return .accepted } catch { return .rejected(reason: "\(error)") }
        }
    }

    func tick() {
        blink.toggle()
        if console.agents != nil { attempt { try console.advanceAgents(at: now) } }
        if !console.session.queuedDisplayTargets.isEmpty { flush() }
        if savePending, now - lastSaveAt >= 1 { saveWorkspace() }
    }

    func startCapture(at url: URL) {
        guard !recording else { return }
        do {
            let writer = try LiveCaptureWriter(at: url, model: self)
            captureWriter = writer
            captureLocation = url
            captureEvents = writer.events
            captureError = nil
            recording = true
        } catch { captureError = String(describing: error) }
    }

    private func collectCapture() {
        guard let captureWriter else { return }
        do {
            try captureWriter.collect(console.log)
            captureEvents = captureWriter.events
        } catch {
            captureError = String(describing: error)
            stopCapture()
        }
    }

    func stopCapture() {
        guard let writer = captureWriter else { return }
        captureWriter = nil
        recording = false
        do { try writer.close() } catch { captureError = String(describing: error) }
    }

    var workspace: XTouchOneWorkspace { console.workspace }

    func panelOpacity(for control: String) -> Double {
        guard let highlightedGroup else { return 1 }
        guard case .parameter(let id) = workspace.configuration.bindings[control],
              workspace.definition(id)?.group == highlightedGroup else { return 0.3 }
        return 1
    }

    func controlLabel(_ id: String) -> XTouchOneControlLabel? { workspace.configuration.labels[id] }

    func editWorkspace(feedback: Bool = false, _ edit: (inout XTouchOneWorkspace) throws -> Void) {
        attempt {
            var next = workspace
            try edit(&next)
            console.workspace = next
            savePending = true
            if feedback, canWriteDisplay { try console.repaintParameterFeedback(at: now) }
        }
        if !console.session.queuedDisplayTargets.isEmpty { flush() }
    }

    private func noteInputValues(_ previous: [ParameterID: Double]) {
        if previous != workspace.values { savePending = true }
        if link == .mock, case .parameter(let id) = workspace.configuration.bindings["encoder.turn"],
           previous[id] != workspace.values[id], !demoLinks {
            attempt { try console.repaintParameterFeedback(at: now) }
        }
    }

    func applyConfiguration(_ configuration: XTouchOneConfiguration, preserveValues: Bool) {
        editWorkspace { try $0.apply(configuration, preserveValues: preserveValues) }
    }

    func saveConfiguration(named name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        configurationLibrary[name] = workspace.configuration
        savePending = true
    }

    func removeConfiguration(named name: String) {
        configurationLibrary.removeValue(forKey: name)
        savePending = true
    }

    func saveWorkspace() {
        guard savePending, diskWritable, let workspaceStore else { return }
        lastSaveAt = now
        do {
            try workspaceStore.save(SavedWorkspace(configuration: workspace.configuration, values: workspace.values,
                library: configurationLibrary, midi: .init(mode: mode.rawValue, channel: channel,
                                                          sourceID: sourceID, destinationID: destinationID)))
            savePending = false
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    func toggleAgents(_ enabled: Bool) {
        attempt {
            if enabled { try console.startAgents(at: now) }
            else { try console.stopAgents(at: now) }
        }
        if !console.session.queuedDisplayTargets.isEmpty { flush() }
    }

    func runAgent(_ index: Int) {
        attempt { try console.invokeAgent(index, at: now) }
        if !console.session.queuedDisplayTargets.isEmpty { flush() }
    }

    func interruptAgent(_ index: Int) {
        attempt { try console.interruptAgent(index, at: now) }
        if !console.session.queuedDisplayTargets.isEmpty { flush() }
    }

    /// A fixed scene for screenshots.
    func loadSampleScene() {
        demoLinks = false
        for (address, state) in [(1, XTouchOneButtonLED.on), (3, .on), (10, .on), (16, .on), (32, .on), (29, .on)] {
            show(.buttonLED(XTouchOneButton(rawValue: UInt8(address))!, state))
        }
        show(.encoderRing(70))
        show(.meter(88))
        showLCD()
        showSegments()
        act(.fader(40))
    }
}
#endif
