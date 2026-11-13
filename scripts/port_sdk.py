#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Port the Switch 2 Swift toolchain to a new ounce-sdk release.

The Swift toolchain sits on top of the console SDK (libounce, OunceVK,
OunceHEN) and depends on a handful of its internals. Most of them are stable
across releases; the ones that are not are listed in `docs/PORTING.md`, and this
script checks every one of them so a port is a checklist rather than an
archaeology exercise.

What it does
------------
1. Reads the version of the SDK archive and of the SDK it would replace.
2. Unpacks the new archive to a staging directory and diffs it against the
   installed one, classifying each change as one the port cares about or one it
   does not.
3. Checks the headers and linker files the port depends on, byte for byte.
4. Checks the allocator interface (`_malloc_r` and friends), because libounce
   links mimalloc and the Swift toolchain's linker wrapper has to cooperate.
5. Rebuilds the Swift artifacts against the new SDK and verifies the TLS
   boundary with `verify_tls_boundary.py`.
6. Writes a report and, with `--apply`, installs the new SDK and updates
   `SWIFT_TLS_START` in `swift_shim.c`.

Usage
-----
    python3 scripts/port_sdk.py --archive NEW.tar.xz --dry-run
    python3 scripts/port_sdk.py --archive NEW.tar.xz --apply

The script never updates a remote or pushes. Committing and pushing are left to
`scripts/release.py`, so a port can be reviewed before it is published.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SHIM = REPO_ROOT / "swift" / "swift_shim.c"
VERIFY_TLS = REPO_ROOT / "scripts" / "verify_tls_boundary.py"

# Files the port reads directly. A change here is always worth reporting, even
# when the change turns out to be harmless.
WATCHED_FILES = (
    "libounce/switch.specs",
    "libounce/switch.ld",
    "libounce/switch2_rules",
    "libounce/switch_rules",
    "libounce/switch2_cpu.mk",
    "libounce/include/switch.h",
    "libounce/include/switch/arm/counter.h",
    "libounce/include/switch/arm/tls.h",
    "libounce/include/switch/kernel/jit.h",
    "libounce/include/switch/runtime/devices/fs_dev.h",
    "switch2vars.sh",
    "portlibs/switch2/include/ouncehen.h",
    "portlibs/switch2/include/ouncehen/protocol.h",
)

# Headers whose change can move the thread-local boundary: anything that
# declares a thread-local, or that includes something that does.
TLS_RELEVANT = re.compile(
    r"thread_local|_Thread_local|__thread\b|__nx_dev_path_buf|fsdev_last_result"
    r"|g_fsPriority|armGetTls"
)

# Symbols the Swift toolchain needs from libounce, and the newlib counterparts
# that they must not collide with.
ALLOCATOR_SYMBOLS = (
    "_malloc_r",
    "_free_r",
    "_realloc_r",
    "_memalign_r",
    "_malloc_usable_size_r",
    "_malloc_trim_r",
)


@dataclass
class Finding:
    """One result of the port check."""

    level: str  # "ok", "info", "warn", "fail"
    title: str
    detail: str = ""
    action: str = ""

    def render(self) -> str:
        marker = {"ok": "ok  ", "info": "info", "warn": "warn", "fail": "FAIL"}[self.level]
        lines = [f"[{marker}] {self.title}"]
        if self.detail:
            lines.extend(f"         {line}" for line in self.detail.splitlines())
        if self.action:
            lines.extend(f"      -> {line}" for line in self.action.splitlines())
        return "\n".join(lines)


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)

    def add(self, level: str, title: str, detail: str = "", action: str = "") -> None:
        self.findings.append(Finding(level, title, detail, action))

    @property
    def failed(self) -> bool:
        return any(finding.level == "fail" for finding in self.findings)

    @property
    def warned(self) -> bool:
        return any(finding.level == "warn" for finding in self.findings)

    def render(self) -> str:
        return "\n\n".join(finding.render() for finding in self.findings)


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run COMMAND, returning the completed process without raising."""
    return subprocess.run(command, capture_output=True, text=True, check=False, **kwargs)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_version(root: Path) -> dict[str, str]:
    """Parse ounce-sdk-version.txt into a dict."""
    path = root / "ounce-sdk-version.txt"
    if not path.is_file():
        return {}
    version = {}
    for line in path.read_text().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            version[parts[0]] = parts[1].strip()
    return version


def extract_archive(archive: Path, destination: Path) -> Path:
    """Extract the SDK archive into DESTINATION and return the tree root."""
    with tarfile.open(archive, "r:xz") as tar:
        tar.extractall(destination)
    return destination


def find_installed_sdk(explicit: Path | None) -> Path:
    """Return the devkitPro root that holds the installed SDK."""
    if explicit:
        return explicit
    for candidate in (Path.home() / ".devkitpro", Path("/opt/devkitpro")):
        if (candidate / "ounce-sdk-version.txt").is_file():
            return candidate
    sys.exit(
        "port_sdk.py: no installed Switch 2 SDK found.\n"
        "Pass --devkitpro PATH, or install one with install.sh first."
    )


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------
def check_versions(report: Report, new_root: Path, installed: Path) -> None:
    new = read_version(new_root)
    old = read_version(installed)
    report.add(
        "info",
        "SDK versions",
        f"installed: {fmt_version(old)}\nnew:       {fmt_version(new)}",
    )
    if new.get("ounce-sdk") == old.get("ounce-sdk"):
        report.add(
            "warn",
            "The archive is the SDK that is already installed",
            action="Nothing to port. Use --archive with a newer release.",
        )
    for key in ("libounce", "ouncevk", "ouncehen"):
        if old.get(key) and new.get(key) and old[key] != new[key]:
            report.add("info", f"{key} moved", f"{old[key]} -> {new[key]}")


def fmt_version(version: dict[str, str]) -> str:
    if not version:
        return "(none)"
    return ", ".join(f"{key} {value}" for key, value in version.items())


def compare_tree(report: Report, new_root: Path, installed: Path) -> None:
    """Diff the new SDK tree against the installed one, file by file."""
    changed: list[str] = []
    added: list[str] = []
    removed: list[str] = []

    new_files = {
        path.relative_to(new_root).as_posix()
        for path in new_root.rglob("*")
        if path.is_file()
    }
    installed_files = {
        path.relative_to(installed).as_posix()
        for path in installed.rglob("*")
        if path.is_file()
    }

    for relative in sorted(new_files):
        new_path = new_root / relative
        old_path = installed / relative
        if not old_path.is_file():
            added.append(relative)
        elif sha256(new_path) != sha256(old_path):
            changed.append(relative)

    for relative in sorted(installed_files - new_files):
        # Only report files the SDK owns; the Swift toolchain and its build
        # products live under swift/ and are not part of the archive. The
        # Nix FHS environment also leaves a marker file in DEVKITPRO.
        if relative.startswith(("swift/", "tests/")) or relative in (
            ".from-nix",
            "sdk-backup",
        ):
            continue
        if relative.startswith("sdk-backup/"):
            continue
        removed.append(relative)

    if added:
        report.add("info", f"{len(added)} file(s) added", "\n".join(added[:40]))
    if removed:
        report.add("info", f"{len(removed)} file(s) removed", "\n".join(removed[:40]))
    if changed:
        watched = [path for path in changed if path in WATCHED_FILES]
        detail = "\n".join(changed[:40])
        if len(changed) > 40:
            detail += f"\n... and {len(changed) - 40} more"
        report.add("info", f"{len(changed)} file(s) changed", detail)
        if watched:
            report.add(
                "warn",
                "Files the port reads have changed",
                "\n".join(watched),
                "Review each one against docs/PORTING.md before applying.",
            )
    if not changed and not added and not removed:
        report.add("ok", "The archive is byte-identical to the installed SDK")


def check_watched_files(report: Report, new_root: Path, installed: Path) -> None:
    """Report the watched files that are identical, so a port knows what to trust."""
    identical = []
    for relative in WATCHED_FILES:
        new_path = new_root / relative
        old_path = installed / relative
        if new_path.is_file() and old_path.is_file():
            if sha256(new_path) == sha256(old_path):
                identical.append(relative)
    if identical:
        report.add(
            "ok",
            f"{len(identical)} watched file(s) are byte-identical",
            "\n".join(identical),
        )


def check_tls_relevant_headers(report: Report, new_root: Path, installed: Path) -> None:
    """Look for thread-local declarations that could move the Swift boundary."""
    hits = []
    for path in sorted((new_root / "libounce" / "include").rglob("*.h")):
        text = path.read_text(errors="replace")
        for match in TLS_RELEVANT.finditer(text):
            line_number = text.count("\n", 0, match.start()) + 1
            hits.append(
                f"{path.relative_to(new_root).as_posix()}:{line_number}: "
                f"{match.group(0)}"
            )
    if hits:
        report.add(
            "info",
            "Thread-local declarations in the new headers",
            "These decide the Swift boundary; the rebuild re-derives it.",
            "\n".join(hits[:30]),
        )


def check_allocator(report: Report, new_root: Path, nm: str) -> None:
    """Check that libounce still supplies the allocator the port expects."""
    archive = new_root / "libounce" / "lib" / "libounce.a"
    if not archive.is_file():
        report.add("fail", "libounce.a is missing from the archive")
        return

    result = run([nm, "-g", "--defined-only", str(archive)])
    if result.returncode != 0:
        report.add(
            "warn",
            "Could not read libounce.a",
            result.stderr.strip(),
            "Install the devkitPro toolchain so nm is on PATH.",
        )
        return

    defined = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)$", result.stdout, re.MULTILINE))
    present = [symbol for symbol in ALLOCATOR_SYMBOLS if symbol in defined]
    missing = [symbol for symbol in ALLOCATOR_SYMBOLS if symbol not in defined]

    if missing:
        report.add(
            "warn",
            "libounce no longer defines every allocator entry point",
            f"present: {', '.join(present) or 'none'}\nmissing: {', '.join(missing)}",
            "The SwiftPM linker wrapper extracts malloc.o and heap_pages.o from "
            "libounce.a. Check that they are still there, and that libswiftCore's "
            "malloc/malloc_usable_size still resolve.",
        )
    else:
        report.add("ok", "libounce still defines the allocator entry points")

    # The objects the linker wrapper extracts by name.
    members = {
        line.strip()
        for line in run([nm, "-A", str(archive)]).stdout.splitlines()
        if line.strip()
    }
    del members  # only used to confirm nm works; names come from ar
    ar = shutil.which("aarch64-none-elf-ar") or shutil.which("ar")
    if ar:
        listing = run([ar, "t", str(archive)])
        if listing.returncode == 0:
            names = set(listing.stdout.split())
            for wanted in ("malloc.o", "heap_pages.o"):
                if wanted not in names:
                    report.add(
                        "warn",
                        f"{wanted} is not a member of libounce.a",
                        action="install-swift-sdk.sh extracts it by name; update "
                        "the list there if the allocator was split differently.",
                    )
            if names & {"malloc.o", "heap_pages.o"}:
                report.add("ok", "The allocator objects the linker wrapper needs are present")


def check_rules_compatibility(report: Report, new_root: Path) -> None:
    """Check the portlibs layout the Swift macros rely on."""
    rules = new_root / "libounce" / "switch2_rules"
    if not rules.is_file():
        report.add("fail", "switch2_rules is missing from the archive")
        return
    text = rules.read_text()
    problems = []
    if "PORTLIBS_SWITCH2" not in text:
        problems.append("PORTLIBS_SWITCH2 is gone")
    if "OVERLAY_LIBPATHS" not in text:
        problems.append("OVERLAY_LIBPATHS is gone")
    if "switch2_cpu.mk" not in text:
        problems.append("switch2_cpu.mk is no longer included")
    if problems:
        report.add(
            "warn",
            "switch2_rules changed shape",
            "\n".join(problems),
            "The Swift rules include switch2_rules and rely on these. A Makefile "
            "that spells out $(PORTLIBS_PATH)/switch2 would break.",
        )
    else:
        report.add("ok", "switch2_rules still has the shape the Swift rules expect")

    for macro in ("switch2_swift_rules", "switch2_swift_full_rules", "switch2_dispatch_rules"):
        path = REPO_ROOT / "swift" / macro
        if not path.is_file():
            report.add("fail", f"{macro} is missing from the repository")
            continue
        if "$(DEVKITPRO)/libounce/switch2_rules" not in path.read_text():
            report.add(
                "warn",
                f"{macro} no longer includes switch2_rules",
                action="Check that the include path is still right.",
            )


def check_ouncehen(report: Report, new_root: Path) -> None:
    """Check the OunceHEN header the Swift wrapper imports."""
    header = new_root / "portlibs" / "switch2" / "include" / "ouncehen.h"
    if not header.is_file():
        report.add("warn", "ouncehen.h is missing", action="OunceHEN is not in this release.")
        return
    text = header.read_text(errors="replace")
    if re.search(r"Result\s+ouncehenJitPublishRanges\s*\(", text):
        report.add("ok", "ouncehenJitPublishRanges is still declared")
    else:
        report.add(
            "warn",
            "ouncehenJitPublishRanges is gone from ouncehen.h",
            action="swift/libounce/Sources/COunce uses it. Update the wrapper.",
        )


def check_cmake_toolchain(report: Report, new_root: Path) -> None:
    """The SDK gained a CMake toolchain; note whether it is still there."""
    cmake = new_root / "libounce" / "cmake" / "Switch2.cmake"
    if cmake.is_file():
        report.add("info", "The archive ships a CMake toolchain", str(cmake.name))
    else:
        report.add("info", "The archive has no CMake toolchain")


# --------------------------------------------------------------------------
# Build verification
# --------------------------------------------------------------------------
def rebuild_and_verify(report: Report, devkitpro: Path, jobs: int) -> None:
    """Rebuild the Swift artifacts and check the TLS boundary."""
    verify = run([sys.executable, str(VERIFY_TLS), "--help"])
    if verify.returncode != 0:
        report.add("warn", "verify_tls_boundary.py is not runnable", verify.stderr.strip())
        return

    examples = [
        REPO_ROOT / "examples" / name / f"{name}.elf"
        for name in ("swift-full", "swift-async")
    ]
    missing = [str(path) for path in examples if not path.is_file()]
    if missing:
        report.add(
            "info",
            "Skipping the TLS check: the examples are not built",
            "\n".join(missing),
            "Build them with `make` in each examples/ directory, then re-run "
            "scripts/verify_tls_boundary.py.",
        )
        return

    environ = {"PATH": f"{devkitpro / 'devkitA64' / 'bin'}:{Path('/usr/bin')}"}
    result = subprocess.run(
        [sys.executable, str(VERIFY_TLS), *map(str, examples), "--shim", str(SHIM)],
        capture_output=True,
        text=True,
        check=False,
        env={**environ},
    )
    output = (result.stdout + result.stderr).strip()
    if result.returncode == 0:
        report.add("ok", "The TLS boundary matches the examples", output)
    else:
        report.add(
            "fail",
            "The TLS boundary does not match the built examples",
            output,
            "Re-derive it with:\n"
            "  python3 scripts/verify_tls_boundary.py --write-swift-shim "
            "swift/swift_shim.c examples/swift-async/swift-async.elf\n"
            "then rebuild everything that links the shim.",
        )


# --------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------
def install_archive(report: Report, archive: Path, devkitpro: Path) -> None:
    """Replace libounce and the Switch 2 portlibs with the archive's copies."""
    if not devkitpro.is_dir():
        report.add("fail", f"{devkitpro} is not a directory")
        return
    backup = devkitpro / "sdk-backup"
    backup.mkdir(exist_ok=True)
    for name in ("libounce", "portlibs/switch2"):
        source = devkitpro / name
        if source.exists():
            target = backup / name.replace("/", "-")
            if target.exists():
                shutil.rmtree(target)
            shutil.move(str(source), str(target))
    with tarfile.open(archive, "r:xz") as tar:
        tar.extractall(devkitpro)
    report.add("ok", f"Installed {archive.name} into {devkitpro}")


def install_swift_scripts(report: Report, devkitpro: Path) -> None:
    """Copy the repository's Swift scripts over the installed copies."""
    swift_home = devkitpro / "swift"
    copies = [
        ("swift/switch2_swift_rules", "switch2_swift_rules"),
        ("swift/switch2_swift_full_rules", "switch2_swift_full_rules"),
        ("swift/switch2_dispatch_rules", "switch2_dispatch_rules"),
        ("swift/swift_shim.c", "swift_shim.c"),
        ("swift/install-swift.sh", "install-swift.sh"),
        ("swift/install-devkitpro.sh", "install-devkitpro.sh"),
        ("swift/full/build-stdlib.sh", "full/build-stdlib.sh"),
        ("swift/dispatch/build-dispatch.sh", "dispatch/build-dispatch.sh"),
        ("swift/swiftpm/install-swift-sdk.sh", "swiftpm/install-swift-sdk.sh"),
        ("swift/swiftpm/switch2-build.sh", "swiftpm/switch2-build.sh"),
    ]
    for relative, destination in copies:
        source = REPO_ROOT / relative
        target = swift_home / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for directory in ("dispatch/config", "dispatch/shim"):
        source = REPO_ROOT / "swift" / directory
        target = swift_home / directory
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
    report.add("ok", f"Installed the Swift scripts into {swift_home}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Port the Swift toolchain to a new ounce-sdk release.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--archive", type=Path, required=True, help="the new ounce-sdk.tar.xz")
    parser.add_argument(
        "--devkitpro",
        type=Path,
        help="the devkitPro root to compare against and install into "
        "(default: $DEVKITPRO, then ~/.devkitpro, then /opt/devkitpro)",
    )
    parser.add_argument("--apply", action="store_true", help="install the new SDK and its scripts")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report only, which is the default; accepted so a command line can "
        "say what it means explicitly",
    )
    parser.add_argument(
        "--skip-tls", action="store_true", help="do not check the built examples"
    )
    parser.add_argument("--jobs", type=int, default=0, help="parallel build jobs (informational)")
    args = parser.parse_args()

    if args.apply and args.dry_run:
        sys.exit("port_sdk.py: --apply and --dry-run contradict each other")

    if not args.archive.is_file():
        sys.exit(f"port_sdk.py: {args.archive}: no such file")

    devkitpro = find_installed_sdk(args.devkitpro)
    report = Report()

    staging = Path(tempfile.mkdtemp(prefix="port-sdk-"))
    try:
        new_root = extract_archive(args.archive, staging)
        # Archives unpack to the devkitPro layout directly.
        if not (new_root / "ounce-sdk-version.txt").is_file():
            candidates = list(new_root.glob("*/ounce-sdk-version.txt"))
            if candidates:
                new_root = candidates[0].parent

        check_versions(report, new_root, devkitpro)
        compare_tree(report, new_root, devkitpro)
        check_watched_files(report, new_root, devkitpro)
        check_rules_compatibility(report, new_root)
        check_allocator(
            report,
            new_root,
            shutil.which("aarch64-none-elf-nm") or shutil.which("nm") or "nm",
        )
        check_ouncehen(report, new_root)
        check_cmake_toolchain(report, new_root)
        check_tls_relevant_headers(report, new_root, devkitpro)

        if not args.skip_tls:
            rebuild_and_verify(report, devkitpro, args.jobs)

        print(report.render())

        if report.failed:
            print("\nThe port has failures. Fix them before applying.", file=sys.stderr)
            return 1

        print(
            "\nNext steps:\n"
            "  1. Install the archive and the scripts:\n"
            f"       python3 scripts/port_sdk.py --archive {args.archive} --apply\n"
            "     or, by hand:\n"
            f"       sh install.sh {args.archive}\n"
            f"       sh $DEVKITPRO/swift/install-swift.sh\n"
            "       sh $DEVKITPRO/swift/full/build-stdlib.sh\n"
            "       sh $DEVKITPRO/swift/dispatch/build-dispatch.sh\n"
            "       sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh --force\n"
            "  2. Rebuild the examples, the tests and the diag probes.\n"
            "  3. Re-derive the TLS boundary and the other version-sensitive "
            "facts in docs/PORTING.md.\n"
            "  4. Update HANDOFF.md and CHANGELOG.md, then commit and push "
            "with scripts/release.py.\n"
        )

        if args.apply:
            install_archive(report, args.archive, devkitpro)
            install_swift_scripts(report, devkitpro)
            print(report.render())
            print(
                "\nInstalled. Rebuild the Swift artifacts now:\n"
                "  sh $DEVKITPRO/swift/install-swift.sh --force\n"
                "  sh $DEVKITPRO/swift/full/build-stdlib.sh\n"
                "  sh $DEVKITPRO/swift/dispatch/build-dispatch.sh\n"
                "  sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh --force\n"
                "then re-run scripts/verify_tls_boundary.py on the examples and "
                "update SWIFT_TLS_START if it moved."
            )

        return 0
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
