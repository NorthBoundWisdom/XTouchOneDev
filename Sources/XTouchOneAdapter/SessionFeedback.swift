import SurfaceBindingContext
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

/// Who asked for a display change. Each origin needs its own grant.
public enum XTouchOneOrigin: Hashable, Sendable {
    case local
    case remote(client: String)
}

public typealias XTouchOneDisplayPlan = FeedbackPlan<[UInt8], XTouchOneOrigin, ContextScope, UInt64, XTouchOneRoute>

/// A display message issued by the session. Issuing is not permission: call `preflight` right before the write.
public struct XTouchOneSend: Equatable, Sendable {
    public let plan: XTouchOneDisplayPlan
    public var bytes: [UInt8] { plan.payload }
    public var targetID: String { plan.targetID }
}

public enum XTouchOneRefusal: Equatable, Sendable {
    case notConnected, observeOnly, notGranted
}

public enum XTouchOneRepaintOutcome: Equatable, Sendable {
    case queued
    /// The same bytes already have an accepted receipt in this generation.
    case alreadyAccepted
    case refused(XTouchOneRefusal)
}

public enum XTouchOneWriteOutcome: Equatable, Sendable {
    case send(XTouchOneSend)
    case refused(XTouchOneRefusal)
}

public enum XTouchOneRecallRefusal: Equatable, Sendable {
    case notConnected, observeOnly, mechanismDisabled, invalidPosition
    /// No touch report has arrived in this generation, so a hand may be on the fader.
    case contactUnknown
    case touched
}

public enum XTouchOneRecallOutcome: Equatable, Sendable {
    case send(XTouchOneSend)
    case refused(XTouchOneRecallRefusal)
}

public struct XTouchOneReceipt: Equatable, Sendable {
    public let fact: FeedbackReceiptFact<XTouchOneDisplayPlan>
    /// True when an accepted send still belonged to the current generation and was the latest for its target.
    public let creditedToCurrentScope: Bool
    /// Sent evidence only. It says nothing about what the device shows.
    public let evidence: TransmissionEvidence?
}

struct NativeGateFacts: Equatable, Sendable {
    let generation: UInt64
    let route: XTouchOneRoute?
    let outputPolicy: XTouchOneOutputPolicy
    let granted: Bool
    let faderContact: DeviceValue?
}

extension XTouchOneSession {
    public mutating func grantDisplay(to origin: XTouchOneOrigin) { grants.insert(origin) }

    /// Cancels this origin's queued repaints and forgets what was accepted for those targets.
    public mutating func withdrawDisplay(from origin: XTouchOneOrigin) {
        grants.remove(origin)
        let targets = queue.orderedEntries.filter { $0.item.origin == origin }.map(\.key)
        for target in targets { queue.cancel(target) }
        requests.withdraw(targets)
    }

    public var queuedDisplayTargets: [String] { queue.orderedKeys }

    /// Coalescing repaint: the latest value per target waits in first-request order for `drainDisplay`.
    public mutating func requestDisplay(_ display: XTouchOneDisplay,
                                        origin: XTouchOneOrigin) throws -> XTouchOneRepaintOutcome {
        let bytes = try profile.encodeDisplay(display)
        if let refusal = refusal(for: origin) { return .refused(refusal) }
        let target = display.targetID
        guard requests.request(bytes, for: target) != nil else {
            queue.cancel(target)
            return .alreadyAccepted
        }
        queue.enqueue(try makePlan(bytes, target: target, origin: origin, delivery: .coalescible), for: target)
        return .queued
    }

    /// Removes what the rate allows from the queue. Each returned send still needs `preflight` and `complete`.
    public mutating func drainDisplay(at instant: Double) throws -> [XTouchOneSend] {
        try queue.drain(at: instant).map { issue($0.item) }
    }

    /// One send per call, never coalesced or suppressed. It replaces a queued repaint of the same target.
    public mutating func writeDisplay(_ display: XTouchOneDisplay,
                                      origin: XTouchOneOrigin) throws -> XTouchOneWriteOutcome {
        let bytes = try profile.encodeDisplay(display)
        if let refusal = refusal(for: origin) { return .refused(refusal) }
        let plan = try makePlan(bytes, target: display.targetID, origin: origin, delivery: .direct)
        queue.cancel(plan.targetID)
        return .send(issue(plan))
    }

    /// Moves the motor fader on an explicit local operator action. No remote path reaches this call.
    /// It needs a released-touch report from the current generation; an unknown or touched fader is refused.
    public mutating func recallFader(to position: UInt8) throws -> XTouchOneRecallOutcome {
        guard isConnected else { return .refused(.notConnected) }
        guard outputPolicy == .write else { return .refused(.observeOnly) }
        guard mechanismPolicy == .localRecall else { return .refused(.mechanismDisabled) }
        guard position < 0x80 else { return .refused(.invalidPosition) }
        switch observations[.faderContact]?.value {
        case .flag(false): break
        case .flag(true): return .refused(.touched)
        default: return .refused(.contactUnknown)
        }
        let bytes = [0xB0 | (profile.channel - 1), Address.fader, position]
        return .send(issue(try makePlan(bytes, target: Element.fader, origin: .local, delivery: .direct,
                                        classification: .mechanism)))
    }

    /// The final gate, evaluated against the session as it is now. Only an issued, uncompleted send can pass.
    public func preflight(_ send: XTouchOneSend) -> FeedbackPreflight {
        let plan = send.plan
        guard inFlight[plan.reference] == plan else { return .rejected(.planMismatch) }
        let facts = gateFacts(for: plan.origin)
        let proof = FeedbackProof(plan: plan, nativeSnapshot: facts, authorization: authorization(for: plan),
                                  safety: safety(of: plan))
        return FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: scope, currentNativeSnapshot: facts)
    }

    /// Records what the transport actually did with an issued send. A refused preflight completes as not attempted.
    public mutating func complete(_ send: XTouchOneSend, result: FeedbackAttemptResult,
                                  at instant: Double) throws -> XTouchOneReceipt {
        let plan = send.plan
        guard inFlight[plan.reference] == plan else { throw XTouchOneMIDIError.unknownSend }
        let fact = FeedbackReceiptFact(plan: plan, result: result)
        let evidence = try result.transmissionOutcome.map {
            try TransmissionEvidence(effectID: String(plan.reference), targetID: plan.targetID, context: plan.scope.context,
                                     endpoint: plan.endpointEvidence, source: plan.source, at: instant, outcome: $0)
        }
        let current = FeedbackReceiptEligibility.matchesCurrentScope(fact, currentScope: scope)
        if current, case .rejected = result { try queue.noteFailure(at: instant) }
        inFlight.removeValue(forKey: plan.reference)
        if plan.classification == .mechanism {
            // The motor may have moved. Only a new device report says where the fader is.
            if current, result.hasTransportAttempt { observations[.faderPosition] = nil }
            return XTouchOneReceipt(fact: fact, creditedToCurrentScope: current && result.successfulSend,
                                    evidence: evidence)
        }

        let latest = latestIssued[plan.targetID] == plan.reference
        let credited = current && latest && result.successfulSend
        if credited {
            requests.recordAccepted(plan.payload, for: plan.targetID)
            if queue.item(for: plan.targetID)?.payload == plan.payload { queue.cancel(plan.targetID) }
        } else if current, latest {
            if plan.classification == .display { requests.invalidate([plan.targetID]) }
        }
        return XTouchOneReceipt(fact: fact, creditedToCurrentScope: credited, evidence: evidence)
    }

    private func refusal(for origin: XTouchOneOrigin) -> XTouchOneRefusal? {
        guard isConnected else { return .notConnected }
        guard outputPolicy == .write else { return .observeOnly }
        let authorization: PlanAuthorization = grants.contains(origin)
            ? .granted(directions: [.display]) : .denied(reason: "display-not-granted")
        let check = FeedbackAuthorizationCheck.evaluate(requirements: [.display], authorization: authorization)
        return check == .sufficient ? nil : .notGranted
    }

    /// Display needs the origin's grant. Mechanism is local only and needs the session's explicit policy.
    private func authorization(for plan: XTouchOneDisplayPlan) -> PlanAuthorization {
        switch plan.classification {
        case .display:
            grants.contains(plan.origin) ? .granted(directions: [.display]) : .denied(reason: "display-not-granted")
        case .mechanism:
            plan.origin == .local && mechanismPolicy == .localRecall
                ? .granted(directions: [.mechanism]) : .denied(reason: "mechanism-not-allowed")
        case .management, .query:
            .denied(reason: "unsupported-effect")
        }
    }

    private func gateFacts(for origin: XTouchOneOrigin) -> NativeGateFacts {
        NativeGateFacts(generation: generation, route: route, outputPolicy: outputPolicy,
                        granted: grants.contains(origin), faderContact: observations[.faderContact]?.value)
    }

    private func safety(of plan: XTouchOneDisplayPlan) -> NativeSafetyResult {
        guard let route else { return .rejected(reason: "disconnected") }
        guard outputPolicy == .write else { return .rejected(reason: "observe-only") }
        guard plan.capturedEvidence == route else { return .rejected(reason: "endpoint-changed") }
        switch plan.classification {
        case .display:
            guard profile.isDisplayPayload(plan.payload) else { return .rejected(reason: "not-a-display-message") }
        case .mechanism:
            guard plan.payload.count == 3, plan.payload[0] == 0xB0 | (profile.channel - 1),
                  plan.payload[1] == Address.fader, plan.payload[2] < 0x80 else {
                return .rejected(reason: "not-a-fader-target")
            }
            guard observations[.faderContact]?.value == .flag(false) else {
                return .rejected(reason: "fader-not-released")
            }
        case .management, .query:
            return .rejected(reason: "unsupported-effect")
        }
        return .passed
    }

    private mutating func makePlan(_ bytes: [UInt8], target: String, origin: XTouchOneOrigin,
                                   delivery: FeedbackDeliveryMode,
                                   classification: EffectClassification = .display) throws -> XTouchOneDisplayPlan {
        guard let route, let endpoint = scope.endpoint else { throw XTouchOneMIDIError.invalidRoute }
        nextReference &+= 1
        return try FeedbackPlan(reference: nextReference, payload: bytes, origin: origin, scope: scope, source: source,
                                endpointEvidence: endpoint, capturedEvidence: route, targetID: target,
                                affectedElements: [target], classification: classification, sideEffects: [],
                                deliveryMode: delivery)
    }

    private mutating func issue(_ plan: XTouchOneDisplayPlan) -> XTouchOneSend {
        inFlight[plan.reference] = plan
        latestIssued[plan.targetID] = plan.reference
        // What the target shows is uncertain until this send has its own receipt.
        if plan.classification == .display { requests.invalidate([plan.targetID]) }
        return XTouchOneSend(plan: plan)
    }
}
