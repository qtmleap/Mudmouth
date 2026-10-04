//
//  Keychain.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Crypto
import Foundation
import KeychainAccess
import SwiftASN1
import X509

extension Keychain {
    func setPrivateKey(_ privateKey: Certificate.PrivateKey) throws {
        try set(privateKey.derRepresentation, key: "privateKey")
    }

    func setCertificate(_ certificate: Certificate) throws {
        try set(certificate.derRepresentation, key: "certificate")
    }

    /// CA証明書鍵
    func getPrivateKey() throws -> Certificate.PrivateKey {
        guard let data: Data = try getData("privateKey", ignoringAttributeSynchronizable: false)
        else {
            throw DecodingError.valueNotFound(P256.Signing.PublicKey.self, .init(codingPath: [], debugDescription: ""))
        }
        return try Certificate.PrivateKey(derBytes: [UInt8](data))
    }

    /// CA証明書
    func getCertificate() throws -> Certificate {
        guard let data: Data = try getData("certificate", ignoringAttributeSynchronizable: false)
        else {
            throw DecodingError.valueNotFound(Certificate.self, .init(codingPath: [], debugDescription: ""))
        }
        return try .init(derEncoded: DER.parse([UInt8](data)))
    }
}
