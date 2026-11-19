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
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: paths[0]))
    let data = try file.read(upToCount: XTouchOneCapture.maximumBytes + 1) ?? Data()
    try file.close()
    guard data.count <= XTouchOneCapture.maximumBytes else { throw XTouchOneCaptureError.tooLarge }
    let review = try XTouchOneCaptureInspection(jsonLines: String(decoding: data, as: UTF8.self))
    print(review.text, terminator: "")
    if !requireComplete { exit(0) }
    if case .native(_, let native) = review, native.isComplete { exit(0) }
    exit(1)
} catch {
    FileHandle.standardError.write(Data("xtouch-one-review: \(error)\n".utf8))
    exit(2)
}
