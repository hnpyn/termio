// swift-tools-version: 5.9
// Phase 1 of docs/design/20261024-client-vt-follows-the-stream.md: can a
// renderer of our own on libghostty-vt keep up with ghostty's embedded surface?
// Two executables, so the two engines never share a process:
//   VTSpike       — libghostty-vt + this spike's Metal/CoreText renderer
//   EmbeddedSpike — the embedded surface termio ships today (libghostty-swift)
// Vendor/ghostty-vt.xcframework is built locally with
// `zig build -Demit-lib-vt -Doptimize=ReleaseFast` at the pinned ghostty and is
// not committed.
import PackageDescription

let package = Package(
    name: "VTRenderer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/termio-sh/libghostty-swift", exact: "1.1.9"),
    ],
    targets: [
        .executableTarget(
            name: "VTSpike",
            dependencies: ["GhosttyVt"],
            path: "Sources/VTSpike",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .executableTarget(
            name: "EmbeddedSpike",
            dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-swift")],
            path: "Sources/EmbeddedSpike"
        ),
        .binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework"),
    ]
)
