#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Add the Switch 2 Glibc shim to Foundation's package manifest.

    patch-package-swift.py PACKAGE_SWIFT SHIM_DIRECTORY

Run by build-foundation.sh before the build. It is idempotent: running it
twice leaves the manifest as it was after the first run.

Why a manifest edit is needed
-----------------------------
Foundation writes `import Glibc` and expects Swift's Linux overlay to supply
it. Overriding where the *compiler* looks is not enough, because `import`
resolves against the package graph: the module has to be a declared dependency
of the target that imports it, or SwiftPM reports the module as belonging to
the wrong target and refuses it. That is what happens if the shim is added
with -Xswiftc -I, and it fails in a confusing place -- inside swift-syntax,
which is a host-side dependency and never wanted the shim at all.

The edits are two: a package dependency, and the product on
FoundationEssentials. Both are inserted at markers rather than appended, so
the manifest keeps its shape and a reader can see where they went. The file
is also excluded from Foundation's own compatibility guarantees, which is why
patching it is acceptable here at all.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "__SWITCH_GLIBC_SHIM__"


def fail(message: str) -> None:
    sys.stderr.write(f"patch-package-swift.py: {message}\n")
    sys.exit(1)


def main() -> int:
    if len(sys.argv) != 3:
        fail("usage: patch-package-swift.py PACKAGE_SWIFT SHIM_DIRECTORY")

    path = Path(sys.argv[1])
    shim = Path(sys.argv[2]).resolve()

    if not path.is_file():
        fail(f"{path}: no such file")
    if not (shim / "Package.swift").is_file():
        fail(
            f"{shim} does not look like the Glibc shim package; "
            "expected a Package.swift in it"
        )

    source = path.read_text()
    if MARKER in source:
        return 0

    # 1. The dependency.
    #
    #    Foundation's manifest declares its dependencies twice: once behind
    #    SWIFTCI_USE_LOCAL_DEPS, for CI builds that check out siblings, and
    #    once as remote URLs. The remote branch is the one that is taken here,
    #    so the shim goes there. Putting it in the first branch by mistake is
    #    silent -- the package simply does not exist as far as SwiftPM is
    #    concerned, and the error names a target that does not include it.
    marker = """            .package(
                url: "https://github.com/swiftlang/swift-syntax",
                from: "600.0.0-latest")"""
    if marker not in source:
        fail(
            f"{path}: could not find the remote dependency list to put the "
            "shim in. Foundation's manifest has changed shape."
        )
    dependency = (
        f"""            .package(
                url: "https://github.com/swiftlang/swift-syntax",
                from: "600.0.0-latest"),
            // {MARKER}: the Glibc module for this port. It supplies errno,
            // POSIXErrorCode and the calls newlib lacks. Its package is
            // named Glibc, so Foundation's `import Glibc` finds it.
            .package(path: "{shim}"),"""
    )
    source = source.replace(marker, dependency, 1)

    # 2. The product, on the target that does the importing.
    # The indentation in Foundation's manifest is ten spaces, not twelve.
    marker = '''          name: "FoundationEssentials",
          dependencies: [
            "_FoundationCShims",'''
    if marker not in source:
        fail(
            f"{path}: could not find the FoundationEssentials target's "
            "dependency list. Foundation's manifest has changed shape."
        )
    source = source.replace(
        marker,
        '''          name: "FoundationEssentials",
          dependencies: [
            "_FoundationCShims",
            // The Glibc module. Foundation imports it on Linux; the shim
            // stands in for the overlay. See build-foundation.sh.
            .product(name: "Glibc", package: "shim"),''',
        1,
    )

    path.write_text(source)
    print(f"patched {path.name} for the Glibc shim")
    return 0


if __name__ == "__main__":
    sys.exit(main())
