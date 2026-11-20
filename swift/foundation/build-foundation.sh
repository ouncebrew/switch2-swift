#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Builds FoundationEssentials for the Switch 2, on top of the standard library
# built by ../full/build-stdlib.sh.
#
#   sh build-foundation.sh [checkout] [jobs]
#
# The default checkout is $DEVKITPRO/swift/foundation-src, created by
# fetch-foundation.sh. The default is the number of CPUs.
#
# What this builds, and what it does not
# --------------------------------------
# Foundation is three libraries. This script builds the first and a focused
# part of the third:
#
#   FoundationEssentials            data, dates, URLs, JSON, codable
#   FoundationInternationalization  calendars, locales, formatting (ICU)
#   FoundationNetworking/XML        URLSession, XMLParser (libcurl, libxml2)
#
# Internationalization needs ICU, which is a much larger port, and XML needs
# libxml2. Neither is attempted here.
#
# FoundationNetworking is different. Upstream's module is part of
# swift-corelibs-foundation and is built on CoreFoundation and libcurl, which
# this port does not have. The console does have what matters underneath,
# though -- libnx's BSD socket service and its ssl service -- so this script
# builds a small FoundationNetworking of its own on top of those. It covers
# HTTP and HTTPS data requests with URLSession, URLRequest and URLResponse; it
# is not a port of upstream's module, and HANDOFF.md lists what it does not
# do. A program that imports `Foundation` rather than the two modules will not
# link, because Internationalization is still missing.
#
# Relationship to the rest of the port
# ------------------------------------
# This is the same shape as build-stdlib.sh: Foundation's own sources are
# checked out unmodified, and the handful of places that assume a POSIX host
# are patched here, at build time, behind `__SWITCH__`. Nothing is edited in
# the checkout, so re-fetching or updating it loses no work. The patches and
# the reason for each are listed in patch_sources below.
#
# Foundation is a SwiftPM package, not a set of loose files like the standard
# library. It is built with `swift build`, driven by the Swift SDK, which is
# why this script is short: SwiftPM resolves swift-collections, swift-syntax
# and swift-foundation-icu itself. The SDK's linker wrapper has to find the
# standard library and libounce, which is what makes the link work; see
# ../swiftpm/install-swift-sdk.sh.
#
# It is still built from source rather than as a package dependency because a
# program may only need FoundationEssentials, and because the patches below
# have to be applied before SwiftPM reads the manifest.

set -eu

usage() {
    echo "usage: sh build-foundation.sh [checkout] [jobs]" >&2
    exit 2
}

[ $# -le 2 ] || usage

DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITPRO

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_HOME="$DEVKITPRO/swift"
TOOLCHAIN="$SWIFT_HOME/toolchain"
DEVKITA64="$DEVKITPRO/devkitA64"
# The Glibc shim: a SwiftPM package built before Foundation, because
# Foundation imports Glibc and the import resolves through the package graph.
SHIM="$SCRIPT_DIR/shim"
SWIFT="$TOOLCHAIN/usr/bin/swift"
SWIFTLIB="$TOOLCHAIN/usr/lib/swift/none/aarch64"
LIBNX="$DEVKITPRO/libounce"
# The networking sources and the C transport that goes with them. They are
# built after FoundationEssentials, because the Swift module imports it.
NETWORKING="$SCRIPT_DIR/networking"
CLANG="$TOOLCHAIN/usr/bin/clang"

if [ -n "${1:-}" ]; then
    SRC="$1"
else
    SRC="$SWIFT_HOME/foundation-src"
fi

if [ -n "${2:-}" ]; then
    JOBS="$2"
else
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
fi

die() {
    echo "build-foundation.sh: $*" >&2
    exit 1
}

[ -d "$SRC" ] || die "no Foundation checkout in $SRC.
Run fetch-foundation.sh first, or pass the path to a checkout."
[ -f "$SRC/Package.swift" ] || die "$SRC does not look like the Swift Foundation package."
[ -x "$SWIFT" ] || die "no Swift toolchain in $TOOLCHAIN. Run install-swift.sh first."
[ -x "$CLANG" ] || die "no clang in $TOOLCHAIN. Run install-swift.sh first."
[ -f "$SWIFTLIB/libswiftCore.a" ] ||
    die "the full standard library is not built. Run ../full/build-stdlib.sh first."

"$SWIFT" sdk list 2>/dev/null | grep -qx switch2 ||
    die "the Switch 2 Swift SDK is not installed. Run ../swiftpm/install-swift-sdk.sh."

[ -d "$NETWORKING/Sources/FoundationNetworking" ] ||
    die "the FoundationNetworking sources are missing from $NETWORKING. Re-run install.sh."

# --------------------------------------------------------------------------
# The patches
# --------------------------------------------------------------------------
# Foundation is written to compile for Darwin, Linux, Windows and WASI, and it
# picks between them with TARGET_OS_* macros. A bare-metal target is none of
# those, so it falls into the `#else` branch of every one of those tests, and
# that branch is the POSIX one. The three patches below are the places where
# POSIX means something the console does not have.
#
# Each is a no-op when run twice, so the script can be re-run on the same
# checkout.
patch_sources() {
    echo "Patching Foundation for __SWITCH__"

    # 1. The random source. uuid.c opens /dev/urandom, reads and closes it.
    #    The console has no /dev/urandom, and no open(2) at all on the bare
    #    metal side; randomness comes from the kernel through libnx's
    #    randomGet, which is backed by the SPL service.
    python3 - "$SRC/Sources/_FoundationCShims/uuid.c" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH__" not in source:
    marker = "#elif TARGET_OS_WASI\n#include <sys/random.h>"
    replacement = """#elif defined(__SWITCH__)
#include <switch.h>

static inline void read_random(void *buffer, unsigned numBytes) {
    randomGet(buffer, numBytes);
}
#elif TARGET_OS_WASI
#include <sys/random.h>"""
    if marker not in source:
        sys.stderr.write("uuid.c: the WASI branch moved; check the random patch\n")
        sys.exit(1)
    source = source.replace(marker, replacement, 1)

    # 2. The clock. read_time asks for the monotonic clock, which the console
    #    does not have as a syscall: the only clock is the ARM system tick.
    #    swift_shim.c already turns that into clock_gettime, so this reads it
    #    the same way rather than duplicating the conversion.
    marker = "    nanotime(&tv);"
    if marker in source:
        replacement = """#if defined(__SWITCH__)
    clock_gettime(CLOCK_MONOTONIC, &tv);
#else
    nanotime(&tv);
#endif"""
        source = source.replace(marker, replacement, 1)

    open(path, "w").write(source)
PYEOF

    # 3. The thread-local key type. _ThreadLocal.swift picks a PlatformKey
    #    with `#if canImport(Darwin) / os(Android) / canImport(Glibc) /
    #    canImport(Musl) / canImport(WinSDK) / canImport(threads_h)`. On a
    #    bare-metal target none of those match, so PlatformKey is never
    #    defined and the file fails to compile with "cannot find type
    #    'PlatformKey' in scope".
    #
    #    pthreads are the right answer here rather than a fallback: libnx
    #    implements pthread_key_create, pthread_setspecific and
    #    pthread_getspecific in libsysbase, they are what the Swift runtime's
    #    own threading shims are built on, and tests/diag/pthread exercises
    #    them on hardware. The Swift branch below is therefore made to select
    #    the pthread path.
    #
    #    Two edits, because Foundation tests for the platform twice: once in
    #    the typealias chain and once in each accessor. Both tests gain the
    #    same `defined(__SWITCH__)` arm, which keeps the change minimal and
    #    leaves upstream's structure intact.

    # 4. The shim, as a package dependency.
    #
    #    Foundation writes `import Glibc` and expects Swift's Linux overlay to
    #    provide it. Passing -I and -fmodule-map-file on the command line is
    #    not enough: `import` resolves against the package graph, and the
    #    module the shim builds is a Swift module that has to be a declared
    #    dependency of the target that imports it.
    #
    #    The dependency is added with an absolute path, because the checkout
    #    and the shim are not siblings: the checkout lives wherever
    #    fetch-foundation.sh put it, and the shim lives in this repository's
    #    installed copy under $DEVKITPRO/swift/foundation/shim. A relative
    #    path would have to be recomputed for every layout.
    python3 "$SCRIPT_DIR/patch-package-swift.py" "$SRC/Package.swift" "$SHIM"

    # 5. One call to Collection.replace(_:with:), which is newer than the
    #    standard library this port builds against.
    #
    #    URL.swift, when encoding slashes, wants to replace every "/" in a
    #    UTF-8 slice with "%2F". The 6.0.3 stdlib has replaceSubrange and
    #    nothing that replaces every occurrence of a subsequence, and the
    #    API is defined neither in Foundation nor in swift-collections, so the
    #    call does not resolve and the whole module fails to type-check.
    #
    #    Only one call site needs it. The replacement is the same operation
    #    written out, and it keeps the same structure: everything before the
    #    slice is copied unchanged, the slice's slashes become three bytes
    #    each, and everything after is copied unchanged.
    python3 - "$SRC/Sources/FoundationEssentials/URL/URL.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_REPLACE__" in source:
    sys.exit(0)

marker = (
    "            utf8[(insertedSlash ? 1 : 0)...].replace([._slash], "
    "with: [UInt8(ascii: \"%\"), UInt8(ascii: \"2\"), UInt8(ascii: \"F\")])\n"
)
if marker not in source:
    sys.stderr.write("URL.swift: the replace call moved; check the patch\n")
    sys.exit(1)

replacement = """            // __SWITCH_REPLACE__: Collection.replace(_:with:) is newer
            // than this port's standard library. Replaces every "/" in the
            // slice with "%2F", which is what the original call did.
            let keep = insertedSlash ? 1 : 0
            var encoded = Array(utf8[0..<keep])
            encoded.reserveCapacity(utf8.count + 2)
            for byte in utf8[keep...] {
                if byte == ._slash {
                    encoded.append(contentsOf: [UInt8(ascii: "%"),
                                                UInt8(ascii: "2"),
                                                UInt8(ascii: "F")])
                } else {
                    encoded.append(byte)
                }
            }
            utf8 = encoded
"""
source = source.replace(marker, replacement, 1)
open(path, "w").write(source)
print("patched URL.swift")
PYEOF

    python3 - "$SRC/Sources/FoundationEssentials/_ThreadLocal.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH__" in source:
    sys.exit(0)

# The import. pthread_key_t has to come from somewhere Swift can see it, and
# the obvious candidates do not work:
#
#   import switch       switch.h does not include <pthread.h> and does not
#                       define pthread_key_t.
#   import pthread      newlib's headers have no module map, so
#                       canImport(pthread) is false and there is nothing to
#                       import.
#   import Glibc        not this platform.
#
# _FoundationCShims is the module that does work, and it is already imported
# by the rest of Foundation for exactly this kind of thing: its _CStdlib.h
# includes <threads.h>, which newlib implements, and the module re-exports
# what it pulls in. Verified by typechecking `import _FoundationCShims` and
# naming pthread_key_t.
marker = "#if canImport(Darwin)\nimport Darwin"
if marker not in source:
    sys.stderr.write("_ThreadLocal.swift: the import block moved; check the patch\n")
    sys.exit(1)
source = source.replace(
    marker,
    """#if __SWITCH__
internal import _FoundationCShims
#elseif canImport(Darwin)
import Darwin""",
    1,
)

# The typealias.
marker = "    fileprivate typealias PlatformKey = pthread_key_t"
if marker not in source:
    sys.stderr.write("_ThreadLocal.swift: the typealias moved; check the patch\n")
    sys.exit(1)

# The conditionals that select pthreads. They read
#   `canImport(Darwin) || os(Android) || canImport(Glibc) || canImport(Musl)`
# in the typealias, the initialiser and both accessors, so the switch is added
# to each occurrence. The spelling is Swift's, not C's: `__SWITCH__`, not
# `defined(__SWITCH__)`, which Swift rejects with "unexpected platform
# condition". It needs -D__SWITCH__ on the *swiftc* command line as well as
# -Xcc for the C side; the build below passes both.
pthread_test = "canImport(Darwin) || os(Android) || canImport(Glibc) || canImport(Musl)"
count = source.count(pthread_test)
if count == 0:
    sys.stderr.write("_ThreadLocal.swift: the pthread conditional moved\n")
    sys.exit(1)
source = source.replace(pthread_test, f"__SWITCH__ || {pthread_test}")

open(path, "w").write(source)
print(f"patched _ThreadLocal.swift ({count} conditional(s))")
PYEOF
    # 6. ProcessInfo asks the standard library for the process arguments.
    #
    #    CommandLine is compiled out of this port's Swift module: its source is
    #    behind SWIFT_STDLIB_HAS_COMMANDLINE, and the runtime half,
    #    _swift_stdlib_getUnsafeArgvArgc, lives in CommandLineSupport, a
    #    library the port does not build. A console program has no argv, so the
    #    __SWITCH__ arms do not guess: arguments is empty, and the process name
    #    comes from the executable path, which Foundation can find by itself.
    #
    #    CommandLine is still missing from the standard library and should be
    #    added there; this patch is the Foundation-side workaround for it.
    python3 - "$SRC/Sources/FoundationEssentials/ProcessInfo/ProcessInfo.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_COMMANDLINE__" not in source:
    marker = "            var current = CommandLine.arguments\n"
    if marker not in source:
        sys.stderr.write("ProcessInfo.swift: the arguments call moved; check the patch\n")
        sys.exit(1)
    source = source.replace(
        marker,
        """#if __SWITCH__ // __SWITCH_COMMANDLINE__
            var current: [String] = []
#else
            var current = CommandLine.arguments
#endif
""",
        1,
    )

    marker = """        guard let processPath = CommandLine.arguments.first else {
            return ""
        }
"""
    if marker not in source:
        sys.stderr.write("ProcessInfo.swift: the process name call moved; check the patch\n")
        sys.exit(1)
    source = source.replace(
        marker,
        """#if __SWITCH__ // __SWITCH_COMMANDLINE__
        guard let processPath = Platform.getFullExecutablePath() else {
            return ""
        }
#else
        guard let processPath = CommandLine.arguments.first else {
            return ""
        }
#endif
""",
        1,
    )

    open(path, "w").write(source)
    print("patched ProcessInfo.swift")
PYEOF

    # 7. The user and group ids are the platform's own type.
    #
    #    getUGIDs returns (UInt32, UInt32), which is glibc's uid_t width, and
    #    its callers pass the result to functions that take uid_t. On glibc
    #    that is the same type; newlib's uid_t is unsigned short, so every one
    #    of those calls fails to type-check. Returning uid_t/gid_t is what the
    #    function means on both platforms, and the __SWITCH__ guard is not
    #    needed because the change is correct everywhere.
    python3 - "$SRC/Sources/FoundationEssentials/Platform.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_UID_T__" not in source:
    marker = "    private static var ROOT_USER: UInt32 { 0 }"
    if marker not in source:
        sys.stderr.write("Platform.swift: ROOT_USER moved; check the patch\n")
        sys.exit(1)
    source = source.replace(
        marker, "    private static var ROOT_USER: uid_t { 0 } // __SWITCH_UID_T__", 1
    )

    marker = "    static func getUGIDs(allowEffectiveRootUID: Bool = true) -> (uid: UInt32, gid: UInt32) {"
    if marker not in source:
        sys.stderr.write("Platform.swift: getUGIDs moved; check the patch\n")
        sys.exit(1)
    source = source.replace(
        marker,
        "    static func getUGIDs(allowEffectiveRootUID: Bool = true) -> (uid: uid_t, gid: gid_t) { // __SWITCH_UID_T__",
        1,
    )

    marker = "        var result: (uid: UInt32, gid: UInt32)\n"
    if marker not in source:
        sys.stderr.write("Platform.swift: the result declaration moved; check the patch\n")
        sys.exit(1)
    source = source.replace(
        marker, "        var result: (uid: uid_t, gid: gid_t) // __SWITCH_UID_T__\n", 1
    )

    open(path, "w").write(source)
    print("patched Platform.swift")
PYEOF

    # 8. String.replacing(_:with:) on a Substring.
    #
    #    Predicate+Description indents a multi-line description. The method it
    #    calls replaces every occurrence of a sequence, and comes from
    #    swift-collections' RangeReplaceableCollection extension; the slice
    #    that `self[startIndex ..< endIndex]` produces is a Slice<String> and
    #    not range-replaceable, so the call does not resolve. Converting to
    #    String first is what the call meant and works on every platform.
    python3 - "$SRC/Sources/FoundationEssentials/Predicate/Predicate+Description.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

marker = '        return String(self[startIndex ..< endIndex].replacing("\\n", with: "\\n    "))\n'
if marker in source:
    source = source.replace(
        marker,
        '        return String(self[startIndex ..< endIndex]).replacing("\\n", with: "\\n    ")\n',
        1,
    )
    open(path, "w").write(source)
    print("patched Predicate+Description.swift")
PYEOF

    # 9. Regular expressions are not in this port's standard library.
    #
    #    Regex, firstMatch and prefixMatch are in _StringProcessing, which
    #    build-stdlib.sh does not build. Foundation already has a switch for
    #    that: `#if !NO_REGEX` guards its use in String+Comparison.swift. This
    #    defines NO_REGEX for the whole module and excludes the only other
    #    file that names Regex, so a .regularExpression compare option falls
    #    through to the literal path instead of failing to compile. That is a
    #    real functional loss and is listed as such in the build output.
    python3 - "$SRC/Sources/FoundationEssentials/String/RegexPatternCache.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_NO_REGEX__" not in source:
    source = "#if !NO_REGEX // __SWITCH_NO_REGEX__\n" + source + "\n#endif // !NO_REGEX\n"
    open(path, "w").write(source)
    print("patched RegexPatternCache.swift")
PYEOF

    # 10. read(2) returns int in newlib, not ssize_t.
    #
    #     FileManager's file comparison counts bytes with `var readBytes = 0`,
    #     which is an Int, and assigns read(2)'s result to it. glibc's read
    #     returns ssize_t, which Swift imports as Int; newlib's returns int,
    #     which is Int32, so the assignment does not type-check. Converting is
    #     what the call means on both.
    python3 - "$SRC/Sources/FoundationEssentials/FileManager/FileManager+Basics.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

marker = "                                readBytes = read(fd1, buf1.baseAddress!, quantum)\n"
if marker in source:
    source = source.replace(
        marker,
        "                                readBytes = Int(read(fd1, buf1.baseAddress!, quantum))\n",
        1,
    )
    open(path, "w").write(source)
    print("patched FileManager+Basics.swift")
PYEOF

    # 11. Predicate's collection contains needs no source change: the
    #     `contains(_:)` it calls takes a collection of elements, which is
    #     another _StringProcessing API, and the Glibc shim supplies it.

    # 12. The regex extensions.
    #
    #     RegexComponent, CustomConsumingRegexComponent and Regex are all in
    #     _StringProcessing too. Date's ISO 8601 conformance and the predicate
    #     expression that matches a regex are unusable without them, so they are
    #     left out under the same NO_REGEX flag. The rest of Date's formatting
    #     and of Predicate are unaffected: neither extension is referenced by
    #     the code that remains.
    python3 - "$SRC/Sources/FoundationEssentials/Formatting/Date+ISO8601FormatStyle.swift" \
              "$SRC/Sources/FoundationEssentials/Predicate/Expressions/Regex.swift" <<'PYEOF'
import sys

# Date.ISO8601FormatStyle: everything from "// MARK: - Regex" to the end.
path = sys.argv[1]
source = open(path).read()
marker = "// MARK: - Regex\n"
if marker in source and "__SWITCH_NO_REGEX_DATE__" not in source:
    source = source.replace(
        marker,
        "#if !NO_REGEX // __SWITCH_NO_REGEX_DATE__\n// MARK: - Regex\n",
        1,
    )
    source = source.rstrip("\n") + "\n\n#endif // !NO_REGEX\n"
    open(path, "w").write(source)
    print("patched Date+ISO8601FormatStyle.swift")

# The whole predicate regex file.
path = sys.argv[2]
source = open(path).read()
if "__SWITCH_NO_REGEX_PREDICATE__" not in source:
    source = (
        "#if !NO_REGEX // __SWITCH_NO_REGEX_PREDICATE__\n"
        + source
        + "\n#endif // !NO_REGEX\n"
    )
    open(path, "w").write(source)
    print("patched Predicate/Expressions/Regex.swift")
PYEOF

    # 13. DIR is not opaque in newlib.
    #
    #     Foundation picks the type of an open directory handle by platform:
    #     `UnsafeMutablePointer<DIR>` on Darwin, where DIR is a full struct,
    #     and `OpaquePointer` everywhere else, where glibc's DIR is opaque.
    #     newlib defines DIR, so neither branch fits: opendir, readdir and
    #     closedir all take the pointer. The __SWITCH__ arm is the Darwin one.
    python3 - "$SRC/Sources/FoundationEssentials/FileManager/FileOperations+Enumeration.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_DIR__" not in source:
    marker = """struct _POSIXDirectoryContentsSequence: Sequence {
    #if canImport(Darwin)
    typealias DirectoryEntryPtr = UnsafeMutablePointer<DIR>
"""
    if marker not in source:
        sys.stderr.write("FileOperations+Enumeration.swift: the DIR typealias moved\n")
        sys.exit(1)
    source = source.replace(
        marker,
        """struct _POSIXDirectoryContentsSequence: Sequence {
    #if __SWITCH__ // __SWITCH_DIR__
    typealias DirectoryEntryPtr = UnsafeMutablePointer<DIR>
    #elseif canImport(Darwin)
    typealias DirectoryEntryPtr = UnsafeMutablePointer<DIR>
""",
        1,
    )
    open(path, "w").write(source)
    print("patched FileOperations+Enumeration.swift (DIR)")
PYEOF

    # 14. sendfile(2).
    #
    #     Foundation copies files with sendfile when it is available and with a
    #     read/write loop on WASI. newlib has no sendfile, so the console takes
    #     the same loop. It is not slower here: fsdev copies through the same
    #     user-space buffers either way.
    python3 - "$SRC/Sources/FoundationEssentials/FileManager/FileOperations.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_SENDFILE__" not in source:
    marker = """        #if os(WASI)
        // WASI doesn't have sendfile, so we need to do it in user space with read/write
"""
    if marker not in source:
        sys.stderr.write("FileOperations.swift: the sendfile block moved\n")
        sys.exit(1)
    source = source.replace(
        marker,
        """        #if os(WASI) || __SWITCH__ // __SWITCH_SENDFILE__
        // Neither WASI nor the console has sendfile, so the copy is done in
        // user space with read and write.
""",
        1,
    )
    open(path, "w").write(source)
    print("patched FileOperations.swift (sendfile)")
PYEOF

    # 15. The regex debug description.
    #
    #     The extension is guarded by `compiler(>=5.11)`, which is true here,
    #     but it names StringContainsRegex, which patch 12 removes under
    #     NO_REGEX. Guarding on both keeps the file consistent.
    python3 - "$SRC/Sources/FoundationEssentials/Predicate/Predicate+Description.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

marker = "#if compiler(>=5.11)\n@available(FoundationPredicateRegex 0.4, *)\nextension PredicateExpressions.StringContainsRegex"
if marker in source:
    source = source.replace(
        marker,
        "#if compiler(>=5.11) && !NO_REGEX // __SWITCH_NO_REGEX_DESCRIPTION__\n@available(FoundationPredicateRegex 0.4, *)\nextension PredicateExpressions.StringContainsRegex",
        1,
    )
    open(path, "w").write(source)
    print("patched Predicate+Description.swift (regex extension)")
PYEOF

    # 16. chown's "leave unchanged" value and its argument type.
    #
    #     The sentinel is UInt32(bitPattern: -1), which is -1 as glibc's uid_t
    #     and as Darwin's. newlib's uid_t is unsigned short, where that value
    #     does not fit; uid_t.max is the same -1 in the type chown takes on
    #     each platform. Annotating the two results stops Swift from choosing
    #     Any? for `uid_t.init` in the optional chain.
    python3 - "$SRC/Sources/FoundationEssentials/FileManager/FileManager+Files.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

if "__SWITCH_CHOWN__" not in source:
    marker = """                var leaveUnchanged: UInt32 { UInt32(bitPattern: -1) }
                let rawUserID = userID.flatMap(uid_t.init) ?? user.flatMap(Platform.uid(forName:)) ?? leaveUnchanged
                let rawGroupID = groupID.flatMap(gid_t.init) ?? group.flatMap(Platform.gid(forName:)) ?? leaveUnchanged
"""
    if marker not in source:
        sys.stderr.write("FileManager+Files.swift: the chown block moved\n")
        sys.exit(1)
    source = source.replace(
        marker,
        """                var leaveUnchanged: uid_t { uid_t.max } // __SWITCH_CHOWN__
                let rawUserID: uid_t = userID.flatMap(uid_t.init) ?? user.flatMap(Platform.uid(forName:)) ?? leaveUnchanged
                let rawGroupID: gid_t = groupID.flatMap(gid_t.init) ?? group.flatMap(Platform.gid(forName:)) ?? leaveUnchanged
""",
        1,
    )
    open(path, "w").write(source)
    print("patched FileManager+Files.swift (chown)")
PYEOF

    # 17. The size argument of write(2).
    #
    #     newlib's read returns int and its write takes size_t, so the byte
    #     count from the read/write copy loop needs converting before it can be
    #     passed back. glibc's read already returns ssize_t; the conversion is
    #     a no-op there.
    python3 - "$SRC/Sources/FoundationEssentials/FileManager/FileOperations.swift" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

marker = "                guard write(dstfd, buffer.baseAddress, bytesRead) == bytesRead else {\n"
if marker in source:
    source = source.replace(
        marker,
        "                guard write(dstfd, buffer.baseAddress, Int(bytesRead)) == Int(bytesRead) else {\n",
        1,
    )
    open(path, "w").write(source)
    print("patched FileOperations.swift (write size)")
PYEOF

    # 18. newlib's <stdatomic.h> cannot be built as a Clang module.
    #
    #     _CStdlib.h includes it when it exists. The C shims do not use any
    #     atomic type -- there is no _Atomic in the directory -- so skipping
    #     the include on the console costs nothing. It has to be skipped for a
    #     program that imports FoundationEssentials, not for the library
    #     build: SwiftPM compiles the header directly, where <stdint.h> has
    #     already defined intmax_t, but a client imports it as a module and
    #     Clang builds newlib's stdatomic.h standalone, where intmax_t is
    #     undeclared and the module fails.
    python3 - "$SRC/Sources/_FoundationCShims/include/_CStdlib.h" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()

marker = "#if __has_include(<stdatomic.h>)\n#include <stdatomic.h>\n#endif"
if marker in source:
    source = source.replace(
        marker,
        "#if __has_include(<stdatomic.h>) && !defined(__SWITCH__) // __SWITCH_NO_STDATOMIC__\n#include <stdatomic.h>\n#endif",
        1,
    )
    open(path, "w").write(source)
    print("patched _CStdlib.h (stdatomic)")
PYEOF
}

# --------------------------------------------------------------------------
# The build
# --------------------------------------------------------------------------
build_shim() {
    # The Glibc module has to exist before Foundation compiles: Foundation's
    # `import Glibc` resolves against it, and it is a package, so it is built
    # the same way Foundation is rather than compiled inline.
    echo "Building the Glibc shim"
    (cd "$SCRIPT_DIR/shim" &&
        "$SWIFT" build \
            --swift-sdk switch2 \
            --triple aarch64-none-none-elf \
            -c release \
            --disable-sandbox) || die "failed to build the Glibc shim"
}

build_foundation() {
    echo "Building FoundationEssentials with $JOBS jobs"

    # SWIFT_ENABLE_REFLECTION is needed for the same reason as in
    # build-stdlib.sh: Foundation's Predicate and AttributedString code
    # reflects over types, and without it the metadata it asks for is not
    # emitted. The defines mirror that build's, so the two agree on the
    # layout of everything they share.
    definitions="-DSWIFT_STDLIB_HAS_TYPE_PRINTING=1"

    # Note the target triple: aarch64-none-none-elf, not aarch64-none-elf.
    # SwiftPM treats the OS component as part of the module cache key, and the
    # value here has to match what switch2-build.sh passes or every package
    # would be rebuilt twice.
    #
    # --disable-sandbox: SwiftPM's sandbox uses seccomp on Linux, and the
    #   build runs inside an FHS chroot on NixOS, where it cannot install a
    #   filter.
    # -Xswiftc -Xcc -D__SWITCH__: the C shims and Foundation's own
    #   `#if os(...)` chains both read it.
    # --target, not --product. The product would be the natural way to get a
    # static library, but SwiftPM resolves the whole package graph for it and
    # builds FoundationInternationalization and ICU along the way -- several
    # hundred C++ files that are out of scope here and fail to compile without
    # the host C++ headers. The target builds exactly what is needed, and
    # install_foundation archives its objects itself.
    #
    # No -Xcc flags here, deliberately. A flag on this command line reaches
    # *every* compilation, including the host-side build of the FoundationMacros
    # plugin, which runs on the build machine and imports Glibc. Pointing it at
    # $LIBNX/include makes libounce's BSD <arpa/inet.h> and <netinet/in.h>
    # shadow the host's, and the host build then fails looking for glibc's
    # <sys/_types.h>. The toolset in the Swift SDK carries those options
    # instead, where SwiftPM applies them to the target only; see
    # ../swiftpm/install-swift-sdk.sh.
    # The Glibc shim. Foundation and swift-collections import Glibc on Linux,
    # and a bare-metal target matches none of the platforms those files test
    # for, so every C library call in them -- floor, labs, malloc,
    # clock_gettime -- would be unresolved. The shim is a module named Glibc
    # that re-exports newlib's headers, so the existing `canImport(Glibc)`
    # arms select it. See shim/Glibc/include/Glibc.h.
    #
    # -fmodule-map-file and -I are both required: the first says where the
    # module is, the second where its header is.

    # -D__SWITCH__ is passed twice on purpose, and both are needed:
    #
    #   -Xswiftc -D__SWITCH__   makes `#if __SWITCH__` true in Swift sources,
    #                           which is what the _ThreadLocal patch relies on.
    #                           Swift's #if does not accept defined(...); the
    #                           bare name is the whole test.
    #   -Xcc      -D__SWITCH__  the same for the C shims.
    #
    # The toolset already sets both for every C compilation and both
    # __SWITCH2__, so these are only here for the Swift side.
    (cd "$SRC" &&
        "$SWIFT" build \
            --swift-sdk switch2 \
            --triple aarch64-none-none-elf \
            -c release \
            -j "$JOBS" \
            --disable-sandbox \
            --target FoundationEssentials \
            -Xswiftc "$definitions" \
            -Xswiftc -D__SWITCH__ \
            -Xswiftc -DNO_REGEX \
            -Xcc -fmodule-map-file="$SHIM/Sources/GlibcC/include/module.modulemap" \
            -Xcc -I"$SHIM/Sources/GlibcC/include" \
            -Xswiftc -Xcc -Xswiftc -fmodule-map-file="$SHIM/Sources/GlibcC/include/module.modulemap" \
            -Xswiftc -Xcc -Xswiftc -I"$SHIM/Sources/GlibcC/include")
}

install_foundation() {
    echo "Installing into $SWIFTLIB"

    # SwiftPM puts the modules and the static archives under
    # .build/<triple>/release. The archives go where every other Swift library
    # lives, so -lswiftFoundationEssentials finds them the same way; the
    # .swiftmodule goes next to the standard library's, so `import
    # FoundationEssentials` resolves.
    build="$SRC/.build/aarch64-none-none-elf/release"
    [ -d "$build" ] || die "no build output in $build"

    # A --target build produces objects, not an archive, so the archive is
    # made here. It holds FoundationEssentials and everything it needs except
    # the Swift standard library: the C shims, the Glibc shim and the
    # swift-collections modules. One archive rather than seven, so a program
    # links it once with -lswiftFoundationEssentials.
    #
    # The objects are copied to staging under a module-qualified name first.
    # Several modules have files with the same basename (Debugging.swift,
    # Descriptions.swift), and ar would replace a member rather than add a
    # second copy.
    staging="$build/foundation-archive"
    archive="$build/libswiftFoundationEssentials.a"
    rm -rf "$staging"
    mkdir -p "$staging"

    objects=0
    for module in FoundationEssentials _FoundationCShims Glibc GlibcC \
        _RopeModule OrderedCollections _CollectionsUtilities \
        InternalCollectionsUtilities; do
        directory="$build/$module.build"
        [ -d "$directory" ] || continue
        for object in "$directory"/*.o; do
            [ -f "$object" ] || continue
            cp "$object" "$staging/${module}__$(basename "$object")"
            objects=$((objects + 1))
        done
    done
    [ "$objects" -gt 0 ] ||
        die "no Foundation objects were built in $build. Check the build output above."

    rm -f "$archive"
    "$DEVKITA64/bin/aarch64-none-elf-ar" rcs "$archive" "$staging"/*.o ||
        die "failed to archive the Foundation objects"
    cp "$archive" "$SWIFTLIB/"

    # The module interfaces. A program that imports FoundationEssentials loads
    # these transitively, so they go beside the standard library's modules even
    # though the program never names them.
    for module in "$build"/Modules/*.swiftmodule; do
        [ -e "$module" ] || continue
        cp "$module" "$SWIFTLIB/"
    done

    glibc_module="$SHIM/.build/aarch64-none-none-elf/release/Modules/Glibc.swiftmodule"
    [ -f "$glibc_module" ] && cp "$glibc_module" "$SWIFTLIB/"

    # The Clang modules FoundationEssentials was compiled against. Importing
    # FoundationEssentials loads them, so their headers and module maps are
    # installed beside the library instead of being left behind in the build
    # checkout. The full rules pass -Xcc -I for both.
    include="$SWIFT_HOME/foundation/include"
    rm -rf "$include"
    mkdir -p "$include"
    cp -r "$SRC/Sources/_FoundationCShims/include" "$include/FoundationCShims"
    cp -r "$SHIM/Sources/GlibcC/include" "$include/GlibcC"
}

build_networking() {
    echo "Building FoundationNetworking"

    build="$NETWORKING/build"
    rm -rf "$build"
    mkdir -p "$build"

    # The transport. It is C because every call it makes is a libnx C call:
    # socketInitializeDefault, getaddrinfo, connect, poll, recv, send and the
    # ssl service. clang, not gcc, so that it agrees with the Swift side on
    # -mtp=tpidrro_el0 and on the target triple.
    "$CLANG" -target aarch64-none-elf --sysroot="$DEVKITA64/aarch64-none-elf" \
        -std=gnu11 -O2 -g -fPIC \
        -mtp=tpidrro_el0 \
        -D__SWITCH__ -D__SWITCH2__ \
        -I"$LIBNX/include" \
        -c "$NETWORKING/transport.c" -o "$build/transport.o" ||
        die "failed to compile the FoundationNetworking transport"

    # The Swift module. It imports the installed FoundationEssentials module,
    # so this runs after install_foundation. The Clang module maps are the
    # ones FoundationEssentials itself was built against; importing it loads
    # them, and the compiler needs to find them again here.
    "$TOOLCHAIN/usr/bin/swiftc" \
        -target aarch64-none-none-elf \
        -parse-as-library -O -g -wmo -swift-version 5 \
        -module-name FoundationNetworking \
        -D__SWITCH__ \
        -I "$SWIFTLIB" \
        -Xcc --sysroot="$DEVKITA64/aarch64-none-elf" \
        -Xcc -D__SWITCH__ \
        -Xcc -D__SWITCH2__ \
        -Xcc -D__STDC_HOSTED__=0 \
        -Xcc -I"$LIBNX/include" \
        -Xcc -I"$SWIFT_HOME/foundation/include/GlibcC" \
        -Xcc -fmodule-map-file="$SWIFT_HOME/foundation/include/GlibcC/module.modulemap" \
        -Xcc -I"$SWIFT_HOME/foundation/include/FoundationCShims" \
        -Xcc -fmodule-map-file="$SWIFT_HOME/foundation/include/FoundationCShims/module.modulemap" \
        -emit-module -emit-module-path "$build/FoundationNetworking.swiftmodule" \
        -emit-object -o "$build/FoundationNetworking.o" \
        "$NETWORKING"/Sources/FoundationNetworking/*.swift ||
        die "failed to compile FoundationNetworking"

    # One object and the transport, archived by devkitA64's own ar rather than
    # by the Swift driver. The driver's static-library path uses libtool on a
    # macOS host and ar on Linux; naming the two members explicitly keeps the
    # archive the same on both. A program links the module once with
    # -lswiftFoundationNetworking, and the object that references sfn_* pulls
    # the transport in.
    "$DEVKITA64/bin/aarch64-none-elf-ar" rcs \
        "$build/libswiftFoundationNetworking.a" \
        "$build/FoundationNetworking.o" "$build/transport.o" ||
        die "failed to archive FoundationNetworking"
}

install_networking() {
    echo "Installing FoundationNetworking into $SWIFTLIB"

    build="$NETWORKING/build"
    [ -f "$build/libswiftFoundationNetworking.a" ] ||
        die "no FoundationNetworking archive in $build"
    [ -f "$build/FoundationNetworking.swiftmodule" ] ||
        die "no FoundationNetworking module in $build"

    cp "$build/libswiftFoundationNetworking.a" "$SWIFTLIB/"
    cp "$build/FoundationNetworking.swiftmodule" "$SWIFTLIB/"
}

patch_sources
build_shim
build_foundation
install_foundation
build_networking
install_networking

cat <<EOF

FoundationEssentials and FoundationNetworking are installed in $SWIFTLIB.

To build a program that uses them, add them to LIBS the same way the standard
library is added:

  LIBS := -lnx -lswiftFoundationEssentials -lswiftFoundationNetworking \\
          \$(SWIFT_FULL_LIBS)

and import FoundationEssentials and FoundationNetworking, not Foundation:
FoundationInternationalization is still missing, so the umbrella module does
not link. See examples/foundation-hello and examples/foundation-network.

FoundationNetworking supports http:// and https:// data requests. HTTPS uses
the console's ssl service, so certificate and host-name verification work
without a CA bundle. It does not implement caches, cookies, proxies,
authentication challenges, compression or HTTP/2; see HANDOFF.md.

Not built here, and why:
  FoundationInternationalization  needs ICU
  FoundationXML                   needs libxml2
EOF
