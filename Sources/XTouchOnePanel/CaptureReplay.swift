import SurfaceFeedbackPlanning
import XTouchOneAdapter
import XTouchOneCapture

/// Imports only the input stream into an isolated, deterministic console.
public struct XTouchOneCaptureReplay: Sendable {
    public private(set) var console: XTouchOneConsole
    public private(set) var replayedMessages = 0
    public var reportedPosition: UInt8? {
        guard case .number(let value)? = (try? console.session.observation(of: .faderPosition, at: 0))?.value else { return nil }
        return UInt8(value)
    }

    public init(_ capture: XTouchOneCapture, workspace: XTouchOneWorkspace? = nil) throws {
        let profile = try capture.header.profile()
        console = try XTouchOneConsole(link: .mock, profile: profile, displayRate: .unlimited, outputPolicy: .observe,
                                      mechanismPolicy: .disabled, demoLinks: false, workspace: workspace)
        let review = try XTouchOneCaptureReview(capture)
        guard review.problems.isEmpty else { throw XTouchOneCaptureError.invalidHeader("cannot replay a damaged timeline") }
        var framer = XTouchOneMIDIFramer()
        var generation: UInt64?
        for record in capture.records {
            if generation != record.generation {
                framer.reset()
                try console.detach(at: record.at)
                try console.attach(XTouchOneConsole.mockRoute, at: record.at)
                generation = record.generation
            }
            switch record.content {
            case .input(let bytes) where console.session.isConnected:
                for message in framer.feed(bytes) {
                    try console.receive(message, at: record.at)
                    replayedMessages += 1
                }
            case .input, .output: break
            case .disconnected:
                framer.reset()
                try console.detach(at: record.at)
            case .connected:
                try console.attach(XTouchOneConsole.mockRoute, at: record.at)
            }
        }
    }
}
