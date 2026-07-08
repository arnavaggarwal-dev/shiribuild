// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MyApp", targets: ["MyApp"]),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [],
            resources: [
                .process("words_dictionary.json")
            ],
            swiftSettings: [
                // The app uses ObservableObject + DispatchQueue + Network
                // callbacks (pre-concurrency style). Swift 6 language mode
                // would reject dozens of these as data-race errors, so pin
                // the language mode to 5 while keeping the 6.0 toolchain.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
