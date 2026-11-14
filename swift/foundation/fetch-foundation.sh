#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Fetches the Foundation source and its dependencies at the versions that match
# the installed Swift toolchain.
#
#   sh fetch-foundation.sh [checkout]
#
# The default checkout is $DEVKITPRO/swift/foundation-src. Run this once,
# before build-foundation.sh. Re-run it with a different --toolchain-version
# after updating the Swift toolchain.
#
# Why versions matter
# -------------------
# Foundation is developed alongside the compiler, and the two move together:
# a branch of Foundation uses language and library features that exist in the
# matching Swift release and not in others. The installed toolchain here is
# Swift 6.0.3, so this fetches Foundation's release/6.0 branch, which is the
# one developed against it. A newer branch needs tools 6.1 or later and fails
# to even load its manifest.
#
# The dependency versions are chosen the same way: swift-collections 1.1
# because Foundation's release/6.0 manifest asks for `from: "1.1.0"`, and
# swift-syntax 600 because it asks for `from: "600.0.0-latest"`. SwiftPM
# would resolve these itself, but pinning them here makes a failed fetch
# obvious and keeps two machines building the same thing.
#
# swift-foundation-icu is fetched because the manifest names it, even though
# FoundationInternationalization is not built. SwiftPM has to be able to
# resolve every dependency in a manifest before it will build any target.

set -eu

usage() {
    echo "usage: sh fetch-foundation.sh [checkout] [--toolchain-version X]" >&2
    exit 2
}

checkout=""
toolchain_version="6.0"

while [ $# -gt 0 ]; do
    case "$1" in
    --toolchain-version)
        [ $# -ge 2 ] || usage
        toolchain_version="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *)
        [ -z "$checkout" ] || usage
        checkout="$1"
        shift
        ;;
    esac
done

DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITPRO

if [ -n "$checkout" ]; then
    SRC="$checkout"
else
    SRC="$DEVKITPRO/swift/foundation-src"
fi

# The branch that matches the toolchain. release/6.0 also covers 6.0.x.
branch="release/$toolchain_version"
case "$toolchain_version" in
6.0 | 6.0.0 | 6.0.1 | 6.0.2 | 6.0.3) branch="release/6.0" ;;
6.1 | 6.1.0 | 6.1.1) branch="release/6.1" ;;
6.2 | 6.2.0 | 6.2.1 | 6.2.2) branch="release/6.2" ;;
*)
    echo "fetch-foundation.sh: no branch known for toolchain $toolchain_version." >&2
    echo "Pick one from https://github.com/swiftlang/swift-foundation/branches" >&2
    echo "and pass it as --toolchain-version with the right prefix." >&2
    exit 1
    ;;
esac

command -v git >/dev/null 2>&1 || {
    echo "fetch-foundation.sh: git is not on PATH" >&2
    exit 1
}

fetch() {
    url="$1"
    ref="$2"
    directory="$3"

    if [ -d "$directory/.git" ]; then
        echo "$(basename "$directory") already fetched"
        return
    fi

    echo "Fetching $(basename "$directory") ($ref)"
    rm -rf "$directory"
    git clone --depth 1 --branch "$ref" --quiet "$url" "$directory" ||
        die_fetch "$url" "$ref"
}

die_fetch() {
    cat >&2 <<EOF
fetch-foundation.sh: could not fetch $1 at $2.

Check the network and the ref. If the branch was removed, pick the one that
matches the toolchain from the repository's branch list and pass its name.
EOF
    exit 1
}

mkdir -p "$SRC"
SRC="$(cd "$SRC" && pwd)"

fetch https://github.com/swiftlang/swift-foundation "$branch" "$SRC"
# The dependencies go beside the checkout, which is what SwiftPM's local-path
# mode expects: the manifest looks for them at ../swift-collections and so on
# when SWIFTCI_USE_LOCAL_DEPS is set. They are fetched into the parent of the
# checkout so that mode works, and so a second checkout can share them.
parent="$(dirname "$SRC")"
fetch https://github.com/apple/swift-collections 1.1.0 "$parent/swift-collections" || true
fetch https://github.com/swiftlang/swift-syntax 600.0.1 "$parent/swift-syntax" || true
fetch https://github.com/swiftlang/swift-foundation-icu release/6.0 "$parent/swift-foundation-icu" || true

cat <<EOF

Foundation is in $SRC

Its dependencies are beside it, in $parent:
  swift-collections, swift-syntax, swift-foundation-icu

CoreFoundation is also needed and is not fetched here: it is the C library the
Swift Foundation is layered on, and it comes from the toolchain rather than
from a repository. build-foundation.sh checks for it.

Build with:
  sh build-foundation.sh "$SRC"
EOF
