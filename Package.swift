// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "computer-use-mcp",
    platforms: [
        // macOS 14 is the floor: CADisplayLink (cursor overlay) and
        // SCScreenshotManager (background-safe capture) both require it.
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "computer-use-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .target(name: "CAtSpi", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/computer-use-mcp",
            linkerSettings: [
                .linkedLibrary("atspi", .when(platforms: [.linux])),
                .linkedLibrary("gobject-2.0", .when(platforms: [.linux])),
                .linkedLibrary("glib-2.0", .when(platforms: [.linux])),
                .linkedLibrary("dbus-1", .when(platforms: [.linux])),
            ]
        ),
        .systemLibrary(
            name: "CAtSpi",
            path: "Sources/CAtSpi",
            pkgConfig: "atspi-2",
            providers: [
                .apt(["libatspi2.0-dev"])
            ]
        ),
        // Deterministic GUI fixture app for the end-to-end "truth suite".
        // See docs/fixture-app.md.
        .executableTarget(
            name: "ComputerUseFixture",
            path: "Sources/ComputerUseFixture"
        ),
        .testTarget(
            name: "ComputerUseMCPTests",
            dependencies: ["computer-use-mcp"],
            path: "Tests/ComputerUseMCPTests"
        ),
    ]
)
