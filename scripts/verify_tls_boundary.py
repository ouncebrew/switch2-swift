#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Find the Swift thread-local boundary in a linked Switch 2 ELF.

`swift/swift_shim.c` clears the Swift thread-locals of the main thread from a
constructor, because the loader does not zero them and the standard library's
variables land in that garbage. It has to start exactly where the Swift
variables begin and not one byte earlier, because everything before that point
belongs to libnx (and now mimalloc) and clearing it breaks fsdev before `main`.

That boundary is an SDK internal and it moves whenever the console SDK adds a
thread-local. On `ounce-sdk 20261113`, mimalloc arrived and pushed it from
0x410 to 0x430. This script re-derives it from a linked program, so a port to a
new SDK release can be checked rather than guessed at.

It also enforces the register rule: **no `tpidr_el0` anywhere in the program**.
On the console `tpidr_el0` holds the kernel's thread control block, so a
`thread_local` compiled against it reads memory that is not the program's. The
compiler must be told `-mtp=tpidrro_el0`, and every C++ library with a
thread-local in it must be rebuilt with that flag; a library built without it
links and runs until the first thread-local access, then reads garbage or
faults. `check_thread_pointer` fails on any occurrence, because a single one
is enough to break a program and there is no benign case.

How it decides
--------------
The ELF's TLS symbols are sorted by offset. libnx and mimalloc own the low
range; the Swift libraries own the high range. The script walks the sorted
symbols and finds the first one it recognises as a Swift thread-local (by
demangled name), then reports the end of the last symbol before it. The two
must agree, and the script fails if they do not, which is the case where a new
SDK has interleaved its variables with Swift's and the boundary cannot be a
single number.

Recognising libnx's symbols by name rather than by count is deliberate: an SDK
that adds a libnx thread-local in the middle of the range must be caught, and
counting bytes from the end of `.tbss` cannot do that.

Usage
-----
    python3 scripts/verify_tls_boundary.py BINARY [BINARY...]
    python3 scripts/verify_tls_boundary.py --shim PATH BINARY
    python3 scripts/verify_tls_boundary.py --write-swift-shim PATH BINARY
    python3 scripts/verify_tls_boundary.py --archive LIB.a [LIB.a...]

Exit status is 0 when every binary agrees on a boundary that matches the shim
and no input uses `tpidr_el0`, 1 when either check fails, 2 on a usage or
parse error.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Symbols that belong to the Swift runtime and therefore mark the start of the
# range the shim clears. Names are matched against the demangled symbol text.
SWIFT_TLS_PATTERNS = (
    "ActiveTask::Value",
    "ExecutorTrackingInfo::ActiveInfoInThread",
    "FallbackTaskLocalStorage::Value",
    "SwiftTLSContext::get()::TLSContext",
    "SwiftTLSContext::TLSContext",
)

# Symbols that belong to libnx, libdispatch or mimalloc, i.e. everything that
# must survive. They are matched for reporting only; the decision is made by
# position relative to the first Swift symbol.
FOREIGN_PREFIXES = ("__mi_", "fsdev_last_result", "g_fsPriority", "__nx_", "__dispatch_tsd")

SHIM_DEFINE = "SWIFT_TLS_START"


@dataclass
class TlsSymbol:
    offset: int
    size: int
    name: str
    is_swift: bool
    is_foreign: bool

    @property
    def end(self) -> int:
        return self.offset + self.size


def find_tool(*names: str) -> str:
    """Return the first tool on PATH, or fail with a useful message."""
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    sys.exit(
        f"verify_tls_boundary.py: none of {', '.join(names)} is on PATH.\n"
        "The devkitPro toolchain provides them; put "
        "$DEVKITPRO/devkitA64/bin on PATH, or run this inside the SDK shell."
    )


def read_tls_symbols(binary: Path, nm: str) -> list[TlsSymbol]:
    """Return the thread-local symbols of BINARY, sorted by offset.

    `nm -S` prints offset, size and name for each symbol, but only for the
    symbols it considers thread-local when the section is known. The filter is
    therefore geometric: a program's TLS lives at the bottom of the address
    space relative to `tpidrro_el0`, and `.tbss` is at most a few kilobytes, so
    the section bounds are read from `readelf` and the symbols are restricted
    to that range.
    """
    result = subprocess.run(
        [nm, "-S", "-C", "--defined-only", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(f"verify_tls_boundary.py: nm failed on {binary}:\n{result.stderr.strip()}")

    symbols: list[TlsSymbol] = []
    for line in result.stdout.splitlines():
        # offset size type name
        parts = line.split(None, 3)
        if len(parts) != 4:
            continue
        offset, size, kind, name = parts
        if kind not in ("b", "B", "d", "D"):
            continue
        try:
            offset_value = int(offset, 16)
            size_value = int(size, 16)
        except ValueError:
            continue
        # Only the low part of the address space is the thread-local block.
        # Program symbols live at their link addresses, which are much higher.
        if offset_value > 0x10000:
            continue
        if size_value == 0:
            continue
        symbols.append(
            TlsSymbol(
                offset=offset_value,
                size=size_value,
                name=name,
                is_swift=any(pattern in name for pattern in SWIFT_TLS_PATTERNS),
                is_foreign=name.startswith(FOREIGN_PREFIXES),
            )
        )

    symbols.sort(key=lambda symbol: (symbol.offset, symbol.size))
    return symbols


def read_tls_sections(binary: Path, readelf: str) -> tuple[int, int]:
    """Return the size of `.tdata` and `.tbss` in BINARY."""
    result = subprocess.run(
        [readelf, "-S", "-W", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(f"verify_tls_boundary.py: readelf failed on {binary}:\n{result.stderr.strip()}")

    sizes = {".tdata": 0, ".tbss": 0}
    for line in result.stdout.splitlines():
        # [Nr] Name Type Address Off Size ES Flg Lk Inf Al
        match = re.search(
            r"\]\s+(\.tdata|\.tbss)\s+\S+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+([0-9A-Fa-f]+)",
            line,
        )
        if match:
            sizes[match.group(1)] = int(match.group(2), 16)
    return sizes[".tdata"], sizes[".tbss"]


def analyse(binary: Path, nm: str, readelf: str) -> tuple[int, list[TlsSymbol]]:
    """Return the Swift TLS boundary and the symbol list it was derived from."""
    symbols = read_tls_symbols(binary, nm)
    if not symbols:
        sys.exit(
            f"verify_tls_boundary.py: no thread-local symbols found in {binary}.\n"
            "Is this a program that links the Swift standard library? An "
            "embedded-Swift program has no Swift thread-locals and no boundary "
            "to check."
        )

    swift_symbols = [symbol for symbol in symbols if symbol.is_swift]
    if not swift_symbols:
        sys.exit(
            f"verify_tls_boundary.py: {binary} has thread-locals but none of them "
            "look like the Swift runtime's.\n"
            f"Recognised names: {', '.join(SWIFT_TLS_PATTERNS)}\n"
            "If a new Swift release renamed them, update SWIFT_TLS_PATTERNS."
        )

    first_swift = min(symbol.offset for symbol in swift_symbols)

    # Everything strictly below the first Swift symbol has to be foreign. If it
    # is not, the SDK has interleaved its variables with Swift's and no single
    # number can describe the boundary.
    foreign_below = [symbol for symbol in symbols if symbol.offset < first_swift]
    interleaved = [
        symbol
        for symbol in foreign_below
        if not symbol.is_foreign
    ]
    if interleaved:
        names = ", ".join(f"{symbol.name}@{symbol.offset:#x}" for symbol in interleaved)
        sys.exit(
            f"verify_tls_boundary.py: {binary} has unrecognised thread-locals "
            f"below the Swift range: {names}.\n"
            "A single SWIFT_TLS_START cannot clear the Swift slots without also "
            "clearing these. Add the names to FOREIGN_PREFIXES if they belong to "
            "libnx or libdispatch, or the port needs a different scheme."
        )

    # The boundary is where the last foreign symbol ends. If that does not equal
    # the first Swift offset there is a gap, which is harmless but worth
    # reporting, or an overlap, which is not.
    last_foreign_end = max(
        (symbol.end for symbol in foreign_below), default=0
    )
    if last_foreign_end > first_swift:
        overlap = [
            symbol.name
            for symbol in foreign_below
            if symbol.offset < first_swift < symbol.end
        ]
        sys.exit(
            f"verify_tls_boundary.py: {binary} has thread-locals that overlap the "
            f"Swift range: {', '.join(overlap)}.\n"
            "The layout is not a clean split and cannot be cleared by offset."
        )

    return first_swift, symbols


def shim_value(shim: Path) -> int:
    """Return the SWIFT_TLS_START the shim currently defines."""
    text = shim.read_text()
    match = re.search(
        rf"#ifndef\s+{SHIM_DEFINE}\s*\n\s*#define\s+{SHIM_DEFINE}\s+0x([0-9A-Fa-f]+)",
        text,
    )
    if not match:
        sys.exit(
            f"verify_tls_boundary.py: could not find '#define {SHIM_DEFINE} 0x...' "
            f"in {shim}."
        )
    return int(match.group(1), 16)


def write_shim_value(shim: Path, value: int) -> bool:
    """Set SWIFT_TLS_START in SHIM to VALUE. Returns whether it changed."""
    text = shim.read_text()
    pattern = re.compile(
        rf"(#ifndef\s+{SHIM_DEFINE}\s*\n\s*#define\s+{SHIM_DEFINE}\s+)0x[0-9A-Fa-f]+"
    )
    updated, count = pattern.subn(rf"\g<1>0x{value:X}", text)
    if count != 1:
        sys.exit(
            f"verify_tls_boundary.py: expected exactly one "
            f"'{SHIM_DEFINE}' definition in {shim}, found {count}."
        )
    if updated == text:
        return False
    shim.write_text(updated)
    return True


def check_thread_pointer(path: Path, objdump: str) -> tuple[bool, list[str]]:
    """Return whether PATH avoids `tpidr_el0`, and where it does not.

    The console has two thread-pointer registers. `tpidrro_el0` is read-only
    from EL0 and points at the block the program's thread-locals live in;
    `tpidr_el0` holds the kernel's thread control block. The compiler emits
    `[tpidr_el0 + offset]` by default, which is why every toolchain here passes
    `-mtp=tpidrro_el0`.

    One occurrence is enough to break a program, and there is no benign case: a
    library built without the flag links cleanly and reads the wrong memory the
    first time one of its thread-locals is touched. What makes this worth
    checking is that a *stale* library is the normal way it appears — the build
    succeeds because the flag is right in the script, while the installed
    archive predates the flag.

    For an archive the member names are reported, because that is what has to be
    rebuilt.
    """
    result = subprocess.run(
        [objdump, "-d", str(path)], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        return False, [
            f"objdump failed: {result.stderr.strip() or 'no output'}"
        ]

    # `tpidrro_el0` contains `tpidr_el0` as a prefix, so the two are told apart
    # before counting: drop every `tpidrro_el0` mention, then look for what is
    # left. A substring test that forgot this would report every correct
    # program as broken.
    offenders: list[str] = []
    current_member = None
    for line in result.stdout.splitlines():
        member = re.match(r"^(\S+\.o):\s+file format", line)
        if member:
            current_member = member.group(1)

        if "tpidr_el0" not in line.replace("tpidrro_el0", ""):
            continue
        label = current_member or "<program>"
        if label not in offenders:
            offenders.append(label)

    return not offenders, offenders


def check_archives(args: argparse.Namespace) -> int:
    """Check static libraries for `tpidr_el0` and nothing else.

    An archive has no linked TLS layout, so the boundary cannot be measured
    from it. This mode exists so the register rule can be checked against the
    libraries themselves, which is where a stale build shows up first and with
    the most detail.
    """
    objdump = find_tool("aarch64-none-elf-objdump", "llvm-objdump", "objdump")
    failed = False

    for path in args.binaries:
        if not path.is_file():
            sys.exit(f"verify_tls_boundary.py: {path}: no such file")
        clean, offenders = check_thread_pointer(path, objdump)
        if clean:
            print(f"{path}: no tpidr_el0")
        else:
            failed = True
            print(f"{path}: uses tpidr_el0 in {len(offenders)} object(s):")
            for offender in offenders[:20]:
                print(f"  {offender}")
            if len(offenders) > 20:
                print(f"  ... and {len(offenders) - 20} more")

    if failed:
        print(
            "\nRebuild the affected library with -mtp=tpidrro_el0. For the "
            "Swift standard library that is:\n"
            "  sh $DEVKITPRO/swift/full/build-stdlib.sh libs",
            file=sys.stderr,
        )
        return 1
    return 0


def describe(symbols: list[TlsSymbol], boundary: int) -> str:

    """Return a short table of the low thread-locals, for the report."""
    lines = []
    for symbol in symbols:
        if symbol.offset > boundary + 0x40:
            continue
        zone = "swift" if symbol.offset >= boundary else "libnx"
        lines.append(
            f"  {symbol.offset:#06x}  {symbol.size:#06x}  {zone:5}  {symbol.name}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the Swift thread-local boundary against a linked ELF.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "binaries",
        nargs="+",
        type=Path,
        help="linked .elf files, or archives with --archive",
    )
    parser.add_argument(
        "--archive",
        action="store_true",
        help="treat the arguments as static libraries: check only the thread "
        "pointer, since an archive has no linked TLS layout to measure",
    )
    parser.add_argument(
        "--shim",
        type=Path,
        help="swift_shim.c to check against, instead of only reporting",
    )
    parser.add_argument(
        "--write-swift-shim",
        type=Path,
        metavar="SHIM",
        help="update SWIFT_TLS_START in this swift_shim.c to the measured value",
    )
    parser.add_argument(
        "--quiet", action="store_true", help="print only failures and the result"
    )
    args = parser.parse_args()

    objdump = find_tool("aarch64-none-elf-objdump", "llvm-objdump", "objdump")

    if args.archive:
        return check_archives(args)

    nm = find_tool("aarch64-none-elf-nm", "llvm-nm", "nm")
    readelf = find_tool("aarch64-none-elf-readelf", "llvm-readelf", "readelf")

    measured: dict[int, list[Path]] = {}
    details: dict[int, str] = {}
    pointer_failures: list[tuple[Path, list[str]]] = []
    for binary in args.binaries:
        if not binary.is_file():
            sys.exit(f"verify_tls_boundary.py: {binary}: no such file")
        boundary, symbols = analyse(binary, nm, readelf)
        tdata, tbss = read_tls_sections(binary, readelf)

        # The whole TLS block has to be big enough that clearing from the
        # boundary leaves room for the Swift slots.
        if boundary >= tdata + tbss:
            sys.exit(
                f"verify_tls_boundary.py: {binary}: the Swift boundary "
                f"{boundary:#x} is past the end of the TLS block "
                f"({tdata + tbss:#x})."
            )

        clean, offenders = check_thread_pointer(binary, objdump)
        if not clean:
            pointer_failures.append((binary, offenders))

        measured.setdefault(boundary, []).append(binary)
        details[boundary] = describe(symbols, boundary)

        if not args.quiet:
            print(f"{binary}:")
            print(f"  TLS block: .tdata {tdata:#x} + .tbss {tbss:#x} = {tdata + tbss:#x}")
            print(f"  Swift thread-locals start at {boundary:#x}")
            print(details[boundary])
            print()

    if len(measured) != 1:
        print(
            "verify_tls_boundary.py: the programs disagree on the boundary:\n"
            + "\n".join(
                f"  {boundary:#x}: {', '.join(str(path) for path in paths)}"
                for boundary, paths in sorted(measured.items())
            ),
            file=sys.stderr,
        )
        print(
            "\nThis means different link sets produce different layouts. The "
            "shim cannot serve both, so the boundary has to be lowered to the "
            "minimum, or the layout has to be made uniform.",
            file=sys.stderr,
        )
        return 1

    boundary = next(iter(measured))
    print(f"All {len(args.binaries)} program(s) agree: {SHIM_DEFINE}=0x{boundary:X}")

    if args.write_swift_shim:
        changed = write_shim_value(args.write_swift_shim, boundary)
        print(
            f"{'Updated' if changed else 'Already set in'} "
            f"{args.write_swift_shim}: {SHIM_DEFINE}=0x{boundary:X}"
        )
        if changed:
            print(
                "Rebuild every Swift program afterwards: the shim is linked into "
                "each of them."
            )

    if args.shim:
        current = shim_value(args.shim)
        if current != boundary:
            print(
                f"\nverify_tls_boundary.py: {args.shim} has {SHIM_DEFINE}"
                f"=0x{current:X}, but the programs need 0x{boundary:X}.\n"
                + (
                    f"A value below the boundary clears part of "
                    f"{'__nx_dev_path_buf' if boundary == 0x430 else 'the libnx'}"
                    " block and breaks fsdev before main.\n"
                    if current < boundary
                    else "A value above the boundary leaves Swift thread-locals "
                    "uncleared, so Task { } dereferences garbage.\n"
                ),
                file=sys.stderr,
            )
            return 1
        print(f"{args.shim}: {SHIM_DEFINE}=0x{current:X} matches")

    if pointer_failures:
        print(
            "\nverify_tls_boundary.py: thread-locals are accessed through "
            "tpidr_el0, which is the kernel's thread control block on the "
            "console, not the program's:",
            file=sys.stderr,
        )
        for binary, offenders in pointer_failures:
            print(f"  {binary}:", file=sys.stderr)
            for offender in offenders[:10]:
                print(f"      {offender}", file=sys.stderr)
            if len(offenders) > 10:
                print(f"      ... and {len(offenders) - 10} more", file=sys.stderr)
        print(
            "\nEvery compiler invocation needs -mtp=tpidrro_el0. A *stale* "
            "library is the usual cause: the flag is right in the build script "
            "but the installed archive predates it. Rebuild it:\n"
            "  sh $DEVKITPRO/swift/full/build-stdlib.sh libs\n"
            "  sh $DEVKITPRO/swift/dispatch/build-dispatch.sh\n"
            "then rebuild every program that links them.",
            file=sys.stderr,
        )
        return 1

    print("No tpidr_el0: every thread-local goes through tpidrro_el0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
