// A Switch 2 program written in Swift with the full standard library.
//
// Unlike examples/swift-hello, this one uses String, arrays, closures and
// string interpolation. The libnx functions are declared with @_silgen_name
// because the SDK ships C headers, not a Swift module map.

@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32

func print(_ text: String) {
    text.withCString { _ = puts($0) }
}

struct Player {
    let name: String
    var score: Int

    var summary: String {
        "\(name): \(score) points"
    }
}

@_cdecl("main")
public func main() -> Int32 {
    _ = consoleInit(nil)

    let players = [
        Player(name: "Switch", score: 2),
        Player(name: "Swift", score: 6),
    ]

    print("Hello from Swift on Switch 2")

    for player in players {
        print(player.summary)
    }

    let total = players.map(\.score).reduce(0, +)
    print("total: \(total)")

    let sorted = players.sorted { $0.score > $1.score }
    print("best: \(sorted[0].name)")

    consoleExit(nil)
    return 0
}
