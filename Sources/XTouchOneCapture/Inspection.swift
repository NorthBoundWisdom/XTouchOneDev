import Foundation

public enum XTouchOneCaptureInspection: Sendable {
    case native(XTouchOneCapture, XTouchOneCaptureReview)
    case compatibleSummary(device: String, inputCount: Int, outputCount: Int)

    private struct ForeignLine: Decodable {
        var kind: String?
        var direction: String?
        var session: Session?
        struct Session: Decodable { var deviceModel: String? }
    }

    public init(jsonLines text: String) throws {
        guard text.utf8.count <= XTouchOneCapture.maximumBytes else { throw XTouchOneCaptureError.tooLarge }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().filter { !$0.element.allSatisfy(\.isWhitespace) }
        let decoder = JSONDecoder()
        if let first = lines.first,
           let header = try? decoder.decode(ForeignLine.self, from: Data(first.element.utf8)),
           header.kind == "capture-start", let model = header.session?.deviceModel, !model.isEmpty {
            var inputs = 0, outputs = 0
            for (index, line) in lines.dropFirst() {
                guard let event = try? decoder.decode(ForeignLine.self, from: Data(line.utf8)) else {
                    throw XTouchOneCaptureError.invalidRecord(line: index + 1)
                }
                if event.direction == "IN" { inputs += 1 }
                if event.direction == "OUT" { outputs += 1 }
            }
            self = .compatibleSummary(device: model, inputCount: inputs, outputCount: outputs)
        } else {
            let capture = try XTouchOneCapture(jsonLines: text)
            self = .native(capture, try XTouchOneCaptureReview(capture))
        }
    }

    public var text: String {
        switch self {
        case .native(_, let review): review.text()
        case .compatibleSummary(let device, let inputs, let outputs):
            "\(device)\n\(inputs) in, \(outputs) out\n异机录制只提供摘要。\n"
        }
    }
}
