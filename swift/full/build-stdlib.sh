#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Builds the full Swift standard library for Switch 2 and installs it into the
# Swift toolchain that install-swift.sh put in $DEVKITPRO/swift/toolchain.
#
#   sh build-stdlib.sh [--jobs N]
#
# The toolchain from swift.org ships a standard library for Linux and an
# embedded one for bare metal. Neither is the full library: the embedded build
# has no String, no reflection and no Unicode. This script builds the full
# library from the Swift sources for aarch64-none-none-elf, the bare-metal
# AArch64 target, against devkitA64's newlib.
#
# It builds and installs:
#   libswiftCore.a        the standard library
#   libswiftRuntime.a     the runtime
#   libswiftDemangle.a    the demangler
#   libswiftLLVMSupport.a the LLVM support routines the runtime uses
#   libswiftStdlibStubs.a the C stubs and the Unicode tables
#   libswiftThreading.a   the once/threading shims
#   Swift.swiftmodule     the module interface
#
# The build needs about 4 GiB of disk and 20 minutes on 8 cores. It downloads
# the Swift and LLVM sources into $DEVKITPRO/swift/full-build/src.
#
# Set DEVKITPRO to use a devkitPro directory other than /opt/devkitpro.
# Set CXX to use a clang++ other than the one in the toolchain. The C++ parts
# need clang 18 or newer: clang 17 cannot parse the libstdc++ headers that
# devkitA64 ships.

set -eu

SWIFT_VERSION=6.0.3
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
TARGET=aarch64-none-none-elf
TARGET_ARCH=aarch64

# The host triple that LLVM records. It is informational here -- every object
# is compiled for the target, and none of the host's object format is used --
# but a toolchain built on macOS should not claim it was built on Linux.
host_triple() {
    case "$(uname -s)" in
    Darwin) host_os=apple-darwin ;;
    Linux) host_os=unknown-linux-gnu ;;
    *) host_os="unknown-$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac
    case "$(uname -m)" in
    arm64 | aarch64) host_arch=aarch64 ;;
    x86_64 | amd64) host_arch=x86_64 ;;
    *) host_arch="$(uname -m)" ;;
    esac
    echo "$host_arch-$host_os"
}
HOST_TRIPLE="$(host_triple)"

usage() {
    echo "usage: sh build-stdlib.sh [--jobs N] [stubs|concurrency|libs]" >&2
    echo "  stubs        rebuild only libswiftStdlibStubs.a, which holds the Unicode tables" >&2
    echo "  concurrency  rebuild only the concurrency runtime and _Concurrency module" >&2
    echo "  libs         rebuild every C++ library, skipping the slow Swift module" >&2
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
    stubs)
        only_stubs=yes
        shift
        ;;
    concurrency)
        only_concurrency=yes
        shift
        ;;
    libs)
        only_libs=yes
        shift
        ;;
    *) usage ;;
    esac
done

DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITPRO

SWIFT_HOME="$DEVKITPRO/swift"
TOOLCHAIN="$SWIFT_HOME/toolchain"
BUILD="$SWIFT_HOME/full-build"
SRC="$BUILD/src"
OBJ="$BUILD/obj"
INSTALL="$TOOLCHAIN/usr/lib/swift/none/$TARGET_ARCH"

DEVKITA64="$DEVKITPRO/devkitA64"
SYSROOT="$DEVKITA64/aarch64-none-elf"
CXXINC="$SYSROOT/include/c++/16.1.0"

die() {
    echo "build-stdlib.sh: $*" >&2
    exit 1
}

[ -x "$TOOLCHAIN/usr/bin/swiftc" ] ||
    die "no Swift toolchain in $TOOLCHAIN. Run install-swift.sh first."
[ -d "$SYSROOT" ] ||
    die "no devkitA64 in $DEVKITA64. Run install.sh first."

SWIFTC="$TOOLCHAIN/usr/bin/swiftc"
SWIFT_INCLUDE="$TOOLCHAIN/usr/include"

# The C++ parts need a clang that understands the libstdc++ headers devkitA64
# ships. Prefer $CXX, then the toolchain's clang++, then clang++ on PATH.
if [ -n "${CXX:-}" ]; then
    CLANGXX="$CXX"
elif [ -x "$TOOLCHAIN/usr/bin/clang++" ]; then
    CLANGXX="$TOOLCHAIN/usr/bin/clang++"
else
    CLANGXX="$(command -v clang++ || true)"
fi
[ -n "$CLANGXX" ] && [ -x "$CLANGXX" ] || die "no clang++ found. Set CXX."

clang_major="$("$CLANGXX" --version 2>/dev/null | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)"
if [ -n "$clang_major" ] && [ "$clang_major" -lt 18 ]; then
    echo "build-stdlib.sh: warning: $CLANGXX is clang $clang_major." >&2
    echo "The libstdc++ headers in devkitA64 need clang 18 or newer." >&2
    echo "Set CXX to a newer clang++ if the C++ parts fail to compile." >&2
fi

#---------------------------------------------------------------------------------
# Sources
#---------------------------------------------------------------------------------
fetch_sources() {
    mkdir -p "$SRC"

    if [ ! -d "$SRC/swift/.git" ]; then
        echo "Fetching the Swift sources"
        git clone --depth 1 --branch "$SWIFT_TAG" --filter=blob:none \
            --sparse https://github.com/swiftlang/swift.git "$SRC/swift"
        git -C "$SRC/swift" sparse-checkout set stdlib include lib utils cmake
    fi

    if [ ! -d "$SRC/llvm-project/.git" ]; then
        echo "Fetching the LLVM headers"
        git clone --depth 1 --branch "$SWIFT_TAG" --filter=blob:none \
            --sparse https://github.com/swiftlang/llvm-project.git \
            "$SRC/llvm-project"
        git -C "$SRC/llvm-project" sparse-checkout set llvm/include
    fi
}

#---------------------------------------------------------------------------------
# Generated headers
#---------------------------------------------------------------------------------
write_generated_headers() {
    mkdir -p "$BUILD/gen/swift/Runtime" "$BUILD/gen/llvm/Config"

    cat >"$BUILD/gen/swift/Runtime/CMakeConfig.h" <<'EOF'
#ifndef SWIFT_RUNTIME_CMAKECONFIG_H
#define SWIFT_RUNTIME_CMAKECONFIG_H
#define SWIFT_BNI_OS_BUILD 0
#define SWIFT_BNI_XCODE_BUILD 0
#define SWIFT_VERSION_MAJOR "6"
#define SWIFT_VERSION_MINOR "0"
#endif
EOF

    cat >"$BUILD/gen/llvm/Config/llvm-config.h" <<EOF
#ifndef LLVM_CONFIG_H
#define LLVM_CONFIG_H
#define LLVM_DEFAULT_TARGET_TRIPLE "aarch64-none-elf"
#define LLVM_ENABLE_THREADS 0
#define LLVM_HAS_ATOMICS 1
#define LLVM_HOST_TRIPLE "$HOST_TRIPLE"
#define LLVM_ON_UNIX 1
#define LLVM_USE_INTEL_JITEVENTS 0
#define LLVM_USE_OPROFILE 0
#define LLVM_USE_PERF 0
#define LLVM_VERSION_MAJOR 17
#define LLVM_VERSION_MINOR 0
#define LLVM_VERSION_PATCH 0
#define LLVM_VERSION_STRING "17.0.0"
#define LLVM_FORCE_ENABLE_STATS 0
#define LLVM_ENABLE_ZLIB 0
#define LLVM_ENABLE_ZSTD 0
#endif
EOF

    cat >"$BUILD/gen/llvm/Config/abi-breaking.h" <<'EOF'
#ifndef LLVM_ABI_BREAKING_CHECKS_H
#define LLVM_ABI_BREAKING_CHECKS_H
#define LLVM_ENABLE_ABI_BREAKING_CHECKS 0
#define LLVM_ENABLE_REVERSE_ITERATION 0
#define LLVM_XSTR(s) LLVM_STR(s)
#define LLVM_STR(s) #s
#define LLVM_HIDDEN_VISIBILITY
#endif
EOF

    # newlib provides posix_memalign but does not declare it without feature
    # macros, and the Swift runtime calls it.
    cat >"$BUILD/gen/newlib_shim.h" <<'EOF'
#ifndef SWIFT_NEWLIB_SHIM_H
#define SWIFT_NEWLIB_SHIM_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int posix_memalign(void **memptr, size_t alignment, size_t size);
#ifdef __cplusplus
}
#endif
#endif
EOF
}

#---------------------------------------------------------------------------------
# The standard library
#---------------------------------------------------------------------------------
# LibcShims.h decides HAS_MALLOC_SIZE from the platform macros, and none of the
# ones it knows about are defined for aarch64-none-none-elf, so
# _swift_stdlib_malloc_size returns 0. ManagedBuffer.capacity is built on it:
#
#   let endAddr = storageAddr + _swift_stdlib_malloc_size(storageAddr)
#   let realCapacity = endAddr - firstElementAddress
#
# With a zero size that is negative, so every ManagedBuffer reports a negative
# capacity. _Deque's uncheckedAppend then trips assert(count < capacity) and
# AsyncStream dies. newlib does provide malloc_usable_size, so add a __SWITCH__
# branch that uses it. Patched here rather than in the checkout, like C11.cpp
# and Clock.cpp.
patch_libc_shims() {
    python3 - "$SRC/swift/stdlib/public/SwiftShims/swift/shims/LibcShims.h" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH__" in source:
    sys.exit(0)

marker = """#else
#define HAS_MALLOC_SIZE 0"""
branch = """#elif defined(__SWITCH__)
#define HAS_MALLOC_SIZE 1
static inline __swift_size_t _swift_stdlib_malloc_size(const void *ptr) {
  extern __swift_size_t malloc_usable_size(void *ptr);
  return malloc_usable_size(CONST_CAST(void *, ptr));
}
#else
#define HAS_MALLOC_SIZE 0"""

if marker not in source:
    sys.exit("LibcShims.h: could not find the HAS_MALLOC_SIZE fallback")

open(path, "w").write(source.replace(marker, branch, 1))
PYEOF
}

build_stdlib() {
    echo "Building the standard library"

    core="$SRC/swift/stdlib/public/core"
    gen="$BUILD/gen/core"
    mkdir -p "$gen"

    for gyb in "$core"/*.gyb; do
        out="$gen/$(basename "${gyb%.gyb}")"
        python3 "$SRC/swift/utils/gyb.py" --line-directive '' \
            -D CMAKE_SIZEOF_VOID_P=8 -o "$out" "$gyb"
    done

    # EmbeddedRuntime, EmbeddedStubs and EmbeddedPrint belong to the embedded
    # library only; they redeclare String, Encodable and friends.
    sources=$(ls "$core"/*.swift "$gen"/*.swift |
        grep -v -E 'EmbeddedRuntime|EmbeddedStubs|EmbeddedPrint')

    # shellcheck disable=SC2086
    "$SWIFTC" -target "$TARGET" -parse-stdlib -nostdimport -parse-as-library \
        -module-name Swift -swift-version 5 -O -wmo \
        -Xfrontend -enable-experimental-concise-pound-file \
        -enable-experimental-feature Macros \
        -enable-experimental-feature FreestandingMacros \
        -enable-experimental-feature Extern \
        -enable-experimental-feature BitwiseCopyable \
        -enable-experimental-feature DebugDescriptionMacro \
        -DSWIFT_ENABLE_REFLECTION \
        $(swift_cc_flags) \
        -emit-module -emit-module-path "$BUILD/Swift.swiftmodule" \
        -emit-library -static -o "$BUILD/libswiftCore.a" \
        $sources
}

#---------------------------------------------------------------------------------
# The C++ flags above, forwarded to clang through -Xcc so that swiftc accepts
# them.  Passing them raw makes swiftc reject --sysroot, -std and -isystem.
#---------------------------------------------------------------------------------
swift_cc_flags() {
    echo "-Xcc --sysroot=$SYSROOT \
        -Xcc -D_GNU_SOURCE \
        -Xcc -D__SWITCH__ \
        -Xcc -mtp=tpidrro_el0 \
        -Xcc -include -Xcc $BUILD/gen/newlib_shim.h \
        -Xcc -I$SRC/swift/stdlib/include \
        -Xcc -I$SRC/swift/stdlib/public/SwiftShims/swift/shims \
        -Xcc -I$SRC/swift/stdlib/public/SwiftShims \
        -Xcc -I$SRC/swift/include -Xcc -I$BUILD/gen \
        -Xcc -isystem -Xcc $CXXINC \
        -Xcc -isystem -Xcc $CXXINC/aarch64-none-elf"
}

#---------------------------------------------------------------------------------
# C++ flags shared by the runtime, the demangler and the stubs
#---------------------------------------------------------------------------------
cc_flags() {
    echo "-target aarch64-none-elf --sysroot=$SYSROOT \
        -std=c++17 -O2 -DNDEBUG -fno-exceptions -fno-rtti -fPIC -D_GNU_SOURCE \
        -mtp=tpidrro_el0 \
        -DSWIFT_STDLIB_HAS_TYPE_PRINTING=1 \
        -include $BUILD/gen/newlib_shim.h \
        -I$SRC/swift/stdlib/include \
        -I$SRC/swift/stdlib/public/SwiftShims/swift/shims \
        -I$SRC/swift/stdlib/public/SwiftShims \
        -I$SRC/swift/include -I$BUILD/gen \
        -I$SRC/llvm-project/llvm/include \
        -isystem $CXXINC -isystem $CXXINC/aarch64-none-elf"
}

# Compiles SOURCES into LIBRARY, skipping the files in SKIP.
#   build_cxx_library LIBRARY SKIP SOURCES...
build_cxx_library() {
    library="$1"
    skip="$2"
    shift 2

    name=$(basename "$library" .a)
    dir="$OBJ/$name"
    mkdir -p "$dir"
    rm -f "$dir"/*.o "$library"

    for source in "$@"; do
        base=$(basename "$source")
        # `case "$base" in $skip)` does not work: an unquoted expansion in a
        # case pattern is a single pattern, so a space-separated list never
        # matched and every "skipped" file was compiled anyway.
        skipped=no
        for pattern in $skip; do
            if [ "$base" = "$pattern" ]; then
                skipped=yes
                break
            fi
        done
        [ "$skipped" = yes ] && continue

        object="$dir/$(basename "$source" .cpp).o"
        # shellcheck disable=SC2046
        "$CLANGXX" $(cc_flags) $EXTRA_CXXFLAGS -c "$source" -o "$object" ||
            die "failed to compile $base"
    done

    "$DEVKITA64/bin/aarch64-none-elf-ar" rcs "$library" "$dir"/*.o
}

#---------------------------------------------------------------------------------
# The runtime, the demangler, the stubs and the threading shims
#---------------------------------------------------------------------------------
build_runtime() {
    echo "Building the runtime"

    # The Objective-C++ file defines the bridging entry points.
    # shellcheck disable=SC2046
    "$CLANGXX" $(cc_flags) -x objective-c++ \
        -DSWIFT_TARGET_LIBRARY_NAME=swiftRuntime -DswiftCore_EXPORTS \
        -c "$SRC/swift/stdlib/public/runtime/SwiftObject.mm" \
        -o "$OBJ/runtime/SwiftObject.o" ||
        die "failed to compile SwiftObject.mm"

    # ImageInspection* and Win32 are for other object formats. LibPrespecialized
    # needs a dynamic loader. The backtracing and crash handlers need an OS.
    # CompatibilityOverride.h builds an include path from this name; without
    # it Casting.cpp and friends fail with "expected FILENAME".
    # swiftCore_EXPORTS gates the KeyPath entry points in Metadata.h;
    # without it KeyPaths.cpp has no declaration to define.
    # ReflectionMirror.cpp is guarded by SWIFT_ENABLE_REFLECTION too; without
    # it Mirror has no runtime and the link fails.
    EXTRA_CXXFLAGS="-DSWIFT_TARGET_LIBRARY_NAME=swiftRuntime -DswiftCore_EXPORTS -DSWIFT_ENABLE_REFLECTION"
    build_cxx_library "$BUILD/libswiftRuntime.a" \
        "ImageInspectionMachO.cpp ImageInspectionCOFF.cpp ImageInspectionWasm.cpp LibPrespecialized.cpp Win32.cpp Backtrace.cpp BacktraceUtils.cpp CrashHandlerMacOS.cpp CrashHandlerLinux.cpp SwiftRT-COFF.cpp" \
        "$SRC/swift/stdlib/public/runtime"/*.cpp

    EXTRA_CXXFLAGS=""

    "$DEVKITA64/bin/aarch64-none-elf-ar" rcs "$BUILD/libswiftRuntime.a" \
        "$OBJ/runtime/SwiftObject.o"
}

build_demangle() {
    echo "Building the demangler"
    build_cxx_library "$BUILD/libswiftDemangle.a" "" \
        "$SRC/swift/lib/Demangling"/*.cpp
}

build_llvm_support() {
    echo "Building the LLVM support routines"
    # LLVM's Backtrace.cpp needs Linux's isPrivileged(); newlib has no such
    # thing, and the console has no backtracer anyway.
    build_cxx_library "$BUILD/libswiftLLVMSupport.a" "Backtrace.cpp" \
        "$SRC/swift/stdlib/public/LLVMSupport"/*.cpp
}

build_stubs() {
    echo "Building the C stubs and the Unicode tables"
    # Without this the Unicode lookups compile to
    # swift_abortDisabledUnicodeSupport, so every non-ASCII String operation
    # aborts: String.count over a grapheme cluster, normalization, case mapping,
    # word breaking. The generated tables are in
    # stdlib/public/stubs/Unicode/Common and ship with the source tree, so the
    # only thing missing was the define. CMake defaults this option to TRUE and
    # warns that disabling it "will cause many String methods to crash".
    EXTRA_CXXFLAGS="-DSWIFT_STDLIB_ENABLE_UNICODE_DATA"
    build_cxx_library "$BUILD/libswiftStdlibStubs.a" "" \
        "$SRC/swift/stdlib/public/stubs"/*.cpp \
        "$SRC/swift/stdlib/public/stubs/Unicode"/*.cpp
    EXTRA_CXXFLAGS=""

    # There is no dynamic loader on the console, so no image can carry
    # prespecialized metadata.
    cat >"$BUILD/LibPrespecializedStub.cpp" <<'EOF'
#include "swift/Runtime/LibPrespecialized.h"

namespace swift {

void libPrespecializedImageLoaded() {}

Metadata *getLibPrespecializedMetadata(const TypeContextDescriptor *description,
                                       const void *const *arguments) {
  return nullptr;
}

} // namespace swift
EOF

    # shellcheck disable=SC2046
    "$CLANGXX" $(cc_flags) -c "$BUILD/LibPrespecializedStub.cpp" \
        -o "$OBJ/libswiftStdlibStubs/LibPrespecializedStub.o"
    "$DEVKITA64/bin/aarch64-none-elf-ar" rcs "$BUILD/libswiftStdlibStubs.a" \
        "$OBJ/libswiftStdlibStubs/LibPrespecializedStub.o"
}

build_threading() {
    echo "Building the threading shims"
    # C11.cpp is wrapped in `#if SWIFT_THREADING_C11`; without the define it
    # compiles to nothing and once_slow is missing at link time. newlib has no
    # pthreads, so the C11 implementation is the one to build.
    #
    # C11ThreadingHelper is a namespace-scope object, so its constructor runs
    # from .init_array in link order. The concurrency runtime's constructor
    # calls swift::once, which reaches once_slow and therefore this helper, and
    # that constructor runs first, so the mutex is still zeroed and the program
    # dies before main. init_priority(101) moves the helper's constructor ahead
    # of every default-priority one. The source is copied rather than edited so
    # the checkout stays clean.
    threading_src="$BUILD/gen/threading"
    mkdir -p "$threading_src"
    sed 's|^C11ThreadingHelper helper;$|C11ThreadingHelper helper __attribute__((init_priority(101)));|' \
        "$SRC/swift/lib/Threading/C11.cpp" > "$threading_src/C11.cpp"
    if ! grep -q 'init_priority(101)' "$threading_src/C11.cpp"; then
        die "could not patch C11ThreadingHelper in C11.cpp"
    fi

    EXTRA_CXXFLAGS="-DSWIFT_THREADING_C11=1"
    build_cxx_library "$BUILD/libswiftThreading.a" "" \
        "$threading_src/C11.cpp" \
        "$SRC/swift/lib/Threading/Errors.cpp"
    EXTRA_CXXFLAGS=""
}

#---------------------------------------------------------------------------------
# Concurrency
#---------------------------------------------------------------------------------
# The concurrency runtime has three global executors. The cooperative one needs
# no threads and no libdispatch: the program donates its thread to the executor
# with swift_task_donateThreadToGlobalExecutorUntil. That is the only one that
# works on the console, so the build selects it with
# SWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY.
build_concurrency() {
    echo "Building the concurrency runtime"

    conc="$SRC/swift/stdlib/public/Concurrency"

    # The runtime includes <sys/syscall.h> on ELF targets but uses nothing from
    # it, and newlib has no such header.
    mkdir -p "$BUILD/gen/shim/sys"
    echo "/* newlib has no sys/syscall.h. */" >"$BUILD/gen/shim/sys/syscall.h"

    # Clock.cpp has no branch for this target. It needs one for clock_gettime
    # and clock_getres, which swift_shim.c implements on the system tick.
    python3 - "$conc/Clock.cpp" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH__" not in source:
    for call, clock in (("clock_gettime", "CLOCK_MONOTONIC"),
                        ("clock_getres", "CLOCK_MONOTONIC")):
        marker = "      %s(%s, &" % (call, clock)
        index = source.find(marker)
        while index != -1:
            end = source.find("\n", index)
            line = source[index:end]
            branch = "\n#elif defined(__SWITCH__)\n" + line
            source = source[:end] + branch + source[end:]
            index = source.find(marker, end + len(branch))
    open(path, "w").write(source)
PYEOF

    dir="$OBJ/concurrency"
    mkdir -p "$dir"
    rm -f "$dir"/*.o "$BUILD/libswift_Concurrency.a"

    for source in "$conc"/*.cpp; do
        # shellcheck disable=SC2046
        "$CLANGXX" $(cc_flags) -D__SWITCH__ \
            -Dswift_Concurrency_EXPORTS \
            -DSWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY=1 \
            -DSWIFT_TARGET_LIBRARY_NAME=swift_Concurrency \
            -I"$BUILD/gen/shim" \
            -c "$source" -o "$dir/$(basename "$source" .cpp).o" ||
            die "failed to compile $(basename "$source")"
    done

    "$DEVKITA64/bin/aarch64-none-elf-ar" rcs "$BUILD/libswift_Concurrency.a" \
        "$dir"/*.o

    echo "Building the _Concurrency module"

    # shellcheck disable=SC2046
    "$SWIFTC" -target "$TARGET" -parse-stdlib -parse-as-library \
        -module-name _Concurrency -swift-version 5 -O -wmo \
        -I "$BUILD" \
        -enable-experimental-feature Macros \
        -enable-experimental-feature FreestandingMacros \
        -enable-experimental-feature Extern \
        -enable-experimental-feature BitwiseCopyable \
        -Xcc -fmodule-map-file="$conc/InternalShims/module.modulemap" \
        -Xcc -I"$conc/InternalShims" \
        -Xcc -fmodule-map-file="$SRC/swift/stdlib/public/SwiftShims/swift/shims/module.modulemap" \
        -Xcc -I"$SRC/swift/stdlib/public/SwiftShims/swift/shims" \
        -Xcc -I"$SRC/swift/stdlib/public/SwiftShims" \
        -Xcc -I"$SRC/swift/include" -Xcc -I"$BUILD/gen" \
        -Xcc -isystem -Xcc "$CXXINC" \
        -Xcc -isystem -Xcc "$CXXINC/aarch64-none-elf" \
        -Xcc --sysroot="$SYSROOT" \
        -emit-module -emit-module-path "$BUILD/_Concurrency.swiftmodule" \
        -emit-library -static -o "$BUILD/libswift_Concurrency_swift.a" \
        $(ls "$conc"/*.swift "$conc"/Deque/*.swift)
}

#---------------------------------------------------------------------------------
# Install
#---------------------------------------------------------------------------------
# True if LIBRARY contains no `tpidr_el0` access. A thread-local compiled
# against that register reads the kernel's thread control block instead of the
# program's thread-locals, and the flag that prevents it (-mtp=tpidrro_el0) is
# easy to lose when a library is built by an older copy of this script. The
# program links and builds either way, so this has to be checked explicitly.
has_wrong_thread_pointer() {
    "$DEVKITA64/bin/aarch64-none-elf-objdump" -d "$1" 2>/dev/null |
        sed 's/tpidrro_el0//g' |
        grep -q 'tpidr_el0'
}

check_thread_pointer() {
    for library in "$@"; do
        if has_wrong_thread_pointer "$library"; then
            cat >&2 <<EOF
build-stdlib.sh: $(basename "$library") accesses thread-locals through
tpidr_el0, which on the console is the kernel's thread control block.

Every compiler invocation must pass -mtp=tpidrro_el0. Check cc_flags and
swift_cc_flags in this script, then remove the stale objects and rebuild:
  rm -rf "$OBJ"
  sh build-stdlib.sh
EOF
            exit 1
        fi
    done
}

install_libraries() {
    echo "Installing into $INSTALL"
    mkdir -p "$INSTALL"
    cp "$BUILD/Swift.swiftmodule" "$INSTALL/"
    cp "$BUILD/_Concurrency.swiftmodule" "$INSTALL/"
    libraries="libswiftCore libswiftRuntime libswiftDemangle \
libswiftLLVMSupport libswiftStdlibStubs libswiftThreading \
libswift_Concurrency libswift_Concurrency_swift"

    # Refuse to install a library that would read the wrong thread pointer.
    # shellcheck disable=SC2086
    check_thread_pointer $(for library in $libraries; do
        echo "$BUILD/$library.a"
    done)

    for library in $libraries; do
        cp "$BUILD/$library.a" "$INSTALL/"
    done
}

fetch_sources
write_generated_headers
mkdir -p "$OBJ/runtime" "$OBJ/libswiftStdlibStubs"

# The Unicode tables live in libswiftStdlibStubs.a and nothing else depends on
# them, so a change to the stub flags only needs that one archive rebuilt.
# `sh build-stdlib.sh stubs` takes seconds; the full build takes much longer.
if [ "${only_stubs:-}" = "yes" ]; then
    build_stubs
    install_libraries
    exit 0
fi

if [ "${only_concurrency:-}" = "yes" ]; then
    build_concurrency
    install_libraries
    exit 0
fi

# Every C++ library, skipping build_stdlib: the Swift module is the slow part
# and does not contain asserts.
if [ "${only_libs:-}" = "yes" ]; then
    build_runtime
    build_demangle
    build_llvm_support
    build_stubs
    build_threading
    build_concurrency
    install_libraries
    exit 0
fi

patch_libc_shims
build_stdlib
build_runtime
build_demangle
build_llvm_support
build_stubs
build_threading
build_concurrency
install_libraries

cat <<EOF

The full Swift standard library is installed in $INSTALL.

To build a Swift program that uses it, include
  include \$(DEVKITPRO)/swift/switch2_swift_full_rules
in its Makefile. See examples/swift-full.
EOF
