// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FaceID",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FaceID", targets: ["FaceID"]),
        .executable(name: "faceid-cli", targets: ["FaceIDCLI"]),
    ],
    targets: [
        // Face detection, alignment, recognition, attention and blink checks, secure storage, lock screen helpers (no UI)
        .target(
            name: "FaceCore",
            path: "Sources/FaceCore"
        ),
        // Menu bar app: setup, unlocking the lock screen, sudo requests, auto-lock
        .executableTarget(
            name: "FaceID",
            dependencies: ["FaceCore"],
            path: "Sources/FaceID"
        ),
        // Command line tool for checking recognition on photos without the UI
        .executableTarget(
            name: "FaceIDCLI",
            dependencies: ["FaceCore"],
            path: "Sources/FaceIDCLI"
        ),
        .testTarget(
            name: "FaceCoreTests",
            dependencies: ["FaceCore"],
            path: "Tests/FaceCoreTests"
        ),
    ]
)
