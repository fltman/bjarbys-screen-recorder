// swift-tools-version: 6.2
import PackageDescription

// All logik utan gränssnitt: inspelning, skrivning, markördata, projektformat,
// rörelse, rendering och export. Appen ovanpå är bara vyer.
let package = Package(
    name: "RecorderKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecorderKit", targets: ["RecorderKit"])
    ],
    targets: [
        .target(
            name: "RecorderKit",
            path: "Sources/RecorderKit"
        ),
        .testTarget(
            name: "RecorderKitTests",
            dependencies: ["RecorderKit"],
            path: "Tests/RecorderKitTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
