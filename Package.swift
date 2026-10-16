// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OmenControl", platforms: [.macOS(.v13)], products: [.executable(name: "OmenControl", targets: ["OmenControl"])], targets: [
    .target(name: "SMCReader", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
    .target(name: "OmenCore"),
    .target(name: "PowerProtocol"),
    .executableTarget(name: "OmenPowerHelper", dependencies: ["PowerProtocol"]),
    .executableTarget(name: "OmenControl", dependencies: ["SMCReader", "OmenCore", "PowerProtocol"], linkerSettings: [.linkedFramework("AppKit")]),
    .executableTarget(name: "OmenCoreChecks", dependencies: ["OmenCore", "PowerProtocol"], path: "Tests/OmenCoreChecks")
])
