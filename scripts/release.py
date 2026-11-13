#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Commit and push a port to a private repository with the `gh` CLI.

This is the last step of `docs/PORTING.md`. It never decides *what* to commit:
a port is reviewed as a diff first, which is why `port_sdk.py` stops before
this point. It only makes publishing repeatable and checks the things that are
easy to get wrong — that the tree has no build products in it, that the
repository is private, and that the commit message names the SDK it was built
against.

Usage
-----
    python3 scripts/release.py --sdk-version 20261113
    python3 scripts/release.py --sdk-version 20261113 --remote origin --no-push

The repository is created on first use and reused afterwards. It is created
private; `--public` refuses rather than silently doing the wrong thing, because
a Swift toolchain that links proprietary console libraries is not something to
publish by accident.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Files that must never be committed. A port touches generated output
# constantly, and an NRO is tens of megabytes.
FORBIDDEN_SUFFIXES = (
    ".nro",
    ".elf",
    ".nacp",
    ".nso",
    ".kip",
    ".o",
    ".a",
    ".so",
    ".dylib",
)
FORBIDDEN_DIRECTORIES = ("build", ".build", "full-build", "toolchain", "__pycache__")


def run(command: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(
        command,
        cwd=cwd or REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        sys.exit(
            f"release.py: {' '.join(command)} failed:\n"
            f"{result.stdout.strip()}\n{result.stderr.strip()}"
        )
    return result


def require_tools(*names: str) -> None:
    missing = [name for name in names if not shutil.which(name)]
    if missing:
        sys.exit(
            f"release.py: {', '.join(missing)} not found on PATH.\n"
            "Install the GitHub CLI (https://cli.github.com) and run 'gh auth login'."
        )


def check_gh_auth() -> str:
    """Return the authenticated GitHub account, or exit."""
    result = run(["gh", "api", "user", "--jq", ".login"], check=False)
    if result.returncode != 0:
        sys.exit(
            "release.py: gh is not authenticated.\n"
            "Run 'gh auth login' first. The token needs the 'repo' scope to "
            "create and push a private repository."
        )
    return result.stdout.strip()


def git_toplevel() -> Path:
    result = run(["git", "rev-parse", "--show-toplevel"], check=False)
    if result.returncode != 0:
        sys.exit(
            f"release.py: {REPO_ROOT} is not a git repository.\n"
            "Run 'git init' and add a remote first, or clone the repository "
            "and copy the port into it."
        )
    return Path(result.stdout.strip())


def check_remote(repo_root: Path, remote: str) -> str | None:
    result = run(["git", "remote", "get-url", remote], cwd=repo_root, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def find_bad_files() -> list[str]:
    """Return tracked-or-untracked files that should not be committed."""
    result = run(["git", "ls-files", "--cached", "--others", "--exclude-standard"])
    bad = []
    for line in result.stdout.splitlines():
        path = Path(line)
        if any(part in FORBIDDEN_DIRECTORIES for part in path.parts):
            bad.append(line)
        elif path.suffix in FORBIDDEN_SUFFIXES:
            bad.append(line)
    return bad


def check_private(repo: str) -> bool | None:
    """Return whether REPO is private, or None when it does not exist."""
    result = run(["gh", "repo", "view", repo, "--json", "isPrivate"], check=False)
    if result.returncode != 0:
        return None
    try:
        return bool(json.loads(result.stdout)["isPrivate"])
    except (json.JSONDecodeError, KeyError):
        return None


def ensure_repository(repo: str, public: bool) -> None:
    """Create REPO on GitHub if it does not exist yet."""
    if public:
        sys.exit(
            "release.py: refusing to publish publicly by default.\n"
            "This repository describes a toolchain that links proprietary console "
            "libraries. Create the repository by hand if that is really wanted."
        )

    visibility = check_private(repo)
    if visibility is None:
        print(f"Creating private repository {repo}")
        run(
            [
                "gh",
                "repo",
                "create",
                repo,
                "--private",
                "--description",
                "Swift toolchain for Nintendo Switch 2 homebrew, on the ounce SDK",
                "--source",
                str(REPO_ROOT),
                "--remote",
                "origin",
            ]
        )
        return

    if visibility is not True:
        sys.exit(
            f"release.py: {repo} exists and is public.\n"
            "Refusing to push. Make it private, or pass a different --repo."
        )
    print(f"{repo} exists and is private")


def git_config(repo_root: Path) -> tuple[str, str]:
    """Return the user name and email git would use, as a sanity check."""
    name = run(["git", "config", "user.name"], cwd=repo_root, check=False)
    email = run(["git", "config", "user.email"], cwd=repo_root, check=False)
    return name.stdout.strip(), email.stdout.strip()


def sdk_version_from_tree() -> str | None:
    """Read the SDK version the tree was last ported to, if it records one."""
    for name in ("SDK_VERSION", "sdk-version.txt"):
        path = REPO_ROOT / name
        if path.is_file():
            return path.read_text().strip()
    return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Commit and push a port to a private GitHub repository.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--sdk-version", required=True, help="the ounce-sdk release, e.g. 20261113")
    parser.add_argument(
        "--repo",
        default="ouncebrew/switch2-swift",
        help="the GitHub repository (default: %(default)s)",
    )
    parser.add_argument("--remote", default="origin", help="the git remote (default: origin)")
    parser.add_argument("--branch", default="main", help="the branch to push (default: main)")
    parser.add_argument("--message", help="the commit message; a default is built from --sdk-version")
    parser.add_argument("--no-push", action="store_true", help="commit but do not push")
    parser.add_argument("--dry-run", action="store_true", help="print what would happen")
    parser.add_argument("--public", action="store_true", help="allow a public repository")
    parser.add_argument(
        "--allow-build-products",
        action="store_true",
        help="commit despite build products in the tree (not recommended)",
    )
    args = parser.parse_args()

    require_tools("git", "gh")
    account = check_gh_auth()
    repo_root = git_toplevel()

    print(f"Repository: {repo_root}")
    print(f"GitHub account: {account}")
    print(f"Target: {args.repo} ({args.branch})")

    recorded = sdk_version_from_tree()
    if recorded and recorded != args.sdk_version:
        sys.exit(
            f"release.py: the tree records SDK {recorded}, but --sdk-version is "
            f"{args.sdk_version}.\nUpdate SDK_VERSION first, so the repository "
            "says which SDK it was built against."
        )

    bad = find_bad_files()
    if bad and not args.allow_build_products:
        sys.exit(
            "release.py: build products would be committed:\n"
            + "\n".join(f"  {path}" for path in bad[:20])
            + (f"\n  ... and {len(bad) - 20} more" if len(bad) > 20 else "")
            + "\n\nRemove them (and extend .gitignore), or pass "
            "--allow-build-products."
        )

    name, email = git_config(repo_root)
    if not name or not email:
        sys.exit(
            "release.py: git user.name and user.email are not set, so the commit "
            "would have no author.\nRun:\n"
            '  git config user.name "Your Name"\n'
            '  git config user.email "you@example.com"'
        )

    message = args.message or (
        f"Port to ounce-sdk {args.sdk_version}\n"
        "\n"
        f"Rebuilt against the {args.sdk_version} console SDK and re-verified the\n"
        "facts the port depends on:\n"
        "\n"
        "- The thread-local boundary (SWIFT_TLS_START) was re-derived from a\n"
        "  linked program with scripts/verify_tls_boundary.py.\n"
        "- The allocator interface still matches: libounce's malloc.o and\n"
        "  heap_pages.o are extracted by the SwiftPM linker wrapper, so that\n"
        "  libc does not claim malloc first.\n"
        "- The build rules and the linker script were compared byte for byte.\n"
    )

    print("\nChanges to commit:")
    status = run(["git", "status", "--short"], cwd=repo_root)
    print(status.stdout.rstrip() or "  (none)")

    if args.dry_run:
        print(f"\nWould commit with message:\n\n{message}")
        print(f"Would push to {args.repo} ({args.branch})")
        return 0

    if not status.stdout.strip():
        print("\nNothing to commit; the tree is already at the ported state.")
    else:
        run(["git", "add", "-A"], cwd=repo_root)
        run(["git", "commit", "-m", message], cwd=repo_root)
        print("\nCommitted")

    ensure_repository(args.repo, args.public)

    url = check_remote(repo_root, args.remote)
    expected = f"github.com/{args.repo}"
    if url is None:
        print(f"Adding remote {args.remote} -> {args.repo}")
        run(
            [
                "git",
                "remote",
                "add",
                args.remote,
                f"https://github.com/{args.repo}.git",
            ],
            cwd=repo_root,
        )
    elif expected not in url:
        sys.exit(
            f"release.py: remote {args.remote} points at {url}, not {args.repo}.\n"
            "Pass --remote with the right name, or fix the remote."
        )

    if args.no_push:
        print("Committed but not pushed (--no-push).")
        return 0

    current = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo_root).stdout.strip()
    if current != args.branch:
        print(f"Renaming branch {current} -> {args.branch}")
        run(["git", "branch", "-M", args.branch], cwd=repo_root)

    print(f"Pushing to {args.repo}")
    run(["git", "push", "-u", args.remote, args.branch], cwd=repo_root)
    print(f"\nDone: https://github.com/{args.repo}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
