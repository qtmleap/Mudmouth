//
//  GameWebToken.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation

public struct GameWebToken: Codable, Sendable {
    public let header: Header
    public let payload: Payload
    public let signature: String

    public init(_ value: String) throws {
        let values = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty }),
              values.allSatisfy(Self.isBase64URL) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JWT format"))
        }
        let decoder = JSONDecoder()
        header = try decoder.decode(Header.self, from: Self.decodeBase64URL(values[0]))
        payload = try decoder.decode(Payload.self, from: Self.decodeBase64URL(values[1]))
        signature = values[2]
    }

    private static func isBase64URL(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }
    }

    private static func decodeBase64URL(_ value: String) throws -> Data {
        guard value.count % 4 != 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JWT encoding"))
        }
        let base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JWT encoding"))
        }
        return data
    }

    public var isRefreshNeeded: Bool {
        Date.now.timeIntervalSince1970 > TimeInterval(payload.exp)
    }

    public struct Header: Codable, Sendable {
        public let alg: String
        public let jku: URL
        public let kid: String
        public let typ: String
    }

    public struct Payload: Codable, Sendable {
        public let isChildRestricted: Bool
        public let aud: String
        public let exp: Int
        public let iat: Int
        public let iss: String
        public let jti: UUID
        public let sub: Int
        public let links: Links
        public let typ: String
        public let membership: Membership
    }

    public struct Membership: Codable, Sendable {
        public let active: Bool
    }

    public struct Links: Codable, Sendable {
        public let networkServiceAccount: ServiceAccount
    }

    public struct ServiceAccount: Codable, Sendable {
        public let id: String
    }
}
