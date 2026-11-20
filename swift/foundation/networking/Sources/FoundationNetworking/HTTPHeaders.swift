// SPDX-License-Identifier: MIT
//
// Small header helpers shared by the FoundationNetworking types. Foundation's
// HTTP header storage is case-insensitive even though Swift dictionaries are
// not, so lookups walk the keys when the exact spelling misses.

import FoundationEssentials

func httpHeaderValue(in headers: [String: String]?, named name: String) -> String? {
    guard let headers else { return nil }
    if let value = headers[name] {
        return value
    }
    let lowered = name.lowercased()
    for (key, value) in headers where key.lowercased() == lowered {
        return value
    }
    return nil
}

func trimmingHTTPWhitespace(_ string: String) -> String {
    var start = string.startIndex
    var end = string.endIndex

    while start < end {
        let character = string[start]
        if character == " " || character == "\t" {
            start = string.index(after: start)
        } else {
            break
        }
    }
    while start < end {
        let index = string.index(before: end)
        let character = string[index]
        if character == " " || character == "\t" {
            end = index
        } else {
            break
        }
    }

    return String(string[start..<end])
}
