# Using the Switch 2 Swift toolchain

This is a handoff note for whoever picks this up next. It says what works, how
to set it up, and where the sharp edges are.

This repository is the Swift half of the Switch 2 SDK. The console SDK
(libounce, OunceVK, OunceHEN) ships separately, as does the NixOS environment.
Install that first; `install.sh` here checks for it.

| Piece | Where | State |
|---|---|---|
| Swift, embedded mode | `swift/switch2_swift_rules` | works |
| Swift, full standard library | `swift/switch2_swift_full_rules` | works |
| Swift concurrency | part of the full library | works, single-threaded |
| libdispatch | `swift/switch2_dispatch_rules` | works |
| SwiftPM | `swift/swiftpm/` | works, release mode only |
| FoundationEssentials | `swift/foundation/` | works, no ICU or networking |
| `Ounce` wrapper | `swift/libounce/` | works |
| Porting tools | `scripts/` | works |

Not ported: `FoundationInternationalization` (ICU), `FoundationNetworking`,
`FoundationXML`, backtracing, dispatch sources that watch file descriptors,
dispatch I/O.

## Setup

Both prebuilt toolchains expect a conventional Linux layout, so on NixOS they
run inside the console SDK's FHS environment:

```sh
nix develop          # or: nix-shell
```

(run in the console SDK repository, which has the `flake.nix`)

That shell fetches devkitPro's toolchain and puts it in `$DEVKITPRO`, which
defaults to `$HOME/.devkitpro`. `nix develop --command` and `nix-shell --run`
do not work, because the dev shell replaces itself with the FHS shell. Use
`nix run .# -- -c '...'`.

Then, once, from this repository:

```sh
sh install.sh
sh $DEVKITPRO/swift/install-swift.sh
sh $DEVKITPRO/swift/full/build-stdlib.sh
sh $DEVKITPRO/swift/foundation/fetch-foundation.sh
sh $DEVKITPRO/swift/foundation/build-foundation.sh
sh $DEVKITPRO/swift/dispatch/build-dispatch.sh
sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh
```

The second line is a 784 MB download from swift.org. On any other Linux,
install devkitPro pacman first and skip the FHS environment; the rest is the
same.

## Building

### Makefile

Change the include line and add the libraries:

```make
include $(DEVKITPRO)/swift/switch2_swift_full_rules   # or switch2_swift_rules
LIBS := -lnx $(SWIFT_FULL_LIBS)
```

For FoundationEssentials, link its library too; the full rules add the shim
module maps once `build-foundation.sh` has installed them:

```make
LIBS := -lnx $(SWIFT_FOUNDATION_LIBS) $(SWIFT_FULL_LIBS)
```

For libdispatch:

```make
include $(DEVKITPRO)/swift/switch2_dispatch_rules
CFLAGS += $(DISPATCH_CFLAGS)
LIBS := -lnx $(DISPATCH_LIBS)
```

`examples/` has one program for each: `swift-hello`, `swift-full`,
`swift-async`, `dispatch-hello`, `foundation-hello`, plus the two C ones.

### FoundationEssentials

`swift/foundation/` builds FoundationEssentials from upstream
swift-foundation, with the same rule as the standard library: the checkout is
unmodified and `build-foundation.sh` patches it at build time behind
`__SWITCH__`. The build installs the archive, the Swift modules and two C shim
module maps; `switch2_swift_full_rules` adds them when present, and
`install-swift-sdk.sh` puts them in the SwiftPM toolset.

The limits are deliberate:

- No `FoundationInternationalization` (ICU), `FoundationNetworking` or
  `FoundationXML`. Import `FoundationEssentials`, not `Foundation`.
- No `_StringProcessing`: regex options compile but fall back to literal
  matching.
- Time zone data is read from `sdmc:/switch/zoneinfo`.
- xattrs and `chown` return `ENOTSUP`; there are no user or group accounts.
- `ProcessInfo.arguments` is empty.

The example `examples/foundation-hello` builds and links; it has not been run
on hardware.

### SwiftPM

```sh
sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh
sh $DEVKITPRO/swift/swiftpm/switch2-build.sh -c release
```

Both scripts take `--devkitpro PATH` to select the Switch 2 SDK root, which is
the devkitPro directory. The order is `--devkitpro`, then `$DEVKITPRO`, then
`/opt/devkitpro`; `switch2-build.sh` also falls back to its own location,
because it lives in `<root>/swift/swiftpm`, so an installed copy needs no
variable set. The resolved absolute path is baked into the generated bundle and
into the linker wrapper, so the SDK keeps working after the variable is gone.

`install-swift-sdk.sh` installs what is missing instead of reporting it: the
devkitPro Switch toolchain through `install-devkitpro.sh`, and the Swift
toolchain through `install-swift.sh`. `--no-deps` turns that off. libounce and
the standard library are still reported, because the first comes from the SDK
archive that only `install.sh` has and the second is a long build.

Release mode only: debug links `SwiftOnoneSupport`, which is not built. The
entry point is top-level code, not `@_cdecl("main")`, because SwiftPM generates
`main` for an executable target.

### The Ounce library

`swift/libounce` is a SwiftPM package that wraps libounce and OunceHEN. It
installs to `$DEVKITPRO/swift/libounce` and is used as a path dependency.

It has two targets, and the split is forced by the C API rather than chosen:

- **`COunce`** is the C surface. It includes `<switch.h>` and `<ouncehen.h>` and
  re-exports, as real functions, every accessor the wrapper needs that libnx
  marks `NX_INLINE` or `NX_CONSTEXPR`. Those are `static inline` in C, and
  Swift's Clang importer cannot call them — `padGetButtons`, `padIsConnected`,
  `padGetIsConnected`, `henGetStatus` and the rest are all in that category.
  Everything that is a real symbol (`consoleInit`, `padUpdate`,
  `fsdevMountSdmc`, `appletMainLoop`, `hosversionIsOunceHEN`, `jitCreate`) is
  used directly from the headers.
- **`Ounce`** is the Swift API: `Console`, `Applet`, `Pad` with a `Button`
  `OptionSet`, `FileSystem`, `HosVersion`, `Hen`, and `ResultCode`/`OunceError`
  so the throwing APIs carry libnx's result code.

Two things had to change in the SDK for it to build:

- **The toolset now puts `$DEVKITPRO/portlibs/switch2/include` on the search
  path**, for both the Swift and C compilers, and
  `$DEVKITPRO/portlibs/switch2/lib` on the linker's. `ouncehen.h` lives in the
  Switch 2 portlibs, not in libounce, so without this `#include <ouncehen.h>`
  fails. A bundle installed before this change has to be rebuilt with
  `--force`.
- **The linker wrapper links `-louncehen` when the archive exists.** It is not
  in every SDK release, and an archive member is only pulled when something
  references it, so adding it conditionally costs nothing.

`ResultCode` formats its own hex because `String(format:)` is Foundation, which
this port does not have. `Hen` is a class rather than a struct so that `deinit`
can close the session; a struct would need `mutating` accessors for the
`&service` the C calls take.

## Portability across SDK versions

The port depends on the console SDK in a few places. These are the ones that
matter when libnx or libounce is updated.

### Verified against

Three SDK releases have been built against. The first two are from the older
console SDK layout; the third is the current one:

| | `ounce-sdk` | libounce | OunceVK | OunceHEN | `SWIFT_TLS_START` |
|---|---|---|---|---|---|
| oldest | 20261109 | `e9d87b77` | `fd483fb` | `3094c24` | 0x410 |
| older | 20261110 | `4c5f5932` | `eb14d9b` | `015032b` | 0x410 |
| current | 20261113 | `db3f88a3` | `791c34e` | `9451c44` | **0x430** |

For 20261113, all four Swift examples, the test suite and all twelve
`tests/diag/` probes build, and the SwiftPM bundle installs, links and packages
an NRO. What changed from 20261110, and what did not:

- **The TLS layout moved by `0x20`.** libounce began linking mimalloc, whose
  four thread-locals (`__mi_thread_locals`, `__mi_theap_cached`,
  `__mi_theap_default`, `__mi_slot_fast`) come first in link order. They take
  0x00–0x1F, so `fsdev_last_result` is now at 0x20, `g_fsPriority` at 0x24,
  `__nx_dev_path_buf` at 0x28 and it ends at 0x429. The Swift entries start at
  **0x430**; `ActiveTask::Value` 0x430, `ExecutorTrackingInfo::
  ActiveInfoInThread` 0x438, `FallbackTaskLocalStorage::Value` 0x440,
  `SwiftTLSContext::TLSContext` 0x448, then `__dispatch_tsd` at 0x458.
  `SWIFT_TLS_START` therefore had to move from 0x410 to **0x430**; the old
  value clears the last 25 bytes of `__nx_dev_path_buf` and breaks `fsdev` in a
  constructor before `main`.
- **`switch/arm/counter.h`, `switch/arm/tls.h`, `switch.specs`, `switch.ld`,
  `switch2_rules`, `switch_rules` and `switch2_cpu.mk` are byte-identical.**
  The clock, the TLS register accessor, the linker script and the build rules
  are not a moving target between these two releases.
- **No header under `libounce/include` changed at all.** The only header that
  changed is `portlibs/switch2/include/ouncehen.h`, which gained an
  `extern "C"` guard around `ouncehenJitPublishRanges` — a fix, not a break.
- **The allocator became reachable through newlib's own symbols.** libounce's
  `malloc.o` defines `_malloc_r`, `_free_r` and the rest as strong symbols; it
  did that in 20261110 too, but 20261113 is the first release where a SwiftPM
  package pulled both libounce's and newlib's copy in and failed with
  `multiple definition of '_malloc_r'`. See the SwiftPM entry below.
- **The archive gained a CMake toolchain** (`libounce/cmake/Switch2.cmake`,
  `portlibs/switch2/bin/aarch64-none-elf-cmake`) and `dkp-toolchain-vars` is
  now required by `switch2vars.sh`. Neither affects the Swift path, but the
  console SDK's installer now checks for it.

The older row is kept because a port that moves two releases at once is easier
to reason about when the intermediate facts are written down.

### What is version-sensitive

- **`SWIFT_TLS_START` in `swift/swift_shim.c` is the one hard number.** It is
  the size of everything before the Swift entries in the thread-local block,
  and the constructor clears everything after it, because the loader does not
  zero the block and the Swift libraries' thread_locals land in the garbage. It
  cannot be *read* out of a file: the boundary is an SDK internal, and the
  block size alone does not reveal it, because the region after the boundary
  differs depending on whether the program links the concurrency runtime and
  libdispatch. It can be *measured* from a linked program, which is what
  `scripts/verify_tls_boundary.py` does. It is a named, overridable constant
  rather than a literal, so a libnx that adds a thread_local can be
  accommodated without editing the file:

  ```sh
  -DSWIFT_TLS_START=0x440
  ```

  The current layout, from `nm` on a linked program, is mimalloc's four
  entries at 0x00, libnx's `fsdev_last_result` at 0x20, `g_fsPriority` at
  0x24, `__nx_dev_path_buf` at 0x28 (1025 bytes, ending at 0x429), then the
  Swift entries from 0x430 to 0x457, then libdispatch's `__dispatch_tsd` at
  0x458. If a new libounce grows its part, the Swift entries move and this
  number has to move with them.

  **Derive it, do not guess it.** `scripts/verify_tls_boundary.py` reads a
  linked program, sorts its thread-locals, and reports where the Swift ones
  begin:

  ```sh
  python3 scripts/verify_tls_boundary.py --shim swift/swift_shim.c \
      examples/swift-async/swift-async.elf
  ```

  It fails rather than guesses when the SDK has interleaved its variables with
  Swift's, which is the case where no single offset can work. The previous
  entry here suggested `-DSWIFT_TLS_START=0x420` as an example override; that
  value is a leftover from an intermediate release and is wrong for both of the
  releases that shipped.

  Two approaches that look better and are not: anchoring on the end of the
  block breaks embedded-Swift programs, which have no Swift TLS at all, and
  anchoring on `__dispatch_tsd` needs a weak reference, which makes the
  compiler use initial-exec TLS and therefore `tpidr_el0` instead of the
  `tpidrro_el0` that everything else here uses.

- **`armGetSystemTickFreq()` and `armGetSystemTick()`** from
  `<switch/arm/counter.h>` are the only clock. `clock_gettime` ignores the
  clock id and reads the tick, so every clock in the program agrees. Both
  callers guard against a zero frequency.

- **`malloc_usable_size`** backs `HAS_MALLOC_SIZE`, which `build-stdlib.sh`
  patches into `LibcShims.h` behind `__SWITCH__`. newlib provides it; if a
  future newlib drops it, `ManagedBuffer.capacity` goes negative again and
  `AsyncStream` dies on `assert(count < capacity)`.

- **`switch.specs` and `default_icon.jpg`** are looked up under
  `$DEVKITPRO/libounce` and `$DEVKITPRO/libnx`. The icon is optional now, so a
  devkitPro without libnx's copy does not stop a SwiftPM build.

- **`$DEVKITPRO/ounce-sdk-version.txt`** records the SDK version, the libounce
  commit and the OunceVK and OunceHEN commits. Nothing reads it yet; it is the
  first thing to check when a build that used to work stops working.

## Sharp edges

These cost time to find. They are all handled by the scripts, but they matter
if you change anything.

- **The target triple is `aarch64-none-none-elf`, not `aarch64-none-elf`.**
  The embedded standard library only ships for the former. devkitA64 uses the
  latter. The objects are the same.
- **`_GNU_SOURCE` must not be defined when `-fblocks` is used.** It makes
  newlib declare `encrypt(char *__block, ...)`, and `__block` is a keyword
  under `-fblocks`. libdispatch needs blocks, so the macro has to go.
- **devkitA64's gcc has no blocks support.** Compile C with the Swift
  toolchain's clang, link with gcc so `switch.specs` and `libsysbase` apply.
- **`libnx.a` in libounce is a 15-byte linker script**, `INPUT(-lounce)`. Do
  not run `nm` on it and conclude a symbol is missing; check `libounce.a`.
- **`libsysbase.a` implements pthreads and POSIX semaphores** on top of the
  `__syscall_*` hooks that libounce provides. Checking `libc.a` alone gives the
  wrong answer. `__syscall_thread_detach` is the one hook libounce does not
  provide, so `pthread_detach` links to NULL and jumps to address 0.
- **The EL0 fault handler is `__libnx_exception_handler`, and it runs on a 1 KiB
  stack.** libnx defines `__nx_exception_stack` weak at `0x400`, and the entry
  code sets `sp` to its top before calling the handler. `tests/common/fault.c`
  overrides it with 16 KiB, which is why a fault inside a deep call chain still
  reports. Anything you put in that handler must also avoid `malloc`, `printf`
  and `fopen`: the fault may have happened inside the allocator or stdio.
- **A Swift trap never reaches that handler.** `fatalError`, a failed
  `precondition` and an out-of-bounds `Array` access compile to `brk`, and the
  kernel terminates the process on a breakpoint without forwarding it to the EL0
  vector — libnx's `ThreadExceptionDesc_Other` is documented as "EC <= 0x34 and
  not a breakpoint". The only hook is the four reporting functions in
  `libswiftStdlibStubs.a`'s `Assert.o`. Override all four or none: they share one
  object, so overriding one leaves the rest undefined, pulls `Assert.o` in and
  fails the link with a duplicate definition.
- **libdispatch: groups and timers.** All thirteen pass now. Eleven passed
  before the fixes below: `sync`, `async`, `serial-order`, `concurrent`,
  `semaphore`, `apply`, `barrier`, `once`, `specific`, `label`, and
  `group-enter-leave` on a good run. `dispatch/group` was seen with 5 of 8
  blocks run and with 0 of 8,
  and `dispatch/after` never fired at all. Three separate causes, all found by
  reading libdispatch's source rather than by guessing:

  1. **`timerfd_create` returned `ENOSYS`.** `_dispatch_timeout_program` does
     `fd = timerfd_create(...); if (!dispatch_assume(fd >= 0)) return;`, so the
     timer was never armed and `dispatch/after` could not fire. `timerfd_*` is
     now implemented in `epoll_shim.c` as an absolute deadline, next to the
     epoll set that waits on it.
  2. **`epoll_wait` only waited on `slot->fds[0]`.** The set holds two kinds of
     descriptor: the manager eventfd, registered first in `_dispatch_epoll_init`,
     and one timerfd per clock, registered later by `_dispatch_timeout_program`.
     Waiting on the first alone loses every timer wakeup, and the old code also
     returned `events[0].data` for whichever descriptor fired. `epoll_wait` now
     scans every registered handle and sleeps on the set's own semaphore until a
     write arrives or the earliest armed timer expires.
  3. **`futex_wait` passed a relative timeout to `pthread_cond_timedwait`.**
     This is what made the group path fail. `_dispatch_timeout` returns a
     *relative* duration and Linux `FUTEX_WAIT` takes a relative timeout, but
     `pthread_cond_timedwait` wants an *absolute* deadline. The relative value
     names a deadline a few seconds after boot, which is already in the past, so
     every timed wait expired immediately and `dispatch_group_wait` reported a
     timeout before any block had run — hence `counter=0`. `futex_wait` now adds
     the duration to `clock_gettime(CLOCK_REALTIME)` first. Note that
     `_dispatch_sema4_timedwait` was already correct: it uses
     `_dispatch_time_nanoseconds_since_epoch`, which is absolute.

  `futex_wake` also used `pthread_cond_signal` on a bucket shared by 64
  addresses, so a wake could release a waiter on a different word while the
  intended one slept on. It now broadcasts and lets each waiter re-check its own
  address, which the futex contract allows and which
  `_dispatch_group_wait_slow`'s retry loop expects.

  `platform_now_ns` in `epoll_shim.c` multiplied before dividing, which
  overflows after about sixteen minutes at 19.2 MHz — and the console may have
  been up for hours before the program starts. It now divides first, matching
  `clock_gettime` in `swift_shim.c`.

  `build-dispatch.sh` also installs libdispatch's headers now. It used to build
  only `libdispatch.a`, while `switch2_dispatch_rules` puts
  `$(DISPATCH_HOME)/include` on the include path, so a fresh install could link
  libdispatch but not compile a program that includes `<dispatch/dispatch.h>`.
  The headers had been copied by hand into the one installation that was
  tested, which hid it.
- **`async let` used to look like a deadlock at scope exit, and was not one.**
  `swift_asyncLet_end` calls `swift_task_cancel`, which takes the task's
  status-record lock through `withStatusRecordLock` → `mtx_lock` →
  `pthread_mutex_lock` → `__libc_lock_acquire`, and that looked like a
  self-deadlock. It was not: the real cause was a live `assert()` in
  `Actor.cpp`, and `fault.c` overrides `__assert_func` to print and *park* the
  thread, so a fired assert is indistinguishable from a hang. Building with
  `-DNDEBUG` fixes it — see the `-DNDEBUG` entry below. The lock analysis was a
  red herring, and `SWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY` never helped: it
  only makes the global executor cooperative
  (`SWIFT_CONCURRENCY_COOPERATIVE_GLOBAL_EXECUTOR`), and `TaskGroup.cpp` guards
  its lock elision with `SWIFT_THREADING_NONE`, which is a different macro and
  does not touch the status-record lock either. Note that `thrd_current` is
  `__getreent`, which returns `_impure_ptr` — the same value for every thread —
  so any self-lock detection built on `thrd_equal` is always "self".
- **A log held open cannot be read back over FTP.** A file that a running
  process still has open reads as `I/O error` from an FTP client, and a program
  that crashes never reaches its final `fclose`, so a log kept open for the life
  of the program is a log you cannot retrieve from the machine that just
  crashed. Nothing holds a log open now: the test suite and the diag probes open,
  append, flush and close for every line, and `tests/common/fault.c` truncates
  the file in `fault_install`, closes it, and reopens it with `O_APPEND` only
  when it has a report to write, calling `fsync` before closing again. `fsync`
  comes from `libsysbase.a`, which is already linked.
- **`fault_install` used to keep its fd for the whole run.** It opened the log
  at startup and only closed it inside the handler, so a program that never
  faulted held `fault-*.log` open from `main` to exit — exactly the case where
  you want to read it. It also stored the caller's `withCString` pointer, which
  dangles once the call returns; the path is copied into a static buffer now.
- **`sdmc` is already mounted before `main`.** `__appInit` calls
  `fsdevMountSdmc()`, so calling it again returns "already mounted" and
  `R_SUCCEEDED` is false. Code that treats that as "no card" silently skips
  logging. Open the file first and only mount if that fails.
- **The thread pointer is the loader's block, not `__tls_start`, and its tail
  holds garbage.** `switch.ld` reserves `.main.tls` at `__tls_start` "for the
  TLS segment of the main thread", but nothing ever points `tpidrro_el0` at it:
  the whole program has 240 reads of that register and zero writes, and
  `msr tpidrro_el0` traps at EL0, so it cannot be repointed. The compiler emits
  `[tpidrro_el0 + offset]`, so the offsets are relative to whatever block the
  loader allocated. That block is large enough and writable, but by the time
  `main` runs its tail holds garbage that changes between runs, and the Swift
  libraries' variables sit exactly there — `ActiveTask::Value` at `0x430`,
  `ExecutorTrackingInfo::ActiveInfoInThread` at `0x438`,
  `FallbackTaskLocalStorage::Value` at `0x440`, `SwiftTLSContext::TLSContext`
  at `0x448`. `swift_task_getCurrent` then returns that garbage as the current
  task and `Task { }` dies dereferencing it. `swift/swift_shim.c` clears
  `[tp+0x430, tp+0x458)` from a constructor; with those slots zeroed,
  `Task { }` creates, runs and completes.
  **Clear only that range.** libnx's and mimalloc's entries occupy the first
  `0x430` bytes — mimalloc's four at `0x0`, `fsdev_last_result` at `0x20`,
  `g_fsPriority` at `0x24`, `__nx_dev_path_buf` (1025 bytes) at `0x28` — and
  zeroing those breaks `fsdev`, which kills the program in a constructor before
  `main` with no output past the early probe. On SDK releases before 20261113
  the boundary was `0x410` because mimalloc was not linked; check it with
  `scripts/verify_tls_boundary.py` rather than assuming either value.
- **clang must be told `-mtp=tpidrro_el0`.** This is the one that costs the most
  time. devkitA64's gcc uses `-mtp=soft`, which reads the thread pointer from
  `tpidrro_el0`. clang's default is `tpidr_el0`, which on the console holds the
  kernel's thread control block instead. Mixing the two makes every TLS access
  read the wrong memory, and it fails *before `main`*, in a library constructor,
  so the program exits to the launcher with no output at all. clang rejects
  `-mtp=soft`, but `-mtp=tpidrro_el0` produces the same base register.

  **Nothing may use `tpidr_el0`, anywhere, ever.** Check with
  `aarch64-none-elf-objdump -d foo.elf | grep -c tpidr_el0` — it must be 0.
  Beware the substring: `tpidrro_el0` contains `tpidr_el0`, so grep on its own
  is misleading; strip `tpidrro_el0` first.

  Passing the flag is not enough on its own, which is the trap this cost the
  most to find. The flag has to be on **every** compile, including the C++
  standard library's, and a library built without it is indistinguishable from
  a correct one until a thread-local is touched: it links, it boots, and it
  reads the wrong memory. The installed `libswift_Concurrency.a` shipped with
  18 `tpidr_el0` accesses in `Actor.o` and 10 in `TaskLocal.o` because the
  archive predated the flag in `cc_flags`; the current script compiles the same
  file to 0 `tpidr_el0` and 16 `tpidrro_el0`. Only `Actor.o` and `TaskLocal.o`
  are affected, because they are the only sources that instantiate the runtime's
  `SWIFT_THREAD_LOCAL_TYPE` macro.

  So the rule is checked rather than trusted:
  `scripts/verify_tls_boundary.py --archive` fails on any archive member that
  uses `tpidr_el0`, `build-stdlib.sh` refuses to install a library that does,
  and `port_sdk.py` runs the archive check as part of every port. Rebuild with
  `sh $DEVKITPRO/swift/full/build-stdlib.sh libs`, which is a few minutes and
  skips the slow Swift module.
- **`build-stdlib.sh` needs `CXX` set to clang 21.** The toolchain's own clang 17
  cannot parse devkitA64's libstdc++ 16 headers and fails on `SwiftObject.mm`
  with an incomplete-type error in `stl_iterator.h`. The script warns about this
  but does not stop:
  `CXX=/nix/store/...-clang-21.1.8/bin/clang++ sh build-stdlib.sh`.
- **Do not redeclare a `_Concurrency` symbol with `@_silgen_name`.** Declaring
  `swift_task_getCurrent` in Swift makes the compiler abort with
  `*** DESERIALIZATION FAILURE ***` and a `SILFunction type mismatch` while
  deserializing `_Concurrency.swiftmodule`, because the module already declares
  it with a different Swift type. Call such functions from C instead, where no
  module is involved.
- **`HAS_MALLOC_SIZE` must be 1, or `ManagedBuffer.capacity` is negative.**
  `LibcShims.h` derives it from the platform macros, and none of the ones it
  knows about are defined for `aarch64-none-none-elf`, so
  `_swift_stdlib_malloc_size` returned 0. `ManagedBuffer.capacity` is built on
  it:
  `endAddr = storageAddr + _swift_stdlib_malloc_size(storageAddr)`, then
  `realCapacity = endAddr - firstElementAddress`. With a zero size that is
  negative, so every `ManagedBuffer` reported a negative capacity and
  `_Deque.uncheckedAppend` tripped `assert(count < capacity)` — which is what
  killed `AsyncStream` with `Deque+UnsafeHandle.swift:368`. newlib does provide
  `malloc_usable_size`, so `build-stdlib.sh` patches a `__SWITCH__` branch into
  `LibcShims.h` (like it already patches `C11.cpp` and `Clock.cpp`) **and**
  passes `-Xcc -D__SWITCH__` in `swift_cc_flags` — without the define the
  `#else` branch still wins and the patch does nothing. Check with
  `aarch64-none-elf-nm libswiftCore.a | grep malloc_usable_size`.
- **`-DNDEBUG` is required, or `assert()` is live in the stdlib.** `cc_flags`
  used `-O2` without it, so the concurrency runtime's internal assertions were
  compiled in — Swift's release stdlib is built with NDEBUG. The one that bites
  is `Actor.cpp:241`, `assert(ActiveTask::get() == nullptr && "active task
  wasn't cleared before suspending?")`, which reads the `ActiveTask` slot after
  a job runs — `[tpidrro_el0 + 0x430]` on the current SDK. Because `tests/common/fault.c` overrides `__assert_func` to
  print and **park the thread**, a fired assert looks exactly like a deadlock:
  the console stops with no further output. That is what `concurrency/yield`
  and `concurrency/actor-reentrancy` were doing. `sh build-stdlib.sh libs`
  rebuilds every C++ library with NDEBUG in a few minutes and skips the slow
  Swift module, which contains no asserts. That took the binary from 1703
  `__assert_func` call sites to 19, all of them in newlib, libgcc and libstdc++
  (`__gethex`, `_malloc_r`, `snprintf`, `__umodti3`, …) rather than in Swift.
  With the asserts gone, `async-let`, `actor-reentrancy` and `yield` all pass —
  the "deadlocks" were asserts parking the thread.
- **`SWIFT_STDLIB_ENABLE_UNICODE_DATA` is required.** Without it the Unicode
  lookups in `stdlib/public/stubs/Unicode/` compile to
  `swift_abortDisabledUnicodeSupport`, so every non-ASCII `String` operation
  aborts: `String.count` over a grapheme cluster, normalization, case mapping,
  word breaking. The symptom is a bare `brk` with no report, because the abort
  is a `fatalError`-free trap. CMake defaults the option to TRUE and warns that
  disabling it "will cause many String methods to crash". The generated tables
  are in `stdlib/public/stubs/Unicode/Common` and ship with the source tree, so
  only the define was missing. Check a binary with
  `aarch64-none-elf-objdump -d foo.elf | grep -c swift_abortDisabledUnicodeSupport`
  — it must be 0. `sh build-stdlib.sh stubs` rebuilds just
  `libswiftStdlibStubs.a`, which is where the tables live, in seconds.
- **`SWIFT_STDLIB_HAS_TYPE_PRINTING=1` is required.** `ReflectionMirror.cpp`
  references `Demangle::keyPathSourceString` unconditionally, but
  `lib/Demangling/NodePrinter.cpp` only defines it inside
  `#if SWIFT_STDLIB_HAS_TYPE_PRINTING`. Without the define the demangler is
  missing the symbol and every Swift link fails with an undefined reference.
- **`swift_stdlib_random` must be replaced.** The standard library seeds its
  hash randomisation from the system entropy source during global
  initialisation, before `main`. On the console there is no `getrandom` and no
  `/dev/urandom`, so the upstream implementation calls `fatalError` and the
  program exits to the launcher with no output at all. `swift/swift_shim.c`
  defines its own `swift_stdlib_random`, which overrides the one in
  `libswiftStdlibStubs.a` because a regular object beats an archive member. It
  mixes the system tick with a stack address, which is enough for hash seeding.

  That "regular object" part is load-bearing, and the SwiftPM path got it wrong
  at first: it shipped the shim inside `libswiftshim.a`, so both copies were
  pulled in and the link failed with `multiple definition of
  'swift_stdlib_random'`. The wrapper now links `swift_shim.o` directly, before
  the `--start-group`, so `Random.o` is never pulled. Any program that
  allocates pulls the shim in for `posix_memalign`, which is why this only
  showed up once a package used `String` or an array.

- **Every `swift5_*` section has to be created empty in `swift_shim.c`.** The
  linker only synthesises `__start_`/`__stop_` for a section that some input
  object actually has, and the image registration constructor references all
  fifteen. A program that uses none of a given feature has no such section, so
  the reference is undefined and the link fails. The file creates all fifteen
  with an empty `.section` directive; an empty section merges with a real one,
  so the bounds still span everything. Only five were listed at first, which
  was enough for the test suite because it uses protocols, type metadata and
  the rest — a minimal package is what exposed the other ten.
- **`C11ThreadingHelper` needs `init_priority(101)`.** It is a namespace-scope
  object in `lib/Threading/C11.cpp`, so its constructor runs from `.init_array`
  in link order. The concurrency runtime's constructor calls `swift::once`,
  which reaches `once_slow` and therefore this helper — and it runs first, so
  the mutex is still zeroed and any program that links `libswift_Concurrency`
  dies before `main`. `build-stdlib.sh` copies `C11.cpp` and adds the attribute
  rather than editing the checkout. Reordering the `-l` flags does not help:
  the linker pulls archive members by symbol need, not by link order.
- **SwiftPM passes `-sdk <sdkRootPath>`** and the compiler then looks for the
  standard library inside that root. devkitA64's sysroot has none, so the
  install script builds a merged sysroot.
- **SwiftPM passes raw linker flags** (`-rpath`, `--gc-sections`,
  `-lclang_rt.builtins-aarch64`) that devkitA64's gcc rejects. The install
  script writes a wrapper that drops them and adds the libraries SwiftPM does
  not know about.
- **SwiftPM adds `-lc` itself, ahead of anything the linker wrapper adds.**
  That makes newlib's `libc.a` win the allocator, and once libswiftCore
  references `malloc_usable_size` the linker also pulls newlib's `mallocr.o`,
  which collides with libounce's `malloc.o`: `multiple definition of
  '_malloc_r'`, `_free_r`, `_realloc_r`, `_memalign_r`,
  `_malloc_usable_size_r`, `_malloc_trim_r`. It is the same six symbols that
  libounce reimplements on mimalloc, so the message names newlib and libounce
  and points at neither.

  The wrapper now passes libounce's `malloc.o` and `heap_pages.o` **first**, as
  plain objects rather than through `-lnx`: an object file is always loaded, so
  libounce's definitions are claimed before the linker opens `libc.a`, and
  newlib's `mallocr.o` is never pulled. `install-swift-sdk.sh` extracts both
  from `libounce.a` at install time, so the wrapper does not have to open an
  archive itself.

  Only SwiftPM is affected. A Makefile program reaches `-lnx` before libc, so
  `examples/swift-full` links fine either way — which is exactly why this
  survived until a package was built. Check any SwiftPM link with
  `SWITCH2_LD_MAP=/tmp/link.map`, which the wrapper now honours, and look at
  the `LOAD` lines: `libc.a` must not appear before `libounce.a`.

- **A clang++ driver compiles `.c` as C++.** `nix/fhs-env.nix` exports `CXX`
  as a clang++ wrapper for `build-stdlib.sh`, and `build-dispatch.sh` used to
  use `$CXX` as its C compiler, so the libdispatch build died with
  `invalid argument '-std=gnu11' not allowed with 'C++'`. The script now
  prefers the toolchain's own clang and only accepts `$CXX` after asking it to
  compile a `.c` file. The wrapper is called `clang20`, so a name check does
  not settle it; the probe does.
- **devkitPro's server is behind Cloudflare** and returns 403 to the default
  curl user agent. The Nix fetchers send a browser one.

## Verification status

Verified by building, on this machine:

- All six Makefile examples produce NROs.
- A SwiftPM package cross-compiles and packages into an NRO.
- The NixOS FHS environment builds `examples/vulkan-clear` end to end.
- `tests/` builds into a 5.4 MB NRO with 156 checks in it.
- All twelve test NROs link the fault handler, and `bl` in
  `__libnx_exception_returnentry` resolves to it. The report format, the
  frame-pointer walk and the recursive-fault guard were exercised by compiling
  `tests/common/fault.c` on the host against a synthetic `ThreadExceptionDump`.

**Runtime behaviour has now been tested on hardware**, through `tests/diag/`.
What works:

- **The full suite passes on hardware: `PASS 156 checks`.** 50 language,
  string, collection, numeric and memory tests; 12 concurrency tests; 13
  libdispatch tests; 4 pthread tests. Nothing is skipped and nothing is flaky.
- C, C++, pthreads and C11 threads.
- libdispatch: `_libdispatch_init` survives, `dispatch_sync` runs, and queues,
  groups, timers, semaphores, `apply`, barriers, `once` and queue-specific
  data all work.
- The Swift runtime starts, and literals, structs, classes and static protocol
  dispatch all work.
- **String heap growth, array growth and `String(repeating:)`**, after the image
  registration fix. `diag-str` runs every step to completion.

What used to fail, all of it inside the standard library, and all of it from one
bug — the main image was never registered with the runtime:

- **String heap growth.** `String.reserveCapacity` trapped. Every interpolated
  string and every `String(repeating:)` died here.
- **`Task { }` creation.** The concurrency runtime initialised, but creating a
  task trapped.
- **Protocol existentials.** `core/protocol-existential` in the main suite.

All three are fixed by the image registration described below. `diag-str` now
runs every step to completion on hardware: array growth, `String.reserveCapacity`,
append and `String(repeating:)` all pass.

These three may be one bug. They are the only things left, and each is the
first operation in its probe that is not a literal, a plain class allocation or
an array. The fault handler described under *Startup crashes* is what turns each
of them from "it died" into a `pc` you can disassemble.

**Root cause: the main image was never registered with the runtime.**

`swift_getTypeByMangledNameInContext2` demangles the name and then looks the
nominal type up in the images registered with `swift_addNewDSOImage`. Upstream
registers the main image from a `__attribute__((constructor))` in
`SwiftRT-ELF-WASM.cpp`. That file compiles to `SwiftRT-ELF-WASM.o` inside
`libswiftRuntime.a`, and the object defines **no global symbol** — only a static
`MetadataSections` and a static constructor. The linker pulls archive members by
symbol need, so it never pulled this one in, and `swift_addNewDSOImage` ended up
with zero callers in every linked program.

With no registered image, `_findContextDescriptor` finds nothing, so
`swift_getTypeByMangledNameInContext2` returns null for *every* mangled name.
`__swift_instantiateConcreteTypeFromMangledName` caches that null, and the caller
then hands a null metadata to `swift_allocObject`. Array growth, string
interpolation, `Task { }` and protocol existentials all go through it, which is
why they failed together.

The fix is in `swift/swift_shim.c`: it rebuilds the `MetadataSections` struct
from `MetadataSections.h` (version 4, from `ImageInspectionCommon.h`), declares
the fifteen `swift5_*` sections that a program may not otherwise have so the
linker synthesises their `__start_`/`__stop_` bounds, and calls
`swift_addNewDSOImage` from its own constructor. `swift_shim.o` is already in
every Swift link, so this is always present. It takes no lock, so it does not
need `C11ThreadingHelper` first, and a plain constructor runs after the
`init_priority(101)` ones.

`swift_addNewDSOImage` is declared weak and the call is guarded, because
embedded Swift (`switch2_swift_rules`) links no `libswiftRuntime` and so has no
such symbol. Embedded Swift resolves no metadata by name, so it does not need
the image registered; without the guard, `examples/swift-hello` failed to link
with `undefined reference to 'swift_addNewDSOImage'`.

Do not try `-Wl,--whole-archive -lswiftRuntime`: `SwiftObject.o` is already
merged into `libswiftCore.a`'s `Swift-1.o`, so it fails with multiple
definitions.

**How the probe found it.** `diag-str` steps 3g–3j call the resolver, the
metadata accessor, `swift_allocObject` and `swift_release` one at a time. On
hardware 3h, 3i and 3j all succeeded and only 3g returned `0x0`, which ruled out
the allocator, generic metadata instantiation and the demangler's parser in one
run. The remaining question was why a valid name resolved to nothing, and the
answer was that there was no image to search.

Note that `Array<Int>` growth *does* use the resolver after all: the generic
`_uninitializedCount` takes the `_ContiguousArrayStorage.Ma` branch, but the
compiler's `Int` specialization (`$ss22_ContiguousArrayBufferV19_uninitializedCount...
Si_Tgm5`) calls `__swift_instantiateConcreteTypeFromMangledName` directly. The
earlier `"SaySiG"` probe returned null only because it lacked the `$s` prefix
that `Demangler::demangleType` requires.

`tests/common/fault.c` also overrides `__assert_func`, because `abort()` returns
to the launcher just as silently as a `brk` does.

`tests/` exists to close that gap. Build it with `make -C $DEVKITPRO/tests`,
copy the NRO to the SD card and launch it. It prints each test name before
running it and flushes to `sdmc:/switch2-swift-tests.log`, so a crash tells you
which test died. Put a substring in `sdmc:/switch2-swift-tests.cfg` to run only
the matching tests.

### Startup crashes

If an NRO exits straight back to the launcher with no output and no log file,
the crash is before `main`, and no amount of logging inside the program will
show it. `_start` calls `__libnx_init`, which ends with `b __libc_init_array`,
so every `.init_array` constructor runs before `main` — including
`_libdispatch_init` and the Swift runtime's own.

`tests/diag/` has eleven NROs that add one component at a time, from pure C up to
the full standard library plus libdispatch. Run them in order and stop at the
first failure; `tests/diag/README.md` has the decision table.

Every probe also links `tests/common/fault.c`, which installs a handler for EL0
exceptions. A memory fault now prints `pc`, `lr`, `esr` and `far` on the console
and to `sdmc:/fault-<probe>.log` instead of returning silently to the launcher.
The same file also replaces Swift's four fatal-error reporters, so a trap prints
`file:line: message` instead of exiting silently. A death with neither report is
a bare `brk` that came from neither path.

## Known gaps found while writing the tests

- **The installed standard library is older than `build-stdlib.sh`.** The
  installed `Swift.swiftmodule` is dated 23:46 and the script 00:36, and the
  module was built before `-DSWIFT_ENABLE_REFLECTION` was added to it. As a
  result `Mirror` is marked unavailable and there is no `core/mirror` test.
  Re-running `build-stdlib.sh` turns reflection back on; add the test back
  afterwards. Check with `ls -la $DEVKITPRO/swift/toolchain/usr/lib/swift/none/aarch64/`
  against `ls -la swift/full/build-stdlib.sh`.
- **`posix_memalign` is defined twice.** `swift/swift_shim.c` and libdispatch's
  `shim/libc_shim.c` both provide it, so a program that links the full standard
  library and libdispatch together fails with a multiple definition error. The
  copy in `swift_shim.c` is now `__attribute__((weak))`, so libdispatch's wins
  and a Swift-only program still gets the weak one.
- **`String.contains(String)` does not exist.** Only the `Character` overload
  does, so `"abc".contains("b")` compiles by accident (the literal becomes a
  `Character`) but `s.contains(t)` with a `String` variable does not. This is
  upstream Swift, not a porting gap. Use `contains(where:)` or a manual search.
- **`String.compare` and `replacingOccurrences` are Foundation**, not the
  standard library, so they are not available here.

## Where things live

```
swift/
  switch2_swift_rules          embedded Swift
  switch2_swift_full_rules     full standard library
  switch2_dispatch_rules       libdispatch
  swift_shim.c                 posix_memalign, clock_gettime, TLS and image setup
  install-swift.sh             downloads the swift.org toolchain
  full/build-stdlib.sh         builds the standard library and concurrency
  dispatch/                    libdispatch config, shims and build script
  swiftpm/                     Swift SDK generator and build wrapper
  libounce/                    the Ounce SwiftPM package
scripts/
  port_sdk.py                  compare a new console SDK release
  verify_tls_boundary.py       re-derive SWIFT_TLS_START from a linked ELF
  release.py                   commit and push a port
examples/                      four programs, one per feature
tests/                         the hardware test suite and the diag probes
docs/
  swiftpm.md                   SwiftPM in detail, with a failure table
  PORTING.md                   the checklist for a new console SDK release
```

The console SDK (libounce, OunceVK and OunceHEN) is a separate installation,
not part of this repository. It ships with its own `install.sh`, and its NixOS
environment provides `nix/` and `flake.nix`; point `--devkitpro` at it if it is
not in `$DEVKITPRO`.
