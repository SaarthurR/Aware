// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Aware",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AwareCore", targets: ["AwareCore"]),
        .executable(name: "AwareGuardian", targets: ["AwareGuardian"]),
        .executable(name: "AwarePowerHelper", targets: ["AwarePowerHelper"]),
        .executable(name: "AwareCoreChecks", targets: ["AwareCoreChecks"]),
    ],
    targets: [
        .target(name: "AwareCore"),
        .executableTarget(name: "AwareGuardian", dependencies: ["AwareCore"]),
        .executableTarget(name: "AwarePowerHelper", dependencies: ["AwareCore"]),
        .executableTarget(name: "AwareCoreChecks", dependencies: ["AwareCore"], path: "Tests/AwareCoreChecks"),
        // CommandLineTools 26 ships Swift Testing outside the SDK. The explicit framework
        // search path is required when Xcode.app is not installed.
        .testTarget(
            name: "AwareCoreTests",
            dependencies: ["AwareCore"],
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags([
                "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-framework", "Testing",
                "-Xlinker", "-rpath",
                "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath",
                "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
            ])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
