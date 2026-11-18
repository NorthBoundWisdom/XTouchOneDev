// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let verify = Process()
verify.executableURL = URL(fileURLWithPath: "/usr/bin/env")
verify.arguments = ["python3", "-B", root.appendingPathComponent("configs/control_surface_kit_dependency.py").path, "verify"]
verify.currentDirectoryURL = root
verify.standardOutput = FileHandle.nullDevice
try verify.run()
verify.waitUntilExit()
guard verify.terminationStatus == 0 else {
    fatalError("Run python3 -B configs/control_surface_kit_dependency.py ensure before building.")
}

let kit: [Target.Dependency] = [
    "SurfaceDeviceContracts", "SurfaceBindingContext", "SurfaceConnectionState", "SurfaceFeedbackPlanning",
].map { .product(name: $0, package: "ControlSurfaceKit") }

let package = Package(
    name: "XTouchOneDev",
    platforms: [.macOS(.v14)],
    products: [.library(name: "XTouchOneAdapter", targets: ["XTouchOneAdapter"])],
    dependencies: [.package(path: "build/dependencies/ControlSurfaceKit")],
    targets: [
        .target(name: "XTouchOneAdapter", dependencies: kit),
        .testTarget(name: "XTouchOneAdapterTests", dependencies: ["XTouchOneAdapter"] + kit),
    ],
    swiftLanguageModes: [.v6]
)
