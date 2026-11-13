#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Installs the Swift toolchain support into a devkitPro installation that
# already has the Switch 2 SDK (libounce and the Switch 2 portlibs).
#
#   sh install.sh [--devkitpro PATH]
#
# This script only copies files; it does not build anything. The order is:
#
#   sh install.sh
#   sh $DEVKITPRO/swift/install-swift.sh        # downloads Swift from swift.org
#   sh $DEVKITPRO/swift/full/build-stdlib.sh    # builds the full stdlib
#   sh $DEVKITPRO/swift/dispatch/build-dispatch.sh
#   sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh
#
# The console SDK itself comes from the Switch 2 SDK's own installer. This
# script checks for it and says where to get it if it is missing.
#
# Set DEVKITPRO, or pass --devkitpro PATH, to use a devkitPro directory other
# than /opt/devkitpro.

set -eu

usage() {
    echo "usage: sh install.sh [--devkitpro PATH]" >&2
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"

while [ $# -gt 0 ]; do
    case "$1" in
    --devkitpro | --sdk)
        [ $# -ge 2 ] || usage
        DEVKITPRO="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

export DEVKITPRO

die() {
    echo "install.sh: $*" >&2
    exit 1
}

# True if DIRECTORY has the parts of the console SDK that Swift needs.
have_console_sdk() {
    [ -d "$1/libounce" ] && [ -d "$1/portlibs/switch2" ] &&
        [ -x "$1/devkitA64/bin/aarch64-none-elf-gcc" ]
}

have_console_sdk "$DEVKITPRO" || die "no Switch 2 SDK in $DEVKITPRO.

Install the console SDK first. It ships separately from this repository:
  - run the Switch 2 SDK's own install.sh, or
  - point --devkitpro at a devkitPro that already has one.

This repository only adds the Swift toolchain on top of it."

SWIFT_HOME="$DEVKITPRO/swift"

mkdir -p "$SWIFT_HOME/full" "$SWIFT_HOME/dispatch" "$SWIFT_HOME/swiftpm"

# The rules, the shim and the top-level scripts. The installed Swift toolchain
# lives in $DEVKITPRO/swift/toolchain and is deliberately not touched.
cp "$SCRIPT_DIR/swift/switch2_swift_rules" \
    "$SCRIPT_DIR/swift/switch2_swift_full_rules" \
    "$SCRIPT_DIR/swift/switch2_dispatch_rules" \
    "$SCRIPT_DIR/swift/swift_shim.c" \
    "$SCRIPT_DIR/swift/install-swift.sh" \
    "$SCRIPT_DIR/swift/install-devkitpro.sh" \
    "$SWIFT_HOME/"

cp "$SCRIPT_DIR/swift/full/build-stdlib.sh" "$SWIFT_HOME/full/"

cp "$SCRIPT_DIR/swift/dispatch/build-dispatch.sh" "$SWIFT_HOME/dispatch/"
rm -rf "$SWIFT_HOME/dispatch/config" "$SWIFT_HOME/dispatch/shim"
cp -R "$SCRIPT_DIR/swift/dispatch/config" \
    "$SCRIPT_DIR/swift/dispatch/shim" "$SWIFT_HOME/dispatch/"

cp "$SCRIPT_DIR/swift/swiftpm/install-swift-sdk.sh" \
    "$SCRIPT_DIR/swift/swiftpm/switch2-build.sh" "$SWIFT_HOME/swiftpm/"

# The Swift wrapper over libounce and OunceHEN. It is a SwiftPM package, so it
# is copied whole; a package that depends on it points at this directory.
rm -rf "$SWIFT_HOME/libounce"
cp -R "$SCRIPT_DIR/swift/libounce" "$SWIFT_HOME/"

# The test suite is a normal Makefile project, so it is installed as one.
mkdir -p "$DEVKITPRO/tests"
cp -R "$SCRIPT_DIR/tests/Makefile" "$SCRIPT_DIR/tests/source" \
    "$SCRIPT_DIR/tests/common" "$SCRIPT_DIR/tests/diag" "$DEVKITPRO/tests/"

# The porting tools, so an installed SDK can check itself without a checkout.
mkdir -p "$SWIFT_HOME/tools"
cp "$SCRIPT_DIR/scripts/verify_tls_boundary.py" \
    "$SCRIPT_DIR/scripts/port_sdk.py" "$SWIFT_HOME/tools/"

cat <<EOF

The Swift toolchain support is installed in $SWIFT_HOME.

Install what is missing, once:
  sh $SWIFT_HOME/install-swift.sh
  sh $SWIFT_HOME/full/build-stdlib.sh
  sh $SWIFT_HOME/dispatch/build-dispatch.sh
  sh $SWIFT_HOME/swiftpm/install-swift-sdk.sh

To build a Swift program with embedded Swift, include
  include \$(DEVKITPRO)/swift/switch2_swift_rules
in its Makefile. For the full standard library, include
\$(DEVKITPRO)/swift/switch2_swift_full_rules instead.

For libdispatch, include \$(DEVKITPRO)/swift/switch2_dispatch_rules.

For SwiftPM, build a package with
  sh $SWIFT_HOME/swiftpm/switch2-build.sh

For Swift, $SWIFT_HOME/libounce wraps libounce and OunceHEN: console, applet
lifecycle, controller input, filesystem mounts and HEN sessions. Add it as a
path dependency and 'import Ounce'.

To check the port on real hardware, run 'make -C $DEVKITPRO/tests' and launch
the NRO it produces. Results go to the screen and to
sdmc:/switch2-swift-tests.log.

To check this installation against the SDK it was built for:
  python3 $SWIFT_HOME/tools/verify_tls_boundary.py --shim $SWIFT_HOME/swift_shim.c \\
      examples/swift-async/swift-async.elf
EOF
