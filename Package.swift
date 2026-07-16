// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenHealth",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenHealth", targets: ["TokenHealth"])
    ],
    targets: [
        .executableTarget(
            name: "TokenHealth",
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "TokenHealthTests",
            dependencies: ["TokenHealth"]
        )
    ]
)
