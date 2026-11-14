# Porting to a new Switch 2 SDK release

The Swift toolchain does not depend on libounce the way a C program does. It
depends on a small number of *internals* of the console SDK, and on the ABI
between the two runtimes. When the console SDK changes, most of it is
irrelevant; a handful of things are not, and they fail in ways that look like
anything but their real cause.

This document is the checklist. `scripts/port_sdk.py` performs the mechanical
part of it and `scripts/verify_tls_boundary.py` confirms the one number that
cannot be checked by reading a file.

## The short version

```sh
# 1. Compare the new release against the installed one.
python3 scripts/port_sdk.py --archive /path/to/ounce-sdk.tar.xz

# 2. Install it and the scripts.
python3 scripts/port_sdk.py --archive /path/to/ounce-sdk.tar.xz --apply

# 3. Rebuild the Swift side.
sh $DEVKITPRO/swift/install-swift.sh --force   # only if Swift itself changed
sh $DEVKITPRO/swift/full/build-stdlib.sh
sh $DEVKITPRO/swift/foundation/build-foundation.sh
sh $DEVKITPRO/swift/dispatch/build-dispatch.sh
sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh --force

# 4. Rebuild the programs and re-derive the boundary.
make -C examples/swift-async
make -C examples/foundation-hello
python3 scripts/verify_tls_boundary.py --shim swift/swift_shim.c \
    examples/swift-full/swift-full.elf examples/swift-async/swift-async.elf \
    examples/foundation-hello/foundation-hello.elf \
    tests/switch2-swift-tests.elf

# 5. Confirm no thread-local goes through tpidr_el0. This checks the
#    libraries as well, because a stale one is how the rule rots.
python3 scripts/verify_tls_boundary.py --archive \
    $DEVKITPRO/swift/toolchain/usr/lib/swift/none/aarch64/*.a
```

The script stops with a `FAIL` when something it can check is wrong. Everything
it reports as `info` or `warn` needs a human decision, and this document says
which decision.

## What actually moves, and why

### 1. `SWIFT_TLS_START` — the one hard number

This is the boundary in the thread-local block between the console SDK's
variables and Swift's. `swift/swift_shim.c` clears Swift's part from a
constructor, because the loader does not zero it and the Swift libraries'
thread-locals therefore start as garbage. `swift_task_getCurrent` then returns
that garbage as the current task, and `Task { }` dies dereferencing it.

Clearing has to start *exactly* at the boundary. Too low and it clears libnx's
own data, which breaks `fsdev` in a constructor before `main` — the program
exits to the launcher with no output. Too high and the Swift slots stay
garbage, which is the original crash.

The boundary moved between the two releases this port has seen:

| Release | libnx part | Swift part starts | Why |
|---|---|---|---|
| `20261112c` and earlier | `0x000`–`0x409` | `0x410` | libnx alone |
| `20261113` | `0x000`–`0x42C` | `0x430` | libounce links mimalloc |

On `20261113`, libounce began linking mimalloc, whose four thread-locals come
first in link order. `__nx_dev_path_buf` (1025 bytes) moved from `0x8` to
`0x28`
and now ends at `0x429`, so the old `0x410` would clear its last 25 bytes.
That is exactly the fsdev breakage the comment in `swift_shim.c` warns about,
and it would look like "the SDK update broke my program".

**Deriving it.** Do not count bytes from the end of `.tbss`: the region after
the boundary differs depending on whether a program links the concurrency
runtime and libdispatch, so the end of the block says nothing about where
Swift's variables begin. Run:

```sh
python3 scripts/verify_tls_boundary.py --shim swift/swift_shim.c \
    examples/swift-async/swift-async.elf
```

It sorts the thread-locals of a linked program, finds the first one that
belongs to the Swift runtime, and reports the end of the last one before it.
It refuses to guess: if the SDK has interleaved its variables with Swift's, no
single offset works and it fails with the offending names.

To update the source automatically:

```sh
python3 scripts/verify_tls_boundary.py --write-swift-shim swift/swift_shim.c \
    examples/swift-async/swift-async.elf tests/switch2-swift-tests.elf
```

**Check every program shape.** The boundary is the same for all of them, but
only if the layout is uniform. Check an embedded-Swift program (none of these
have Swift TLS at all, so the script will decline), a full-stdlib program, a
concurrency program, a libdispatch program, and the full test suite, which
links everything at once. `port_sdk.py` does this if the examples are built.

If a program's boundary disagrees with the others, chance are it links a
different set of archives. Prefer making the layout uniform over shipping two
values.

### 2. The thread pointer: `tpidrro_el0`, never `tpidr_el0`

This is not an SDK fact that moves; it is an invariant that quietly rots. It is
in the porting checklist because the way it rots is *by a port* — a library
gets rebuilt from a script whose flags changed, and a stale copy survives.

The console has two thread-pointer registers:

| Register | What it holds |
|---|---|
| `tpidrro_el0` | the program's thread-local block — readable at EL0, not writable |
| `tpidr_el0` | the kernel's thread control block |

The compiler emits `[tpidr_el0 + offset]` by default, so every invocation gets
`-mtp=tpidrro_el0` (devkitA64's gcc spells the same thing `-mtp=soft`). An
access through `tpidr_el0` reads memory that is not the program's, which
usually means garbage or a fault, and it fails before `main` in a constructor,
so the program exits to the launcher with no output at all.

**Passing the flag is not sufficient.** It has to be on *every* compile,
including the C++ standard library's, and a library built without it is
indistinguishable from a correct one until a thread-local is touched — it
links, it boots, and then it reads the wrong memory. The installed
`libswift_Concurrency.a` shipped with 18 `tpidr_el0` accesses in `Actor.o` and
10 in `TaskLocal.o` for exactly this reason: the archive predated the flag in
`cc_flags`, even though the script had it. Those two files are the only ones
affected, because they are the only sources that instantiate
`SWIFT_THREAD_LOCAL_TYPE`:

```cpp
// stdlib/public/Concurrency/Actor.cpp
class ActiveTask {
  static SWIFT_THREAD_LOCAL_TYPE(Pointer<AsyncTask>, tls_key::concurrency_task) Value;
};
```

so a plain `thread_local` in the standard library is not the risk; the
runtime's macro is.

Check it rather than trust it:

```sh
# Every archive member, by name, so you know what to rebuild.
python3 scripts/verify_tls_boundary.py --archive \
    $DEVKITPRO/swift/toolchain/usr/lib/swift/none/aarch64/*.a

# Any linked program. Strip tpidrro_el0 first: it contains tpidr_el0 as a
# substring, so a bare grep reports every correct program as broken.
aarch64-none-elf-objdump -d foo.elf | sed 's/tpidrro_el0//g' | grep -c tpidr_el0
```

`build-stdlib.sh` refuses to install a library that fails this, and
`port_sdk.py` runs the archive check on every port. When one fails, rebuild
with `sh $DEVKITPRO/swift/full/build-stdlib.sh libs` — a few minutes, and it
skips the slow Swift module, which contains no thread-locals of this kind.

### 3. The allocator interface

libounce replaces `malloc` and friends with mimalloc. The Swift toolchain has
to cooperate in three places, and each fails differently:

- **`LibcShims.h` needs `HAS_MALLOC_SIZE`.** `build-stdlib.sh` patches a
  `__SWITCH__` branch into it that uses `malloc_usable_size`. Without it,
  `ManagedBuffer.capacity` is negative and `AsyncStream` trips
  `assert(count < capacity)`.
- **`swift_shim.c` defines a weak `posix_memalign`.** It must stay weak,
  because libdispatch's `libc_shim.c` defines the same function and a program
  that links both would otherwise fail with a multiple definition.
- **The SwiftPM linker wrapper extracts `malloc.o` and `heap_pages.o`.** This
  is the subtle one. SwiftPM puts `-lc` on its own command line, ahead of
  anything the wrapper adds, so newlib's `libc.a` is searched first and its
  `malloc` wins. libswiftCore references `malloc_usable_size`, which pulls
  newlib's `mallocr.o`, and then libounce's `malloc.o` collides with it:
  `multiple definition of '_malloc_r'`. The wrapper therefore passes the
  allocator objects *first*, as plain objects, so libounce's definitions are
  claimed before the linker opens `libc.a`.

  This only bites a SwiftPM package, not a Makefile program, because the
  Makefile link reaches `-lnx` before libc. It surfaced when `20261113` began
  shipping an allocator that defines `_malloc_r` as a strong symbol.

If `port_sdk.py` reports that libounce no longer defines the allocator entry
points, or that `malloc.o`/`heap_pages.o` are missing, check all three.

### 4. The build rules' shape

`switch2_swift_rules`, `switch2_swift_full_rules` and `switch2_dispatch_rules`
include `$(DEVKITPRO)/libounce/switch2_rules` and rely on what it sets:

- `PORTLIBS_SWITCH2` — the Switch 2 portlibs overlay.
- `OVERLAY_LIBPATHS` — puts those libraries ahead of the Switch 1 ones, so
  `-lEGL` and `-lvulkan` find OunceVK.
- `switch2_cpu.mk` — defines `SWITCH2_CPU`.

The rules were reshaped in the `20261110` release and again in `20261113`; the
current shape is the one the Makefiles use, with `LIBDIRS := $(PORTLIBS)
$(LIBNX)`. A Makefile that spelled out `$(PORTLIBS_PATH)/switch2` would break.

### 5. Headers the port includes

Mostly stable, but two matter:

- `switch/arm/counter.h` — `armGetSystemTick` and `armGetSystemTickFreq` are
  the only clock. `swift_shim.c` implements `clock_gettime` and `clock_getres`
  on them, and every clock in the program agrees because of it.
- `switch/arm/tls.h` — `armGetTls` is `static inline` reading
  `tpidrro_el0`. A change here means the whole TLS scheme needs review.

`ouncehenJitPublishRanges` is the one non-inline OunceHEN function the Swift
wrapper imports. It gained `extern "C"` in `20261113`, which is a fix rather
than a break, but it is worth noticing when it changes.

### 6. The linker script and specs

`switch.ld` and `switch.specs` were byte-identical across both releases seen so
far, and are worth checking byte for byte when they are not, because
`SWIFT_TLS_START` and `__tls_start`/`__tls_end` depend on them. Note that
`__tls_start` is *not* where the Swift slots are: nothing ever points
`tpidrro_el0` at `.main.tls`, and `msr tpidrro_el0` traps at EL0. The shim
reads the register the loader set up instead, and uses `__tls_start`/`__tls_end`
only to bound the clear.

## Things that do not need checking

The full Swift standard library is built against devkitA64's newlib, not
against libounce, so a console SDK release does not invalidate it. It has no
references to `fsdev`, `nx_` or `ounce` symbols; confirm with:

```sh
aarch64-none-elf-nm -u libswiftCore.a | grep -iE 'fsdev|ounce|nx_'
```

An empty result means the installed standard library survives the SDK update.
libdispatch *does* depend on libounce (through pthreads and the `__syscall_*`
hooks), so it is rebuilt.

## Order of operations

1. `port_sdk.py` compares and reports.
2. Install the archive and the scripts.
3. Rebuild the standard library's C++ libraries, libdispatch and the SwiftPM
   bundle. All three depend on libounce.
4. Confirm the archives use `tpidrro_el0` and not `tpidr_el0`. A rebuild that
   silently reused a stale object is the failure this catches.
5. Rebuild the examples, the test suite and the diag probes.
6. Re-derive `SWIFT_TLS_START` and update `swift_shim.c` if it moved.
7. Rebuild everything that links the shim: that is every Swift program.
8. Update `HANDOFF.md`'s compatibility table and `CHANGELOG.md`.
9. `scripts/release.py` to commit and push.

Steps 4 and 7 are not optional. The shim is a plain object in every Swift
link, so a change to it invalidates every previously built binary; and a
library built without `-mtp=tpidrro_el0` links and boots and then reads the
wrong memory, so the flag being right in the script proves nothing about what
is installed.

## When a program crashes before `main`

That is almost always the TLS boundary or the image registration. The diag
probes bisect it, one component at a time:

```sh
for d in tests/diag/*/; do make -C "$d" || echo "FAILED: $d"; done
```

Run them in order on hardware and stop at the first failure;
`tests/diag/README.md` has the decision table. A program that dies with no
output at all before `main` and has a *correct* boundary is a different
problem: check that `swift_clear_tls` still runs after libnx's constructors,
and that the image registration constructor still finds
`swift_addNewDSOImage`.
