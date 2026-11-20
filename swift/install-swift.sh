#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Installs the Swift toolchain that switch2_swift_rules uses.
#
#   sh install-swift.sh [--force]
#
# The toolchain goes into $DEVKITPRO/swift/toolchain. Set DEVKITPRO to use a
# devkitPro directory other than /opt/devkitpro.
#
# The SDK needs Swift 6.0 or newer. Its embedded standard library is the only
# one that ships a build for aarch64-none-none-elf, the bare-metal AArch64
# target that Switch 2 programs use. Older toolchains have no such target and
# cannot compile for the console.
#
# Two hosts are supported:
#
#   Linux x86_64   the Ubuntu 24.04 toolchain, unpacked from its tarball
#   macOS          the osx toolchain, extracted from its installer package
#
# Both are the same compiler release installed into the same layout, so
# everything after this script is host-neutral. On macOS the devkitA64 tools
# are native too, so no container or FHS environment is involved.
#
# On any other system, install a Swift 6 toolchain from
# https://swift.org/download and put it in $TOOLCHAIN.

set -eu

SWIFT_VERSION=6.0.3
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"

usage() {
    echo "usage: sh install-swift.sh [--force]" >&2
    exit 2
}

force=no
for argument in "$@"; do
    case "$argument" in
    --force) force=yes ;;
    *) usage ;;
    esac
done

DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITPRO

SWIFT_HOME="$DEVKITPRO/swift"
TOOLCHAIN="$SWIFT_HOME/toolchain"

if [ -x "$TOOLCHAIN/usr/bin/swiftc" ] && [ "$force" = no ]; then
    echo "The Swift toolchain is already in $TOOLCHAIN."
    echo "Run 'sh install-swift.sh --force' to replace it."
    exit 0
fi

# Pick the host's package. Both are the same compiler release; only the
# packaging differs. The Linux tarball is rooted at the toolchain, and the
# macOS installer package's payload holds the same `usr` directory.
case "$(uname -s)" in
Linux)
    SWIFT_HOST=linux
    SWIFT_PACKAGE="swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/${SWIFT_TAG}/${SWIFT_PACKAGE}"
    ;;
Darwin)
    SWIFT_HOST=macos
    SWIFT_PACKAGE="swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/${SWIFT_TAG}/${SWIFT_PACKAGE}"
    ;;
*)
    cat >&2 <<EOF
install-swift.sh: unsupported host: $(uname -s).

This script installs the Linux x86_64 and macOS toolchains. Install a Swift 6
toolchain from https://swift.org/download instead, then either put it in
$TOOLCHAIN or set SWIFT_HOME to its directory when you build.
EOF
    exit 1
    ;;
esac

# The architectures each host's package is built for. The macOS package is a
# universal binary for Apple silicon and Intel; the Linux one is x86_64 only.
case "$SWIFT_HOST:$(uname -m)" in
linux:x86_64 | linux:amd64 | macos:arm64 | macos:x86_64) ;;
*)
    echo "install-swift.sh: no $SWIFT_HOST build for $(uname -m)." >&2
    exit 1
    ;;
esac

# Runs a command as root if the current user cannot write DIRECTORY.
#   as_owner DIRECTORY COMMAND...
as_owner() {
    directory="$1"
    shift
    if [ -w "$directory" ]; then
        "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

as_owner "$DEVKITPRO" mkdir -p "$SWIFT_HOME"

archive="$(mktemp)"
expanded=""
cleanup() {
    rm -f "$archive"
    if [ -n "$expanded" ]; then
        rm -rf "$expanded"
    fi
}
trap cleanup EXIT

echo "Downloading Swift $SWIFT_VERSION for $SWIFT_HOST from swift.org"
if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$archive" "$SWIFT_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$archive" "$SWIFT_URL"
else
    echo "install-swift.sh: curl or wget is required." >&2
    exit 1
fi

if [ "$SWIFT_HOST" = macos ]; then
    # The package is a product archive with one component. Expanding it writes
    # the payload to disk without running the system installer or needing root,
    # and the payload's `usr` directory is exactly the tarball's top level.
    # pkgutil refuses to expand into an existing directory, so take the name
    # mktemp picked and remove the empty directory it created.
    expanded="$(mktemp -d)"
    rmdir "$expanded"
    if ! pkgutil --expand-full "$archive" "$expanded"; then
        cat >&2 <<EOF
install-swift.sh: could not expand $SWIFT_PACKAGE.

'pkgutil --expand-full' needs macOS 10.14 or newer. Install a Swift 6
toolchain from https://swift.org/download and put it in $TOOLCHAIN instead.
EOF
        exit 1
    fi

    swiftc_payload="$(find "$expanded" -path '*/usr/bin/swiftc' | head -1)"
    if [ -z "$swiftc_payload" ]; then
        echo "install-swift.sh: no usr/bin/swiftc in $SWIFT_PACKAGE." >&2
        exit 1
    fi
    payload_root="${swiftc_payload%/usr/bin/swiftc}"

    echo "Unpacking into $TOOLCHAIN"
    as_owner "$SWIFT_HOME" rm -rf "$TOOLCHAIN"
    as_owner "$SWIFT_HOME" mkdir -p "$TOOLCHAIN"
    as_owner "$TOOLCHAIN" cp -R "$payload_root/usr" "$TOOLCHAIN/usr"
else
    echo "Unpacking into $TOOLCHAIN"
    as_owner "$SWIFT_HOME" rm -rf "$TOOLCHAIN"
    as_owner "$SWIFT_HOME" mkdir -p "$TOOLCHAIN"
    as_owner "$TOOLCHAIN" tar -xzf "$archive" -C "$TOOLCHAIN" --strip-components=1
fi

if ! swiftc_error="$("$TOOLCHAIN/usr/bin/swiftc" --version 2>&1)"; then
    if [ "$SWIFT_HOST" = macos ]; then
        cat >&2 <<EOF

install-swift.sh: swiftc does not run on this system.

$swiftc_error

The macOS toolchain needs the Xcode command line tools:
  xcode-select --install

It also needs macOS 13 or newer. If the message above names a missing library,
install that library, or install a Swift 6 toolchain from
https://swift.org/download that matches this system and put it in $TOOLCHAIN.
EOF
    else
        cat >&2 <<EOF

install-swift.sh: swiftc does not run on this system.

$swiftc_error

The toolchain is built for Ubuntu 24.04 and needs glibc 2.39 or newer. If the
message above names a missing shared library, install that library, or install
a Swift 6 toolchain from https://swift.org/download that matches your system
and put it in $TOOLCHAIN.
EOF
    fi
    exit 1
fi

cat <<EOF

Swift $SWIFT_VERSION is installed in $TOOLCHAIN.

To build a Swift program for Switch 2, include
  include \$(DEVKITPRO)/swift/switch2_swift_rules
in its Makefile. See examples/swift-hello.
EOF
