#if os(macOS)
import Foundation
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
    case values, lights, monitor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .values: "数值"
        case .lights: "按键灯"
        case .monitor: "MIDI 监视"
        }
    }
    var systemImage: String {
        switch self {
        case .values: "slider.horizontal.3"
        case .lights: "lightbulb"
        case .monitor: "waveform"
        }
    }
}

/// Owns the console value and the CoreMIDI objects on the main actor.
@MainActor
@Observable
final class AppModel {
    /// Not a qualified device budget: a conservative placeholder until the transport is measured.
    static let hardwareDisplayRate = FeedbackQueueRate.bucket(perSecond: 50, burst: 10, failureCooldown: 1)

    private(set) var console: XTouchOneConsole
    private(set) var link = XTouchOneConsole.Link.mock
    private(set) var mode = XTouchOneMIDIMode.midi
    private(set) var channel: UInt8 = 1
    private(set) var allowWrite = false
    private(set) var allowRecall = false
    private(set) var sources: [XTouchOneMIDIEndpoint] = []
    private(set) var destinations: [XTouchOneMIDIEndpoint] = []
    private(set) var lastError: String?
    var sourceID: Int32?
    var destinationID: Int32?
    var selection: PanelSelection? = .fader
    var tab = WorkspaceTab.values
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

    init() {
        console = try! XTouchOneConsole(link: .mock, profile: XTouchOneMIDIProfile(mode: .midi, channel: 1),
                                        displayRate: .unlimited, outputPolicy: .write, mechanismPolicy: .localRecall)
    }

    var now: Double { ProcessInfo.processInfo.systemUptime }
    var isConnected: Bool { console.session.isConnected }
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
        do { try body(); lastError = nil } catch { lastError = "\(error)" }
    }

    // MARK: Configuration. Every change builds a new session, so nothing carries over.

    func configure(link: XTouchOneConsole.Link? = nil, mode: XTouchOneMIDIMode? = nil, channel: UInt8? = nil,
                   allowWrite: Bool? = nil, allowRecall: Bool? = nil) {
        let reconnect = isConnected && (link ?? self.link) == .hardware && self.link == .hardware
        disconnect()
        self.link = link ?? self.link
        self.mode = mode ?? self.mode
        self.channel = channel ?? self.channel
        self.allowWrite = allowWrite ?? self.allowWrite
        self.allowRecall = (allowRecall ?? self.allowRecall) && self.allowWrite
        let demo = console.demoLinks
        attempt {
            let profile = try XTouchOneMIDIProfile(mode: self.mode, channel: self.channel)
            let mock = self.link == .mock
            console = try XTouchOneConsole(
                link: self.link, profile: profile, displayRate: mock ? .unlimited : Self.hardwareDisplayRate,
                outputPolicy: mock || self.allowWrite ? .write : .observe,
                mechanismPolicy: mock || self.allowRecall ? .localRecall : .disabled, demoLinks: demo)
        }
        if self.link == .hardware { refreshEndpoints() }
        if reconnect { connect() }
    }

    func refreshEndpoints() {
        sources = XTouchOneMIDIEndpoint.all(.source)
        destinations = XTouchOneMIDIEndpoint.all(.destination)
        if !sources.contains(where: { $0.uniqueID == sourceID }) { sourceID = nil }
        if !destinations.contains(where: { $0.uniqueID == destinationID }) { destinationID = nil }
    }

    /// Opens the selected input for listening and, when one is selected, an output port. Opening sends nothing.
    func connect() {
        guard link == .hardware, let source = sources.first(where: { $0.uniqueID == sourceID }) else { return }
        let destination = destinations.first { $0.uniqueID == destinationID }
        attempt {
            let route = try XTouchOneRoute(inputID: String(source.uniqueID),
                                           outputID: destination.map { String($0.uniqueID) } ?? "not-selected",
                                           transportOrigin: source.isVirtual ? .localVirtual : .physicalUSB)
            input = try XTouchOneMIDIInput(sourceUniqueID: source.uniqueID, clientName: "XTouchOneApp", receive: { [weak self] message in
                Task { @MainActor in self?.received(message) }
            }, setupChanged: { [weak self] in
                Task { @MainActor in self?.setupChanged() }
            })
            output = try destination.map { try XTouchOneMIDIOutput(destinationUniqueID: $0.uniqueID, clientName: "XTouchOneApp") }
            try console.attach(route, at: now)
        }
        if lastError != nil { disconnect() }
    }

    func disconnect() {
        input = nil
        output = nil
        if link == .hardware, isConnected { attempt { try console.detach(at: now) } }
    }

    private func setupChanged() {
        refreshEndpoints()
        if isConnected, sourceID == nil || sources.first(where: { $0.uniqueID == sourceID })?.isOffline == true { disconnect() }
    }

    private func received(_ message: [UInt8]) {
        guard isConnected else { return }
        attempt { try console.receive(message, at: now) }
        flush()
    }

    // MARK: Panel and inspector actions

    func act(_ action: XTouchOnePanelAction) {
        attempt { try console.operate(action, at: now) }
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

    func recall() {
        attempt { try console.recallFader(to: UInt8(recallTarget), at: now, write: transport) }
    }

    /// Drains again later when the rate held something back.
    func flush() {
        attempt { try console.pump(at: now, write: transport) }
    }

    private var transport: (([UInt8]) -> FeedbackAttemptResult)? {
        guard let output else { return nil }
        return { bytes in
            do { try output.write(bytes); return .accepted } catch { return .rejected(reason: "\(error)") }
        }
    }

    func tick() {
        blink.toggle()
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
