// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "toki",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "toki",
      path: "Sources/toki",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
