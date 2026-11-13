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
# Only the Linux x86_64 toolchain is installed here. On other systems, install
# a Swift 6 toolchain from https://swift.org/download and point SWIFT_HOME at
# it, or set SWIFTC to its swiftc.

set -eu

SWIFT_VERSION=6.0.3
SWIFT_PLATFORM=ubuntu24.04
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}.tar.gz"

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

case "$(uname -s)" in
Linux) ;;
*)
    cat >&2 <<EOF
install-swift.sh: this script installs the Linux x86_64 toolchain only.

Install a Swift 6 toolchain from https://swift.org/download, then either put
it in $TOOLCHAIN or set SWIFT_HOME to its directory when you build.
EOF
    exit 1
    ;;
esac

case "$(uname -m)" in
x86_64 | amd64) ;;
*)
    echo "install-swift.sh: this script installs the x86_64 toolchain only." >&2
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
trap 'rm -f "$archive"' EXIT

echo "Downloading Swift $SWIFT_VERSION from swift.org"
if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$archive" "$SWIFT_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$archive" "$SWIFT_URL"
else
    echo "install-swift.sh: curl or wget is required." >&2
    exit 1
fi

echo "Unpacking into $TOOLCHAIN"
as_owner "$SWIFT_HOME" rm -rf "$TOOLCHAIN"
as_owner "$SWIFT_HOME" mkdir -p "$TOOLCHAIN"
as_owner "$TOOLCHAIN" tar -xzf "$archive" -C "$TOOLCHAIN" --strip-components=1

if ! swiftc_error="$("$TOOLCHAIN/usr/bin/swiftc" --version 2>&1)"; then
    cat >&2 <<EOF

install-swift.sh: swiftc does not run on this system.

$swiftc_error

The toolchain is built for Ubuntu 24.04 and needs glibc 2.39 or newer. If the
message above names a missing shared library, install that library, or install
a Swift 6 toolchain from https://swift.org/download that matches your system
and put it in $TOOLCHAIN.
EOF
    exit 1
fi

cat <<EOF

Swift $SWIFT_VERSION is installed in $TOOLCHAIN.

To build a Swift program for Switch 2, include
  include \$(DEVKITPRO)/swift/switch2_swift_rules
in its Makefile. See examples/swift-hello.
EOF
