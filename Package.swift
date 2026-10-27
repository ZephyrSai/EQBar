// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "EQBar",
  platforms: [.macOS("14.4")],
  products: [
    .executable(name: "EQBar", targets: ["EQBar"])
  ],
  targets: [
    // Lock-free primitives shared between the UI thread and the real-time audio thread.
    .target(name: "CAtomics", path: "Sources/CAtomics"),
    // Audio engine, DSP, models and persistence. No UI code lives here.
    .target(
      name: "EQBarCore",
      dependencies: ["CAtomics"],
      path: "Sources/EQBarCore",
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("Accelerate")
      ]
    ),
    // Menu bar app (AppKit only).
    .executableTarget(
      name: "EQBar",
      dependencies: ["EQBarCore"],
      path: "Sources/EQBar"
    ),
    .testTarget(
      name: "EQBarCoreTests",
      dependencies: ["EQBarCore"],
      path: "Tests/EQBarCoreTests"
    )
  ]
)
