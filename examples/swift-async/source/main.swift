// A Switch 2 program that uses Swift concurrency.
//
// The console has no libdispatch and no pthreads, so the runtime uses the
// cooperative global executor. Tasks are queued, and the program runs them by
// donating its thread with swift_task_donateThreadToGlobalExecutorUntil. That
// call returns when the condition becomes true or the queue is empty.

import _Concurrency

@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32

@_silgen_name("swift_task_donateThreadToGlobalExecutorUntil")
func donateThread(_ condition: @convention(c) (UnsafeMutableRawPointer?) -> Bool,
                  _ context: UnsafeMutableRawPointer?)

func print(_ text: String) {
    text.withCString { _ = puts($0) }
}

var finished = false

/// Runs queued tasks until `finished` is set or the queue drains.
func drainExecutor() {
    donateThread({ _ in finished }, nil)
}

func sum(to limit: Int) async -> Int {
    var total = 0
    for value in 1...limit {
        total += value
    }
    return total
}

func describe(_ value: Int) async -> String {
    "the sum is \(value)"
}

@_cdecl("main")
public func main() -> Int32 {
    _ = consoleInit(nil)
    print("Swift concurrency on Switch 2")

    Task {
        let total = await sum(to: 10)
        let text = await describe(total)
        print(text)
        finished = true
    }

    drainExecutor()
    print("executor drained")

    consoleExit(nil)
    return 0
}
