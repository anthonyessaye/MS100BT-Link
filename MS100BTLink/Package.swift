// swift-tools-version:5.10
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "MS100BTLink",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZoomCore", targets: ["ZoomCore"]),
        .executable(name: "zoomprobe", targets: ["zoomprobe"]),
        .executable(name: "MS100BTLinkApp", targets: ["MS100BTLinkApp"]),
    ],
    targets: [
        .target(
            name: "ZoomCore",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .executableTarget(
            name: "zoomprobe",
            dependencies: ["ZoomCore"],
            linkerSettings: [
                // Embed an Info.plist so the CLI carries NSBluetoothAlwaysUsageDescription.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Support/zoomprobe-Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "MS100BTLinkApp",
            dependencies: ["ZoomCore"],
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("CoreAudioKit")]
        ),
        .testTarget(
            name: "ZoomCoreTests",
            dependencies: ["ZoomCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
