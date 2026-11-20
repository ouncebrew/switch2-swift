#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Installs the devkitPro Switch toolchain that the SDK builds on.
#
#   sh install-devkitpro.sh [--devkitpro PATH]
#
# This is the part of install.sh that needs devkitPro pacman: switch-dev
# brings devkitA64, libnx and the NRO tools, and switch-zlib is what the
# standard library links against. It is a separate script so that
# install-swift-sdk.sh can call it without needing the SDK archive, which only
# install.sh has.
#
# It is idempotent: it exits 0 straight away when the toolchain is already
# there, so it is safe to call from another installer.
#
# Set DEVKITPRO, or pass --devkitpro PATH, to use a devkitPro directory other
# than /opt/devkitpro.

set -eu

usage() {
    echo "usage: sh install-devkitpro.sh [--devkitpro PATH]" >&2
    exit 2
}

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

# True on Windows (MSYS2), which has no sudo.
is_windows() {
    case "$(uname -s)" in
    MINGW* | MSYS*) return 0 ;;
    *) return 1 ;;
    esac
}

# Runs a command as root, unless the current user is root or on Windows.
as_root() {
    if [ "$(id -u)" -eq 0 ] || is_windows; then
        "$@"
    else
        sudo "$@"
    fi
}

# Writes the devkitPro pacman command, or nothing if there is none.
find_pacman() {
    if command -v dkp-pacman >/dev/null 2>&1; then
        echo dkp-pacman
    elif command -v pacman >/dev/null 2>&1 &&
        pacman -Sl dkp-libs >/dev/null 2>&1; then
        # Arch Linux and MSYS2 use pacman with the devkitPro repositories.
        echo pacman
    fi
}

# True if the parts of devkitPro that the SDK needs are installed.
have_devkitpro() {
    [ -x "$DEVKITPRO/devkitA64/bin/aarch64-none-elf-gcc" ] &&
        [ -f "$DEVKITPRO/devkitA64/base_rules" ] &&
        [ -x "$DEVKITPRO/tools/bin/elf2nro" ] &&
        [ -x "$DEVKITPRO/tools/bin/nacptool" ] &&
        [ -f "$DEVKITPRO/portlibs/switch/lib/libz.a" ]
}

if have_devkitpro; then
    exit 0
fi

pacman_command="$(find_pacman)"
if [ -z "$pacman_command" ]; then
    cat >&2 <<EOF
install-devkitpro.sh: the devkitPro Switch toolchain is not in $DEVKITPRO,
and devkitPro pacman is not installed.

Install devkitPro pacman first. The instructions are at
  https://devkitpro.org/wiki/devkitPro_pacman
Then run this script again. It installs switch-dev and switch-zlib.

On macOS there is no system pacman: install devkitpro-pacman-installer.pkg
from https://github.com/devkitPro/pacman/releases first. It installs native
Apple silicon and Intel binaries, so no container is needed, and this script
uses the dkp-pacman it puts in /usr/local/bin.
EOF
    exit 1
fi

echo "Installing switch-dev and switch-zlib with $pacman_command"
as_root "$pacman_command" -S --needed --noconfirm switch-dev switch-zlib || {
    echo "install-devkitpro.sh: $pacman_command failed." >&2
    echo "Run '$pacman_command -Syu' to update the package lists, then" \
        "run this script again." >&2
    exit 1
}

have_devkitpro || {
    echo "install-devkitpro.sh: devkitPro in $DEVKITPRO is still not complete." >&2
    exit 1
}
