// swift-tools-version:6.0
import PackageDescription

/// A Swift wrapper over libounce and OunceHEN.
///
/// `COunce` is the C surface: it re-exports `<switch.h>` and `<ouncehen.h>` and
/// turns the accessors libnx marks `static inline` into real functions, which
/// is the only form Swift can call. `Ounce` is the Swift API on top.
///
/// The include paths for both headers come from the Swift SDK's toolset, so a
/// package that depends on this one needs nothing extra in its manifest.
let package = Package(
    name: "Ounce",
    products: [
        .library(name: "Ounce", targets: ["Ounce"])
    ],
    targets: [
        .target(name: "COunce"),
        .target(name: "Ounce", dependencies: ["COunce"])
    ]
)
