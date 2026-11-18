import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import Testing
import XTouchOneAdapter

private let route = try! XTouchOneRoute(inputID: "in", outputID: "out", transportOrigin: .localVirtual)

private func makeSession(output: XTouchOneOutputPolicy = .write,
                         mechanism: XTouchOneMechanismPolicy = .localRecall) throws -> XTouchOneSession {
    var session = try XTouchOneSession(source: .simulation, profile: XTouchOneMIDIProfile(mode: .midi, channel: 2),
                                       displayRate: .unlimited, outputPolicy: output, mechanismPolicy: mechanism)
    try session.attach(route)
    return session
}

private func release(_ session: inout XTouchOneSession) throws {
    _ = try session.receive([0x91, 110, 127], at: 0)
    _ = try session.receive([0x91, 110, 0], at: 0)
}

struct RecallTests {
    @Test func recallIsRefusedUnlessEveryConditionHolds() throws {
        var defaults = try XTouchOneSession(source: .simulation, profile: XTouchOneMIDIProfile(mode: .midi, channel: 2),
                                            displayRate: .unlimited)
        #expect(defaults.mechanismPolicy == .disabled && defaults.outputPolicy == .observe)
        #expect(try defaults.recallFader(to: 1) == .refused(.notConnected))
        var observing = try makeSession(output: .observe)
        try release(&observing)
        #expect(try observing.recallFader(to: 1) == .refused(.observeOnly))
        var disabled = try makeSession(mechanism: .disabled)
        try release(&disabled)
        #expect(try disabled.recallFader(to: 1) == .refused(.mechanismDisabled))

        var session = try makeSession()
        #expect(try session.recallFader(to: 1) == .refused(.contactUnknown))
        _ = try session.receive([0xB1, 70, 9], at: 0)
        #expect(try session.recallFader(to: 1) == .refused(.contactUnknown), "position is not contact evidence")
        _ = try session.receive([0x91, 110, 127], at: 0)
        #expect(try session.recallFader(to: 1) == .refused(.touched))
        _ = try session.receive([0x91, 110, 0], at: 0)
        #expect(try session.recallFader(to: 128) == .refused(.invalidPosition))
        guard case .send(let send) = try session.recallFader(to: 100) else { Issue.record("expected a send"); return }
        #expect(send.bytes == [0xB1, 70, 100] && session.preflight(send) == .permitted)
        #expect(send.plan.requiredDirections == [.mechanism] && send.plan.affectedElements == ["fader"])
        #expect(send.plan.origin == .local && send.plan.deliveryMode == .direct)
    }

    @Test func aTouchOrLifecycleChangeAfterIssueStopsTheRecallAtTheGate() throws {
        var session = try makeSession()
        try release(&session)
        guard case .send(let touchedLater) = try session.recallFader(to: 5) else { Issue.record("expected a send"); return }
        _ = try session.receive([0x91, 110, 127], at: 1)
        #expect(session.preflight(touchedLater) == .rejected(.nativeRejected(reason: "fader-not-released")))
        _ = try session.receive([0x91, 110, 0], at: 2)
        #expect(session.preflight(touchedLater) == .permitted)

        try session.detach()
        try session.attach(route)
        #expect(session.preflight(touchedLater) == .rejected(.staleScope))
        #expect(try session.recallFader(to: 5) == .refused(.contactUnknown), "reconnect forgets the earlier release")
    }

    @Test func aRecallAttemptMakesTheFaderPositionUnknown() throws {
        for result in [FeedbackAttemptResult.accepted, .rejected(reason: "transport")] {
            var session = try makeSession()
            try release(&session)
            _ = try session.receive([0xB1, 70, 9], at: 0)
            guard case .send(let send) = try session.recallFader(to: 90) else { Issue.record("expected a send"); return }
            let receipt = try session.complete(send, result: result, at: 1)
            #expect(receipt.creditedToCurrentScope == result.successfulSend)
            #expect(try session.observation(of: .faderPosition, at: 2).state == .unknown)
            #expect(try session.observation(of: .faderContact, at: 2).value == .flag(false))
            _ = try session.receive([0xB1, 70, 90], at: 3)
            #expect(try session.observation(of: .faderPosition, at: 4).value == .number(90))
        }
        var session = try makeSession()
        try release(&session)
        _ = try session.receive([0xB1, 70, 9], at: 0)
        guard case .send(let send) = try session.recallFader(to: 90) else { Issue.record("expected a send"); return }
        _ = try session.complete(send, result: .notAttempted(reason: "gate"), at: 1)
        #expect(try session.observation(of: .faderPosition, at: 2).value == .number(9))
    }

    @Test func recallNeverSharesStateWithDisplayRequests() throws {
        var session = try makeSession()
        try release(&session)
        session.grantDisplay(to: .remote(client: "panel"))
        guard case .send(let recall) = try session.recallFader(to: 1) else { Issue.record("expected a send"); return }
        _ = try session.complete(recall, result: .accepted, at: 0)
        guard case .send(let again) = try session.recallFader(to: 1) else { Issue.record("expected a send"); return }
        #expect(again.plan.reference != recall.plan.reference, "every recall is its own send")
        #expect(session.queuedDisplayTargets.isEmpty)
        session.withdrawDisplay(from: .local)
        #expect(session.preflight(again) == .permitted, "display grants do not govern the local recall")
    }
}
