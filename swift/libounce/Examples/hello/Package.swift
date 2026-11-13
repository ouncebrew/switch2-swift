// swift-tools-version:6.0
import PackageDescription

/// A minimal package that depends on the Ounce library.
///
/// The path is `../..` because this example lives inside the library's own
/// directory. In a real project the dependency would be a path to wherever
/// `libounce` was copied, or a URL.
let package = Package(
    name: "hello",
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "hello",
            dependencies: [.product(name: "Ounce", package: "libounce")]
        )
    ]
)
