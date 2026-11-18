import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import Testing
import XTouchOneAdapter

private let rate = FeedbackQueueRate.bucket(perSecond: 2, burst: 2, failureCooldown: 1)

private func makeSession(_ source: DeviceSource = .simulation, policy: XTouchOneOutputPolicy = .write,
                         attached: Bool = true) throws -> XTouchOneSession {
    var session = try XTouchOneSession(source: source, profile: XTouchOneMIDIProfile(mode: .midi, channel: 1),
                                       displayRate: rate, outputPolicy: policy, mappingRevision: "rev-1")
    if attached { try session.attach(usb) }
    session.grantDisplay(to: .local)
    return session
}

private let usb = try! XTouchOneRoute(inputID: "in-1", outputID: "out-1", deviceID: "one-1", transportOrigin: .physicalUSB)
private let other = try! XTouchOneRoute(inputID: "in-2", outputID: "out-2", transportOrigin: .localVirtual)

private func led(_ address: UInt8, _ state: XTouchOneButtonLED) -> XTouchOneDisplay {
    .buttonLED(XTouchOneButton(rawValue: address)!, state)
}

struct SessionLifecycleTests {
    @Test func inputCarriesTheAttachedRouteAndSource() throws {
        var session = try makeSession(.hardware, policy: .observe, attached: false)
        #expect(try session.receive([0xB0, 70, 5], at: 1) == .ignored(.disconnected))
        let change = try session.attach(usb)
        #expect(change.previousGeneration == 0 && change.generation == 1 && change.startedNewGeneration)
        #expect(try session.attach(usb).startedNewGeneration == false)
        guard case .event(let event) = try session.receive([0xB0, 70, 5], at: 2) else {
            Issue.record("expected a fader event"); return
        }
        #expect(event.source == .hardware && event.elementID == "fader" && event.value == .number(5))
        #expect(event.context.id == "xtouch-one.Midi.ch1" && event.context.generation == "1")
        #expect(event.context.mappingRevision == "rev-1")
        #expect(event.endpoint.endpointID == "in-1" && event.endpoint.deviceID == "one-1")
        #expect(event.endpoint.connectionGeneration == 1 && event.endpoint.transportOrigin == .physicalUSB)
        #expect(session.scope.endpoint?.endpointID == "out-1")
        #expect(try session.receive([0xB0, 71, 5], at: 3) == .ignored(.unrecognized))
        #expect(throws: XTouchOneMIDIError.invalidRoute) {
            try XTouchOneRoute(inputID: "", outputID: "out", transportOrigin: .unknown)
        }
    }

    @Test func faderFactsAreUnknownUntilReportedAndNeverCrossGenerations() throws {
        var session = try makeSession()
        for fact in XTouchOneObservedFact.allCases {
            let unknown = try session.observation(of: fact, at: 1)
            #expect(unknown.state == .unknown && unknown.value == nil && unknown.evidence == nil)
        }
        _ = try session.receive([0xB0, 70, 100], at: 2)
        _ = try session.receive([0x90, 110, 127], at: 3)
        let position = try session.observation(of: .faderPosition, at: 9)
        let contact = try session.observation(of: .faderContact, at: 9)
        #expect(position.value == .number(100) && position.at == 2 && position.evidence == .deviceReport)
        #expect(contact.value == .flag(true) && contact.at == 3 && contact.targetID == "fader.contact")
        _ = try session.receive([0x90, 110, 0], at: 4)
        #expect(try session.observation(of: .faderContact, at: 9).value == .flag(false))

        let changes: [(inout XTouchOneSession) throws -> XTouchOneLifecycleChange] = [
            { try $0.detach() }, { try $0.attach(usb) }, { try $0.attach(other) },
            { try $0.selectProfile(XTouchOneMIDIProfile(mode: .midi, channel: 2)) },
        ]
        for (index, change) in changes.enumerated() {
            if session.isConnected { _ = try session.receive([0xB0 | UInt8(index / 3), 70, 1], at: 5) }
            let before = session.generation
            #expect(try change(&session).generation == before + 1)
            for fact in XTouchOneObservedFact.allCases {
                #expect(try session.observation(of: fact, at: 6).state == .unknown)
            }
        }
        #expect(session.context.id == "xtouch-one.Midi.ch2" && session.context.generation == "5")
    }

    @Test func lifecycleChangesDiscardQueuedDisplayAndIssueNothing() throws {
        var session = try makeSession()
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .queued)
        #expect(try session.requestDisplay(.meter(9), origin: .local) == .queued)
        #expect(try session.detach().discardedDisplayTargets == ["button.1", "meter"])
        #expect(try session.drainDisplay(at: 0).isEmpty)
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .refused(.notConnected))
        try session.attach(usb)
        #expect(session.queuedDisplayTargets.isEmpty)
        #expect(try session.drainDisplay(at: 10).isEmpty)
    }
}

struct SessionFeedbackTests {
    @Test func outputIsRefusedUntilWritePolicyConnectionAndGrant() throws {
        var observing = try makeSession(.hardware, policy: .observe)
        #expect(try observing.requestDisplay(led(0, .on), origin: .local) == .refused(.observeOnly))
        #expect(try observing.writeDisplay(led(0, .on), origin: .local) == .refused(.observeOnly))
        var session = try makeSession()
        let remote = XTouchOneOrigin.remote(client: "panel")
        #expect(try session.requestDisplay(led(0, .on), origin: remote) == .refused(.notGranted))
        #expect(try session.writeDisplay(led(0, .on), origin: remote) == .refused(.notGranted))
        #expect(session.queuedDisplayTargets.isEmpty)
        #expect(throws: XTouchOneMIDIError.invalidDataByte) { try session.requestDisplay(.meter(200), origin: .local) }
    }

    @Test func repaintKeepsFirstRequestOrderLatestValueAndTheRate() throws {
        var session = try makeSession()
        for display in [led(1, .on), .meter(3), led(2, .flash), led(1, .off)] {
            #expect(try session.requestDisplay(display, origin: .local) == .queued)
        }
        #expect(session.queuedDisplayTargets == ["button.1", "meter", "button.2"])
        let first = try session.drainDisplay(at: 0)
        #expect(first.map(\.bytes) == [[0x90, 1, 0], [0xB0, 90, 3]])
        #expect(first.allSatisfy { session.preflight($0) == .permitted })
        #expect(try session.drainDisplay(at: 0.25).isEmpty)
        #expect(try session.drainDisplay(at: 0.5).map(\.bytes) == [[0x90, 2, 64]])
        #expect(throws: FeedbackQueueError.nonfiniteTime) { try session.drainDisplay(at: .nan) }
    }

    @Test func onlyAnAcceptedReceiptSuppressesARepeatedRepaint() throws {
        var session = try makeSession()
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .queued)
        let send = try #require(try session.drainDisplay(at: 0).first)
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .queued)
        #expect(try session.requestDisplay(led(1, .off), origin: .local) == .queued)
        let receipt = try session.complete(send, result: .accepted, at: 0.1)
        #expect(receipt.creditedToCurrentScope && session.queuedDisplayTargets == ["button.1"])
        #expect(receipt.evidence?.outcome == .accepted && receipt.evidence?.endpoint.endpointID == "out-1")

        let off = try #require(try session.drainDisplay(at: 0.1).first)
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .queued)
        let on = try #require(try session.drainDisplay(at: 1).first)
        #expect(try session.complete(off, result: .accepted, at: 1).creditedToCurrentScope == false,
                "a later send to the same target was already issued")
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .queued)
        let latest = on
        #expect(try session.complete(latest, result: .accepted, at: 1.1).creditedToCurrentScope)
        #expect(session.queuedDisplayTargets.isEmpty, "the identical queued repaint is cancelled on acceptance")
        #expect(try session.requestDisplay(led(1, .off), origin: .local) == .queued)
        #expect(try session.requestDisplay(led(1, .on), origin: .local) == .alreadyAccepted)
        #expect(session.queuedDisplayTargets.isEmpty, "the obsolete repaint is cancelled")
        #expect(throws: XTouchOneMIDIError.unknownSend) { try session.complete(latest, result: .accepted, at: 0.3) }
    }

    @Test func failureInvalidatesTheTargetAndStartsTheCooldown() throws {
        var session = try makeSession()
        _ = try session.requestDisplay(.encoderRing(7), origin: .local)
        let accepted = try #require(try session.drainDisplay(at: 0).first)
        _ = try session.complete(accepted, result: .accepted, at: 0)
        guard case .send(let write) = try session.writeDisplay(.encoderRing(8), origin: .local) else {
            Issue.record("expected a direct send"); return
        }
        let failed = try session.complete(write, result: .rejected(reason: "transport"), at: 1)
        #expect(failed.creditedToCurrentScope == false && failed.fact.hasTransportAttempt)
        #expect(failed.evidence?.outcome == .rejected(reason: "transport"))
        #expect(try session.requestDisplay(.encoderRing(7), origin: .local) == .queued,
                "an uncertain target is repainted even with the previously accepted bytes")
        #expect(try session.drainDisplay(at: 1.5).isEmpty)
        #expect(try session.drainDisplay(at: 2).map(\.bytes) == [[0xB0, 80, 7]])
        _ = try session.requestDisplay(.meter(1), origin: .local)
        let pending = try #require(try session.drainDisplay(at: 3).first)
        #expect(throws: DeviceContractError.nonFiniteValue) {
            try session.complete(pending, result: .accepted, at: .infinity)
        }
        #expect(try session.complete(pending, result: .accepted, at: 3).creditedToCurrentScope,
                "a refused completion leaves the send outstanding")
    }

    @Test func directWritesAreNeverSuppressedAndReplaceAQueuedRepaint() throws {
        var session = try makeSession()
        let lcd = XTouchOneDisplay.lcd(upper: "Run", lower: "", color: .green, invertUpper: false, invertLower: false)
        _ = try session.requestDisplay(lcd, origin: .local)
        var sends: [XTouchOneSend] = []
        for _ in 0..<3 {
            guard case .send(let send) = try session.writeDisplay(lcd, origin: .local) else {
                Issue.record("expected a direct send"); return
            }
            #expect(session.preflight(send) == .permitted && send.plan.deliveryMode == .direct)
            #expect(try session.complete(send, result: .accepted, at: 0).fact.successfulSend)
            sends.append(send)
        }
        #expect(Set(sends.map(\.plan.reference)).count == 3 && session.queuedDisplayTargets.isEmpty)
        #expect(sends[0].plan.requiredDirections == [.display] && sends[0].plan.affectedElements == ["lcd"])
    }

    @Test func withdrawalCancelsThatOriginAndFailsItsIssuedSendsAtTheGate() throws {
        var session = try makeSession()
        let remote = XTouchOneOrigin.remote(client: "panel")
        session.grantDisplay(to: remote)
        _ = try session.requestDisplay(led(1, .on), origin: remote)
        let issued = try #require(try session.drainDisplay(at: 0).first)
        _ = try session.requestDisplay(led(2, .on), origin: remote)
        _ = try session.requestDisplay(led(3, .on), origin: .local)
        session.withdrawDisplay(from: remote)
        #expect(session.queuedDisplayTargets == ["button.3"])
        #expect(session.preflight(issued) == .rejected(.authorizationDenied(reason: "display-not-granted")))
        let receipt = try session.complete(issued, result: .notAttempted(reason: "withdrawn"), at: 0)
        #expect(receipt.evidence == nil && receipt.fact.hasTransportAttempt == false)
        session.grantDisplay(to: remote)
        #expect(session.queuedDisplayTargets == ["button.3"], "a new grant restores no earlier request")
        #expect(try session.requestDisplay(led(1, .on), origin: remote) == .queued)
    }

    @Test func sendsIssuedBeforeALifecycleChangeAreStaleAndNeverCredited() throws {
        let changes: [(inout XTouchOneSession) throws -> Void] = [
            { try $0.detach() }, { try $0.detach(); try $0.attach(usb) }, { try $0.attach(other) },
            { try $0.selectProfile(XTouchOneMIDIProfile(mode: .controlChange, channel: 1)) },
        ]
        for change in changes {
            var session = try makeSession()
            _ = try session.requestDisplay(led(4, .on), origin: .local)
            let send = try #require(try session.drainDisplay(at: 0).first)
            try change(&session)
            #expect(session.preflight(send) == .rejected(.staleScope))
            let late = try session.complete(send, result: .accepted, at: 1)
            #expect(late.fact.successfulSend && late.creditedToCurrentScope == false)
            #expect(late.evidence?.context.generation == "1", "evidence keeps the generation it was captured in")
            if !session.isConnected { try session.attach(usb) }
            #expect(try session.requestDisplay(led(4, .on), origin: .local) == .queued)
        }
    }

    @Test func theGateRejectsSendsTheSessionDidNotIssue() throws {
        var session = try makeSession()
        _ = try session.requestDisplay(led(5, .on), origin: .local)
        let send = try #require(try session.drainDisplay(at: 0).first)
        var twin = try makeSession()
        #expect(twin.preflight(send) == .rejected(.planMismatch))
        _ = try twin.requestDisplay(led(6, .on), origin: .local)
        let foreign = try #require(try twin.drainDisplay(at: 0).first)
        #expect(foreign.plan.reference == send.plan.reference && session.preflight(foreign) == .rejected(.planMismatch))
        #expect(throws: XTouchOneMIDIError.unknownSend) { try session.complete(foreign, result: .accepted, at: 0) }
    }

    @Test(arguments: XTouchOneMIDIMode.allCases)
    func noDisplayRequestCanProduceAFaderTarget(_ mode: XTouchOneMIDIMode) throws {
        var session = try XTouchOneSession(source: .hardware, profile: XTouchOneMIDIProfile(mode: mode, channel: 1),
                                           displayRate: .unlimited, outputPolicy: .write)
        try session.attach(usb)
        session.grantDisplay(to: .local)
        var displays = (UInt8(0)...34).flatMap { address in
            [XTouchOneButtonLED.off, .flash, .on].map { led(address, $0) }
        }
        displays += (UInt8(0)...127).flatMap { [XTouchOneDisplay.encoderRing($0), .meter($0)] }
        displays.append(.lcd(upper: "A", lower: "B", color: .white, invertUpper: false, invertLower: true))
        displays.append(.segmentDisplay(segments: Array(repeating: 0x7F, count: 12), dotsLow: 0x7F, dotsHigh: 0x1F))
        for display in displays {
            guard case .send(let send) = try session.writeDisplay(display, origin: .local) else {
                Issue.record("expected a direct send"); return
            }
            #expect(session.preflight(send) == .permitted)
            #expect(!(send.bytes.count == 3 && send.bytes[0] & 0xF0 == 0xB0 && send.bytes[1] == 70))
            _ = try session.complete(send, result: .accepted, at: 0)
        }
    }
}
