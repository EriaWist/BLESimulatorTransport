// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BluetoothMock",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "BluetoothMock", targets: ["BluetoothMock"])
    ],
    targets: [
        .target(name: "BluetoothMock"),
        .testTarget(name: "BluetoothMockTests", dependencies: ["BluetoothMock"])
    ],
    swiftLanguageVersions: [.v5]
)
