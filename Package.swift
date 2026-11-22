// swift-tools-version: 5.9
// JetBird iOS - Fast multi-part download manager & PS4 companion
// Port of nueex/JetBird (GPL-3.0-or-later)

import PackageDescription

let package = Package(
    name: "JetBird",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "JetBirdCore", targets: ["JetBirdCore"]),
        .library(name: "JetBirdUI", targets: ["JetBirdUI"]),
        .executable(name: "JetBirdApp", targets: ["JetBirdApp"]),
    ],
    dependencies: [
        // Swift Crypto for TLS/certificate pinning
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Swift ASN.1 for certificate parsing
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // Swift Certificates for X.509
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        // Network framework for Bonjour/mDNS
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
        // ZIP handling for PKG
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        // Core library - protocol, crypto, download manager
        .target(
            name: "JetBirdCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "CJetBirdSpake2", // Rust FFI
            ],
            path: "Sources/JetBirdCore",
            resources: [
                .process("Resources/filters"),
                .process("Resources/certificates"),
            ]
        ),

        // Rust FFI module
        .target(
            name: "CJetBirdSpake2",
            path: "Sources/CJetBirdSpake2",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Foundation"),
            ]
        ),

        // UI layer - SwiftUI views
        .target(
            name: "JetBirdUI",
            dependencies: ["JetBirdCore"],
            path: "Sources/JetBirdUI",
            resources: [
                .process("Resources/Fonts"),
                .process("Resources/Assets.xcassets"),
            ]
        ),

        // Main app target
        .executableTarget(
            name: "JetBirdApp",
            dependencies: ["JetBirdCore", "JetBirdUI"],
            path: "Sources/JetBirdApp",
            resources: [
                .process("Resources/Info.plist"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)