import SurfaceBindingContext
import SurfaceConnectionState
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

/// Whether the session may hand display messages to a transport. The default only observes.
public enum XTouchOneOutputPolicy: String, Equatable, Sendable {
    case observe, write
}

/// The endpoints the caller actually selected. Identity is never inferred from there being one device.
public struct XTouchOneRoute: Equatable, Sendable {
    public let inputID: String
    public let outputID: String
    public let deviceID: String?
    public let transportOrigin: EndpointTransportOrigin

    public init(inputID: String, outputID: String, deviceID: String? = nil,
                transportOrigin: EndpointTransportOrigin) throws {
        guard !inputID.isEmpty, !outputID.isEmpty, deviceID?.isEmpty != true else {
            throw XTouchOneMIDIError.invalidRoute
        }
        self.inputID = inputID
        self.outputID = outputID
        self.deviceID = deviceID
        self.transportOrigin = transportOrigin
    }
}

/// Whether the session may ever ask the fader motor to move. The default never does.
public enum XTouchOneMechanismPolicy: String, Equatable, Sendable {
    case disabled, localRecall
}

public enum XTouchOneIgnoredInput: Equatable, Sendable {
    case disconnected, unrecognized
}

public enum XTouchOneInputResult: Equatable, Sendable {
    case event(DeviceInputEvent)
    case ignored(XTouchOneIgnoredInput)
}

/// Facts the device reports about its one fader. Nothing sent to the device appears here.
public enum XTouchOneObservedFact: String, CaseIterable, Sendable {
    case faderPosition = "fader"
    case faderContact = "fader.contact"
}

public struct XTouchOneLifecycleChange: Equatable, Sendable {
    public let previousGeneration: UInt64
    public let generation: UInt64
    /// Queued display targets dropped by this change. They are not replayed.
    public let discardedDisplayTargets: [String]
    public var startedNewGeneration: Bool { previousGeneration != generation }
}

struct RouteIdentity: Equatable, Sendable {
    let profile: XTouchOneMIDIProfile
    let deviceID: String?
    let transportOrigin: EndpointTransportOrigin?
}

/// One caller-driven session for one selected mode and route. It is a value: the caller owns
/// serialization, time and the transport. Attaching, detaching and changing mode produce no output.
public struct XTouchOneSession: Sendable {
    public let source: DeviceSource
    public let outputPolicy: XTouchOneOutputPolicy
    public let mechanismPolicy: XTouchOneMechanismPolicy
    public let mappingRevision: String?
    public private(set) var profile: XTouchOneMIDIProfile
    public private(set) var route: XTouchOneRoute?
    public private(set) var context: DeviceContext
    public private(set) var scope: ContextScope
    private var connection: ConnectionState<RouteIdentity>
    private var inputEndpoint: EndpointProvenance?
    var observations: [XTouchOneObservedFact: DeviceObservation] = [:]

    var grants: Set<XTouchOneOrigin> = []
    var queue: FeedbackQueue<String, XTouchOneDisplayPlan>
    var requests = FeedbackRequestState<String, [UInt8]>(repeatedRequestPolicy: .suppressAfterAcceptedReceipt,
                                                         withdrawnIntentPolicy: .discard)
    var inFlight: [UInt64: XTouchOneDisplayPlan] = [:]
    var latestIssued: [String: UInt64] = [:]
    var nextReference: UInt64 = 0

    public var generation: UInt64 { connection.connectionGeneration }
    public var isConnected: Bool { route != nil }

    /// `displayRate` has no default because the hardware budget is not yet qualified.
    public init(source: DeviceSource, profile: XTouchOneMIDIProfile, displayRate: FeedbackQueueRate,
                outputPolicy: XTouchOneOutputPolicy = .observe,
                mechanismPolicy: XTouchOneMechanismPolicy = .disabled, mappingRevision: String? = nil) throws {
        self.source = source
        self.outputPolicy = outputPolicy
        self.mechanismPolicy = mechanismPolicy
        self.mappingRevision = mappingRevision
        self.profile = profile
        let identity = RouteIdentity(profile: profile, deviceID: nil, transportOrigin: nil)
        connection = ConnectionState(snapshot: try ConnectionSnapshot(inputID: nil, outputID: nil,
                                                                      transportGeneration: nil, isConnected: false,
                                                                      extra: identity),
                                     connectionGeneration: 0)
        context = try DeviceContext(id: profile.contextID, generation: "0", mappingRevision: mappingRevision)
        scope = ContextScope(source: source, context: context, endpoint: nil)
        queue = try FeedbackQueue(rate: displayRate)
    }

    /// Selecting the same route again changes nothing. A different route starts a new generation.
    @discardableResult
    public mutating func attach(_ route: XTouchOneRoute) throws -> XTouchOneLifecycleChange {
        try apply(route: route, profile: profile)
    }

    @discardableResult
    public mutating func detach() throws -> XTouchOneLifecycleChange {
        try apply(route: nil, profile: profile)
    }

    /// The mode and channel are set on the device by the operator. This records that choice only.
    @discardableResult
    public mutating func selectProfile(_ profile: XTouchOneMIDIProfile) throws -> XTouchOneLifecycleChange {
        try apply(route: route, profile: profile)
    }

    /// Takes one framed message received on the attached input.
    public mutating func receive(_ message: [UInt8], at: Double) throws -> XTouchOneInputResult {
        guard let endpoint = inputEndpoint else { return .ignored(.disconnected) }
        guard let input = profile.decodeInput(message) else { return .ignored(.unrecognized) }
        let event = try DeviceInputEvent(elementID: input.id, kind: input.kind, value: input.value, context: context,
                                         endpoint: endpoint, source: source, at: at)
        let fact: XTouchOneObservedFact? = switch (input.id, input.kind) {
        case (Element.fader, .absolute): .faderPosition
        case (Element.fader, .contactBegan), (Element.fader, .contactEnded): .faderContact
        default: nil
        }
        if let fact {
            observations[fact] = try DeviceObservation(targetID: fact.rawValue, value: input.value, state: .observed,
                                                       evidence: .deviceReport, context: context, endpoint: endpoint,
                                                       source: source, at: at)
        }
        return .event(event)
    }

    /// The last report in the current generation, or an explicit unknown. Earlier generations never carry over.
    public func observation(of fact: XTouchOneObservedFact, at: Double) throws -> DeviceObservation {
        if let observed = observations[fact] { return observed }
        let endpoint = try inputEndpoint ?? EndpointProvenance(endpointID: nil, deviceID: nil,
                                                               connectionGeneration: generation,
                                                               transportOrigin: .unknown)
        return try DeviceObservation(targetID: fact.rawValue, value: nil, state: .unknown, evidence: nil,
                                     context: context, endpoint: endpoint, source: source, at: at)
    }

    private mutating func apply(route next: XTouchOneRoute?,
                                profile nextProfile: XTouchOneMIDIProfile) throws -> XTouchOneLifecycleChange {
        let identity = RouteIdentity(profile: nextProfile, deviceID: next?.deviceID,
                                     transportOrigin: next?.transportOrigin)
        let snapshot = try ConnectionSnapshot(inputID: next?.inputID, outputID: next?.outputID,
                                              transportGeneration: nil, isConnected: next != nil, extra: identity)
        var candidate = connection
        let transition = candidate.apply(snapshot)
        guard transition.invalidatesScope else {
            return XTouchOneLifecycleChange(previousGeneration: generation, generation: generation,
                                            discardedDisplayTargets: [])
        }
        let generation = transition.currentGeneration
        let nextContext = try DeviceContext(id: nextProfile.contextID, generation: String(generation),
                                            mappingRevision: mappingRevision)
        func endpoint(_ id: String?) throws -> EndpointProvenance? {
            guard let next, let id else { return nil }
            return try EndpointProvenance(endpointID: id, deviceID: next.deviceID, connectionGeneration: generation,
                                          transportOrigin: next.transportOrigin)
        }
        let nextInput = try endpoint(next?.inputID)
        let nextOutput = try endpoint(next?.outputID)

        connection = candidate
        profile = nextProfile
        route = next
        context = nextContext
        inputEndpoint = nextInput
        scope = ContextScope(source: source, context: nextContext, endpoint: nextOutput)
        observations.removeAll()
        requests.clear()
        latestIssued.removeAll()
        return XTouchOneLifecycleChange(previousGeneration: transition.previousGeneration, generation: generation,
                                        discardedDisplayTargets: queue.clear())
    }
}
