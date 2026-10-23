//
//  HTTPHookTransport.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import NIOCore
import NIOHTTP1

/// One upstream write sent from the hook handler to the glue as a user inbound event.
///
/// Carries the completion of the *local* write so the end of a message can drive `onLeave`,
/// and an explicit flush so a release that happens outside a read cycle still reaches the wire.
public struct HTTPHookUpstreamWrite {
    public var part: HTTPClientRequestPart
    /// Completed by the glue when the write on the peer channel completes.
    public var promise: EventLoopPromise<Void>?
    /// Flush the peer channel right after this write.
    public var flush: Bool

    public init(part: HTTPClientRequestPart, promise: EventLoopPromise<Void>? = nil, flush: Bool = false) {
        self.part = part
        self.promise = promise
        self.flush = flush
    }
}

/// Fired inbound toward the glue so its *peer* channel stops (`hold`) or resumes (`release`) reading.
/// The downstream channel's own reads are held by `HTTPHookHandler.read`.
public enum HTTPHookReadHold: Sendable, Equatable {
    case hold
    case release
}

/// The validated CONNECT authority of a connection. Written once by `ConnectHandler`, read by the hook handler.
/// Both live on the same event loop, so no locking is needed.
public final class HTTPHookAuthority: @unchecked Sendable {
    public private(set) var host: String?

    public init(host: String? = nil) {
        self.host = host?.lowercased()
    }

    public func establish(host: String) {
        self.host = host.lowercased()
    }
}

/// Fired inbound toward the glue to flush its peer channel after an asynchronous release.
public struct HTTPHookUpstreamFlush {
    public init() {}
}

/// Administrative shutdown or revocation: discard buffered work and close without waiting for writes.
/// Fire inbound on the client-facing channel; ordinary upstream closes still drain successful responses.
public struct HTTPHookAbort: Sendable {
    public init() {}
}
