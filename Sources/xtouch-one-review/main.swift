import Foundation
import XTouchOneCapture

// Reads one capture file and prints its review. It opens no MIDI endpoint.
let arguments = Array(CommandLine.arguments.dropFirst())
let requireComplete = arguments.contains("--require-complete")
let paths = arguments.filter { !$0.hasPrefix("--") }
guard paths.count == 1, arguments.allSatisfy({ !$0.hasPrefix("--") || $0 == "--require-complete" }) else {
    FileHandle.standardError.write(Data("usage: xtouch-one-review [--require-complete] <capture.jsonl>\n".utf8))
    exit(2)
}
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
    let review = try XTouchOneCaptureReview(XTouchOneCapture(jsonLines: String(decoding: data, as: UTF8.self)))
    print(review.text(), terminator: "")
    exit(requireComplete && !review.isComplete ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("xtouch-one-review: \(error)\n".utf8))
    exit(2)
}
