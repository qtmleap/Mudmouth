//
//  HTTPPluginTypes.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation

/// The four lifecycle phases. Raw values match the runtime's dotted phase names.
public enum HTTPPluginPhase: String, Sendable, CaseIterable {
    case requestEnter = "request.onEnter"
    case requestLeave = "request.onLeave"
    case responseEnter = "response.onEnter"
    case responseLeave = "response.onLeave"
}

/// A request leg as seen by a plugin. `host` is the authenticated CONNECT authority, never the Host header.
public struct HTTPPluginRequest: Sendable, Equatable {
    public var id: UUID
    public var method: String
    public var host: String
    /// Request path without the query.
    public var path: String
    /// Query items parsed from the original URI before the query was removed from `path`.
    public var query: [String: String]
    /// Lowercase header names.
    public var headers: [String: String]
    public var body: Data

    public init(
        id: UUID, method: String, host: String, path: String, query: [String: String] = [:],
        headers: [String: String], body: Data,
    ) {
        self.id = id
        self.method = method
        self.host = host
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// A response leg as seen by a plugin.
public struct HTTPPluginResponse: Sendable, Equatable {
    public var status: Int
    /// Lowercase header names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Async seam between the NIO transport and a plugin runtime. The transport never blocks its event loop on it.
@available(macOS 14, iOS 17, *)
public protocol HTTPPluginProcessing: Sendable {
    /// Cheap, synchronous match on the request head (body is empty). Called on the event loop.
    func matches(_ request: HTTPPluginRequest) -> Bool
    /// Whether the activation grant and capture consent are still valid. Checked before a callback and before applying a result.
    func isAuthorized() async -> Bool
    /// Runs one phase. On an enter phase the returned data replaces that leg's JSON body; `nil` means no mutation.
    /// Data returned from a leave phase is ignored.
    func process(_ phase: HTTPPluginPhase, request: HTTPPluginRequest, response: HTTPPluginResponse?) async throws -> Data?
}
