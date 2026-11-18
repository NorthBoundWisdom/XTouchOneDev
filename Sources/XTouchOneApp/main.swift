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
            GeometryReader { proxy in
                let inspectorWidth = min(max(proxy.size.width * 0.24, 300), 380)
                HStack(spacing: 0) {
                    SurfaceArea(model: model)
                    Divider()
                    ControlInspectorView(model: model).frame(width: inspectorWidth)
                }
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onReceive(clock) { _ in model.tick() }
    }
}

/// The panel and the workspace side by side, or stacked when the window is narrow.
private struct SurfaceArea: View {
    let model: AppModel
    private static let padding: CGFloat = 18
    private static let gap: CGFloat = 16
    private static let minWorkspace: CGFloat = 380

    var body: some View {
        GeometryReader { proxy in
            let natural = SurfacePanelView.naturalSize
            let width = proxy.size.width - Self.padding * 2, height = proxy.size.height - Self.padding * 2
            let sideScale = min(max(min((width - Self.gap - Self.minWorkspace) / natural.width, height / natural.height), 0.8), 1.5)
            let sideBySide = width - Self.gap - natural.width * sideScale >= Self.minWorkspace
            let scale = sideBySide ? sideScale : min(max(width / natural.width, 0.8), 1.5)
            let workspaceWidth = sideBySide ? min(width - Self.gap - natural.width * scale, 640) : natural.width * scale
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if sideBySide {
                        HStack(alignment: .top, spacing: Self.gap) { content(scale, workspaceWidth, height) }
                    } else {
                        VStack(spacing: Self.gap) { content(scale, workspaceWidth, 420) }
                    }
                }
                .padding(Self.padding)
                .frame(minWidth: proxy.size.width, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func content(_ scale: CGFloat, _ workspaceWidth: CGFloat, _ workspaceHeight: CGFloat) -> some View {
        let natural = SurfacePanelView.naturalSize
        SurfacePanelView(model: model)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
        WorkspaceTabsView(model: model)
            .frame(width: workspaceWidth, height: max(360, min(workspaceHeight, natural.height * scale)))
    }
}

struct XTouchOneApplication: App {
    var body: some Scene {
        WindowGroup("X-Touch One Console") { ContentView(model: AppModel()).frame(minWidth: 1180, minHeight: 720) }
            .defaultSize(width: 1520, height: 900)
    }
}

/// `--snapshot <png> [--sample] [--tab values|lights|monitor] [--hardware]` lays the whole window out
/// off screen, writes one image and exits. It shows no window and opens no MIDI endpoint.
@MainActor
func writeSnapshot(to path: String, arguments: [String]) throws {
    let model = AppModel()
    if arguments.contains("--sample") { model.loadSampleScene() }
    if arguments.contains("--hardware") { model.setMode(.hardwareListen) }
    if let flag = arguments.firstIndex(of: "--tab"), flag + 1 < arguments.count, let tab = WorkspaceTab(rawValue: arguments[flag + 1]) {
        model.tab = tab
    }
    let size = NSSize(width: 1520, height: 900)
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
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    NSApplication.shared.setActivationPolicy(.prohibited)
    do { try writeSnapshot(to: arguments[flag + 1], arguments: arguments) } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
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
