// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root + "/" + path) }

var targets: [Target] = [
    .target(name: "AzkiCore", path: "Sources/Core", resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")])
]
if exists("Tools/AzkiEval") {
    targets.append(.executableTarget(name: "azki-eval", dependencies: ["AzkiCore"], path: "Tools/AzkiEval"))
}
if exists("Tests/CoreTests") {
    targets.append(.testTarget(name: "AzkiCoreTests", dependencies: ["AzkiCore"], path: "Tests/CoreTests"))
}

let package = Package(
    name: "AzkiNative",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AzkiCore", targets: ["AzkiCore"])],
    targets: targets,
    swiftLanguageModes: [.v5]
)
