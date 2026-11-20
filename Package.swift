// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auxmo",
    platforms: [.macOS("15.4")],
    products: [
        .executable(name: "Auxmo", targets: ["Auxmo"]),
        .executable(name: "AuxmoUpdateHelper", targets: ["AuxmoUpdateHelper"])
    ],
    targets: [
        .target(name: "AuxmoCore"),
        .target(name: "AuxmoUpdateSupport"),
        .executableTarget(name: "Auxmo", dependencies: ["AuxmoCore", "AuxmoUpdateSupport"], resources: [.process("Resources")]),
        .executableTarget(name: "AuxmoUpdateHelper", dependencies: ["AuxmoUpdateSupport"]),
        .testTarget(name: "AuxmoCoreTests", dependencies: ["AuxmoCore"]),
        .testTarget(name: "AuxmoUpdateHelperTests", dependencies: ["AuxmoUpdateHelper"]),
        .testTarget(name: "AuxmoUpdateSupportTests", dependencies: ["AuxmoUpdateSupport"]),
        .testTarget(name: "AuxmoPanelTests", dependencies: ["Auxmo"])
    ],
    swiftLanguageModes: [.v5]
)
