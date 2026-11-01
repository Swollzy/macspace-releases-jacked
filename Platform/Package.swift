// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The oldest macOS it runs on: 26, the last release for Intel Macs, unless MOLT_MIN_MACOS says otherwise (Make DMG.command falls
// back to 27 when a build for 26 fails).
let minimumMacOS = ProcessInfo.processInfo.environment["MOLT_MIN_MACOS"] ?? "26.0"

// Shared plumbing for the app, the helper and the modules. A separate package for the same reason as Sdk.
let package = Package(
    name: "Platform",
    platforms: [.macOS(minimumMacOS)],
    products: [.library(name: "MacSpacePlatform", type: .dynamic, targets: ["MacSpacePlatform"])],
    dependencies: [.package(path: "../Sdk")],
    targets: [
        .target(name: "MacSpacePlatform", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk")], path: ".", exclude: ["Package.swift"]),
    ]
)
