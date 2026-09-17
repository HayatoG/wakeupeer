// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WakeUpeerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WakeUpeerDomain", targets: ["WakeUpeerDomain"]),
        .library(name: "WakeUpeerPersistence", targets: ["WakeUpeerPersistence"]),
        .library(name: "WakeUpeerPlatformMac", targets: ["WakeUpeerPlatformMac"]),
    ],
    targets: [
        // Puro. Só Foundation. Compila em Linux/Windows.
        .target(name: "WakeUpeerDomain"),

        // Puro. FileManager. Compila em Linux/Windows.
        .target(name: "WakeUpeerPersistence", dependencies: ["WakeUpeerDomain"]),

        // AppKit/EventKit/UserNotifications/ServiceManagement. Só macOS.
        .target(name: "WakeUpeerPlatformMac", dependencies: ["WakeUpeerDomain"]),

        .testTarget(name: "WakeUpeerDomainTests", dependencies: ["WakeUpeerDomain"]),
        .testTarget(
            name: "WakeUpeerPersistenceTests",
            dependencies: ["WakeUpeerPersistence", "WakeUpeerDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
