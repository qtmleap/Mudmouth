//
//  HTTPHookJSON.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation

/// Strict, bounded JSON admission check for bodies the transport may hand to a plugin.
///
/// Valid RFC 8259 grammar, UTF-8, nesting depth ≤ 32 and every number a safe JS number
/// (integers within ±(2^53 − 1), other numbers finite).
enum HTTPHookJSON {
    static let maxDepth = 32
    private static let maxSafeInteger: UInt64 = 9_007_199_254_740_991

    static func isEligible(_ data: Data) -> Bool {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { return false }
        var scanner = Parser(bytes: [UInt8](data))
        return scanner.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseDocument() -> Bool {
            skipWhitespace()
            guard parseValue(depth: 0) else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private mutating func parseValue(depth: Int) -> Bool {
            guard index < bytes.count else { return false }
            switch bytes[index] {
                case UInt8(ascii: "{"): return parseObject(depth: depth + 1)
                case UInt8(ascii: "["): return parseArray(depth: depth + 1)
                case UInt8(ascii: "\""): return parseString()
                case UInt8(ascii: "t"): return parseLiteral("true")
                case UInt8(ascii: "f"): return parseLiteral("false")
                case UInt8(ascii: "n"): return parseLiteral("null")
                default: return parseNumber()
            }
        }

        private mutating func parseLiteral(_ literal: StaticString) -> Bool {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else { return false }
            index += expected.count
            return true
        }

        private mutating func parseObject(depth: Int) -> Bool {
            guard depth <= HTTPHookJSON.maxDepth else { return false }
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return true
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), parseString() else { return false }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return false }
                index += 1
                skipWhitespace()
                guard parseValue(depth: depth) else { return false }
                skipWhitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { return false }
                index += 1
                return true
            }
        }

        private mutating func parseArray(depth: Int) -> Bool {
            guard depth <= HTTPHookJSON.maxDepth else { return false }
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return true
            }
            while true {
                skipWhitespace()
                guard parseValue(depth: depth) else { return false }
                skipWhitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else { return false }
                index += 1
                return true
            }
        }

        private mutating func parseString() -> Bool {
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                    case UInt8(ascii: "\""):
                        index += 1
                        return true
                    case UInt8(ascii: "\\"):
                        index += 1
                        guard index < bytes.count else { return false }
                        switch bytes[index] {
                            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                                 UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                                index += 1
                            case UInt8(ascii: "u"):
                                guard index + 4 < bytes.count else { return false }
                                for offset in 1 ... 4 where !Parser.isHex(bytes[index + offset]) {
                                    return false
                                }
                                index += 5
                            default:
                                return false
                        }
                    case 0 ..< 0x20:
                        return false
                    default:
                        index += 1
                }
            }
            return false
        }

        private static func isHex(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
        }

        private mutating func parseNumber() -> Bool {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count else { return false }
            let integerStart = index
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if (0x31 ... 0x39).contains(bytes[index]) {
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    index += 1
                }
            } else {
                return false
            }
            let integerDigits = bytes[integerStart ..< index]
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                let fractionStart = index
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    index += 1
                }
                guard index > fractionStart else { return false }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                let exponentStart = index
                while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                    index += 1
                }
                guard index > exponentStart else { return false }
            }
            if isInteger {
                guard integerDigits.count <= 16 else { return false }
                var value: UInt64 = 0
                for digit in integerDigits {
                    value = value * 10 + UInt64(digit - 0x30)
                }
                return value <= HTTPHookJSON.maxSafeInteger
            }
            guard let text = String(bytes: bytes[start ..< index], encoding: .utf8), let number = Double(text) else { return false }
            return number.isFinite
        }
    }
}
