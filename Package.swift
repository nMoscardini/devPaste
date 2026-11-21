// swift-tools-version: 6.0
// devPaste - Personal class (see devPaste_Specification_v2_0.md).
import PackageDescription

let package = Package(
    name: "devPaste",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic: models, SQLite store, search, capture policy. No AppKit, so it is unit tested on its own.
        .target(
            name: "DevPasteCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu bar app. build.sh wraps the binary in devPaste.app.
        .executableTarget(
            name: "devPaste",
            dependencies: ["DevPasteCore"],
            // Used by the Xcode build only. build.sh copies App/AppIcon.icns instead.
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "DevPasteCoreTests",
            dependencies: ["DevPasteCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
