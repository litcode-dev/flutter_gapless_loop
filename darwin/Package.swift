// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_gapless_loop",
    platforms: [
        .iOS("14.0"),
        .macOS("11.0"),
    ],
    products: [
        .library(name: "flutter_gapless_loop", targets: ["flutter_gapless_loop"]),
    ],
    targets: [
        .target(
            name: "flutter_gapless_loop",
            path: "Sources/flutter_gapless_loop"
        ),
    ]
)
