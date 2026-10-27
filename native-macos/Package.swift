// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PandaPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PandaPlayer", targets: ["PandaPlayer"])],
    targets: [
        .target(name: "PlayerCore"),
        .target(name: "CMPV", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "PandaPlayer", dependencies: ["CMPV", "PlayerCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("OpenGL"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/Applications/IINA.app/Contents/Frameworks"], .when(configuration: .debug))
        ]),
        .executableTarget(name: "PlayerCoreChecks", dependencies: ["PlayerCore"], path: "Tests/PlayerCoreTests")
    ]
)
