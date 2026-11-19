// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
for script in ["control_surface_kit_dependency.py", "surface_plugins_dependency.py"] {
    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    verify.arguments = ["python3", "-B", root.appendingPathComponent("configs/" + script).path, "verify"]
    verify.currentDirectoryURL = root
    verify.standardOutput = FileHandle.nullDevice
    try verify.run()
    verify.waitUntilExit()
    guard verify.terminationStatus == 0 else {
        fatalError("Run python3 -B configs/\(script) ensure before building.")
    }
}

let contracts: [Target.Dependency] = ["SurfaceControlContracts", "SurfacePluginContracts"].map {
    .product(name: $0, package: "SurfacePlugins")
}
let kit: [Target.Dependency] = [
    "SurfaceDeviceContracts", "SurfaceBindingContext", "SurfaceConnectionState", "SurfaceFeedbackPlanning",
].map { .product(name: $0, package: "ControlSurfaceKit") }

let package = Package(
    name: "XTouchOneDev",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XTouchOneAdapter", targets: ["XTouchOneAdapter"]),
        // Offline stand-in for the device. The adapter, surface and transport never depend on it;
        // the app uses it for its mock link and to draw what was sent.
        .library(name: "XTouchOneSurface", targets: ["XTouchOneSurface"]),
        .library(name: "XTouchOneCapture", targets: ["XTouchOneCapture"]),
        // The endpoint classes exist only where CoreMIDI does; the packet codec builds everywhere.
        .library(name: "XTouchOneCoreMIDI", targets: ["XTouchOneCoreMIDI"]),
        .executable(name: "xtouch-one-review", targets: ["xtouch-one-review"]),
        .executable(name: "xtouch-one-monitor", targets: ["xtouch-one-monitor"]),
        // The panel app. Its sources compile to a stub outside macOS.
        .executable(name: "XTouchOneApp", targets: ["XTouchOneApp"]),
        .library(name: "XTouchOnePanel", targets: ["XTouchOnePanel"]),
        .library(name: "XTouchOneSimulator", targets: ["XTouchOneSimulator"]),
    ],
    dependencies: [
        .package(path: "build/dependencies/ControlSurfaceKit"),
        .package(path: "build/dependencies/SurfacePlugins"),
    ],
    targets: [
        .target(name: "XTouchOneAdapter", dependencies: kit),
        .testTarget(name: "XTouchOneAdapterTests", dependencies: ["XTouchOneAdapter"] + kit),
        .target(name: "XTouchOneSimulator", dependencies: ["XTouchOneAdapter"]),
        .target(name: "XTouchOneCapture", dependencies: ["XTouchOneAdapter"]),
        .target(name: "XTouchOneSurface", dependencies: ["XTouchOneAdapter"] + kit + contracts),
        .testTarget(name: "XTouchOneSurfaceTests",
                    dependencies: ["XTouchOneAdapter", "XTouchOneSurface", "XTouchOneSimulator"] + kit + contracts),
        .target(name: "XTouchOnePanel", dependencies: ["XTouchOneAdapter", "XTouchOneSimulator"] + kit),
        .testTarget(name: "XTouchOnePanelTests", dependencies: ["XTouchOneAdapter", "XTouchOnePanel"] + kit),
        .executableTarget(name: "XTouchOneApp",
                          dependencies: ["XTouchOneAdapter", "XTouchOnePanel", "XTouchOneCoreMIDI", "XTouchOneSimulator"] + kit),
        .target(name: "XTouchOneCoreMIDI"),
        .executableTarget(name: "xtouch-one-monitor",
                          dependencies: ["XTouchOneAdapter", "XTouchOneCapture", "XTouchOneCoreMIDI", "XTouchOnePanel"] + kit),
        .testTarget(name: "XTouchOneCoreMIDITests", dependencies: ["XTouchOneCoreMIDI"]),
        .executableTarget(name: "xtouch-one-review", dependencies: ["XTouchOneCapture"]),
        .testTarget(name: "XTouchOneCaptureTests", dependencies: ["XTouchOneAdapter", "XTouchOneCapture", "XTouchOneSimulator"]),
        .testTarget(name: "XTouchOneSimulatorTests", dependencies: ["XTouchOneAdapter", "XTouchOneSimulator"] + kit),
    ],
    swiftLanguageModes: [.v6]
)
