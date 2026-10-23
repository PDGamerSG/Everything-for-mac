// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EverythingForMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EverythingCore", targets: ["EverythingCore"]),
        .library(name: "EverythingIPC", targets: ["EverythingIPC"]),
        .library(name: "EverythingServers", targets: ["EverythingServers"]),
        .library(name: "EverythingSDK", type: .dynamic, targets: ["EverythingSDK"]),
        .executable(name: "Everything", targets: ["Everything"]),
        .executable(name: "es", targets: ["es"]),
    ],
    targets: [
        .target(name: "EverythingCore", path: "Sources/EverythingCore",
                swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .target(name: "EverythingIPC", dependencies: ["EverythingCore"], path: "Sources/EverythingIPC"),
        .target(name: "EverythingServers", dependencies: ["EverythingCore", "EverythingIPC"], path: "Sources/EverythingServers"),
        .target(name: "EverythingSDK", dependencies: ["EverythingIPC"], path: "Sources/EverythingSDK"),
        .executableTarget(name: "Everything", dependencies: ["EverythingCore", "EverythingIPC", "EverythingServers"], path: "Sources/Everything",
                          exclude: ["Resources/Info.plist"],
                          resources: [.copy("Resources/http"), .copy("Resources/help")],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("Carbon"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreServices")]),
        .executableTarget(name: "es", dependencies: ["EverythingCore", "EverythingIPC"], path: "Sources/es"),
        .testTarget(name: "EverythingCoreTests", dependencies: ["EverythingCore"], path: "Tests/EverythingCoreTests"),
        .testTarget(name: "EverythingIPCTests", dependencies: ["EverythingIPC"], path: "Tests/EverythingIPCTests"),
        .testTarget(name: "EverythingServersTests", dependencies: ["EverythingServers"], path: "Tests/EverythingServersTests"),
        .testTarget(name: "ESTests", dependencies: ["es", "EverythingIPC"], path: "Tests/ESTests"),
    ],
    swiftLanguageVersions: [.v5]
)
