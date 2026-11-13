# Changelog

The SDK version each release was built and verified against is in
`SDK_VERSION`. The console SDK ships separately; see `docs/PORTING.md` for what
has to be re-derived when it moves.

## 20261113 — first release in this repository

Ported to `ounce-sdk 20261113` (libounce `db3f88a3`, OunceVK `791c34e`,
OunceHEN `9451c44`), up from `20261112c`. The Swift half is split out of the
console SDK repository into this one.

### Fixed: thread-locals went through `tpidr_el0`

The installed `libswift_Concurrency.a` was a stale build that predated
`-mtp=tpidrro_el0` in `cc_flags`: `Actor.o` had 18 accesses through
`tpidr_el0` and `TaskLocal.o` had 10. On the console `tpidr_el0` is the
kernel's thread control block, so every one of those read memory that was not
the program's. It built, linked and booted, and would have failed the first
time the concurrency runtime touched its own thread-locals.

Rebuilt the C++ libraries; every one of the eight archives now has 0
`tpidr_el0`, with 28 `tpidrro_el0` accesses between them, and every example,
the test suite and the SwiftPM package links the same way.

The rule is now enforced instead of documented, because a library built
without the flag is indistinguishable from a correct one until it runs:

- `scripts/verify_tls_boundary.py --archive` fails on any archive member that
  uses `tpidr_el0`, naming the object, and every linked binary is checked too.
- `build-stdlib.sh` refuses to install a library that fails the check.
- `port_sdk.py` runs the archive check as part of every port.

### Fixed for the new console SDK

- **`SWIFT_TLS_START` moved from `0x410` to `0x430`.** libounce began linking
  mimalloc, whose four thread-locals come first in link order and pushed every
  libnx variable up by `0x20`. `__nx_dev_path_buf` now ends at `0x429`, so the
  old value would have cleared the last 25 bytes of it and broken `fsdev` in a
  constructor before `main`. The value is now derived from a linked program by
  `scripts/verify_tls_boundary.py` rather than by hand.
- **SwiftPM packages failed to link with `multiple definition of '_malloc_r'`.**
  SwiftPM puts `-lc` on its own command line, ahead of anything the linker
  wrapper adds, so newlib's `malloc` won and its `mallocr.o` then collided with
  libounce's `malloc.o`. The wrapper now passes libounce's `malloc.o` and
  `heap_pages.o` first, as plain objects. Only SwiftPM was affected; the
  Makefile path reaches `-lnx` before libc.
- **`build-dispatch.sh` compiled C with whatever `$CXX` named.** The FHS
  environment sets `CXX` to a clang++ for the standard library build, and a C++
  driver rejects `-std=gnu11`. The script now prefers the toolchain's own clang
  and only accepts `$CXX` after asking it to compile a `.c` file.

### Added

- `scripts/port_sdk.py` compares a new console SDK release against the
  installed one, checks the facts the port depends on, and installs it.
- `scripts/verify_tls_boundary.py` re-derives `SWIFT_TLS_START` from a linked
  ELF and can update `swift_shim.c`.
- `scripts/release.py` commits and pushes a port to a private repository with
  the GitHub CLI.
- `docs/PORTING.md` records what moves between releases and why, so the checks
  in the scripts have a reason attached to them.
- `install.sh`, so the Swift half installs on its own, on top of a console SDK
  installed separately.

### Verified

- All four examples build: embedded Swift, full standard library, concurrency
  and libdispatch.
- The test suite builds; `tests/diag/` probes all build.
- The `Ounce` SwiftPM package builds, links and packages into an NRO.
- `SWIFT_TLS_START` is `0x430` for every program shape, checked by
  `scripts/verify_tls_boundary.py`.
- Runtime behaviour on hardware was not re-tested for this release; the
  previous release passed all 156 checks.
