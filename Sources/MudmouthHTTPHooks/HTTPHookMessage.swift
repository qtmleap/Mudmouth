//
//  HTTPHookMessage.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import NIOCore
import NIOHTTP1

/// Pure helpers: leg construction, URI splitting and body-hook eligibility.
enum HTTPHookMessage {
    enum Framing: Equatable {
        case none
        case contentLength(Int)
        case chunked
        case invalid
    }

    static func lowercasedHeaders(_ headers: HTTPHeaders) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            if let existing = result[key] {
                result[key] = "\(existing), \(value)"
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Splits a request target into its path (without query) and decoded query items. The first value of a repeated name wins.
    static func splitTarget(_ uri: String) -> (path: String, query: [String: String]) {
        var target = Substring(uri)
        if let fragment = target.firstIndex(of: "#") {
            target = target[..<fragment]
        }
        if !target.hasPrefix("/"), let scheme = target.range(of: "://") {
            let rest = target[scheme.upperBound...]
            target = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        let path: Substring
        let rawQuery: Substring
        if let mark = target.firstIndex(of: "?") {
            path = target[..<mark]
            rawQuery = target[target.index(after: mark)...]
        } else {
            path = target
            rawQuery = ""
        }
        var query: [String: String] = [:]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pieces.first, !rawName.isEmpty else { continue }
            let name = decode(rawName)
            if query[name] == nil {
                query[name] = pieces.count > 1 ? decode(pieces[1]) : ""
            }
        }
        return (String(path), query)
    }

    private static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func framing(_ headers: HTTPHeaders) -> Framing {
        let encodings = headers[canonicalForm: "transfer-encoding"].map { $0.lowercased() }
        let lengths = headers[canonicalForm: "content-length"]
        if !encodings.isEmpty {
            return encodings == ["chunked"] && lengths.isEmpty ? .chunked : .invalid
        }
        guard !lengths.isEmpty else { return .none }
        guard lengths.count == 1, !lengths[0].isEmpty, lengths[0].utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              let length = Int(lengths[0])
        else { return .invalid }
        return .contentLength(length)
    }

    static func isJSONContentType(_ headers: HTTPHeaders) -> Bool {
        let values = headers[canonicalForm: "content-type"]
        guard values.count == 1 else { return false }
        let media = values[0].split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return media == "application/json" || (media.hasSuffix("+json") && media.hasPrefix("application/"))
    }

    static func isIdentityEncoding(_ headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: "content-encoding"].allSatisfy { $0.lowercased() == "identity" }
    }

    /// Exactly one `gzip` coding (case/whitespace-insensitive) and nothing else.
    static func isSingleGzipEncoding(_ headers: HTTPHeaders) -> Bool {
        let values = headers["content-encoding"]
        return values.count == 1 && values[0].trimmingCharacters(in: .whitespaces).lowercased() == "gzip"
    }

    /// Same framing/type rules as `hasEligibleBodyHeaders`, for a body whose only coding is one gzip.
    static func hasEligibleGzipBodyHeaders(_ headers: HTTPHeaders, maxBody: Int) -> Bool {
        switch framing(headers) {
            case let .contentLength(length) where length >= 1 && length <= maxBody: break
            case .chunked: break
            default: return false
        }
        return isJSONContentType(headers) && isSingleGzipEncoding(headers)
    }

    /// Observation-only headers for a decoded body: the coding and its framing no longer apply.
    static func decodedHeaders(_ headers: HTTPHeaders) -> [String: String] {
        var decoded = lowercasedHeaders(headers)
        decoded["content-encoding"] = nil
        decoded["content-length"] = nil
        decoded["transfer-encoding"] = nil
        return decoded
    }

    /// Headers alone decide whether a body may be handed to a plugin. The body itself is validated once complete.
    static func hasEligibleBodyHeaders(_ headers: HTTPHeaders, maxBody: Int) -> Bool {
        switch framing(headers) {
            case let .contentLength(length) where length >= 1 && length <= maxBody: break
            case .chunked: break
            default: return false
        }
        return isJSONContentType(headers) && isIdentityEncoding(headers)
    }

    static func isUpgrade(_ headers: HTTPHeaders) -> Bool {
        headers.contains(name: "upgrade") || headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
    }

    static func data(of buffers: [ByteBuffer]) -> Data {
        var data = Data()
        data.reserveCapacity(buffers.reduce(0) { $0 + $1.readableBytes })
        for buffer in buffers {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }
}

extension HTTPHookMessage {
    /// Body replaced: Content-Length is the single framing header and Transfer-Encoding is removed.
    static func repairedFraming(_ headers: HTTPHeaders, bodyLength: Int) -> HTTPHeaders {
        var repaired = headers
        repaired.remove(name: "transfer-encoding")
        repaired.replaceOrAdd(name: "content-length", value: String(bodyLength))
        return repaired
    }
}
