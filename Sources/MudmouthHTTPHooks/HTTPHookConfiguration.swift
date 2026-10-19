//
//  HTTPHookConfiguration.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import NIOCore
import NIOHTTP1

/// Receives the messages that were actually forwarded, in forwarding order.
/// Confined to the connection's event loop. Interim 1xx responses are never reported.
public protocol HTTPExchangeObserving: AnyObject {
    func requestHead(_ head: HTTPRequestHead)
    func requestBody(_ buffer: ByteBuffer)
    func responseHead(_ head: HTTPResponseHead)
    func responseBody(_ buffer: ByteBuffer)
    /// The final response of the oldest outstanding exchange was fully forwarded.
    func responseEnd()
    /// Same moment as `responseEnd()`, but `written` completes with the local end-write. Observers that persist
    /// "what was actually forwarded" override this; the default reports immediately.
    func responseEnd(written: EventLoopFuture<Void>)
}

public extension HTTPExchangeObserving {
    func responseEnd(written _: EventLoopFuture<Void>) {
        responseEnd()
    }
}

/// Bounds for one connection.
public struct HTTPHookLimits: Sendable, Equatable {
    /// Largest original body that is eligible for hooks.
    public var bodyBytes: Int
    /// Buffered + queued + retained bytes per connection.
    public var bufferedBytes: Int
    /// Queued inbound parts per connection while an async phase is in flight.
    public var queuedParts: Int
    /// Exchanges whose final response has not completed. Further requests are forwarded without hooks.
    public var pipelinedExchanges: Int
    /// Hard cap on exchanges awaiting a final response. Beyond it the connection is closed, because the
    /// request/response association can neither be dropped nor grow without bound.
    public var outstandingExchanges: Int
    /// After this an in-flight phase is abandoned and the original message is forwarded.
    public var phaseDeadline: TimeAmount

    public init(
        bodyBytes: Int = 24 * 1024,
        bufferedBytes: Int = 64 * 1024,
        queuedParts: Int = 256,
        pipelinedExchanges: Int = 8,
        phaseDeadline: TimeAmount = .seconds(5),
        outstandingExchanges: Int = 128,
    ) {
        self.outstandingExchanges = outstandingExchanges
        self.bodyBytes = bodyBytes
        self.bufferedBytes = bufferedBytes
        self.queuedParts = queuedParts
        self.pipelinedExchanges = pipelinedExchanges
        self.phaseDeadline = phaseDeadline
    }
}
