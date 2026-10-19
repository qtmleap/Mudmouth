//
//  HTTPHookHandler+State.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import NIOCore
import NIOHTTP1

/// Internal nested types keep the event-loop-confined state model beside its handler.
@available(macOS 14, iOS 17, *)
extension HTTPHookHandler {
    final class Exchange {
        /// `nil` when the request did not match; unmatched exchanges only keep FIFO association.
        var request: HTTPPluginRequest?
        let isHead: Bool
        /// Bytes of `request.body` retained for the response phase; counted in the connection budget.
        var retained = 0

        init(request: HTTPPluginRequest?, isHead: Bool) {
            self.request = request
            self.isHead = isHead
        }
    }

    enum RequestStage {
        case idle
        case streaming
        case collecting
    }

    enum ResponseStage {
        case idle
        /// Final response streaming through; the exchange is retired at its end.
        case streamingFinal
        case collecting
    }

    enum QueuedInbound {
        case part(HTTPServerRequestPart)
        case inputClosed
    }

    struct CollectedRequest {
        var head: HTTPRequestHead
        var bodies: [ByteBuffer] = []
        var bytes = 0
        let exchange: Exchange
    }

    struct CollectedResponse {
        var head: HTTPResponseHead
        var promises: [EventLoopPromise<Void>?]
        var bodies: [(buffer: ByteBuffer, promise: EventLoopPromise<Void>?)] = []
        var bytes = 0
        let exchange: Exchange
    }

    struct Outcome: Sendable {
        var authorized: Bool
        var replacement: Data?
    }

    /// Owns the callback bodies until the local end-write completes or the handler aborts.
    struct PendingWriteBodies {
        let request: HTTPPluginRequest
        let response: HTTPPluginResponse?
    }

    /// Shared request storage is counted once across live exchanges, pending writes and leave tasks.
    static func retainedCallbackBytes(
        leaves: [UInt64: (requestID: UUID, requestBytes: Int, responseBytes: Int)],
        writes: [UInt64: PendingWriteBodies], exchanges: [Exchange],
    ) -> Int {
        var requests = Set<UUID>()
        var bytes = 0
        func count(_ requestID: UUID, _ requestBytes: Int, _ responseBytes: Int) {
            bytes += responseBytes
            if requests.insert(requestID).inserted,
               !exchanges.contains(where: { $0.request?.id == requestID && $0.retained > 0 })
            {
                bytes += requestBytes
            }
        }
        for body in leaves.values {
            count(body.requestID, body.requestBytes, body.responseBytes)
        }
        for body in writes.values {
            count(body.request.id, body.request.body.count, body.response?.body.count ?? 0)
        }
        return bytes
    }

    /// One async phase slot. Invalidating bumps the token so a late completion is ignored.
    struct PhaseSlot {
        var token: UInt64 = 0
        var task: Task<Void, Never>?
        var deadline: Scheduled<Void>?

        mutating func begin() -> UInt64 {
            invalidate()
            return token
        }

        mutating func invalidate() {
            token &+= 1
            task?.cancel()
            task = nil
            deadline?.cancel()
            deadline = nil
        }
    }
}
