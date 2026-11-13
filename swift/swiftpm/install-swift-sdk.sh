#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Installs the Switch 2 Swift SDK, so that SwiftPM can cross-compile packages
# for the console.
#
#   sh install-swift-sdk.sh [--devkitpro PATH] [--force] [--no-deps]
#
# After this, a package builds with:
#
#   swift build --swift-sdk switch2 --triple aarch64-none-none-elf
#
# or, more simply, with switch2-build.sh from this directory.
#
# The bundle is generated rather than shipped, because the paths inside it are
# absolute and depend on where devkitPro is installed.
#
# --devkitpro PATH selects the Switch 2 SDK root, which is the devkitPro
# directory. It defaults to $DEVKITPRO, then to /opt/devkitpro. The path is
# resolved to an absolute one and baked into the generated bundle, so the
# installed SDK keeps working without the variable set.
#
# Missing pieces are installed rather than reported, unless --no-deps is given:
#
#   - the devkitPro Switch toolchain, through install-devkitpro.sh
#   - the Swift toolchain, through install-swift.sh
#
# libounce and the Swift standard library are not installed here. libounce
# comes from the SDK archive, which only install.sh has, and the standard
# library is a long build. Both are reported with the command to run.

set -eu

usage() {
    echo "usage: sh install-swift-sdk.sh [--devkitpro PATH] [--force] [--no-deps]" >&2
    exit 2
}

force=no
deps=yes
DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"

while [ $# -gt 0 ]; do
    case "$1" in
    --devkitpro | --sdk)
        [ $# -ge 2 ] || usage
        DEVKITPRO="$2"
        shift 2
        ;;
    --force)
        force=yes
        shift
        ;;
    --no-deps)
        deps=no
        shift
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

# The bundle records absolute paths, so a relative --devkitpro would break as
# soon as the package is built from another directory.
case "$DEVKITPRO" in
/*) ;;
*)
    DEVKITPRO="$(cd "$DEVKITPRO" && pwd)" ||
        {
            echo "install-swift-sdk.sh: $DEVKITPRO: no such directory" >&2
            exit 1
        }
    ;;
esac

export DEVKITPRO

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SWIFT_HOME="$DEVKITPRO/swift"
TOOLCHAIN="$SWIFT_HOME/toolchain"
SWIFTLIB="$TOOLCHAIN/usr/lib/swift/none/aarch64"
DEVKITA64="$DEVKITPRO/devkitA64"
SYSROOT="$DEVKITA64/aarch64-none-elf"
LIBNX="$DEVKITPRO/libounce"
# OunceHEN lives in the Switch 2 portlibs, not in libounce.
PORTLIBS2="$DEVKITPRO/portlibs/switch2"
# The allocator that -lnx brings in. Only libounce has it; libounce_core, which
# a sysmodule links, keeps newlib's malloc and ships no allocator object.
LIBNX_ARCHIVE="$LIBNX/lib/libounce.a"

die() {
    echo "install-swift-sdk.sh: $*" >&2
    exit 1
}

# The helpers sit next to this script's parent directory, both in the
# repository and in an installed SDK.
helper() {
    if [ -x "$SCRIPT_DIR/../$1" ]; then
        echo "$SCRIPT_DIR/../$1"
    fi
}

if [ "$deps" = yes ]; then
    devkitpro_installer="$(helper install-devkitpro.sh)"
    if [ -n "$devkitpro_installer" ]; then
        sh "$devkitpro_installer" --devkitpro "$DEVKITPRO" || exit 1
    fi
fi

[ -x "$DEVKITA64/bin/aarch64-none-elf-gcc" ] ||
    die "no devkitA64 in $DEVKITA64. Run install-devkitpro.sh, or install.sh."

if [ "$deps" = yes ] && [ ! -x "$TOOLCHAIN/usr/bin/swift" ]; then
    swift_installer="$(helper install-swift.sh)"
    if [ -n "$swift_installer" ]; then
        echo "Installing the Swift toolchain"
        sh "$swift_installer" || exit 1
    fi
fi

[ -x "$TOOLCHAIN/usr/bin/swift" ] ||
    die "no Swift toolchain in $TOOLCHAIN. Run install-swift.sh first."

[ -d "$LIBNX" ] ||
    die "no libounce in $LIBNX. Run install.sh first; it unpacks the SDK archive."

if [ ! -f "$SWIFTLIB/Swift.swiftmodule" ]; then
    cat >&2 <<EOF
install-swift-sdk.sh: no Swift standard library in $SWIFTLIB.

Build it once with:
  sh $SWIFT_HOME/full/build-stdlib.sh
EOF
    exit 1
fi

SWIFT="$TOOLCHAIN/usr/bin/swift"

if [ "$force" = no ] && "$SWIFT" sdk list 2>/dev/null | grep -qx switch2; then
    echo "The Switch 2 Swift SDK is already installed."
    echo "Its bundle records the path it was built against, which may not be"
    echo "$DEVKITPRO. Run 'sh install-swift-sdk.sh --force' to rebuild it"
    echo "against that path."
    exit 0
fi

# SwiftPM passes -sdk <sdkRootPath> to the compiler, and the compiler then
# looks for the standard library inside that root. devkitA64's sysroot has no
# Swift standard library, so a merged root is built here: the C sysroot's
# headers and libraries, plus the Swift resources.
MERGED="$SWIFT_HOME/swiftpm/sysroot"
rm -rf "$MERGED"
mkdir -p "$MERGED/usr/lib"

ln -s "$SYSROOT/include" "$MERGED/usr/include"
for entry in "$SYSROOT"/lib/*; do
    ln -s "$entry" "$MERGED/usr/lib/$(basename "$entry")"
done
ln -s "$TOOLCHAIN/usr/lib/swift" "$MERGED/usr/lib/swift"

# The Swift runtime calls posix_memalign, which newlib does not provide, and
# the shim also carries the image registration and thread-local setup. It is
# linked as a plain object rather than an archive member, because it replaces
# swift_stdlib_random: a regular object beats an archive member, so the copy in
# libswiftStdlibStubs.a is never pulled in. Inside an archive both get pulled
# and the link fails with a multiple definition.
"$DEVKITA64/bin/aarch64-none-elf-gcc" -c "$SWIFT_HOME/swift_shim.c" \
    -o "$SWIFT_HOME/swiftpm/swift_shim.o" \
    -march=armv8-a+crc+crypto -mtune=cortex-a57 -fPIE -O2 \
    -I"$LIBNX/include"

# libounce supplies malloc, free, memalign and the rest on top of mimalloc, and
# newlib's libc.a supplies the same names. Whichever the linker sees first wins,
# and the two must not both be pulled in: libounce's malloc.o defines _malloc_r
# and friends, which newlib's mallocr.o also defines, so a link that pulls both
# fails with "multiple definition of `_malloc_r`".
#
# SwiftPM puts -lc on the command line itself, ahead of everything this wrapper
# adds, so libc.a's memory functions would be taken. The Makefile path does not
# have the problem because it reaches -lnx before libc.
#
# The allocator object is therefore passed first, as an object rather than
# through an archive: an object is always loaded, so libounce's definitions are
# claimed before the linker opens libc.a and newlib's mallocr.o is never pulled.
# libswiftCore references malloc and malloc_usable_size, so this matters for any
# package that touches String or Array.
ALLOCATOR_OBJECTS=""
if [ -f "$LIBNX_ARCHIVE" ]; then
    for object in malloc.o heap_pages.o; do
        if "$DEVKITA64/bin/aarch64-none-elf-ar" t "$LIBNX_ARCHIVE" 2>/dev/null \
            | grep -qx "$object"; then
            rm -f "$SWIFT_HOME/swiftpm/$object"
            (cd "$SWIFT_HOME/swiftpm" &&
                "$DEVKITA64/bin/aarch64-none-elf-ar" x \
                    "$LIBNX_ARCHIVE" "$object") ||
                die "could not extract $object from $LIBNX_ARCHIVE"
            ALLOCATOR_OBJECTS="$ALLOCATOR_OBJECTS $SWIFT_HOME/swiftpm/$object"
        fi
    done
fi

# SwiftPM treats the linker as a plain linker and passes it flags such as
# -rpath and --gc-sections. devkitA64's gcc is a driver and rejects those, so
# this wrapper drops the ones that make no sense for a static bare-metal link
# and forwards the rest.
#
# The devkitPro path is substituted below rather than read from the
# environment, so that a bundle installed with --devkitpro keeps working when
# DEVKITPRO is not set.
LINKER="$SWIFT_HOME/swiftpm/switch2-ld"
cat >"$LINKER" <<'LINKER_EOF'
#!/bin/sh
# Translates SwiftPM's linker flags into something devkitA64's gcc accepts.
set -eu

DEVKITPRO="@DEVKITPRO@"
ALLOCATOR_OBJECTS="@ALLOCATOR_OBJECTS@"
arguments=""

while [ $# -gt 0 ]; do
    case "$1" in
    -rpath)
        # A static bare-metal binary has no run-time search path.
        shift 2
        ;;
    --gc-sections | -EL | -EB)
        shift
        ;;
    -lclang_rt.builtins-*)
        # The toolchain only ships the host's builtins. devkitA64's libgcc
        # provides them for the target.
        shift
        ;;
    *)
        arguments="$arguments $1"
        shift
        ;;
    esac
done

# SwiftPM only links libswiftCore, because that is what the module autolinks.
# The rest of the standard library and its C++ dependencies have to be added
# here, the same way the Makefile rules add them.
SWIFTLIB="$DEVKITPRO/swift/toolchain/usr/lib/swift/none/aarch64"

# OunceHEN is not in every SDK release, and only a program that uses it needs
# it. An archive member is pulled only when something references it, so adding
# it when it exists costs nothing.
ouncehen=""
if [ -f "$DEVKITPRO/portlibs/switch2/lib/libouncehen.a" ]; then
    ouncehen="-louncehen"
fi

# Optional link map, for diagnosing this class of problem:
#   SWITCH2_LD_MAP=/tmp/link.map sh $DEVKITPRO/swift/swiftpm/switch2-build.sh
map=""
if [ -n "${SWITCH2_LD_MAP:-}" ]; then
    map="-Wl,-Map,$SWITCH2_LD_MAP"
fi

# shellcheck disable=SC2086
exec "$DEVKITPRO/devkitA64/bin/aarch64-none-elf-gcc" $ALLOCATOR_OBJECTS \
    $arguments $map \
    "$DEVKITPRO/swift/swiftpm/swift_shim.o" \
    -L"$SWIFTLIB" \
    -Wl,--start-group \
    -lswift_Concurrency_swift -lswift_Concurrency \
    -lswiftRuntime -lswiftDemangle -lswiftLLVMSupport \
    -lswiftStdlibStubs -lswiftThreading \
    -Wl,--end-group \
    -L"$DEVKITPRO/libounce/lib" -L"$DEVKITPRO/portlibs/switch2/lib" \
    -lnx $ouncehen -lstdc++ -lm
LINKER_EOF

# The path can contain slashes and ampersands, so it is substituted with a
# delimiter that cannot appear in it. The allocator objects are absolute paths
# already, so they need no expansion beyond the substitution.
sed -e "s|@DEVKITPRO@|$DEVKITPRO|g" \
    -e "s|@ALLOCATOR_OBJECTS@|$ALLOCATOR_OBJECTS|g" \
    "$LINKER" >"$LINKER.tmp"
mv "$LINKER.tmp" "$LINKER"
chmod +x "$LINKER"

bundle="$(mktemp -d)/switch2.artifactbundle"
trap 'rm -rf "$(dirname "$bundle")"' EXIT

mkdir -p "$bundle/switch2"

# The artifact manifest. supportedTriples lists the hosts the SDK runs on,
# not the target it builds for.
cat >"$bundle/info.json" <<EOF
{
  "schemaVersion": "1.0",
  "artifacts": {
    "switch2": {
      "type": "swiftSDK",
      "version": "1.0",
      "variants": [
        {
          "path": "switch2",
          "supportedTriples": [
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu"
          ]
        }
      ]
    }
  }
}
EOF

# The Swift SDK description. Schema 4.0.0 is the one Swift 6 reads; the older
# toolset.json alone is not enough.
cat >"$bundle/switch2/swift-sdk.json" <<EOF
{
  "schemaVersion": "4.0.0",
  "targetTriples": {
    "aarch64-none-none-elf": {
      "sdkRootPath": "$MERGED",
      "swiftResourcesPath": "$TOOLCHAIN/usr/lib/swift",
      "swiftStaticResourcesPath": "$TOOLCHAIN/usr/lib/swift",
      "includeSearchPaths": [
        "$LIBNX/include"
      ],
      "librarySearchPaths": [
        "$LIBNX/lib",
        "$SWIFTLIB"
      ],
      "toolsetPaths": [
        "toolset.json"
      ]
    }
  }
}
EOF

# The tools. The Swift compiler targets the bare-metal triple, the C compiler
# is clang because libdispatch and blocks need it, and the link goes through
# devkitA64's gcc so that switch.specs and libsysbase are picked up.
cat >"$bundle/switch2/toolset.json" <<EOF
{
  "schemaVersion": "1.0",
  "swiftCompiler": {
    "path": "$TOOLCHAIN/usr/bin/swiftc",
    "extraCLIOptions": [
      "-target", "aarch64-none-none-elf",
      "-Xcc", "--sysroot=$SYSROOT",
      "-Xcc", "-I$LIBNX/include",
      "-Xcc", "-I$PORTLIBS2/include"
    ]
  },
  "cCompiler": {
    "path": "$TOOLCHAIN/usr/bin/clang",
    "extraCLIOptions": [
      "-target", "aarch64-none-elf",
      "--sysroot", "$SYSROOT",
      "-I$LIBNX/include",
      "-I$PORTLIBS2/include"
    ]
  },
  "linker": {
    "path": "$LINKER",
    "extraCLIOptions": [
      "-specs=$LIBNX/switch.specs",
      "-march=armv8-a+crc+crypto",
      "-mtune=cortex-a57",
      "-mtp=soft",
      "-fPIE",
      "-L$LIBNX/lib",
      "-L$PORTLIBS2/lib",
      "-L$SWIFTLIB"
    ]
  },
  "librarian": {
    "path": "$DEVKITA64/bin/aarch64-none-elf-ar"
  }
}
EOF

if [ "$force" = yes ]; then
    "$SWIFT" sdk remove switch2 >/dev/null 2>&1 || true
fi

"$SWIFT" sdk install "$bundle"

cat <<EOF

The Switch 2 Swift SDK is installed, built against $DEVKITPRO.

To build a package, run from its directory:
  sh $SWIFT_HOME/swiftpm/switch2-build.sh

or drive SwiftPM directly:
  swift build --swift-sdk switch2 --triple aarch64-none-none-elf

The bundle records $DEVKITPRO, so DEVKITPRO does not have to be set to build.
EOF
