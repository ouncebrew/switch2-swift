// A Switch 2 program that performs an HTTPS GET with the port's
// FoundationNetworking.
//
// It is the network counterpart to foundation-hello: the request is real (the
// URLSession code path, the libnx socket transport and the console's ssl
// service), so a run on hardware says whether the whole stack works. The log
// is flushed after every line, so the last line reached survives a crash.
//
// The async API is used for symmetry with Foundation, but this port executes a
// request synchronously: the console has one cooperative executor, and
// blocking it on a socket would starve every other task. See URLSession.swift.

import FoundationEssentials
import FoundationNetworking

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

let logPath = "sdmc:/foundation-network.log"
var logFile: OpaquePointer?

func openLog() {
    logFile = logPath.withCString { fopen($0, "w") }
    if logFile == nil {
        _ = fsdevMountSdmc()
        logFile = logPath.withCString { fopen($0, "w") }
    }
}

func log(_ text: String) {
    text.withCString { _ = puts($0) }

    guard let logFile else { return }
    text.withCString { _ = fputs($0, logFile) }
    "\n".withCString { _ = fputs($0, logFile) }
    _ = fflush(logFile)
}

@main
struct FoundationNetworkHello {
    static func main() async {
        _ = consoleInit(nil)
        openLog()
        if logFile != nil {
            log("log: sdmc:/foundation-network.log")
        } else {
            log("log: unavailable (console only)")
        }

        log("FoundationNetworking on Switch 2")

        guard let url = URL(string: "https://example.com/") else {
            log("url: failed")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse {
                log("status: \(http.statusCode)")
                log("type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "-")")
            } else {
                log("status: not an HTTP response")
            }
            log("body: \(data.count) bytes")
            let text = String(decoding: data, as: UTF8.self)
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? "-"
            log("first line: \(firstLine)")
        } catch let error as URLError {
            log("request failed: \(error.code.rawValue) \(error)")
        } catch {
            log("request failed: \(error)")
        }

        if let logFile {
            _ = fclose(logFile)
        }
        consoleExit(nil)
    }
}
