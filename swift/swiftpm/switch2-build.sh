#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Builds a Swift package for Switch 2 and packages the result as an NRO.
#
#   sh switch2-build.sh [--devkitpro PATH] [-c release] [--] [swift build options]
#
# Run it from the package directory. It runs
#
#   swift build --swift-sdk switch2 --triple aarch64-none-none-elf
#
# and then turns the executable into <name>.nro next to the package.
#
# The Swift SDK has to be installed first:
#
#   sh install-swift-sdk.sh
#
# The Switch 2 SDK root is found in this order: --devkitpro PATH, then
# $DEVKITPRO, then the directory this script was installed into, then
# /opt/devkitpro. Because the script lives in <root>/swift/swiftpm, an
# installed copy finds its own SDK without any variable being set.

set -eu

usage() {
    echo "usage: sh switch2-build.sh [--devkitpro PATH] [-c release] [--] [options]" >&2
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# True if DIRECTORY looks like a devkitPro installation with the Switch
# toolchain in it.
is_devkitpro() {
    [ -n "$1" ] && [ -x "$1/devkitA64/bin/aarch64-none-elf-gcc" ]
}

DEVKITPRO="${DEVKITPRO:-}"

configuration=debug
build_options=""
while [ $# -gt 0 ]; do
    case "$1" in
    --devkitpro | --sdk)
        [ $# -ge 2 ] || usage
        DEVKITPRO="$2"
        shift 2
        ;;
    -c | --configuration)
        [ $# -ge 2 ] || usage
        configuration="$2"
        shift 2
        ;;
    --)
        shift
        build_options="$*"
        break
        ;;
    -h | --help) usage ;;
    *)
        build_options="$build_options $1"
        shift
        ;;
    esac
done

if ! is_devkitpro "$DEVKITPRO"; then
    # <root>/swift/swiftpm/switch2-build.sh, so the root is two levels up.
    if is_devkitpro "$SCRIPT_DIR/../.."; then
        DEVKITPRO="$(cd "$SCRIPT_DIR/../.." && pwd)"
    else
        DEVKITPRO=/opt/devkitpro
    fi
fi

export DEVKITPRO

SWIFT_HOME="$DEVKITPRO/swift"
TOOLCHAIN="$SWIFT_HOME/toolchain"
SWIFT="$TOOLCHAIN/usr/bin/swift"
TOOLS="$DEVKITPRO/tools/bin"

die() {
    echo "switch2-build.sh: $*" >&2
    exit 1
}

[ -f Package.swift ] || die "no Package.swift here. Run this from a package."
[ -x "$SWIFT" ] ||
    die "no Swift toolchain in $TOOLCHAIN. Run install-swift.sh, or pass --devkitpro."
[ -x "$TOOLS/elf2nro" ] ||
    die "no elf2nro in $TOOLS. Run install.sh, or pass --devkitpro."

"$SWIFT" sdk list 2>/dev/null | grep -qx switch2 ||
    die "the Switch 2 Swift SDK is not installed. Run install-swift-sdk.sh."

echo "Building for Switch 2 ($configuration) with $DEVKITPRO"

# shellcheck disable=SC2086
"$SWIFT" build --swift-sdk switch2 --triple aarch64-none-none-elf \
    -c "$configuration" $build_options

# SwiftPM puts the executable in .build/<triple>/<configuration>/.
binary="$(find .build -type f -name "$(basename "$PWD")" -perm -u+x 2>/dev/null |
    grep -E "/$configuration/" | head -1)"

if [ -z "$binary" ]; then
    # The product name need not match the directory name; fall back to the
    # newest executable SwiftPM produced for this configuration.
    binary="$(find .build -type f -perm -u+x -newer Package.swift 2>/dev/null |
        grep -E "/$configuration/" | grep -v '\.o$' | head -1)"
fi

[ -n "$binary" ] || die "could not find the built executable in .build"

name="$(basename "$binary")"
echo "Packaging $name"

"$TOOLS/nacptool" --create "$name" "Swift Package" "1.0.0" "$name.nacp" >/dev/null

# The icon is optional: libnx ships one, but a devkitPro without it should not
# stop the build.
icon_option=""
for icon in "$DEVKITPRO/libnx/default_icon.jpg" "$DEVKITPRO/libounce/default_icon.jpg"; do
    if [ -f "$icon" ]; then
        icon_option="--icon=$icon"
        break
    fi
done

# shellcheck disable=SC2086
"$TOOLS/elf2nro" "$binary" "$name.nro" $icon_option --nacp="$name.nacp" >/dev/null

echo "Built $name.nro"
