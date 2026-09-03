// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageDirectory)/Resources/Info.plist"

let package = Package(
    name: "Thingsync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "thingsync", targets: ["thingsync"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "ThingsyncCore"
        ),
        .target(
            name: "ThingsyncAdapters",
            dependencies: ["ThingsyncCore"]
        ),
        .executableTarget(
            name: "thingsync",
            dependencies: [
                "ThingsyncCore",
                "ThingsyncAdapters",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlistPath])
            ]
        ),
        .testTarget(
            name: "ThingsyncCoreTests",
            dependencies: ["ThingsyncCore"],
            path: "SwiftTests/ThingsyncCoreTests"
        ),
        .testTarget(
            name: "ThingsyncAdaptersTests",
            dependencies: ["ThingsyncAdapters"],
            path: "SwiftTests/ThingsyncAdaptersTests"
        )
    ]
)
