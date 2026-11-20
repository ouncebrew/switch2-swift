# Using SwiftPM with the Switch 2 SDK

This document covers building Swift packages for the Switch 2 with SwiftPM: how
to install the Swift SDK, how to lay out a package, how to build it into an NRO,
and what does and does not work.

If you only want to compile a single Swift file, the Makefile rules
(`switch2_swift_rules`, `switch2_swift_full_rules`) are simpler. SwiftPM is for
packages with several targets, or for projects that already use it.

---

## 1. What the SwiftPM path gives you

`swift build` normally compiles for the host. The Switch 2 Swift SDK teaches it a
second target, `aarch64-none-none-elf`, so that:

```sh
swift build --swift-sdk switch2 --triple aarch64-none-none-elf
```

produces an AArch64 bare-metal executable. `switch2-build.sh` wraps that command
and turns the executable into an NRO you can copy to the SD card.

The target triple is `aarch64-none-none-elf`, **not** `aarch64-none-elf`. The
embedded standard library only ships for the former. devkitA64 uses the latter.
The objects are identical; only the spelling differs.

---

## 2. Prerequisites

Four things have to be in place. The installer handles the first two for you.

| Component | Where it goes | Installed by |
|---|---|---|
| devkitPro Switch toolchain | `$DEVKITPRO/devkitA64`, `$DEVKITPRO/tools` | `install-devkitpro.sh` (automatic) |
| Swift toolchain | `$DEVKITPRO/swift/toolchain` | `install-swift.sh` (automatic) |
| libounce | `$DEVKITPRO/libounce` | `install.sh` (from the SDK archive) |
| Full Swift standard library | `$DEVKITPRO/swift/toolchain/usr/lib/swift/none/aarch64` | `build-stdlib.sh` (manual) |

The last two are not installed automatically. libounce comes from the SDK
archive, which only `install.sh` has, and the standard library is a long build.
If either is missing, `install-swift-sdk.sh` stops and prints the command to run.

On NixOS, `nix develop` gives you an FHS environment with devkitPro already
populated. SwiftPM compiles the package manifest for the *host*, and that link
needs a conventional glibc layout, so the FHS environment is required there.

On macOS there is no FHS environment to enter. devkitPro's pacman `.pkg`
installs native devkitA64 tools, `install-swift.sh` installs the macOS Swift
toolchain, and the generated bundle lists the Apple host triples alongside the
Linux ones.

---

## 3. Installing the Swift SDK

```sh
sh $DEVKITPRO/swift/swiftpm/install-swift-sdk.sh
```

That is all you need in the common case. It installs the devkitPro toolchain and
the Swift toolchain if they are missing, then generates and installs the bundle.

### Options

| Option | Meaning |
|---|---|
| `--devkitpro PATH` | Use `PATH` as the Switch 2 SDK root. `--sdk` is an alias. |
| `--force` | Rebuild and replace an already installed bundle. |
| `--no-deps` | Do not install anything; only report what is missing. |
| `-h`, `--help` | Print usage. |

### Choosing the SDK path

The Switch 2 SDK root is the devkitPro directory. It is resolved in this order:

1. `--devkitpro PATH`
2. `$DEVKITPRO`
3. `/opt/devkitpro`

A relative path is resolved to an absolute one, because the bundle records
absolute paths and a relative one would break as soon as you built from another
directory.

The resolved path is baked into the generated bundle **and** into the linker
wrapper, so the installed SDK keeps working after `DEVKITPRO` is unset:

```sh
sh install-swift-sdk.sh --devkitpro /home/me/devkitpro
```

If a bundle is already installed, the script says so and exits. That is because
the existing bundle records the path it was built against, which may not be the
one you just passed. Use `--force` to rebuild it.

### Verifying

```sh
swift sdk list
```

should print `switch2`. The bundle itself lives at:

```
~/.swiftpm/swift-sdks/switch2.artifactbundle
```

To remove it:

```sh
swift sdk remove switch2
```

---

## 4. Creating a package

A minimal package needs a `Package.swift` and one source file.

```
hello-switch2/
  Package.swift
  Sources/
    hello-switch2/
      main.swift
```

### Package.swift

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hello-switch2",
    targets: [
        .executableTarget(name: "hello-switch2")
    ]
)
```

No `platforms:` entry is needed, and there is nothing to declare about the
target triple; that comes from the `--triple` flag.

### The entry point

**Use top-level code in `main.swift`.** SwiftPM generates `main` for an
executable target, so `@_cdecl("main")` collides with it and the link fails with
a duplicate symbol.

This is the opposite of the Makefile examples, which use `@_cdecl("main")`
because nothing else provides one.

### Calling libnx

The SDK ships C headers, not a Swift module map, so libnx functions are declared
with `@_silgen_name`:

```swift
@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleUpdate")
func consoleUpdate(_ console: UnsafeMutableRawPointer?)

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32
```

### A complete `main.swift`

```swift
@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleUpdate")
func consoleUpdate(_ console: UnsafeMutableRawPointer?)

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32

/// Writes one line and draws it. The console is double buffered, so nothing
/// appears until consoleUpdate runs.
func log(_ text: String) {
    text.withCString { _ = puts($0) }
    consoleUpdate(nil)
}

_ = consoleInit(nil)

log("Hello from SwiftPM on Switch 2")

var total = 0
for value in 1...10 {
    total += value
}
log("sum 1...10 = \(total)")

consoleExit(nil)
```

Two things about output:

- **`consoleUpdate(nil)` is what draws.** `puts` alone writes to the buffer.
- **Swift's `print` also works**, because libnx's `consoleInit` redirects
  `stdout` to the console. The examples and the hardware test suite use a
  `puts`-based helper instead, which is why this document does too. If output
  seems to lag, call `fflush(nil)`.

`consoleExit(nil)` returns to the launcher. If you want the output to stay on
screen, keep the program alive with a loop over `appletMainLoop()` and exit on a
button press, the way `tests/source/main.swift` does.

### Using the Ounce library

Everything above declares libnx functions by hand with `@_silgen_name`. The
`Ounce` package does that for you, and wraps the parts of libounce and OunceHEN
a program needs at startup. It installs to `$DEVKITPRO/swift/libounce`.

```swift
import Ounce

Console.initialize()
Console.print("Hello from Swift")

let pad = Pad()
while Applet.isRunning {
    pad.update()
    if pad.buttonsDown.contains(.plus) { break }
}

Console.exit()
```

Add it as a path dependency:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "my-homebrew",
    dependencies: [
        .package(path: "/path/to/devkitpro/swift/libounce")
    ],
    targets: [
        .executableTarget(
            name: "my-homebrew",
            dependencies: [.product(name: "Ounce", package: "Ounce")]
        )
    ]
)
```

It provides `Console`, `Applet`, `Pad` with a `Button` `OptionSet`,
`FileSystem` for mounting devices, `HosVersion`, and `Hen` for OunceHEN
sessions. `swift/libounce/README.md` has the full API.

The package needs the SDK's toolset to put the libounce and OunceHEN include
paths on the compiler's search path. `install-swift-sdk.sh` does that; a bundle
installed before the library existed has to be rebuilt with `--force`.

### Using FoundationEssentials and FoundationNetworking

Once `build-foundation.sh` has installed the libraries, import them directly;
no `Package.swift` change is needed:

```swift
import FoundationEssentials
import FoundationNetworking

let now = Date()
let data = Data("switch".utf8)

let (body, response) = try await URLSession.shared.data(
    from: URL(string: "https://example.com/")!)
```

`Data`, `Date`, `URL`, `JSONEncoder`/`JSONDecoder`, `Codable`, `FileManager`
and `ProcessInfo` work. `URLSession`, `URLRequest`, `URLResponse`,
`HTTPURLResponse` and `URLError` do too, over libnx's socket service and the
console's ssl service. Import these two modules, not `Foundation`: the umbrella
module also needs Internationalization and XML, which are not ported. Requests
execute synchronously; caches, cookies, proxies, authentication challenges,
compression and HTTP/2 are not implemented. There are no regular expressions
(the toolchain has no `_StringProcessing`), time zone data is read from
`sdmc:/switch/zoneinfo`, and xattrs and `chown` report `ENOTSUP`.

`install-swift-sdk.sh` adds the shim module maps to the generated toolset and
the linker wrapper adds `libswiftFoundationEssentials.a` and
`libswiftFoundationNetworking.a` when they exist. A bundle generated before
the Foundation build existed has to be rebuilt with `--force`.

---

## 5. Building

From the package directory:

```sh
sh $DEVKITPRO/swift/swiftpm/switch2-build.sh -c release
```

### Options

| Option | Meaning |
|---|---|
| `--devkitpro PATH` | Use `PATH` as the Switch 2 SDK root. `--sdk` is an alias. |
| `-c CONFIG`, `--configuration CONFIG` | Build configuration. Use `release`. |
| `--` | Everything after this is passed to `swift build`. |
| `-h`, `--help` | Print usage. |

Anything else is forwarded to `swift build`, so `-v`, `--build-path` and similar
work.

### Finding the SDK root

`switch2-build.sh` resolves the root in this order:

1. `--devkitpro PATH`
2. `$DEVKITPRO`
3. The directory the script was installed into, two levels up
4. `/opt/devkitpro`

Step 3 matters: the script lives in `<root>/swift/swiftpm`, so an installed copy
finds its own SDK with no environment variable set at all.

### Output

The script runs:

```sh
swift build --swift-sdk switch2 --triple aarch64-none-none-elf -c release
```

then packages the executable. You get two files in the package directory:

```
<product>.nro     the program, ready for the SD card
<product>.nacp    its metadata
```

The product name is the executable's name, which need not match the directory
name.

### Driving SwiftPM directly

If you want the executable without the NRO packaging:

```sh
swift build -c release --swift-sdk switch2 --triple aarch64-none-none-elf
```

SwiftPM puts the result under `.build/<triple>/<configuration>/`.

---

## 6. Running on hardware

1. Copy `<product>.nro` to the SD card, for example to `sdmc:/switch/`.
2. Insert the card and launch the program from the homebrew menu.

If the program exits straight back to the launcher with no output, it died before
`main`. See `HANDOFF.md` for the startup-crash decision table and the
`tests/diag/` probes.

---

## 7. What works

The hardware test suite (`tests/`) runs 156 checks on a real console and all of
them pass. Everything below is exercised there.

**Language and runtime**

- Structs, classes, inheritance, protocols and existentials, generics, closures,
  enums with associated values, error handling, key paths, `weak`/`unowned`,
  `deinit`, property observers, `lazy`, subscripts, pattern matching, tuples,
  static initialisation, global initialisation.
- `String` in full: interpolation, Unicode and grapheme clusters, UTF-8 views,
  comparison, splitting and joining, substrings, character properties, hashing.
- `Array`, `Dictionary`, `Set`, sorting, higher-order functions, lazy sequences,
  slices, custom `Hashable`.
- Integer overflow behaviour, `Double`, conversions, bitwise operations,
  `random`.
- Allocation of small, large and many blocks, `posix_memalign`, large arrays,
  string churn.

**Concurrency**

`async`/`await`, `async let`, task groups, detached tasks, actors and actor
reentrancy, `Task.yield`, cancellation, continuations, `AsyncStream`, task-local
values.

**libdispatch**

Queues, groups, timers (`dispatch_after`), semaphores, `dispatch_apply`,
barriers, `dispatch_once`, queue-specific data.

The SwiftPM linker wrapper does not link libdispatch, and this document does not
cover wiring it into a package: it needs its headers, `-fblocks` and its own
library path, which SwiftPM passes through several different flag channels. If
you need it, the Makefile rules are the supported path — see
`switch2_dispatch_rules` and `examples/dispatch-hello`.

---

## 8. What does not work

- **Debug builds.** `-c debug` links `SwiftOnoneSupport`, which this port does
  not build. The toolchain only ships the host's copy. Always use
  `-c release`.
- **Backtracing.** Not ported.
- **Dispatch sources that watch file descriptors**, and **dispatch I/O.** The
  console has no descriptor table. Queues, timers and the manager thread do
  work.
- **`String.contains(String)`.** Only the `Character` overload exists, so
  `s.contains(t)` with a `String` variable does not compile. This is upstream
  Swift, not a porting gap. Use `contains(where:)` or a manual search.
- **`String.compare` and `replacingOccurrences`.** These are Foundation, not the
  standard library.

---

## 9. Troubleshooting

| Message | Cause and fix |
|---|---|
| `no Package.swift here` | Run the script from the package directory. |
| `no Swift toolchain in ...` | Run `install-swift.sh`, or pass `--devkitpro`. |
| `no elf2nro in ...` | devkitPro is incomplete. Run `install.sh`. |
| `the Switch 2 Swift SDK is not installed` | Run `install-swift-sdk.sh`. |
| `could not find the built executable in .build` | The build produced no executable. Check the `swift build` output above it. |
| `no Swift standard library in ...` | Run `sh $DEVKITPRO/swift/full/build-stdlib.sh`. |
| `no libounce in ...` | Run `install.sh`; it unpacks the SDK archive. |
| `undefined reference to 'main'` | You used `@_cdecl("main")`. Use top-level code in `main.swift`. |
| duplicate symbol `main` | Same cause: SwiftPM already generates `main`. |
| `cannot find -lswiftOnoneSupport` | You built in debug mode. Use `-c release`. |
| `cannot open Scrt1.o` / `cannot find -lgcc` | SwiftPM is compiling the manifest for the host and cannot find glibc. On NixOS, run inside `nix develop`. |

---

## 10. How it works

SwiftPM's model does not fit a bare-metal target, so the installer does more than
write a bundle.

**A merged sysroot.** SwiftPM passes `-sdk <sdkRootPath>` and the compiler then
looks for the standard library inside that root. devkitA64's sysroot has none, so
`install-swift-sdk.sh` builds one at `$DEVKITPRO/swift/swiftpm/sysroot` that
carries the C sysroot's headers and libraries plus the Swift resources.

**A linker wrapper.** SwiftPM treats the linker as a plain linker and passes
`-rpath`, `--gc-sections` and `-lclang_rt.builtins-aarch64`, none of which
devkitA64's gcc accepts or needs. The wrapper at
`$DEVKITPRO/swift/swiftpm/switch2-ld` drops those and adds what SwiftPM does not
know about: the rest of the standard library, the shim, and libnx. It also
records the devkitPro path it was generated for.

**A runtime shim.** `swift_shim.o` provides `posix_memalign`, which newlib does
not have, plus the image registration and thread-local setup the runtime needs on
this target. It is linked as a plain object rather than an archive member,
because it replaces `swift_stdlib_random`: a regular object beats an archive
member, so the copy in `libswiftStdlibStubs.a` is never pulled in. `HANDOFF.md`
explains why each piece is necessary.

**A toolset.** `toolset.json` in the bundle names the Swift compiler, the C
compiler (clang, because blocks need it) and the linker wrapper, with the flags
each needs.

---

## See also

- `README.md` — the SDK as a whole, including the Makefile rules.
- `HANDOFF.md` — why the port looks the way it does, and the sharp edges.
- `tests/` — the hardware test suite, and the best source of working Swift code
  for this target.
