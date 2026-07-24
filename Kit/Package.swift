// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RommpleTVKit",
    platforms: [.macOS(.v13), .tvOS(.v17)],
    products: [.library(name: "RommpleTVKit", targets: ["RommpleTVKit"])],
    targets: [
        .target(name: "CLibretro"),
        .target(name: "RommpleTVKit", dependencies: ["CLibretro"]),
        .testTarget(name: "RommpleTVKitTests", dependencies: ["RommpleTVKit"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
