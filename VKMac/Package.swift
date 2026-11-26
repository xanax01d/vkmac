// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "VKMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VKMac", targets: ["VKMac"])
    ],
    targets: [
        .systemLibrary(
            name: "CVkCore",
            path: "Generated/CVkCore"
        ),
        .executableTarget(
            name: "VKMac",
            dependencies: ["CVkCore"],
            path: "Sources/VKMac",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L../target/release", "-lvk_core"]),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
