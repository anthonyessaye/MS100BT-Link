// swift-tools-version:5.10
import PackageDescription

// Renders the promo video frames with the app's own drawing code (AppControls.swift is a copy
// of MS100BTLinkApp/Controls.swift) and the real effect catalog from ZoomCore.
let package = Package(
    name: "PromoRenderer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../MS100BTLink")],
    targets: [
        .executableTarget(name: "PromoRenderer", dependencies: [.product(name: "ZoomCore", package: "MS100BTLink")]),
    ],
    swiftLanguageVersions: [.v5]
)
