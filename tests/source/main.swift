// Switch 2 Swift toolchain test suite.
//
// This runs on the console, not on the host. It prints to the libnx console and
// appends every line to sdmc:/switch2-swift-tests.log, so a crash still leaves
// a record of the last test that started.
//
// Build:  make -C tests
// Run:    copy tests/switch2-swift-tests.nro to the SD card and launch it.
//         Press + to exit.
//
// Filter: put a substring in sdmc:/switch2-swift-tests.cfg to run only the
//         tests whose name contains it. One line, no quotes. This is how you
//         re-run a single failing test without rebuilding.
//
// The C half of the suite (libdispatch, pthreads) is in ctests.c. It reports
// through the callback at the bottom of this file so that everything lands in
// one log.

import _Concurrency

// MARK: - libnx bindings

@_silgen_name("consoleInit")
func consoleInit(_ console: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("consoleUpdate")
func consoleUpdate(_ console: UnsafeMutableRawPointer?)

@_silgen_name("consoleClear")
func consoleClear()

@_silgen_name("consoleExit")
func consoleExit(_ console: UnsafeMutableRawPointer?)

@_silgen_name("puts")
func puts(_ text: UnsafePointer<CChar>) -> Int32

@_silgen_name("fsdevMountSdmc")
func fsdevMountSdmc() -> UInt32

@_silgen_name("fopen")
func fopen(_ path: UnsafePointer<CChar>, _ mode: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("fgets")
func fgets(_ buffer: UnsafeMutablePointer<CChar>, _ size: Int32, _ file: OpaquePointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("fputs")
func fputs(_ text: UnsafePointer<CChar>, _ file: OpaquePointer?) -> Int32

@_silgen_name("fclose")
func fclose(_ file: OpaquePointer?) -> Int32

@_silgen_name("fflush")
func fflush(_ file: OpaquePointer?) -> Int32

@_silgen_name("swift_task_donateThreadToGlobalExecutorUntil")
func donateThread(_ condition: @convention(c) (UnsafeMutableRawPointer?) -> Bool,
                  _ context: UnsafeMutableRawPointer?)

@_silgen_name("appletMainLoop")
func appletMainLoop() -> Bool

// padshim.c. padInitializeDefault and padGetButtonsDown are inline in the
// libnx headers, so they have no symbol to bind to.
@_silgen_name("testpad_init")
func testpad_init()

@_silgen_name("testpad_plus_pressed")
func testpad_plus_pressed() -> Bool

// ctests.c
@_silgen_name("run_dispatch_tests")
func run_dispatch_tests(_ report: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void)

@_silgen_name("run_thread_tests")
func run_thread_tests(_ report: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void)

// MARK: - Reporting

var logEnabled = false
var checks = 0
var failures = 0
var currentTest = ""
var filter = ""

let logPath = "sdmc:/switch2-swift-tests.log"

/// Writes one line to the console and to the log. The console update is what
/// makes a crash point visible: whatever was printed last is on screen when the
/// program dies.
func emit(_ line: String) {
    line.withCString { _ = puts($0) }
    appendToLog(line)
    consoleUpdate(nil)
}

/// Appends one line, opening and closing the file each time rather than holding
/// it open for the life of the program.
///
/// A file that a running process still has open reads back over FTP as an I/O
/// error, and a crash never reaches the fclose at the end of main, so a log held
/// open is a log that cannot be retrieved from the machine that just crashed.
/// Opening per line costs one FS round trip and leaves the file closed and its
/// directory entry committed at every point a crash can happen.
func appendToLog(_ line: String) {
    guard logEnabled else { return }
    guard let file = logPath.withCString({ fopen($0, "a") }) else { return }
    line.withCString { _ = fputs($0, file) }
    "\n".withCString { _ = fputs($0, file) }
    _ = fflush(file)
    _ = fclose(file)
}

func fail(_ message: String) {
    failures += 1
    emit("     FAIL \(message)")
}

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fail(message) }
}

func checkEqual(_ actual: Int, _ expected: Int, _ message: String) {
    checks += 1
    if actual != expected { fail("\(message): expected \(expected), got \(actual)") }
}

func checkEqual(_ actual: String, _ expected: String, _ message: String) {
    checks += 1
    if actual != expected { fail("\(message): expected \"\(expected)\", got \"\(actual)\"") }
}

func checkEqual(_ actual: Bool, _ expected: Bool, _ message: String) {
    checks += 1
    if actual != expected { fail("\(message): expected \(expected), got \(actual)") }
}

func checkEqual(_ actual: Double, _ expected: Double, _ message: String) {
    checks += 1
    if actual != expected { fail("\(message): expected \(expected), got \(actual)") }
}

/// For types without a printable form. Keeps the failure path free of
/// reflection, so a broken Mirror cannot mask a real failure.
func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checks += 1
    if actual != expected { fail("\(message): values differ") }
}

// MARK: - Test registry

struct Test {
    let name: String
    let body: () throws -> Void
}

struct AsyncTest {
    let name: String
    let body: () async throws -> Void
}

var tests: [Test] = []
var asyncTests: [AsyncTest] = []

func test(_ name: String, _ body: @escaping () throws -> Void) {
    tests.append(Test(name: name, body: body))
}

func asyncTest(_ name: String, _ body: @escaping () async throws -> Void) {
    asyncTests.append(AsyncTest(name: name, body: body))
}

func selected(_ name: String) -> Bool {
    filter.isEmpty || containsSubstring(name, filter)
}

/// String.contains(String) is not a standard library API, so the filter needs
/// its own search.
func containsSubstring(_ haystack: String, _ needle: String) -> Bool {
    if needle.isEmpty { return true }
    let h = Array(haystack)
    let n = Array(needle)
    guard n.count <= h.count else { return false }
    var start = 0
    while start + n.count <= h.count {
        var i = 0
        while i < n.count && h[start + i] == n[i] { i += 1 }
        if i == n.count { return true }
        start += 1
    }
    return false
}

// MARK: - Runner

var asyncDone = false

func run(_ t: Test) {
    guard selected(t.name) else { return }
    currentTest = t.name
    emit("RUN  \(t.name)")
    let before = failures
    do {
        try t.body()
    } catch {
        fail("threw \(error)")
    }
    if failures == before { emit("     ok") }
}

func run(_ t: AsyncTest) {
    guard selected(t.name) else { return }
    currentTest = t.name
    emit("RUN  \(t.name)")
    let before = failures
    asyncDone = false
    // Logged around each step: a trap here is a bare brk with no report, so the
    // last line printed is the only evidence of where it died.
    emit("     creating the task")
    Task {
        do {
            try await t.body()
        } catch {
            fail("threw \(error)")
        }
        asyncDone = true
    }
    emit("     task created, donating the thread")
    // Returns when the task finishes or the queue drains. If it drains with the
    // task still suspended, the task is stuck and that is a failure.
    donateThread({ _ in asyncDone }, nil)
    emit("     executor returned")
    if !asyncDone {
        fail("never finished: the executor drained with the task still suspended")
    }
    if failures == before { emit("     ok") }
}

// MARK: - Core language

func registerCore() {
    test("core/global-init") {
        checkEqual(globalInitialized, 42, "global initializer ran")
    }

    test("core/struct") {
        struct Point: Equatable {
            var x: Int
            var y: Int
            var lengthSquared: Int { x * x + y * y }
        }
        let p = Point(x: 3, y: 4)
        checkEqual(p.lengthSquared, 25, "computed property")
        checkEqual(p, Point(x: 3, y: 4), "memberwise equality")
    }

    test("core/class-inheritance") {
        class Base {
            func name() -> String { "base" }
            func describe() -> String { "I am \(name())" }
        }
        class Derived: Base {
            override func name() -> String { "derived" }
        }
        let objects: [Base] = [Base(), Derived()]
        checkEqual(objects[0].describe(), "I am base", "base dispatch")
        checkEqual(objects[1].describe(), "I am derived", "vtable dispatch")
    }

    test("core/protocol-existential") {
        protocol Shape {
            var area: Int { get }
        }
        struct Square: Shape {
            let side: Int
            var area: Int { side * side }
        }
        struct Rect: Shape {
            let w: Int, h: Int
            var area: Int { w * h }
        }
        let shapes: [Shape] = [Square(side: 3), Rect(w: 2, h: 5)]
        checkEqual(shapes.map(\.area).reduce(0, +), 19, "witness table dispatch")
    }

    test("core/generics") {
        func largest<T: Comparable>(_ items: [T]) -> T? {
            guard var best = items.first else { return nil }
            for item in items.dropFirst() where item > best { best = item }
            return best
        }
        checkEqual(largest([3, 9, 2]) ?? 0, 9, "generic over Int")
        checkEqual(largest(["a", "z", "m"]) ?? "", "z", "generic over String")
    }

    test("core/closures") {
        var counter = 0
        let bump = { counter += 1 }
        bump(); bump(); bump()
        checkEqual(counter, 3, "captured var")
        let add = { (a: Int, b: Int) -> Int in a + b }
        checkEqual(add(2, 3), 5, "closure value")
    }

    test("core/enum-associated") {
        enum Message {
            case quit
            case move(x: Int, y: Int)
            case text(String)
        }
        func describe(_ m: Message) -> String {
            switch m {
            case .quit: return "quit"
            case .move(let x, let y): return "move \(x),\(y)"
            case .text(let s): return "text \(s)"
            }
        }
        checkEqual(describe(.quit), "quit", "no payload")
        checkEqual(describe(.move(x: 1, y: 2)), "move 1,2", "labelled payload")
        checkEqual(describe(.text("hi")), "text hi", "string payload")
    }

    test("core/error-handling") {
        enum Failure: Error { case bad(Int) }
        func risky(_ n: Int) throws -> Int {
            if n < 0 { throw Failure.bad(n) }
            return n * 2
        }
        checkEqual(try? risky(4), 8, "success path")
        var caught = false
        do {
            _ = try risky(-1)
        } catch Failure.bad(let n) {
            caught = n == -1
        } catch {
            caught = false
        }
        check(caught, "typed catch")
    }

    test("core/keypath") {
        struct Row { let id: Int; let label: String }
        let rows = [Row(id: 2, label: "b"), Row(id: 1, label: "a")]
        let ids = rows.map(\.id)
        checkEqual(ids, [2, 1], "key path map")
        let sorted = rows.sorted { $0.id < $1.id }
        checkEqual(sorted[0].label, "a", "sorted by key path value")
    }

    // There is no core/mirror test: the installed Swift.swiftmodule was built
    // without SWIFT_ENABLE_REFLECTION, so Mirror is marked unavailable. The
    // build script passes the flag now, so a rebuild turns it back on. Add the
    // test back once the artifacts are newer than swift/full/build-stdlib.sh.

    test("core/arc-weak") {
        class Node { var next: Node?; let id: Int; init(id: Int) { self.id = id } }
        weak var weakRef: Node?
        do {
            let node = Node(id: 7)
            weakRef = node
            checkEqual(weakRef?.id ?? -1, 7, "weak reference alive")
        }
        check(weakRef == nil, "weak reference cleared after release")
    }

    test("core/deinit") {
        final class Tracker {
            static var count = 0
            deinit { Tracker.count += 1 }
        }
        Tracker.count = 0
        for _ in 0..<5 { _ = Tracker() }
        checkEqual(Tracker.count, 5, "deinit ran for every instance")
    }

    test("core/property-observer") {
        var seen: [Int] = []
        var value = 0 {
            didSet { seen.append(value) }
        }
        value = 1
        value = 2
        checkEqual(seen, [1, 2], "didSet fired")
    }

    test("core/lazy") {
        lazyRuns = 0
        final class Holder {
            lazy var expensive: Int = { lazyRuns += 1; return 99 }()
        }
        let holder = Holder()
        checkEqual(holder.expensive, 99, "lazy value")
        _ = holder.expensive
        checkEqual(lazyRuns, 1, "lazy initializer ran once")
    }

    test("core/subscript") {
        struct Grid {
            var cells = [Int](repeating: 0, count: 9)
            subscript(x: Int, y: Int) -> Int {
                get { cells[y * 3 + x] }
                set { cells[y * 3 + x] = newValue }
            }
        }
        var grid = Grid()
        grid[1, 2] = 5
        checkEqual(grid[1, 2], 5, "subscript round trip")
    }

    test("core/pattern-matching") {
        func classify(_ value: Int) -> String {
            switch value {
            case 0: return "zero"
            case 1..<10: return "small"
            case let n where n % 5 == 0: return "multiple of five"
            default: return "other"
            }
        }
        checkEqual(classify(0), "zero", "literal case")
        checkEqual(classify(3), "small", "range case")
        checkEqual(classify(15), "multiple of five", "where clause")
        checkEqual(classify(7), "small", "range beats where")
        checkEqual(classify(13), "other", "default case")
    }

    test("core/tuple") {
        let pair = (name: "swift", version: 6)
        checkEqual(pair.name, "swift", "labelled tuple element")
        let (a, b) = (1, 2)
        checkEqual(a + b, 3, "tuple destructuring")
    }

    test("core/static-init") {
        struct Registry {
            static let values: [Int] = (0..<4).map { $0 * $0 }
        }
        checkEqual(Registry.values, [0, 1, 4, 9], "static stored property")
    }
}

var globalInitialized: Int = { 40 + 2 }()
var lazyRuns = 0

// MARK: - Strings and Unicode

func registerStrings() {
    test("string/basic") {
        var s = "hello"
        s += ", world"
        checkEqual(s.count, 12, "count")
        checkEqual(s.uppercased(), "HELLO, WORLD", "uppercased")
        check(s.hasPrefix("hello"), "hasPrefix")
        check(s.hasSuffix("world"), "hasSuffix")
    }

    test("string/interpolation") {
        let n = 7
        let d = 2.5
        let text = "n=\(n) d=\(d) sum=\(n + 1)"
        checkEqual(text, "n=7 d=2.5 sum=8", "interpolation")
    }

    test("string/unicode") {
        let emoji = "🇯🇵🇬🇧"
        checkEqual(emoji.count, 2, "flag grapheme clusters")
        let family = "👨‍👩‍👧‍👦"
        checkEqual(family.count, 1, "ZWJ sequence is one grapheme")
        let combining = "e\u{301}"
        checkEqual(combining.count, 1, "combining acute is one grapheme")
        checkEqual(combining, "é", "combining form equals precomposed")
    }

    test("string/utf8") {
        let text = "héllo"
        checkEqual(text.utf8.count, 6, "utf8 byte count")
        checkEqual(Array(text.utf8).count, 6, "utf8 view")
        checkEqual(String(decoding: Array(text.utf8), as: UTF8.self), text, "utf8 round trip")
    }

    test("string/compare") {
        check("apple" < "banana", "lexicographic")
        check("Z" < "a", "uppercase sorts before lowercase")
        checkEqual("same", "same", "equality")
        check("abc" != "abd", "inequality")
    }

    test("string/split-join") {
        let parts = "a,b,,c".split(separator: ",", omittingEmptySubsequences: false)
        checkEqual(parts.count, 4, "split keeps empty field")
        checkEqual(parts.joined(separator: "-"), "a-b--c", "join")
    }

    test("string/substring") {
        let text = "switch2"
        let prefix = text.prefix(6)
        checkEqual(String(prefix), "switch", "prefix")
        checkEqual(String(text.suffix(1)), "2", "suffix")
        checkEqual(String(text.dropFirst(6)), "2", "dropFirst")
    }

    test("string/character-properties") {
        check("a".first!.isLetter, "isLetter")
        check("7".first!.isNumber, "isNumber")
        check(" ".first!.isWhitespace, "isWhitespace")
        checkEqual("A".first!.asciiValue ?? 0, 65, "asciiValue")
    }

    test("string/replace") {
        // replacingOccurrences is Foundation, so this goes through split/join.
        let text = "the cat sat on the mat"
        let replaced = text.split(separator: " ")
            .map { $0 == "cat" ? "dog" : String($0) }
            .joined(separator: " ")
        checkEqual(replaced, "the dog sat on the mat", "word replacement")
    }

    test("string/hash") {
        var seen = Set<String>()
        for i in 0..<200 { seen.insert("key\(i)") }
        checkEqual(seen.count, 200, "string hashing has no collisions here")
    }
}

// MARK: - Collections

func registerCollections() {
    test("collection/array") {
        var a = [1, 2, 3]
        a.append(4)
        a.insert(0, at: 0)
        a.remove(at: 2)
        // [1,2,3] -> append 4 -> [1,2,3,4] -> insert 0 at 0 -> [0,1,2,3,4]
        // -> remove index 2, which holds 2 -> [0,1,3,4].
        // Compared element by element so a failure names the index.
        checkEqual(a.count, 4, "append/insert/remove count")
        checkEqual(a[0], 0, "append/insert/remove [0]")
        checkEqual(a[1], 1, "append/insert/remove [1]")
        checkEqual(a[2], 3, "append/insert/remove [2]")
        checkEqual(a[3], 4, "append/insert/remove [3]")
        checkEqual(a.first ?? -1, 0, "first")
        checkEqual(a.last ?? -1, 4, "last")
    }

    test("collection/array-growth") {
        var a: [Int] = []
        for i in 0..<10_000 { a.append(i) }
        checkEqual(a.count, 10_000, "count after growth")
        checkEqual(a[9_999], 9_999, "last element")
        checkEqual(a.reduce(0, +), 49_995_000, "sum")
    }

    test("collection/dictionary") {
        var d: [String: Int] = [:]
        for i in 0..<500 { d["k\(i)"] = i }
        checkEqual(d.count, 500, "dictionary count")
        checkEqual(d["k250"] ?? -1, 250, "lookup")
        d["k250"] = nil
        checkEqual(d.count, 499, "removal")
        check(d["missing"] == nil, "missing key is nil")
    }

    test("collection/set") {
        var s = Set<Int>()
        for i in 0..<300 { s.insert(i % 100) }
        checkEqual(s.count, 100, "set deduplicates")
        check(s.contains(42), "contains")
        checkEqual(s.union([100, 101]).count, 102, "union")
    }

    test("collection/sort") {
        let values = [5, 3, 9, 1, 7]
        checkEqual(values.sorted(), [1, 3, 5, 7, 9], "sorted")
        checkEqual(values.sorted(by: >), [9, 7, 5, 3, 1], "sorted descending")
        var mutable = values
        mutable.sort()
        checkEqual(mutable, [1, 3, 5, 7, 9], "in-place sort")
    }

    test("collection/higher-order") {
        let values = Array(1...10)
        checkEqual(values.map { $0 * 2 }.reduce(0, +), 110, "map+reduce")
        checkEqual(values.filter { $0 % 2 == 0 }.count, 5, "filter")
        checkEqual(values.first { $0 > 6 } ?? -1, 7, "first where")
        check(values.allSatisfy { $0 > 0 }, "allSatisfy")
    }

    test("collection/lazy") {
        var evaluations = 0
        let result = (1...100).lazy.map { n -> Int in
            evaluations += 1
            return n * 2
        }.prefix(3)
        checkEqual(Array(result), [2, 4, 6], "lazy prefix")
        checkEqual(evaluations, 3, "lazy evaluated only what was needed")
    }

    test("collection/slice") {
        let values = [0, 1, 2, 3, 4, 5]
        let slice = values[2..<5]
        checkEqual(Array(slice), [2, 3, 4], "range subscript")
        checkEqual(slice.startIndex, 2, "slice keeps parent indices")
    }

    test("collection/hashable-custom") {
        struct Key: Hashable {
            let a: Int
            let b: String
        }
        var d: [Key: Int] = [:]
        d[Key(a: 1, b: "x")] = 10
        d[Key(a: 1, b: "x")] = 20
        checkEqual(d.count, 1, "synthesized Hashable deduplicates")
        checkEqual(d[Key(a: 1, b: "x")] ?? -1, 20, "synthesized Hashable lookup")
    }

    test("collection/string-keys") {
        var d: [String: [Int]] = [:]
        for i in 0..<100 { d["group\(i % 10)", default: []].append(i) }
        checkEqual(d.count, 10, "grouped keys")
        checkEqual(d["group0"]?.count ?? -1, 10, "group size")
    }
}

// MARK: - Numerics

func registerNumerics() {
    test("numeric/integers") {
        checkEqual(Int.max, 9_223_372_036_854_775_807, "Int is 64-bit")
        checkEqual(Int.min, -9_223_372_036_854_775_808, "Int.min")
        checkEqual(7 / 2, 3, "integer division truncates")
        checkEqual(-7 % 3, -1, "remainder keeps sign")
    }

    test("numeric/overflow") {
        checkEqual(Int.max &+ 1, Int.min, "wrapping add")
        checkEqual(Int.min &- 1, Int.max, "wrapping subtract")
        checkEqual(UInt8(200) &* 2, 144, "wrapping multiply")
    }

    test("numeric/double") {
        checkEqual(0.1 + 0.2 == 0.3, false, "binary floating point is inexact")
        check(abs((0.1 + 0.2) - 0.3) < 1e-9, "within epsilon")
        checkEqual((2.0).squareRoot(), 1.4142135623730951, "sqrt")
        check(Double.infinity > Double.greatestFiniteMagnitude, "infinity")
        check(Double.nan.isNaN, "nan")
    }

    test("numeric/conversion") {
        checkEqual(Int(3.99), 3, "truncating conversion")
        checkEqual(Double(7) / 2.0, 3.5, "double division")
        checkEqual(Int8(bitPattern: 0xFF), -1, "bit pattern conversion")
        checkEqual(UInt32(4_294_967_295), UInt32.max, "UInt32 max")
    }

    test("numeric/bitwise") {
        checkEqual(0b1010 & 0b1100, 0b1000, "and")
        checkEqual(0b1010 | 0b0101, 0b1111, "or")
        checkEqual(1 << 10, 1024, "shift")
        checkEqual(0xFF.nonzeroBitCount, 8, "popcount")
        checkEqual(0b1000.trailingZeroBitCount, 3, "trailing zeros")
    }

    test("numeric/random") {
        // SystemRandomNumberGenerator needs entropy. If this hangs or returns
        // the same value every time, the port has no working entropy source.
        var generator = SystemRandomNumberGenerator()
        var seen = Set<Int>()
        for _ in 0..<32 { seen.insert(Int.random(in: 0..<1_000_000, using: &generator)) }
        check(seen.count > 28, "random produced varied values")
    }
}

// MARK: - Memory

func registerMemory() {
    test("memory/alloc-small") {
        for size in [1, 7, 16, 64, 255] {
            let p = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            p.storeBytes(of: UInt8(0xAB), as: UInt8.self)
            checkEqual(p.load(as: UInt8.self), 0xAB, "alloc \(size) bytes")
            p.deallocate()
        }
    }

    test("memory/alloc-large") {
        let bytes = 16 * 1024 * 1024
        let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        p.storeBytes(of: UInt32(0xDEADBEEF), as: UInt32.self)
        checkEqual(p.load(as: UInt32.self), 0xDEADBEEF, "16 MB allocation")
        p.deallocate()
    }

    test("memory/alloc-many") {
        var pointers: [UnsafeMutableRawPointer] = []
        for _ in 0..<2_000 {
            pointers.append(UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8))
        }
        checkEqual(pointers.count, 2_000, "2000 live allocations")
        for p in pointers { p.deallocate() }
    }

    test("memory/posix-memalign") {
        // The shim in swift_shim.c. newlib has no posix_memalign, and the Swift
        // runtime calls it.
        var raw: UnsafeMutableRawPointer?
        let result = posix_memalign(&raw, 64, 1024)
        checkEqual(result, 0, "posix_memalign returned success")
        check(raw != nil, "posix_memalign produced a pointer")
        if let p = raw {
            checkEqual(Int(bitPattern: p) % 64, 0, "result is 64-byte aligned")
            free(p)
        }
    }

    test("memory/array-large") {
        let count = 1_000_000
        var values = [Int](repeating: 0, count: count)
        for i in 0..<count { values[i] = i & 0xFF }
        checkEqual(values.count, count, "million element array")
        checkEqual(values[999_999], 999_999 & 0xFF, "last element")
    }

    test("memory/string-churn") {
        var total = 0
        for i in 0..<5_000 {
            let s = "value-\(i)"
            total += s.count
        }
        check(total > 0, "5000 temporary strings")
    }
}

@_silgen_name("posix_memalign")
func posix_memalign(_ pointer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, _ alignment: Int, _ size: Int) -> Int32

@_silgen_name("free")
func free(_ pointer: UnsafeMutableRawPointer?)

// MARK: - Concurrency

/// File scope, not local: `async let` requires the callee to be Sendable, and a
/// local function cannot be marked as such.
func slowAdd(_ n: Int) async -> Int {
    // Logged so the async-let test can tell "the child never ran" from "the
    // child ran but the await never noticed".
    emit("     slowAdd(\(n)) running")
    return n + 1
}

func registerConcurrency() {
    asyncTest("concurrency/async-basic") {
        func double(_ n: Int) async -> Int { n * 2 }
        let result = await double(21)
        checkEqual(result, 42, "await a simple async function")
    }

    asyncTest("concurrency/async-throws") {
        struct Boom: Error {}
        func boom() async throws -> Int { throw Boom() }
        var caught = false
        do {
            _ = try await boom()
        } catch {
            caught = true
        }
        check(caught, "async throw propagates")
    }

    asyncTest("concurrency/async-let") {
        // async let creates a child task rather than a plain one, so it takes a
        // different path through swift_task_create_common. Logged step by step
        // because a trap here is a bare brk with no report.
        emit("     body: creating async let a")
        async let a = slowAdd(1)
        emit("     body: creating async let b")
        async let b = slowAdd(2)
        emit("     body: awaiting a")
        let av = await a
        emit("     body: awaiting b")
        let bv = await b
        emit("     body: got b")
        emit("     body: a = \(av), b = \(bv)")
        checkEqual(av + bv, 5, "async let runs both")
        emit("     body: checks done, leaving scope")
    }

    asyncTest("concurrency/task-group") {
        func square(_ n: Int) async -> Int { n * n }
        let total = await withTaskGroup(of: Int.self) { group in
            for i in 1...5 { group.addTask { await square(i) } }
            var sum = 0
            for await value in group { sum += value }
            return sum
        }
        checkEqual(total, 55, "task group sum of squares")
    }

    asyncTest("concurrency/task-detached") {
        let value = await Task.detached { 7 * 6 }.value
        checkEqual(value, 42, "detached task value")
    }

    asyncTest("concurrency/actor") {
        actor Counter {
            private var value = 0
            func increment() -> Int {
                value += 1
                return value
            }
        }
        let counter = Counter()
        let first = await counter.increment()
        let second = await counter.increment()
        checkEqual(first, 1, "actor first call")
        checkEqual(second, 2, "actor state persisted")
    }

    asyncTest("concurrency/yield") {
        // Task.yield() re-enqueues the current task and suspends it, so it is
        // the smallest thing that needs the executor to resume a task it
        // suspended itself. actor-reentrancy is the first test that uses it.
        emit("     body: before yield")
        await Task.yield()
        emit("     body: after yield")
        check(true, "yield resumed")
    }

    asyncTest("concurrency/actor-reentrancy") {
        actor Store {
            private var items: [Int] = []
            func add(_ n: Int) async {
                items.append(n)
                await Task.yield()
                items.append(n * 10)
            }
            func snapshot() -> [Int] { items }
        }
        let store = Store()
        await store.add(1)
        await store.add(2)
        let items = await store.snapshot()
        checkEqual(items.count, 4, "actor survived suspension points")
    }

    asyncTest("concurrency/cancellation") {
        let task = Task {
            var spins = 0
            while !Task.isCancelled && spins < 1_000_000 {
                spins += 1
                await Task.yield()
            }
            return Task.isCancelled
        }
        task.cancel()
        let wasCancelled = await task.value
        check(wasCancelled, "Task.isCancelled observed")
    }

    asyncTest("concurrency/continuation") {
        func answer() async -> Int {
            await withCheckedContinuation { continuation in
                continuation.resume(returning: 42)
            }
        }
        checkEqual(await answer(), 42, "checked continuation")
    }

    asyncTest("concurrency/async-stream") {
        func numbers() -> AsyncStream<Int> {
            AsyncStream { continuation in
                for i in 1...4 { continuation.yield(i) }
                continuation.finish()
            }
        }
        var collected: [Int] = []
        for await n in numbers() { collected.append(n) }
        checkEqual(collected, [1, 2, 3, 4], "async stream")
    }

    asyncTest("concurrency/task-local") {
        let value = await TaskLocalValues.$number.withValue(99) {
            await TaskLocalValues.read()
        }
        checkEqual(value, 99, "task local value")
    }
}

enum TaskLocalValues {
    @TaskLocal static var number: Int = 0
    static func read() async -> Int { number }
}

// MARK: - C tests

let reportCallback: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void = { name, ok, detail in
    checks += 1
    if ok == 0 {
        failures += 1
        let label = name.map { String(cString: $0) } ?? "?"
        let why = detail.map { String(cString: $0) } ?? ""
        emit("     FAIL \(label): \(why)")
    }
}

// MARK: - Entry point

func readFilter() -> String {
    guard let file = "sdmc:/switch2-swift-tests.cfg".withCString({ fopen($0, "r") }) else {
        return ""
    }
    defer { _ = fclose(file) }
    var buffer = [CChar](repeating: 0, count: 256)
    guard fgets(&buffer, 256, file) != nil else { return "" }
    var text = String(cString: buffer)
    while let last = text.last, last == "\n" || last == "\r" || last == " " {
        text.removeLast()
    }
    return text
}

@_silgen_name("fault_install")
func fault_install(_ path: UnsafePointer<CChar>?)

@_cdecl("main")
public func main() -> Int32 {
    _ = consoleInit(nil)
    testpad_init()
    "sdmc:/fault-suite.log".withCString { fault_install($0) }

    // __appInit already calls fsdevMountSdmc before constructors run, so
    // calling it again returns "already mounted" and looks like a failure.
    // Open the file first and only mount if that fails. This open truncates any
    // log from a previous run; every later write appends and closes.
    var probe = logPath.withCString { fopen($0, "w") }
    if probe == nil {
        _ = fsdevMountSdmc()
        probe = logPath.withCString { fopen($0, "w") }
    }
    logEnabled = probe != nil
    if let file = probe { _ = fclose(file) }

    emit("Switch 2 Swift toolchain tests")
    emit(logEnabled ? "log: sdmc:/switch2-swift-tests.log" : "no log file: console only")

    filter = readFilter()
    if !filter.isEmpty { emit("filter: \(filter)") }

    registerCore()
    registerStrings()
    registerCollections()
    registerNumerics()
    registerMemory()
    registerConcurrency()

    emit("")
    emit("-- language, strings, collections, numerics, memory --")
    for t in tests { run(t) }

    emit("")
    emit("-- concurrency --")
    for t in asyncTests { run(t) }

    emit("")
    emit("-- libdispatch --")
    run_dispatch_tests(reportCallback)

    emit("")
    emit("-- pthreads --")
    run_thread_tests(reportCallback)

    // Clear the screen so the summary is what stays visible.
    consoleClear()
    emit("")
    if failures == 0 {
        emit("PASS  \(checks) checks")
    } else {
        emit("FAIL  \(failures) of \(checks) checks failed")
    }
    emit("")
    emit("Press + to exit.")

    // Keep the process alive so the results stay on screen. appletMainLoop
    // returns false when the system asks the applet to exit, so HOME works too.
    while appletMainLoop() {
        if testpad_plus_pressed() { break }
    }

    consoleExit(nil)
    return failures == 0 ? 0 : 1
}
