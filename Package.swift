// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MKTLauncher",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "MKTLauncher",
            dependencies: ["SwiftTerm"],
            path: "Sources/MKTLauncher"
        ),
    ]
)
