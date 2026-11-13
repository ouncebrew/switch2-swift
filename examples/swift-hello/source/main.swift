// A minimal Switch 2 program written in Swift.
//
// Embedded Swift has no String, so text is passed to the C library as a
// StaticString. The libnx functions are declared with @_silgen_name because
// the SDK ships C headers, not a Swift module map.

@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32

func print(_ text: StaticString) {
    _ = puts(UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self))
}

struct Counter {
    var value: Int32 = 0

    mutating func add(_ amount: Int32) {
        value += amount
    }
}

@_cdecl("main")
public func main() -> Int32 {
    _ = consoleInit(nil)

    print("Hello from Swift on Switch 2")

    var counter = Counter()
    for step in 1...10 {
        counter.add(Int32(step))
    }

    print(counter.value == 55 ? "sum ok" : "sum wrong")

    consoleExit(nil)
    return 0
}
