#if os(macOS)
import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @State var model: AppModel
    private let clock = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(model: model)
            HeaderBar(model: model)
            Divider()
            SurfaceArea(model: model)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onReceive(clock) { _ in model.tick() }
    }
}

/// The device and the side panel. The whole device is always visible: it scales to fit the area, and the
/// side panel goes beside it, or below it when the window is tall and narrow enough for that to give a larger device.
private struct SurfaceArea: View {
    let model: AppModel
    private static let padding: CGFloat = 18
    private static let gap: CGFloat = 16
    private static let minSideWidth: CGFloat = 400
    private static let maxSideWidth: CGFloat = 760
    private static let minSideHeight: CGFloat = 460
    private static let scaleRange: ClosedRange<CGFloat> = 0.5...1.5

    struct Plan: Equatable {
        var stacked: Bool
        var scale: CGFloat
        var side: CGSize
    }

    static func plan(in size: CGSize) -> Plan {
        let natural = SurfacePanelView.naturalSize
        let width = max(size.width - padding * 2, 0), height = max(size.height - padding * 2, 0)
        let beside = min(height / natural.height, (width - gap - minSideWidth) / natural.width)
        let below = min(width / natural.width, (height - gap - minSideHeight) / natural.height)
        // Stacking has to buy a visibly larger device, so the layout does not flip on small resizes.
        let stacked = min(below, scaleRange.upperBound) > min(beside, scaleRange.upperBound) * 1.1
        let scale = min(max(stacked ? below : beside, scaleRange.lowerBound), scaleRange.upperBound)
        let side = stacked
            ? CGSize(width: min(width, max(natural.width * scale, maxSideWidth)),
                     height: max(height - gap - natural.height * scale, minSideHeight))
            : CGSize(width: min(max(width - gap - natural.width * scale, minSideWidth), maxSideWidth), height: height)
        return Plan(stacked: stacked, scale: scale, side: side)
    }

    var body: some View {
        GeometryReader { proxy in
            let plan = Self.plan(in: proxy.size)
            let layout = plan.stacked ? AnyLayout(VStackLayout(spacing: Self.gap)) : AnyLayout(HStackLayout(alignment: .top, spacing: Self.gap))
            let natural = SurfacePanelView.naturalSize
            layout {
                SurfacePanelView(model: model)
                    .scaleEffect(plan.scale, anchor: .topLeading)
                    .frame(width: natural.width * plan.scale, height: natural.height * plan.scale, alignment: .topLeading)
                SidePanelView(model: model)
                    .frame(width: plan.side.width, height: plan.side.height)
            }
            .padding(Self.padding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
            .animation(.snappy(duration: 0.2), value: plan.stacked)
        }
    }
}

struct XTouchOneApplication: App {
    var body: some Scene {
        WindowGroup("X-Touch One Console") { ContentView(model: AppModel()).frame(minWidth: 900, minHeight: 680) }
            .defaultSize(width: 1280, height: 900)
    }
}

private enum SnapshotError: LocalizedError {
    case missingOutput
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .missingOutput: "--snapshot requires a PNG output path."
        case .invalidSize: "--size requires two positive integers (WIDTHxHEIGHT), up to 8192 per side and 16777216 total points."
        }
    }
}

private func snapshotSize(arguments: [String]) throws -> NSSize {
    guard let flag = arguments.firstIndex(of: "--size") else { return NSSize(width: 1520, height: 900) }
    guard flag + 1 < arguments.count else { throw SnapshotError.invalidSize }
    let parts = arguments[flag + 1].split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
          (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216 else {
        throw SnapshotError.invalidSize
    }
    return NSSize(width: width, height: height)
}

/// `--snapshot <png> [--sample] [--tab values|lights|monitor] [--hardware] [--size <width>x<height>]` lays the whole window out
/// off screen, writes one image and exits. It shows no window and opens no MIDI endpoint.
@MainActor
func writeSnapshot(to path: String, arguments: [String]) throws {
    let size = try snapshotSize(arguments: arguments)
    let model = AppModel()
    if arguments.contains("--sample") { model.loadSampleScene() }
    if arguments.contains("--hardware") { model.setMode(.hardwareListen) }
    if let flag = arguments.firstIndex(of: "--tab"), flag + 1 < arguments.count, let tab = WorkspaceTab(rawValue: arguments[flag + 1]) {
        model.tab = tab
    }
    let host = NSHostingView(rootView: ContentView(model: model).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--snapshot") {
    do {
        guard flag + 1 < arguments.count, !arguments[flag + 1].hasPrefix("--") else { throw SnapshotError.missingOutput }
        NSApplication.shared.setActivationPolicy(.prohibited)
        try writeSnapshot(to: arguments[flag + 1], arguments: arguments)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}
// A SwiftPM executable has no bundle, so ask for a regular foreground app explicitly.
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
XTouchOneApplication.main()
#else
import Foundation
FileHandle.standardError.write(Data("XTouchOneApp needs SwiftUI and runs on macOS only.\n".utf8))
exit(2)
#endif
