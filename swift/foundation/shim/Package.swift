// swift-tools-version:5.9
import PackageDescription

/// The Glibc module for the Switch 2.
///
/// Foundation imports Glibc on Linux, and that module is a Swift overlay: it
/// re-exports the C library and adds Swift types on top, POSIXErrorCode among
/// them. A bare-metal target has neither, so this package supplies both, which
/// is why the product carries the name Glibc rather than something of its own.
///
/// Nothing here imitates glibc. GlibcC re-exports devkitA64's newlib headers
/// and adds only what newlib lacks; the Swift target re-exports GlibcC and
/// adds the overlay types Foundation expects from its platform module.
///
/// See Sources/Glibc/Glibc.swift.
let package = Package(
    name: "Glibc",
    products: [
        .library(name: "Glibc", targets: ["Glibc"])
    ],
    targets: [
        // The C half: newlib's headers plus the shims in shim.c. A .target,
        // not a .systemLibrary -- a system library describes a package
        // installed somewhere else, and this one is part of the checkout.
        .target(
            name: "GlibcC",
            path: "Sources/GlibcC"
        ),
        .target(
            name: "Glibc",
            dependencies: ["GlibcC"],
            path: "Sources/Glibc"
        )
    ]
)
