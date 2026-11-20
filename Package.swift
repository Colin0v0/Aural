// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aural",
    platforms: [.macOS("15.4")],
    products: [
        .executable(name: "Aural", targets: ["Aural"]),
        .executable(name: "AuralUpdateHelper", targets: ["AuralUpdateHelper"])
    ],
    targets: [
        .target(name: "AuralCore"),
        .target(name: "AuralUpdateSupport"),
        .executableTarget(name: "Aural", dependencies: ["AuralCore", "AuralUpdateSupport"], resources: [.process("Resources")]),
        .executableTarget(name: "AuralUpdateHelper", dependencies: ["AuralUpdateSupport"]),
        .testTarget(name: "AuralCoreTests", dependencies: ["AuralCore"]),
        .testTarget(name: "AuralUpdateHelperTests", dependencies: ["AuralUpdateHelper"]),
        .testTarget(name: "AuralUpdateSupportTests", dependencies: ["AuralUpdateSupport"]),
        .testTarget(name: "AuralPanelTests", dependencies: ["Aural"])
    ],
    swiftLanguageModes: [.v5]
)
