// swift-tools-version:5.10
import PackageDescription

// Renders the promo video frames. AppControls.swift holds the app's pedal, knob and LED drawing
// (from the native Mac app), so the video looks like the app; it needs nothing else from the repo.
let package = Package(
    name: "PromoRenderer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PromoRenderer"),
    ],
    swiftLanguageVersions: [.v5]
)
