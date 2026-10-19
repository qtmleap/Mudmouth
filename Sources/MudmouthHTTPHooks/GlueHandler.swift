//
//  GlueHandler.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import NIOCore

/// Pipes two channels together. Lives in the pure module so it can be tested with embedded channels.
///
/// Besides plain piping it understands three user events fired by `HTTPHookHandler`:
/// `HTTPHookUpstreamWrite` (a write that carries its completion promise and optional flush),
/// `HTTPHookUpstreamFlush` (explicit flush after an asynchronous release) and
/// `HTTPHookReadHold` (stop/resume reading on the peer channel).
public final class GlueHandler: ChannelDuplexHandler {
    // MARK: Public

    public typealias InboundIn = NIOAny
    public typealias OutboundIn = NIOAny
    public typealias OutboundOut = NIOAny

    public static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()

        first.partner = second
        second.partner = first

        return (first, second)
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    public func handlerRemoved(context _: ChannelHandlerContext) {
        context = nil
        partner = nil
    }

    public func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data, promise: nil, flush: false)
    }

    public func channelReadComplete(context _: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    public func channelInactive(context _: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    public func userInboundEventTriggered(context _: ChannelHandlerContext, event: Any) {
        switch event {
            case let write as HTTPHookUpstreamWrite:
                if let partner {
                    partner.partnerWrite(NIOAny(write.part), promise: write.promise, flush: write.flush)
                } else {
                    write.promise?.fail(ChannelError.ioOnClosedChannel)
                }
            case is HTTPHookUpstreamFlush:
                partner?.partnerFlush()
            case let hold as HTTPHookReadHold:
                partner?.setReadHold(hold == .hold)
            case let event as ChannelEvent:
                if case .inputClosed = event {
                    partner?.partnerWriteEOF()
                }
            default:
                break
        }
    }

    public func errorCaught(context _: ChannelHandlerContext, error _: Error) {
        partner?.partnerCloseFull()
    }

    public func read(context: ChannelHandlerContext) {
        if readHeld {
            pendingRead = true
        } else if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    // MARK: Private

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private var readHeld = false

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }

    private func partnerWrite(_ data: NIOAny, promise: EventLoopPromise<Void>?, flush: Bool) {
        guard let context else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        context.write(data, promise: promise)
        if flush {
            context.flush()
        }
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead, !readHeld {
            pendingRead = false
            context?.read()
        }
    }

    /// Hold or resume reads on this handler's own channel, on behalf of the partner's hook handler.
    private func setReadHold(_ hold: Bool) {
        readHeld = hold
        if !hold, pendingRead {
            pendingRead = false
            if let partner, partner.partnerWritable {
                context?.read()
            } else {
                pendingRead = true
            }
        }
    }
}
