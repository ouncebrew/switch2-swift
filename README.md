# Swift for Nintendo Switch 2 homebrew

A Swift toolchain for Switch 2 homebrew, on top of the
[ounce SDK](https://github.com/ouncebrew). It provides:

- **Build rules** for `make`, so a libnx-style Makefile project builds in
  Swift with one changed include line.
- **Embedded Swift**, for programs that need no standard library at all.
- **The full Swift standard library**, built for `aarch64-none-none-elf`
  against devkitA64's newlib: `String`, arrays, reflection, Unicode.
- **FoundationEssentials**, the ICU-free part of Foundation: `Data`, `Date`,
  `URL`, JSON, `Codable`, `FileManager` and `ProcessInfo`.
- **Swift concurrency** — `async`/`await`, actors, task groups — single
  threaded, on the console's cooperatively scheduled global executor.
- **libdispatch**, built on shims for the pieces the console lacks: futex,
  epoll, eventfd and timerfd.
- **SwiftPM** support, so a package cross-compiles and packages into an NRO.
- **`Ounce`**, a Swift wrapper over libounce and OunceHEN: console, applet
  lifecycle, controller input, filesystem mounts and HEN sessions.

Not ported: `FoundationInternationalization` (ICU), `FoundationNetworking`,
`FoundationXML`, backtracing, dispatch sources that watch file descriptors,
dispatch I/O.

This repository is the Swift half of the Switch 2 SDK. The console SDK itself —
libounce, OunceVK, OunceHEN — ships separately; `install.sh` checks for it and
says where to get it.

## Install

The console SDK must be installed first, into `$DEVKITPRO` (usually
`~/.devkitpro` on NixOS, `/opt/devkitpro` elsewhere).

```sh
sh install.sh                      # copies the rules and scripts
sh $DEVKITPRO/swift/install-swift.sh
sh $DEVKITPRO/swift/full/build-stdlib.sh
sh $DEVKITPRO/swift/foundation/fetch-foundation.sh
sh $DEVKITPRO/swift/foundation/build-foundation.sh
sh $DEVKITPRO/swift/dispatch/build-dispatch.sh
sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh
```

The second line downloads a 784 MB Swift 6.0.3 toolchain from swift.org. The
third builds the standard library from source, which takes about 4 GiB of disk
and 20 minutes on 8 cores. libdispatch takes a few minutes. None of them need
to be run again unless the Swift toolchain or the console SDK changes.

On NixOS, both prebuilt toolchains need an FHS environment. The console SDK's
`flake.nix` provides one; run these inside it, not on the bare system.

## Build a program

A Swift program uses the same Makefile as a C one, with a different include
line:

```make
include $(DEVKITPRO)/swift/switch2_swift_rules
```

For the full standard library:

```make
include $(DEVKITPRO)/swift/switch2_swift_full_rules
```

For libdispatch:

```make
include $(DEVKITPRO)/swift/switch2_dispatch_rules
```

Each adds a `%.o: %.swift` rule and `SWIFT_SHIM_OBJ`, a C object with the
runtime functions that newlib lacks. A Makefile that uses Swift adds the Swift
objects to `OFILES_SRC` and the shim to `OFILES`:

```make
SWIFTFILES	:=	$(foreach dir,$(SOURCES),$(notdir $(wildcard $(dir)/*.swift)))
export OFILES_SRC	:=	$(CPPFILES:.cpp=.o) $(CFILES:.c=.o) $(SFILES:.s=.o) \
				$(SWIFTFILES:.swift=.o)
export OFILES	:=	$(OFILES_BIN) $(OFILES_SRC) $(SWIFT_SHIM_OBJ)
```

and, for the full library or libdispatch, adds the libraries to `LIBS`:

```make
LIBS	:=	-lnx $(SWIFT_FULL_LIBS)              # full standard library
LIBS	:=	-lnx $(DISPATCH_LIBS)                # libdispatch
```

`examples/` has one program for each: `swift-hello` (embedded), `swift-full`
(full library), `swift-async` (concurrency), `dispatch-hello` (libdispatch) and
`foundation-hello` (FoundationEssentials).

## FoundationEssentials

`swift/foundation/` builds the part of Foundation that needs no ICU: `Data`,
`Date`, `URL`, `JSONDecoder`, `Codable`, `FileManager` and `ProcessInfo`. The
build fetches upstream swift-foundation, patches its POSIX assumptions behind
`__SWITCH__` at build time and installs `libswiftFoundationEssentials.a`, its
Swift modules and the C shim module maps. The upstream sources stay unmodified.

```sh
sh $DEVKITPRO/swift/foundation/fetch-foundation.sh
sh $DEVKITPRO/swift/foundation/build-foundation.sh
```

Import `FoundationEssentials`, not `Foundation`: the umbrella module pulls in
Internationalization, Networking and XML, which this port does not include. The
full-library rules add the shim module maps and `SWIFT_FOUNDATION_LIBS` once the
build has installed them, so a Makefile only needs
`LIBS := -lnx $(SWIFT_FOUNDATION_LIBS) $(SWIFT_FULL_LIBS)`. SwiftPM packages
get the same flags from the generated SDK bundle, so `import
FoundationEssentials` is enough there.

Not in this port: regular expressions (the toolchain has no
`_StringProcessing`), time zone data beyond `sdmc:/switch/zoneinfo`, extended
attributes and `chown` (the SD filesystem has neither), and user or group
accounts (the console has none).

## Build a SwiftPM package

```sh
sh $DEVKITPRO/swift/swiftpm/switch2-build.sh -c release
```

Run it from the package directory. It installs nothing; run
`install-swift-sdk.sh` once first. Both scripts take `--devkitpro PATH` to pick
a Switch 2 SDK root other than `$DEVKITPRO`. Release mode only: debug links
`SwiftOnoneSupport`, which is not built.

The entry point is top-level code, not `@_cdecl("main")`, because SwiftPM
generates `main` for an executable target. `docs/swiftpm.md` has the details
and the failure table.

## Use the Ounce library

`swift/libounce` is a SwiftPM package wrapping libounce and OunceHEN. It
installs to `$DEVKITPRO/swift/libounce` and is used as a path dependency:

```swift
dependencies: [
    .package(path: "/path/to/devkitpro/swift/libounce")
]
```

```swift
import Ounce

Console.puts("Hello from Swift on Switch 2")
```

Its README has the API and an example.

## Check the port on hardware

```sh
make -C $DEVKITPRO/tests
```

Copy the NRO to the SD card and launch it. It prints each test name before
running it and flushes to `sdmc:/switch2-swift-tests.log`, so a crash says which
test died. Put a substring in `sdmc:/switch2-swift-tests.cfg` to run a subset.

`tests/diag/` has twelve probes that add one component at a time, from pure C
up to the full library plus libdispatch, for when a program dies before `main`.
`tests/diag/README.md` has the decision table.

## Porting to a new console SDK

See [docs/PORTING.md](docs/PORTING.md). Two scripts do the mechanical part:

```sh
python3 scripts/port_sdk.py --archive /path/to/ounce-sdk.tar.xz
python3 scripts/verify_tls_boundary.py --shim swift/swift_shim.c \
    examples/swift-async/swift-async.elf
```

The one number that cannot be read out of a file is `SWIFT_TLS_START`, the
boundary between the console SDK's thread-locals and Swift's. It moved from
`0x410` to `0x430` when libounce started linking mimalloc. Getting it wrong
either breaks `fsdev` before `main` or makes `Task { }` dereference garbage, so
it is measured from a linked program rather than guessed.

## Layout

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
scripts/
  port_sdk.py                  compare a new console SDK release
  verify_tls_boundary.py       re-derive SWIFT_TLS_START from an ELF
  release.py                   commit and push a port
```

## Licence

MIT, except where a file says otherwise. The Swift toolchain and its standard
library are Apache 2.0 with a runtime exception; libdispatch is Apache 2.0.
