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
///
/// `OunceMitm` is the same thing for the mitm and hook framework, which comes
/// from the libounce-mitm patch set rather than from every libounce. It is a
/// separate product so that a package which does not install that patch set
/// still builds `Ounce`.
let package = Package(
    name: "Ounce",
    products: [
        .library(name: "Ounce", targets: ["Ounce"]),
        .library(name: "OunceMitm", targets: ["OunceMitm"])
    ],
    targets: [
        .target(name: "COunce"),
        .target(name: "Ounce", dependencies: ["COunce"]),
        .target(name: "COunceMitm"),
        .target(name: "OunceMitm", dependencies: ["COunceMitm", "Ounce"])
    ]
)
