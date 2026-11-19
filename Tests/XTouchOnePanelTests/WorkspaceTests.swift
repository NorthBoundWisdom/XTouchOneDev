import Foundation
import SurfacePluginContracts
import Testing
import XTouchOneAdapter
import XTouchOneCapture
import XTouchOnePanel

struct WorkspaceTests {
    @Test func physicalFaderMovesSoftwareOnlyWhileTouchedAndButtonsDebounce() throws {
        var configuration = XTouchOneConfiguration.standard
        configuration.bindings["button.4"] = .action(.step("level", 1))
        let profile = try XTouchOneMIDIProfile(mode: .midiRelative, channel: 1)
        var console = try XTouchOneConsole(link: .hardware, profile: profile, displayRate: .unlimited,
            outputPolicy: .observe, mechanismPolicy: .disabled, demoLinks: false, workspace: XTouchOneWorkspace(configuration: configuration))
        try console.attach(XTouchOneRoute(inputID: "a", outputID: "b", transportOrigin: .physicalUSB), at: 0)
        try console.receive([0xB0, 70, 100], at: 1)
        #expect(console.faderPosition == 100 && console.workspace.values["level"] == 0)
        try console.receive([0x90, 110, 127], at: 2)
        try console.receive([0xB0, 70, 42], at: 2)
        try console.receive([0x90, 110, 0], at: 2)
        try console.receive([0xB0, 70, 89], at: 3)
        #expect(console.workspace.values["level"] == 42 && console.faderPosition == 89)
        try console.receive([0x90, 4, 127], at: 4)
        try console.receive([0x90, 4, 127], at: 5)
        #expect(console.workspace.values["level"] == 43)
        try console.receive([0x90, 4, 0], at: 6)
        try console.receive([0x90, 4, 127], at: 7)
        try console.pump(at: 7) { _ in
            Issue.record("Observe mode wrote to MIDI")
            return .accepted
        }
        #expect(console.workspace.values["level"] == 44 && console.log.allSatisfy { $0.kind != .output })
    }

    @Test func macrosAndScenesCommitAtomicallyAndUndoAsOneStep() throws {
        var workspace = try XTouchOneWorkspace()
        try workspace.run([.set("level", 40), .step("encoder", 6), .cycle("level", [30, 40, 50])])
        #expect(workspace.values["level"] == 50 && workspace.values["encoder"] == 6)
        try workspace.saveScene(named: "Session")
        #expect(throws: XTouchOneWorkspaceError.unknownParameter) {
            try workspace.run([.set("level", 12), .set("missing", 30)])
        }
        #expect(workspace.values["level"] == 50)
        workspace.undo()
        #expect(workspace.values["level"] == 0 && workspace.values["encoder"] == 0)
        try workspace.recallScene(named: "Session")
        #expect(workspace.values["level"] == 50 && workspace.values["encoder"] == 6 && !workspace.canRedo)
        workspace.undo()
        workspace.redo()
        #expect(workspace.values["level"] == 50)
    }

    @Test func importedConfigurationsKeepIdentityAndValidationIsTransactional() throws {
        var configuration = XTouchOneConfiguration.standard
        configuration.programs["Example"] = [.toggle("encoder"), .resetGroup("主控")]
        configuration.labels["encoder.turn"] = .init(name: "Sweep", color: .purple)
        configuration.bindings["button.2"] = .program("Example")
        let contents = try JSONEncoder().encode(configuration)
        #expect(try XTouchOneConfiguration.decode(contents) == configuration)
        var workspace = try XTouchOneWorkspace(configuration: configuration)
        try workspace.set("encoder", to: 88)
        configuration.device = "X-TOUCH COMPACT"
        #expect(throws: XTouchOneWorkspaceError.incompatibleConfiguration) {
            try workspace.apply(configuration, preserveValues: false)
        }
        #expect(workspace.configuration.device == XTouchOneConfiguration.deviceName && workspace.values["encoder"] == 88)
    }

    @Test func replayFramingAndLifecycleNeverReplayRecordedMotorOutput() throws {
        let header = XTouchOneCaptureHeader(mode: .midi, channel: 1, source: "hardware")
        let records: [XTouchOneCaptureRecord] = [
            .init(seq: 1, at: 0, generation: 1, content: .connected),
            .init(seq: 2, at: 1, generation: 1, content: .input([0xB0, 70])),
            .init(seq: 3, at: 1, generation: 1, content: .input([55])),
            .init(seq: 4, at: 2, generation: 1, content: .output([0xB0, 70, 12])),
            .init(seq: 5, at: 3, generation: 1, content: .input([0x90, 2, 127])),
            .init(seq: 6, at: 4, generation: 1, content: .disconnected),
            .init(seq: 7, at: 5, generation: 3, content: .connected),
            .init(seq: 8, at: 6, generation: 3, content: .input([0xB0, 88, 1])),
        ]
        let replay = try XTouchOneCaptureReplay(XTouchOneCapture(header: header, records: records))
        #expect(replay.replayedMessages == 3 && replay.console.jogTicks == -1 && replay.console.pressed.isEmpty)
        #expect(replay.console.session.source.rawValue == "simulation" && replay.console.shown.faderTargets.isEmpty)
        #expect(replay.console.log.allSatisfy { $0.kind != .output })
    }
}
