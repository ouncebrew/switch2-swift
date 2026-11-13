#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Builds libdispatch for Switch 2 and installs it into $DEVKITPRO/swift/dispatch.
#
#   sh build-dispatch.sh [--jobs N]
#
# libdispatch has no configuration for a bare-metal target. This script builds
# it against newlib and libounce with a hand-written config and a set of shims:
#
#   config/config.h        the platform configuration
#   shim/                  headers newlib lacks, and the emulations
#
# The shims provide what the console does not have:
#
#   futex_shim.c   FUTEX_WAIT and FUTEX_WAKE over pthread mutexes and
#                  condition variables, because libdispatch's Linux lock
#                  encoding calls syscall(SYS_futex, ...) directly
#   epoll_shim.c   epoll, eventfd and timerfd over semaphores and the system
#                  tick, because the console has none of them and libdispatch's
#                  manager thread needs all three
#   libc_shim.c    the C library functions newlib declares but does not
#                  implement: pread, pwrite, sigaction, syslog
#   dispatch_stubs.c  the parts that cannot work without a descriptor table
#                  or mach: dispatch I/O, disk sources, vouchers, workqueues
#
# POSIX semaphores are not shimmed: libsysbase.a implements them on top of the
# __syscall_* hooks that libounce provides.
#
# The build needs about 1 GiB of disk and a few minutes.
#
# Set DEVKITPRO to use a devkitPro directory other than /opt/devkitpro.
# Set CLANG to use a compiler other than the one in the Swift toolchain.
# CXX is still honoured for backwards compatibility, but only when it names a
# C compiler: the FHS environment in nix/fhs-env.nix sets CXX to clang++ for the
# standard library build, and a C++ driver rejects the C flags used here.

set -eu

SWIFT_VERSION=6.0.3
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"

usage() {
    echo "usage: sh build-dispatch.sh [--jobs N]" >&2
    exit 2
}

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
while [ $# -gt 0 ]; do
    case "$1" in
    --jobs)
        [ $# -ge 2 ] || usage
        jobs="$2"
        shift 2
        ;;
    *) usage ;;
    esac
done

DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITPRO

DISPATCH_HOME="$DEVKITPRO/swift/dispatch"
TOOLCHAIN="$DEVKITPRO/swift/toolchain"
BUILD="$DISPATCH_HOME/build"
SRC="$BUILD/src"
OBJ="$BUILD/obj"
INSTALL="$DISPATCH_HOME/lib"

DEVKITA64="$DEVKITPRO/devkitA64"
SYSROOT="$DEVKITA64/aarch64-none-elf"
LIBNX="$DEVKITPRO/libounce"

die() {
    echo "build-dispatch.sh: $*" >&2
    exit 1
}

[ -d "$SYSROOT" ] || die "no devkitA64 in $DEVKITA64. Run install.sh first."
[ -d "$LIBNX" ] || die "no libounce in $LIBNX. Run install.sh first."

# The compiler. The sources are C, and the toolchain's own clang is a C driver,
# so it is preferred. nix/fhs-env.nix exports CXX for build-stdlib.sh, and that
# wrapper is a clang++: it compiles .c files as C++ and rejects -std=gnu11, so
# CXX is only used as a fallback, and only after it has been asked to compile a
# .c file the way the build does. The driver's name settles nothing (the wrapper
# is called clang20), hence the probe.
driver_compiles_c() {
    probe="$(mktemp -d)"
    printf 'int probe(void);\nint probe(void) { return 0; }\n' >"$probe/probe.c"

    if "$1" -std=gnu11 -c "$probe/probe.c" -o "$probe/probe.o" \
        >/dev/null 2>&1; then
        status=0
    else
        status=1
    fi
    rm -rf "$probe"
    return "$status"
}

if [ -z "${CLANG:-}" ] && [ -x "$TOOLCHAIN/usr/bin/clang" ] &&
    driver_compiles_c "$TOOLCHAIN/usr/bin/clang"; then
    CLANG="$TOOLCHAIN/usr/bin/clang"
elif [ -z "${CLANG:-}" ] && [ -n "${CXX:-}" ] && [ -x "$CXX" ] &&
    driver_compiles_c "$CXX"; then
    CLANG="$CXX"
elif [ -z "${CLANG:-}" ]; then
    CLANG="$(command -v clang || true)"
fi
[ -n "${CLANG:-}" ] && [ -x "$CLANG" ] || die "no clang found. Set CLANG."

driver_compiles_c "$CLANG" ||
    die "$CLANG does not compile C with these flags. Set CLANG to a C compiler."

#---------------------------------------------------------------------------------
# Sources
#---------------------------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    echo "Fetching the libdispatch sources"
    git clone --depth 1 --branch "$SWIFT_TAG" --filter=blob:none \
        --sparse https://github.com/swiftlang/swift-corelibs-libdispatch.git "$SRC"
    git -C "$SRC" sparse-checkout set src os cmake dispatch private
fi

#---------------------------------------------------------------------------------
# Compile
#---------------------------------------------------------------------------------
# _GNU_SOURCE is deliberately not defined. It forces _XOPEN_SOURCE 700 in
# newlib, which declares encrypt(char *__block, ...) and collides with the
# __block keyword that -fblocks introduces. libdispatch needs blocks, so the
# feature macro has to go.
CFLAGS="-target aarch64-none-elf --sysroot=$SYSROOT
    -std=gnu11 -O2 -fPIC -fblocks
    -mtp=tpidrro_el0
    -D__SWITCH__ -D__unix__ -D__linux__ -DHAVE_CONFIG_H
    -include $DISPATCH_HOME/shim/dispatch_blocks_shim.h
    -I$DISPATCH_HOME -I$DISPATCH_HOME/shim
    -I$SRC -I$SRC/src -I$SRC/src/BlocksRuntime -I$SRC/private
    -I$LIBNX/include"

mkdir -p "$OBJ"
rm -f "$OBJ"/*.o

compile() {
    name="$1"
    source="$2"

    # shellcheck disable=SC2086
    "$CLANG" $CFLAGS -c "$source" -o "$OBJ/$name.o" ||
        die "failed to compile $source"
}

echo "Building libdispatch"

# The core. mach.c and voucher.c are Darwin-only; benchmark.c is a test tool.
for name in object queue init once semaphore source time transform data apply \
    introspection shims io allocator; do
    compile "$name" "$SRC/src/$name.c"
done

# The event backend and the block runtime.
compile event "$SRC/src/event/event.c"
compile event_epoll "$SRC/src/event/event_epoll.c"
compile blocks_data "$SRC/src/BlocksRuntime/data.c"
compile blocks_runtime "$SRC/src/BlocksRuntime/runtime.c"

# The lock and yield shims carry the futex and once implementations.
compile shims_lock "$SRC/src/shims/lock.c"
compile shims_yield "$SRC/src/shims/yield.c"

# The platform shims.
for name in futex_shim epoll_shim libc_shim dispatch_stubs; do
    compile "$name" "$DISPATCH_HOME/shim/$name.c"
done

echo "Archiving"
mkdir -p "$INSTALL"
rm -f "$INSTALL/libdispatch.a"
"$DEVKITA64/bin/aarch64-none-elf-ar" rcs "$INSTALL/libdispatch.a" "$OBJ"/*.o

# The headers are what switch2_dispatch_rules puts on the include path, so they
# have to be installed too. Without them a program that includes
# <dispatch/dispatch.h> fails to compile even though the library is there.
echo "Installing headers"
rm -rf "$DISPATCH_HOME/include"
mkdir -p "$DISPATCH_HOME/include"
cp -R "$SRC/dispatch" "$SRC/os" "$DISPATCH_HOME/include/"

cat <<EOF

libdispatch is installed in $INSTALL.

To build a program that uses it, include
  include \$(DEVKITPRO)/swift/switch2_dispatch_rules
in its Makefile. See examples/dispatch-hello.
EOF
