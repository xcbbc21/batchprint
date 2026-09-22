// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BatchPrint", platforms: [.macOS(.v14)], products: [.executable(name: "BatchPrint", targets: ["BatchPrint"])], targets: [
 .systemLibrary(name: "CCups"), .systemLibrary(name: "CSQLite"),
 .executableTarget(name: "BatchPrint", dependencies: ["CCups", "CSQLite"], swiftSettings: [.swiftLanguageMode(.v5)]),
 .testTarget(name: "BatchPrintTests", dependencies: ["BatchPrint"], swiftSettings: [.swiftLanguageMode(.v5)])])
