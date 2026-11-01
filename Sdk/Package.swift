// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The oldest macOS it runs on: 26, the last release for Intel Macs, unless MOLT_MIN_MACOS says otherwise (Make DMG.command falls
// back to 27 when a build for 26 fails).
let minimumMacOS = ProcessInfo.processInfo.environment["MOLT_MIN_MACOS"] ?? "26.0"

// The module contract. A separate package so that the app and every module link ONE shared copy of these types
// (SwiftPM would otherwise embed a private copy in each module, and the app could not recognise their classes).
let package = Package(
    name: "Sdk",
    platforms: [.macOS(minimumMacOS)],
    products: [.library(name: "MacSpaceSdk", type: .dynamic, targets: ["MacSpaceSdk"])],
    targets: [.target(name: "MacSpaceSdk", path: ".", exclude: ["Package.swift"])]
)
