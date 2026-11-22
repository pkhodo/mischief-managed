// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FrameDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FrameDesk", targets: ["FrameDesk"]),
               .executable(name: "FrameDeskTestCards", targets: ["FrameDeskTestCards"])],
    targets: [
        .target(name: "FrameDeskCore"),
        .executableTarget(name: "FrameDesk", dependencies: ["FrameDeskCore"]),
        .executableTarget(name: "FrameDeskTestCards", dependencies: ["FrameDeskCore"], path: "Integration/TestCards"),
        .testTarget(name: "FrameDeskCoreTests", dependencies: ["FrameDeskCore"]),
        .testTarget(name: "FrameDeskTests", dependencies: ["FrameDesk", "FrameDeskCore"])
    ]
)
