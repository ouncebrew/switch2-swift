// A Switch 2 program written in Swift with FoundationEssentials.
//
// It exercises the parts of Foundation that the port builds: dates and
// calendar arithmetic, Data, URLs, JSON and file paths. The libnx functions
// are declared with @_silgen_name because the SDK ships C headers, not a Swift
// module map.
//
// This is a compile and link test first. The output below is also what the
// program prints on hardware, so a run that stops after a line says which
// subsystem failed. Every line is mirrored to sdmc:/foundation-hello.log and
// flushed, so the log survives a crash.

import FoundationEssentials

@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32

@_silgen_name("fsdevMountSdmc")
func fsdevMountSdmc() -> UInt32

@_silgen_name("fopen")
func fopen(_ path: UnsafePointer<CChar>, _ mode: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("fputs")
func fputs(_ text: UnsafePointer<CChar>, _ file: OpaquePointer?) -> Int32

@_silgen_name("fclose")
func fclose(_ file: OpaquePointer?) -> Int32

@_silgen_name("fflush")
func fflush(_ file: OpaquePointer?) -> Int32

/// The SD-card log. The handle is opened once and every line is flushed, so a
/// crash still leaves the last line that ran. The path is at the card root
/// because that always exists; /switch may not on a fresh card.
let logPath = "sdmc:/foundation-hello.log"
var logFile: OpaquePointer?

func openLog() {
    logFile = logPath.withCString { fopen($0, "w") }
    if logFile == nil {
        // __appInit normally mounts the card, but a standalone NRO launched
        // from the homebrew menu may not have it yet. Mount and retry once.
        _ = fsdevMountSdmc()
        logFile = logPath.withCString { fopen($0, "w") }
    }
}

func print(_ text: String) {
    text.withCString { _ = puts($0) }

    guard let logFile else { return }
    text.withCString { _ = fputs($0, logFile) }
    "\n".withCString { _ = fputs($0, logFile) }
    _ = fflush(logFile)
}

struct Save: Codable, Equatable {
    var name: String
    var score: Int
    var played: Date
}

@_cdecl("main")
public func main() -> Int32 {
    _ = consoleInit(nil)
    openLog()
    if logFile != nil {
        print("log: sdmc:/foundation-hello.log")
    } else {
        print("log: unavailable (console only)")
    }

    print("FoundationEssentials on Switch 2")

    // Date is seconds since 1970 on both platforms; this does not need a
    // time zone database.
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    print("date: \(epoch.timeIntervalSince1970)")

    // Data and String.
    let bytes = Data([0x53, 0x77, 0x69, 0x66, 0x74])
    let word = String(decoding: bytes, as: UTF8.self)
    print("data: \(word) (\(bytes.count) bytes)")

    // URL. Percent-encoding is Foundation's, not the standard library's, and
    // it is the part of the port most likely to differ from a host.
    if let url = URL(string: "https://example.com/a%20b?q=1") {
        print("url: \(url.absoluteString)")
        print("host: \(url.host ?? "-")")
    }

    // JSON round trip.
    let save = Save(name: "switch", score: 2, played: epoch)
    do {
        let encoded = try JSONEncoder().encode(save)
        print("json bytes: \(encoded.count)")
        let decoded = try JSONDecoder().decode(Save.self, from: encoded)
        print("json name: \(decoded.name), score: \(decoded.score)")
    } catch {
        print("json failed: \(error)")
    }

    // URL file paths, which exercise URL's path encoding.
    let fileURL = URL(fileURLWithPath: "/switch/roms/game.nro")
    print("file name: \(fileURL.lastPathComponent)")
    print("path: \(fileURL.path)")

    if let logFile {
        _ = fclose(logFile)
    }
    consoleExit(nil)
    return 0
}
