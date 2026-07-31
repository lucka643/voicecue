// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceCue",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoiceCue", targets: ["VoiceCue"])],
    targets: [.executableTarget(name: "VoiceCue")],
    swiftLanguageModes: [.v5]
)
