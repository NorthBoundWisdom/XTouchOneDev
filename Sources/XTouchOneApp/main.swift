#if os(macOS)
import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @State var model: AppModel
    private let clock = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                let scale = min(geometry.size.width / PanelView.size.width, geometry.size.height / PanelView.size.height)
                PanelView(model: model)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minWidth: 420, minHeight: 540)
            .padding(12)
            .background(Color(white: 0.2))
            InspectorView(model: model).frame(width: 380)
        }
        .onReceive(clock) { _ in model.tick() }
    }
}

struct XTouchOneApplication: App {
    var body: some Scene {
        WindowGroup("X-Touch One") { ContentView(model: AppModel()) }
            .defaultSize(width: 1040, height: 820)
    }
}

/// `--snapshot <png> [--sample]` draws the panel once and exits. It opens no window and no MIDI endpoint.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count {
    let model = AppModel()
    if arguments.contains("--sample") { model.loadSampleScene() }
    let renderer = ImageRenderer(content: PanelView(model: model).padding(12).background(Color(white: 0.2)))
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("snapshot failed\n".utf8))
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: arguments[flag + 1]))
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
