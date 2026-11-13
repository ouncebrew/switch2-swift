# Ounce — a Swift wrapper over libounce and OunceHEN

`Ounce` is a Swift library for Switch 2 homebrew. It has two layers: a small
Swift API for the things a program does at startup — the text console, the
applet lifecycle, controller input, filesystem mounts, HEN sessions — and the
whole of libnx underneath it, so anything the C API can do is reachable from
Swift.

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

## Requirements

- The Switch 2 Swift SDK, installed with `install-swift-sdk.sh`. It puts the
  libounce and OunceHEN include paths into the toolset, which is what lets this
  package find `<switch.h>` and `<ouncehen.h>`.
- Release builds only. Debug links `SwiftOnoneSupport`, which this port does
  not build.

## Adding it to a package

Put this directory next to your package and add it as a path dependency:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "my-homebrew",
    dependencies: [
        .package(path: "../libounce")
    ],
    targets: [
        .executableTarget(
            name: "my-homebrew",
            dependencies: [.product(name: "Ounce", package: "libounce")]
        )
    ]
)
```

Then build with `switch2-build.sh -c release`, as described in
`docs/swiftpm.md`.

## The mitm and hook framework

`OunceMitm` wraps the man-in-the-middle IPC framework from the
**libounce-mitm** patch set: request parsing, response building for both
serializations, verbatim forwarding, the service-agnostic hook table, the
fsp-srv specialization, and the override and loader paths.

It is a separate product because that framework is not part of every libounce.
A package that does not install the patch set still builds `Ounce`.

```swift
import Ounce
import OunceMitm

let hooks = MitmHookTable()
try hooks.install(interface: FsHookInterface.root.rawValue,
                  command: FsHookCommand.openSdCardFileSystem.rawValue) { ctx in
    // Refuse SD card access.
    _ = ctx.beginResponse(result: ResultCode(0xE01), payloadSize: 0, numHandles: 0)
    return ResultCode(0)
}

let override = try MitmHookOverride()
try override.start(service: "fsp-srv")
try override.serve()
```

| | |
|---|---|
| `MitmService` | A session. Owns both handles and closes them on release. |
| `MitmRequest` | A parsed request. Pointers are only valid until the next one. |
| `MitmDomainTable` | Maps mitm object IDs to the real service's IDs. |
| `MitmHookTable` | (interface, command) to Swift closure handlers. |
| `MitmHookOverride` | The in-process override server. |
| `MitmHookLoaderServer` | The loader-facing server. |
| `FsHookInterface`, `FsHookCommand` | The fsp-srv interface and command IDs. |

Handlers are Swift closures. The framework calls them through a C trampoline,
so a handler can capture context. Return `MitmHookTable.forwardToSession` to
have the request forwarded verbatim to the real service.

**This product needs a libounce built with the patch set.** The headers alone
are not enough: `libounce.a` must contain `mitmDomainTable*`, `mitmHook*`,
`mitmHookOverride*` and `mitmHookLoaderServer*`. Without them the module
compiles and the link fails.

## What is in it

### The whole of libnx

`import Ounce` also brings in every libnx type, constant and function, because
`COunce` re-exports `<switch.h>` and `<ouncehen.h>`. `hidInitialize`,
`svcSleepThread`, `armGetTls`, `HidNpadButton_A`, `AccountUid`, `NroAssetHeader`
— all of it is in scope.

The exception is the declarations libnx marks `NX_INLINE` or `NX_CONSTEXPR`.
Those are `static inline` in C, so they produce no symbol and Swift's Clang
importer cannot call them. All 134 of them are re-exported from the shim as
real functions with an `ounce_` prefix:

| libnx | Swift |
|---|---|
| `padGetButtons` | `ounce_padGetButtons` |
| `padIsConnected` | `ounce_padIsConnected` |
| `smGetService` | `ounce_smGetService` |
| `serviceClose` | `ounce_serviceClose` |
| `jitGetRwAddr` | `ounce_jitGetRwAddr` |
| `hipcMakeBuffer` | `ounce_hipcMakeBuffer` |

Dropping the prefix gives the libnx name. The friendly API below is a thin
layer over the same calls.

One caveat: libnx's `Result` is a `u32` typedef and shadows the standard
library's `Result`. Write `Swift.Result` when you need the latter.

### `Console`

The libnx text console. It is double buffered, so writing only fills the
buffer and nothing appears until `update()` runs. `print(_:)` does both.

| | |
|---|---|
| `initialize()` | Sets up the default console. Call once, first. |
| `print(_:)` | Writes a line and draws it. |
| `write(_:)` | Writes a line without drawing. |
| `update()` | Draws everything written since the last update. |
| `clear()` | Clears the buffer. |
| `exit()` | Restores and releases the console. |

### `Applet`

`Applet.isRunning` is false once the system has asked the program to exit.
Loop on it so HOME and sleep are handled cleanly.

### `Pad`

Controller input. Call `update()` once per frame, then read:

| | |
|---|---|
| `buttons` | Every button currently held. |
| `buttonsDown` | Buttons that went down since the last update. |
| `buttonsUp` | Buttons that came up since the last update. |
| `isConnected` | Whether any controller is connected. |
| `stick(_:)` | Stick position; 0 is left, 1 is right. |

`Button` is an `OptionSet` with one member per `HidNpadButton_*`: `.a`, `.b`,
`.x`, `.y`, `.l`, `.r`, `.zl`, `.zr`, `.plus`, `.minus`, `.up`, `.down`,
`.left`, `.right`, `.stickL`, `.stickR`, the eight `.stickL*`/`.stickR*`
directions, and `.leftSL`, `.leftSR`, `.rightSL`, `.rightSR`.

### `FileSystem`

The console has no descriptor table, so there is no `open`/`read`/`write`.
libnx mounts a filesystem under a device name instead, and the C library's
`fopen` works on paths under it.

```swift
try FileSystem.mountSdCard()
let file = fopen("sdmc:/hello.txt", "w")
```

`unmountAll()` releases every device.

### `HosVersion`

`HosVersion.isOunceHEN` is true when the program is running under OunceHEN.
Check it before using `Hen`.

### `Hen`

A session with OunceHEN. A program started from hbloader gets RO's `ldr:ro`
session as a service override and opens a HEN session through it; a program
started from the plain homebrew menu has no override, so `init()` throws.

```swift
guard Hen.isAvailable else {
    Console.print("Not running under OunceHEN")
    return
}

let hen = try Hen()
let status = try hen.status
Console.print("HEN protocol \(status.protocolVersion)")
```

| | |
|---|---|
| `isAvailable` | True when running under OunceHEN. |
| `status` | HEN's process ID, protocol version and startup result. |
| `filesystemRoot()` | A clone of HEN's filesystem proxy root session. |
| `settingsSession()` | A clone of HEN's `set:sys` session. |
| `processHandle()` | A copy of this program's process handle. |
| `serviceManager()` | A borrowed service-manager session, by copy. |

The four session accessors return a raw `Handle` that the caller owns and must
close. The HEN session itself is closed when the `Hen` object is released, or
by calling `close()`.

### `ResultCode` and `OunceError`

libnx packs a module, a description and a value into one `u32` and treats zero
as success. `ResultCode` exposes `isSuccess`, `module`, `descriptionCode` and
`value`, and prints as hex. The throwing APIs raise `OunceError`, which carries
the code and the operation that failed.

## How it works

`Sources/COunce` is the C surface. It includes `<switch.h>` and `<ouncehen.h>`
and re-exports, as real functions, every accessor libnx marks `NX_INLINE` or
`NX_CONSTEXPR`. Those are `static inline` in C, and Swift's Clang importer
cannot call them — `padGetButtons`, `padIsConnected`, `henGetStatus` and the
rest are all in that category. Everything that is a real symbol
(`consoleInit`, `padUpdate`, `fsdevMountSdmc`, `appletMainLoop`,
`hosversionIsOunceHEN`, `jitCreate`) is used directly from the headers.

`Sources/Ounce` is the Swift API on top. It adds the things C cannot express
here: `Button` as an `OptionSet`, `Stick` as a struct, `Hen` as a class that
owns its session and closes it in `deinit`, and `throws` instead of result
codes.

## Limitations

- **No Foundation.** No `Date`, `Data`, `URL` or `JSONEncoder`. `ResultCode`
  formats its own hex because `String(format:)` is Foundation.
- **No file I/O wrapper.** `FileSystem` mounts devices; reading and writing go
  through the C library's `fopen`/`fread`/`fwrite`, which are not wrapped here.
- **No JIT wrapper.** `jitCreate`, `ounce_jitGetRwAddr` and `ounce_jitGetRxAddr`
  are all reachable, but there is no `Jit` class that owns the mapping and
  frees it. OunceHEN's JIT publishing is the same.
- **No graphics.** Vulkan and EGL are not wrapped. Use the Makefile rules and
  `examples/vulkan-clear` for those.
- **No dispatch sources on file descriptors.** The console has no descriptor
  table. Queues, timers and the manager thread do work.
