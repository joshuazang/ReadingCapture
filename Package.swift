// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReadingCapture", platforms: [.macOS(.v13)], products: [.executable(name: "ReadingCapture", targets: ["ReadingCapture"])], targets: [.executableTarget(name: "ReadingCapture"), .testTarget(name: "ReadingCaptureTests", dependencies: ["ReadingCapture"])])
