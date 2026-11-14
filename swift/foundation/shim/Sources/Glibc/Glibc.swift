//===----------------------------------------------------------------------===//
//
// The Glibc module for the Switch 2.
//
// Foundation imports Glibc on Linux, and that module is a Swift overlay: it
// re-exports the C library and adds Swift names on top, POSIXErrorCode and
// errno among them. A bare-metal target has neither, so this module is both
// halves at once, which is why it carries the name Glibc rather than one of
// its own.
//
// Nothing here imitates glibc. GlibcC re-exports devkitA64's newlib headers
// and adds only what newlib lacks; this file adds the Swift-side names
// Foundation expects to find in its platform module.
//
//===----------------------------------------------------------------------===//

@_exported import GlibcC

/// The C library's error number for the last failed call.
///
/// newlib declares this as a macro over `__errno()`, and Swift cannot use the
/// macro: it reports "macro 'errno' unavailable: structure not supported" and
/// does not fall back to any other declaration. A variable of the same name
/// cannot be declared in the header either, because the macro rewrites that
/// declaration before the compiler reads it.
///
/// So the storage is reached from here instead. `__switch_errno_address()` is
/// compiled in a .c file, out of the macro's reach, and returns a pointer to
/// the real thread-local. Reading and writing through it is the same as using
/// the macro, because it is the same object.
///
/// This is a computed property rather than a `let`, so a read always sees the
/// current value: Foundation checks it after a call fails.
public var errno: Int32 {
    get { __switch_errno_address().pointee }
    set { __switch_errno_address().pointee = newValue }
}

// MARK: - glibc's file-type constants, retyped

/// The mask that selects the file type from `st_mode`.
///
/// glibc defines these as Int32 and its `st_mode` is Int32 too, so
/// Foundation's `st_mode & S_IFMT == S_IFDIR` type-checks. newlib's
/// `st_mode` is mode_t and therefore UInt32, and its versions of these names
/// are macros, which Swift cannot use at all. Both problems are solved by
/// declaring them here as mode_t: the expression becomes UInt32 throughout
/// and Foundation's code is unchanged.
///
/// The values are newlib's own; see glibc's <sys/stat.h> for the same octal
/// numbers.
public let S_IFMT: mode_t = SWITCH_S_IFMT
public let S_IFDIR: mode_t = SWITCH_S_IFDIR
public let S_IFCHR: mode_t = SWITCH_S_IFCHR
public let S_IFBLK: mode_t = SWITCH_S_IFBLK
public let S_IFREG: mode_t = SWITCH_S_IFREG
public let S_IFLNK: mode_t = SWITCH_S_IFLNK
public let S_IFSOCK: mode_t = SWITCH_S_IFSOCK
public let S_IFIFO: mode_t = SWITCH_S_IFIFO
public let S_ISVTX: mode_t = SWITCH_S_ISVTX
public let S_IWUSR: mode_t = SWITCH_S_IWUSR

// MARK: - clock ids

/// newlib's clock ids, with newlib's `clockid_t` rather than its Int32 macros.
///
/// Foundation writes `clock_gettime(CLOCK_MONOTONIC, &ts)`, which is glibc's
/// spelling and also newlib's, but newlib's macros are plain integers and its
/// `clockid_t` is `unsigned long`, so the call does not type-check. These
/// constants give the names the type the call expects. `clock_gettime` in
/// swift_shim.c ignores the id and reads the ARM system tick, so all three
/// name the same clock.
public let CLOCK_REALTIME: clockid_t = SWITCH_CLOCK_REALTIME
public let CLOCK_MONOTONIC: clockid_t = SWITCH_CLOCK_MONOTONIC
public let CLOCK_MONOTONIC_RAW: clockid_t = SWITCH_CLOCK_MONOTONIC_RAW

// MARK: - names newlib does not have

/// The number of symbolic links a path resolution may follow.
///
/// glibc defines this in <limits.h>; newlib does not. Foundation's
/// `standardizingPath` counts links and stops at this value. 20 is glibc's
/// number and the one Foundation's tests expect.
public let MAXSYMLINKS: Int = 20

/// Where time zone files are read from.
///
/// glibc hard-codes `/usr/share/zoneinfo`, which cannot exist on the console:
/// there is no root filesystem, only the program's romFS and the SD card. The
/// SD card location is the one a program can populate, so that is the default.
/// A program that mounts the SD card can install tzdata there; without it,
/// `TimeZone(identifier:)` simply finds no file, which is what it would do on
/// a Linux host without tzdata too.
public let TZDIR: String = "sdmc:/switch/zoneinfo"

/// The file `/etc/localtime` names on a host, moved to the SD card for the
/// same reason as `TZDIR`.
public let TZDEFAULT: String = "sdmc:/switch/localtime"

/// `mmap`'s failure value.
///
/// glibc's is the macro `((void *)-1)`; Swift cannot import a cast, so the
/// Swift Glibc overlay supplies it as a constant. Foundation's `Data` reads
/// files with `mmap` and compares the result against this.
public let MAP_FAILED: UnsafeMutableRawPointer = UnsafeMutableRawPointer(bitPattern: -1)!

/// Splits a double into its integral and fractional parts.
///
/// glibc's Swift overlay provides this two-result form; the C declaration in
/// newlib is the two-argument `modf(_:_:)`, which Foundation does not call.
/// `FileManager` uses the tuple to turn a `Date` into a `timeval`.
public func modf(_ value: Double) -> (Double, Double) {
    var integral: Double = 0
    let fractional = modf(value, &integral)
    return (integral, fractional)
}

// MARK: - string algorithms the standard library does not build

// `String.contains(_:)` for another string and `String.replacing(_:with:)`
// live in `_StringProcessing`, which this port's standard library does not
// build (see build-stdlib.sh). Foundation uses both, and they are ordinary
// string operations on every other platform, so the shim supplies them here
// rather than making Foundation carry a patch at each call site.
//
// They work on UTF-8 bytes, which is the same comparison Swift makes for a
// literal substring: a UTF-8 substring match is a code-unit match, and a match
// cannot start in the middle of a scalar's encoding because the needle is a
// valid string. The offset is advanced by one byte, which can only skip a
// position that could not start a match anyway.

/// Returns true if `other` occurs anywhere in this collection.
///
/// This is `Collection.contains(_:)` for a collection of elements, which lives
/// in `_StringProcessing` and is therefore missing from this port too. The
/// predicate expression `CollectionContainsCollection` is its caller.
extension Collection where Element: Equatable {
    public func contains<C: Collection>(_ other: C) -> Bool
    where C.Element == Element {
        if other.isEmpty {
            return true
        }

        var start = startIndex
        while start != endIndex {
            var candidate = start
            var element = other.startIndex
            while candidate != endIndex && element != other.endIndex &&
                self[candidate] == other[element] {
                candidate = index(after: candidate)
                element = other.index(after: element)
            }
            if element == other.endIndex {
                return true
            }
            start = index(after: start)
        }
        return false
    }
}

extension String {
    /// Removes `prefix` from the start, if it is there.
    ///
    /// `String.trimmingPrefix(_:)` is another `_StringProcessing` API.
    /// Foundation uses it to make a path relative to the directory it was
    /// enumerated from.
    public func trimmingPrefix<T: StringProtocol>(_ prefix: T) -> Substring {
        let prefix = String(prefix)
        guard hasPrefix(prefix) else {
            return self[...]
        }
        return self[index(startIndex, offsetBy: prefix.count)...]
    }

    /// Returns a copy of this string with every occurrence of `target`
    /// replaced by `replacement`.
    public func replacing<T: StringProtocol>(_ target: T, with replacement: String) -> String {
        let haystack = Array(utf8)
        let needle = Array(target.utf8)
        let replacementBytes = Array(replacement.utf8)

        if needle.isEmpty {
            return self
        }

        var result: [UInt8] = []
        result.reserveCapacity(haystack.count)

        var index = 0
        while index < haystack.count {
            var match = index + needle.count <= haystack.count
            if match {
                var offset = 0
                while offset < needle.count {
                    if haystack[index + offset] != needle[offset] {
                        match = false
                        break
                    }
                    offset += 1
                }
            }

            if match {
                result.append(contentsOf: replacementBytes)
                index += needle.count
            } else {
                result.append(haystack[index])
                index += 1
            }
        }

        return String(decoding: result, as: UTF8.self)
    }
}
