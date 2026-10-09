// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MDriveHealthCore",
    defaultLocalization: "vi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MDriveHealthCore", targets: ["MDriveHealthCore"]),
        .executable(name: "mdrivehealth-cli", targets: ["mdrivehealth-cli"]),
        .executable(name: "mdrivehealth-worker", targets: ["mdrivehealth-worker"]),
    ],
    targets: [
        .target(
            name: "CSMART",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "MDriveHealthCore",
            dependencies: ["CSMART"],
            resources: [
                .copy("Resources/drivedb.json"),
                .process("Resources/en.lproj"),
                .process("Resources/vi.lproj"),
            ]
        ),
        .executableTarget(
            name: "mdrivehealth-cli",
            dependencies: ["MDriveHealthCore"]
        ),
        .executableTarget(name: "mdrivehealth-worker", dependencies: ["MDriveHealthCore"]),
        .testTarget(
            name: "MDriveHealthCoreTests",
            dependencies: ["MDriveHealthCore"]
        ),
    ]
)
