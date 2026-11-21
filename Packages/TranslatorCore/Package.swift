// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TranslatorCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TranslatorCore", targets: ["TranslatorCore"]),
        .executable(name: "translator-cli", targets: ["translator-cli"]),
    ],
    targets: [
        .target(name: "TranslatorCore"),
        .executableTarget(name: "translator-cli", dependencies: ["TranslatorCore"]),
    ],
    swiftLanguageModes: [.v6]
)
