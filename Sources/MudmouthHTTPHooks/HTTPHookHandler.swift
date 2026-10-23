//
//  HTTPHookHandler.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import NIOCore
import NIOHTTP1

/// Lifecycle handler between the TLS-terminated HTTP codec and the glue.
///
/// Matched, eligible messages are buffered (bounded), handed to the async processor off the event loop,
/// optionally body-mutated and forwarded. `onLeave` runs only after the local end-write promise succeeds.
/// Everything else streams through unchanged. All state is confined to the channel's event loop.
@available(macOS 14, iOS 17, *)
public final class HTTPHookHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPClientRequestPart
    public typealias OutboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    /// - Parameters:
    ///   - authority: the authenticated CONNECT authority; never the Host header.
    ///   - processor: `nil` streams ordinary HTTP without hook processing.
    public init(
        authority: HTTPHookAuthority,
        processor: (any HTTPPluginProcessing)?,
        observer: (any HTTPExchangeObserving)? = nil,
        isConsentGranted: @escaping @Sendable () -> Bool = { true },
        limits: HTTPHookLimits = .init(),
    ) {
        self.authority = authority
        self.processor = processor
        self.observer = observer
        self.isConsentGranted = isConsentGranted
        self.limits = limits
    }

    // MARK: Lifecycle

    public func handlerRemoved(context _: ChannelHandlerContext) {
        teardown()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        teardown()
        context.fireChannelInactive()
    }

    // MARK: Inbound (client request)

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closed, !refusingRequest else { return }
        guard isConsentGranted() else {
            closeConnection(context)
            return
        }
        let part = unwrapInboundIn(data)
        if requestBusy || !inboundQueue.isEmpty {
            enqueueInbound(.part(part), context: context)
        } else {
            handleRequestPart(part, context: context)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is HTTPHookAbort {
            closeConnection(context)
            return
        }
        guard !refusingRequest else { return }
        if let event = event as? ChannelEvent, case .inputClosed = event {
            if requestBusy || !inboundQueue.isEmpty {
                enqueueInbound(.inputClosed, context: context)
                return
            }
            if case .collecting = requestStage {
                abandonCollectedRequest(context: context)
            }
            // Everything written so far must be flushed before the half-close reaches the peer.
            context.fireUserInboundEventTriggered(HTTPHookUpstreamFlush())
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func read(context: ChannelHandlerContext) {
        if readHeld {
            pendingRead = true
        } else {
            context.read()
        }
    }

    // MARK: Outbound (upstream response)

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !closed, !refusalSent else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        guard isConsentGranted() else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            closeConnection(context)
            return
        }
        let part = unwrapOutboundIn(data)
        if responseBusy || !outboundQueue.isEmpty {
            enqueueOutbound(part, promise, context: context)
        } else {
            handleResponsePart(part, promise: promise, context: context)
        }
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard !closed, mode == .output || mode == .all else {
            context.close(mode: mode, promise: promise)
            return
        }
        // A close from the server must not truncate a response that is still buffered or in flight.
        if refusingRequest, !refusalSent, !exchanges.isEmpty,
           !responseBusy, outboundQueue.isEmpty, responseEndsPending == 0
        {
            // The server closed before all preceding responses arrived. FIFO completion is impossible.
            teardown()
            context.close(mode: mode, promise: promise)
            return
        }
        if responseBusy || !outboundQueue.isEmpty || responseEndsPending > 0 || refusingRequest {
            deferredClose.append((mode, promise))
            sendRefusalIfReady(context)
            return
        }
        if case .collecting = responseStage {
            abandonCollectedResponse(context: context)
        }
        context.flush()
        context.close(mode: mode, promise: promise)
    }

    // MARK: Private state

    private let authority: HTTPHookAuthority
    private let processor: (any HTTPPluginProcessing)?
    private let observer: (any HTTPExchangeObserving)?
    private let isConsentGranted: @Sendable () -> Bool
    private let limits: HTTPHookLimits

    private var closed = false
    private var refusingRequest = false
    private var refusalSent = false
    private var exchanges: [Exchange] = []

    private var readHeld = false
    private var pendingRead = false

    private var requestStage = RequestStage.idle
    private var collectedRequest: CollectedRequest?
    private var pendingRequest: (collected: CollectedRequest, original: Data)?
    private var requestBusy = false
    private var requestAuthorizationRecheck = false
    private var requestPhase = PhaseSlot()
    private var inboundQueue: [QueuedInbound] = []
    private var inboundQueueBytes = 0
    private var inboundBypass = false

    private var responseStage = ResponseStage.idle
    private var collectedResponse: CollectedResponse?
    private var pendingResponse: (collected: CollectedResponse, original: Data)?
    private var responseBusy = false
    private var responseAuthorizationRecheck = false
    private var responsePhase = PhaseSlot()
    private var outboundQueue: [(part: HTTPClientResponsePart, promise: EventLoopPromise<Void>?)] = []
    private var outboundQueueBytes = 0
    private var outboundBypass = false
    private var deferredClose: [(mode: CloseMode, promise: EventLoopPromise<Void>?)] = []
    private var lastResponseEnd: EventLoopFuture<Void>?
    private var responseEndsPending = 0
    private var retainedBytes = 0
    private var pendingWrites: [UInt64: PendingWriteBodies] = [:]
    private var nextWriteID: UInt64 = 0

    private var leaveTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextLeaveID: UInt64 = 0
    private var leaveBodies: [UInt64: (requestID: UUID, requestBytes: Int, responseBytes: Int)] = [:]
    private static var maxLeaves: Int {
        4
    }

    private var bufferedTotal: Int {
        (collectedRequest?.bytes ?? 0) + (pendingRequest?.collected.bytes ?? 0)
            + (collectedResponse?.bytes ?? 0) + (pendingResponse?.collected.bytes ?? 0)
            + inboundQueueBytes + outboundQueueBytes + retainedBytes
            + Self.retainedCallbackBytes(leaves: leaveBodies, writes: pendingWrites, exchanges: exchanges)
    }
}

// MARK: - Shutdown and read hold

@available(macOS 14, iOS 17, *)
private extension HTTPHookHandler {
    func teardown() {
        guard !closed else { return }
        closed = true
        requestPhase.invalidate()
        responsePhase.invalidate()
        collectedRequest = nil
        pendingRequest = nil
        collectedResponse?.promises.forEach { $0?.fail(ChannelError.ioOnClosedChannel) }
        collectedResponse?.bodies.forEach { $0.promise?.fail(ChannelError.ioOnClosedChannel) }
        collectedResponse = nil
        pendingResponse?.collected.promises.forEach { $0?.fail(ChannelError.ioOnClosedChannel) }
        pendingResponse?.collected.bodies.forEach { $0.promise?.fail(ChannelError.ioOnClosedChannel) }
        pendingResponse = nil
        inboundQueue.removeAll()
        outboundQueue.forEach { $0.promise?.fail(ChannelError.ioOnClosedChannel) }
        outboundQueue.removeAll()
        deferredClose.forEach { $0.promise?.fail(ChannelError.ioOnClosedChannel) }
        deferredClose.removeAll()
        leaveTasks.values.forEach { $0.cancel() }
        leaveTasks.removeAll()
        leaveBodies.removeAll()
        pendingWrites.removeAll()
        lastResponseEnd = nil
        responseEndsPending = 0
        exchanges.removeAll()
        inboundQueueBytes = 0
        outboundQueueBytes = 0
        retainedBytes = 0
    }

    /// Revocation, write failure or a lost peer: drop everything buffered and close. Never forwards, never retries.
    func closeConnection(_ context: ChannelHandlerContext) {
        teardown()
        context.close(promise: nil)
    }

    /// Protocol switches are unsupported. Finish earlier HTTP responses before emitting a refusal.
    func sendRefusalIfReady(_ context: ChannelHandlerContext) {
        guard refusingRequest, !refusalSent, !closed, !requestBusy, !responseBusy,
              exchanges.isEmpty, outboundQueue.isEmpty, responseEndsPending == 0 else { return }
        guard isConsentGranted() else {
            closeConnection(context)
            return
        }
        refusalSent = true
        let written = context.eventLoop.makePromise(of: Void.self)
        responseEndsPending += 1
        lastResponseEnd = written.futureResult
        let head = HTTPResponseHead(version: .http1_1, status: .notImplemented,
                                    headers: HTTPHeaders([("Content-Length", "0"), ("Connection", "close")]))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.end(nil)), promise: written)
        context.flush()
        written.futureResult.whenComplete { [self] _ in
            guard !closed else { return }
            let waiting = deferredClose
            deferredClose.removeAll()
            teardown()
            let closing = context.eventLoop.makePromise(of: Void.self)
            for (_, promise) in waiting {
                if let promise {
                    closing.futureResult.cascade(to: promise)
                }
            }
            context.close(promise: closing)
        }
    }

    func holdOwnRead() {
        readHeld = true
    }

    func releaseOwnRead(_ context: ChannelHandlerContext) {
        guard !refusingRequest else { return }
        readHeld = false
        if pendingRead, !closed {
            pendingRead = false
            context.read()
        }
    }
}

// MARK: - Request path

@available(macOS 14, iOS 17, *)
private extension HTTPHookHandler {
    func enqueueInbound(_ item: QueuedInbound, context: ChannelHandlerContext) {
        if case let .part(.body(buffer)) = item {
            inboundQueueBytes += buffer.readableBytes
        }
        inboundQueue.append(item)
        if bufferedTotal > limits.bufferedBytes || (requestAuthorizationRecheck && inboundQueue.count > limits.queuedParts + 1) {
            // Reads are held. Additional decoded data cannot grow the authorization-wait queue.
            closeConnection(context)
        } else if inboundQueue.count > limits.queuedParts {
            inboundBypass = true
            cancelRequestPhaseAndForward(context)
        }
    }

    func cancelRequestPhaseAndForward(_ context: ChannelHandlerContext) {
        guard requestBusy, pendingRequest != nil, !requestAuthorizationRecheck else { return }
        recheckAuthorization(request: true, token: requestPhase.token, context: context)
    }

    func drainInbound(_ context: ChannelHandlerContext) {
        while !requestBusy, !closed, !refusingRequest, !inboundQueue.isEmpty {
            guard isConsentGranted() else {
                closeConnection(context)
                return
            }
            let item = inboundQueue.removeFirst()
            switch item {
                case let .part(part):
                    if case let .body(buffer) = part {
                        inboundQueueBytes -= buffer.readableBytes
                    }
                    handleRequestPart(part, context: context)
                case .inputClosed:
                    if case .collecting = requestStage {
                        abandonCollectedRequest(context: context)
                    }
                    context.fireUserInboundEventTriggered(HTTPHookUpstreamFlush())
                    context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }
        }
        guard !closed else { return }
        if inboundQueue.isEmpty, case .idle = requestStage {
            inboundBypass = false
        }
        // Released outside a read cycle: do not rely on channelReadComplete to flush.
        context.fireUserInboundEventTriggered(HTTPHookUpstreamFlush())
    }

    func forwardRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch part {
            case let .head(head):
                observer?.requestHead(head)
                context.fireChannelRead(wrapInboundOut(.head(head)))
            case let .body(buffer):
                observer?.requestBody(buffer)
                context.fireChannelRead(wrapInboundOut(.body(.byteBuffer(buffer))))
            case let .end(trailers):
                context.fireChannelRead(wrapInboundOut(.end(trailers)))
        }
    }

    func handleRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch requestStage {
            case .idle:
                guard case let .head(head) = part else {
                    forwardRequestPart(part, context: context)
                    return
                }
                beginRequest(head, context: context)
            case .streaming:
                forwardRequestPart(part, context: context)
                if case .end = part {
                    requestStage = .idle
                    if inboundQueue.isEmpty {
                        inboundBypass = false
                    }
                }
            case .collecting:
                collectRequestPart(part, context: context)
        }
    }

    func beginRequest(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        if head.method == .CONNECT || HTTPHookMessage.isUpgrade(head.headers) {
            refusingRequest = true
            holdOwnRead()
            inboundQueue.removeAll()
            inboundQueueBytes = 0
            sendRefusalIfReady(context)
            return
        }
        guard exchanges.count < limits.outstandingExchanges else {
            // The association cannot be dropped or grow without bound: stop rather than misassociate.
            closeConnection(context)
            return
        }
        let expectsContinue = head.headers[canonicalForm: "expect"].contains { $0.lowercased() == "100-continue" }
        var request: HTTPPluginRequest?
        if let processor, !inboundBypass, !expectsContinue, exchanges.count < limits.pipelinedExchanges,
           let host = authority.host
        {
            let target = HTTPHookMessage.splitTarget(head.uri)
            let candidate = HTTPPluginRequest(
                id: UUID(), method: head.method.rawValue, host: host, path: target.path, query: target.query,
                headers: HTTPHookMessage.lowercasedHeaders(head.headers), body: Data(),
            )
            if processor.matches(candidate) {
                request = candidate
            }
        }
        let exchange = Exchange(request: request, isHead: head.method == .HEAD)
        exchanges.append(exchange)
        if request != nil, HTTPHookMessage.hasEligibleBodyHeaders(head.headers, maxBody: limits.bodyBytes) {
            collectedRequest = CollectedRequest(head: head, exchange: exchange)
            requestStage = .collecting
        } else {
            forwardRequestPart(.head(head), context: context)
            requestStage = .streaming
        }
    }

    func collectRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        guard var collected = collectedRequest else {
            requestStage = .idle
            forwardRequestPart(part, context: context)
            return
        }
        switch part {
            case .head:
                // Not valid HTTP; the decoder should have rejected it. Release what we hold and treat it as a new message.
                abandonCollectedRequest(context: context)
                requestStage = .idle
                handleRequestPart(part, context: context)
            case let .body(buffer):
                collected.bytes += buffer.readableBytes
                collected.bodies.append(buffer)
                collectedRequest = collected
                if collected.bytes > limits.bodyBytes || bufferedTotal > limits.bufferedBytes {
                    abandonCollectedRequest(context: context)
                }
            case let .end(trailers):
                collectedRequest = nil
                requestStage = .idle
                let original = HTTPHookMessage.data(of: collected.bodies)
                let declared = HTTPHookMessage.framing(collected.head.headers)
                var lengthMatches = true
                if case let .contentLength(length) = declared {
                    lengthMatches = length == original.count
                }
                guard trailers == nil, lengthMatches, HTTPHookJSON.isEligible(original) else {
                    replayRequest(collected, trailers: trailers, includeEnd: true, context: context)
                    return
                }
                startRequestEnter(collected, original: original, context: context)
        }
    }

    /// Replays the original head and body parts. With `includeEnd == false` the rest of the message keeps streaming.
    func replayRequest(_ collected: CollectedRequest, trailers: HTTPHeaders?, includeEnd: Bool, context: ChannelHandlerContext) {
        forwardRequestPart(.head(collected.head), context: context)
        for body in collected.bodies {
            forwardRequestPart(.body(body), context: context)
        }
        if includeEnd {
            forwardRequestPart(.end(trailers), context: context)
        } else {
            requestStage = .streaming
        }
    }

    func abandonCollectedRequest(context: ChannelHandlerContext) {
        guard let collected = collectedRequest else { return }
        collectedRequest = nil
        replayRequest(collected, trailers: nil, includeEnd: false, context: context)
    }

    func startRequestEnter(_ collected: CollectedRequest, original: Data, context: ChannelHandlerContext) {
        guard let processor, var request = collected.exchange.request else { return }
        request.body = original
        pendingRequest = (collected, original)
        requestBusy = true
        holdOwnRead()
        let token = requestPhase.begin()
        let loop = context.eventLoop
        let handler = NIOLoopBound(self, eventLoop: loop)
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let phaseRequest = request
        requestPhase.task = Task {
            var authorized = await processor.isAuthorized()
            var replacement: Data?
            if authorized {
                replacement = try? await processor.process(.requestEnter, request: phaseRequest, response: nil)
                // Immediately before applying or forwarding the buffered result.
                authorized = await processor.isAuthorized()
            }
            let outcome = Outcome(authorized: authorized, replacement: replacement)
            loop.execute { handler.value.requestEnterFinished(token: token, outcome: outcome, context: boundContext.value) }
        }
        requestPhase.deadline = loop.scheduleTask(in: limits.phaseDeadline) {
            handler.value.requestDeadlineHit(token: token, context: boundContext.value)
        }
    }

    /// The callback is stalled: abandon it, then make a bounded, fresh activation check.
    func requestDeadlineHit(token: UInt64, context: ChannelHandlerContext) {
        recheckAuthorization(request: true, token: token, context: context)
    }

    /// Both overflow and deadline fallback recheck the grant before forwarding original bytes.
    /// A hung authorization check closes at the same bounded deadline.
    func recheckAuthorization(request: Bool, token: UInt64, context: ChannelHandlerContext) {
        guard !closed, let processor else { return }
        let recheck: UInt64
        if request {
            guard token == requestPhase.token, pendingRequest != nil, !requestAuthorizationRecheck else { return }
            requestAuthorizationRecheck = true
            recheck = requestPhase.begin()
        } else {
            guard token == responsePhase.token, pendingResponse != nil, !responseAuthorizationRecheck else { return }
            responseAuthorizationRecheck = true
            recheck = responsePhase.begin()
        }
        let loop = context.eventLoop
        let handler = NIOLoopBound(self, eventLoop: loop)
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let finish: (Bool) -> Void = { authorized in
            let outcome = Outcome(authorized: authorized, replacement: nil)
            if request {
                handler.value.requestEnterFinished(token: recheck, outcome: outcome, context: boundContext.value)
            } else {
                handler.value.responseEnterFinished(token: recheck, outcome: outcome, context: boundContext.value)
            }
        }
        let task = Task {
            let authorized = await processor.isAuthorized()
            loop.execute { finish(authorized) }
        }
        let deadline = loop.scheduleTask(in: limits.phaseDeadline) { finish(false) }
        if request {
            requestPhase.task = task
            requestPhase.deadline = deadline
        } else {
            responsePhase.task = task
            responsePhase.deadline = deadline
        }
    }

    func requestEnterFinished(token: UInt64, outcome: Outcome, context: ChannelHandlerContext) {
        guard !closed, token == requestPhase.token, let pending = pendingRequest else { return }
        requestPhase.invalidate()
        requestAuthorizationRecheck = false
        pendingRequest = nil
        guard isConsentGranted(), outcome.authorized, context.channel.isActive else {
            closeConnection(context)
            return
        }
        forwardCollectedRequest(pending.collected, original: pending.original, replacement: outcome.replacement, context: context)
        requestBusy = false
        releaseOwnRead(context)
        drainInbound(context)
    }

    func forwardCollectedRequest(_ collected: CollectedRequest, original: Data, replacement: Data?, context: ChannelHandlerContext) {
        var head = collected.head
        var bodies = collected.bodies
        var forwarded = original
        if let replacement, replacement != original, HTTPHookJSON.isEligible(replacement),
           original.count <= limits.bufferedBytes - bufferedTotal,
           replacement.count <= limits.bufferedBytes - bufferedTotal - original.count
        {
            head.headers = HTTPHookMessage.repairedFraming(head.headers, bodyLength: replacement.count)
            bodies = [ByteBuffer(bytes: replacement)]
            forwarded = replacement
        }
        if collected.exchange.request != nil {
            collected.exchange.request?.body = forwarded
            retainedBytes += forwarded.count - collected.exchange.retained
            collected.exchange.retained = forwarded.count
        }
        collected.exchange.request?.headers = HTTPHookMessage.lowercasedHeaders(head.headers)
        let writeID = reserveWriteBodies(request: collected.exchange.request, response: nil)

        forwardRequestPart(.head(head), context: context)
        for body in bodies {
            forwardRequestPart(.body(body), context: context)
        }
        // The end write carries a promise so onLeave can follow its local completion, and flushes explicitly.
        let endPromise = context.eventLoop.makePromise(of: Void.self)
        context.fireUserInboundEventTriggered(HTTPHookUpstreamWrite(part: .end(nil), promise: endPromise, flush: true))
        endPromise.futureResult.whenComplete { [self] result in
            guard !closed else { return }
            let retained = pendingWrites.removeValue(forKey: writeID)
            switch result {
                case .success:
                    if let retained {
                        startLeave(.requestLeave, request: retained.request, response: nil, context: context)
                    }
                case .failure:
                    // Partial write: never retry, never replay, never run leave.
                    closeConnection(context)
            }
        }
    }
}

// MARK: - Response path

@available(macOS 14, iOS 17, *)
private extension HTTPHookHandler {
    func enqueueOutbound(_ part: HTTPClientResponsePart, _ promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        if case let .body(buffer) = part {
            outboundQueueBytes += buffer.readableBytes
        }
        outboundQueue.append((part, promise))
        if bufferedTotal > limits.bufferedBytes || (responseAuthorizationRecheck && outboundQueue.count > limits.queuedParts + 1) {
            closeConnection(context)
        } else if outboundQueue.count > limits.queuedParts {
            outboundBypass = true
            cancelResponsePhaseAndForward(context)
        }
    }

    func cancelResponsePhaseAndForward(_ context: ChannelHandlerContext) {
        guard responseBusy, pendingResponse != nil, !responseAuthorizationRecheck else { return }
        recheckAuthorization(request: false, token: responsePhase.token, context: context)
    }

    func drainOutbound(_ context: ChannelHandlerContext) {
        while !responseBusy, !closed, !outboundQueue.isEmpty {
            guard isConsentGranted() else {
                closeConnection(context)
                return
            }
            let item = outboundQueue.removeFirst()
            if case let .body(buffer) = item.part {
                outboundQueueBytes -= buffer.readableBytes
            }
            handleResponsePart(item.part, promise: item.promise, context: context)
        }
        guard !closed else { return }
        if outboundQueue.isEmpty, case .idle = responseStage {
            outboundBypass = false
        }
        context.flush()
        if !responseBusy, outboundQueue.isEmpty {
            if refusingRequest {
                if !deferredClose.isEmpty, !exchanges.isEmpty {
                    closeConnection(context)
                } else {
                    sendRefusalIfReady(context)
                }
                return
            }
            // An ordinary read boundary may leave the next response incomplete. Only a real
            // upstream close ends collection early; otherwise keep buffering until its end.
            if !deferredClose.isEmpty, case .collecting = responseStage {
                abandonCollectedResponse(context: context)
            }
            let closing = deferredClose
            deferredClose.removeAll()
            let written = lastResponseEnd
            for (mode, promise) in closing {
                if mode == .all, let written {
                    // A full close fails writes still in flight; let the forwarded response land first.
                    written.whenComplete { [self] _ in
                        guard !closed else {
                            promise?.fail(ChannelError.ioOnClosedChannel)
                            return
                        }
                        context.close(mode: mode, promise: promise)
                    }
                } else {
                    context.close(mode: mode, promise: promise)
                }
            }
        }
    }

    func forwardResponsePart(_ part: HTTPClientResponsePart, promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        switch part {
            case let .head(head):
                context.write(wrapOutboundOut(.head(head)), promise: promise)
            case let .body(buffer):
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
            case let .end(trailers):
                context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }

    func handleResponsePart(_ part: HTTPClientResponsePart, promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        switch responseStage {
            case .idle:
                guard case let .head(head) = part else {
                    forwardResponsePart(part, promise: promise, context: context)
                    return
                }
                beginResponse(head, promise: promise, context: context)
            case .streamingFinal:
                if case let .end(trailers) = part {
                    responseStage = .idle
                    retireExchange()
                    forwardResponseEnd(trailers, promise: promise, context: context)
                    if refusingRequest {
                        sendRefusalIfReady(context)
                    }
                } else {
                    observeResponse(part)
                    forwardResponsePart(part, promise: promise, context: context)
                }
            case .collecting:
                collectResponsePart(part, promise: promise, context: context)
        }
    }

    func observeResponse(_ part: HTTPClientResponsePart) {
        switch part {
            case let .head(head): observer?.responseHead(head)
            case let .body(buffer): observer?.responseBody(buffer)
            case .end: break
        }
    }

    /// Reports the end synchronously (keeping the observer's FIFO intact) together with the future of its write.
    func forwardResponseEnd(_ trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        let written = context.eventLoop.makePromise(of: Void.self)
        responseEndsPending += 1
        lastResponseEnd = written.futureResult
        observer?.responseEnd(written: written.futureResult)
        if let promise {
            written.futureResult.cascade(to: promise)
        }
        context.write(wrapOutboundOut(.end(trailers)), promise: written)
        written.futureResult.whenComplete { [self] result in
            guard !closed else { return }
            responseEndsPending -= 1
            if case .failure = result {
                closeConnection(context)
            } else if !responseBusy {
                drainOutbound(context)
            }
        }
    }

    func retireExchange() {
        guard !exchanges.isEmpty else { return }
        retainedBytes -= exchanges.removeFirst().retained
    }

    func beginResponse(_ head: HTTPResponseHead, promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        let code = head.status.code
        if code == 101 {
            promise?.fail(ChannelError.operationUnsupported)
            closeConnection(context)
            return
        } else if code >= 100, code < 200 {
            // NIO forwards informational responses as a head only, without an end or FIFO retirement.
            forwardResponsePart(.head(head), promise: promise, context: context)
            return
        }
        let exchange = exchanges.first
        if processor != nil, !outboundBypass, let exchange, exchange.request != nil, !exchange.isHead,
           code != 204, code != 304,
           HTTPHookMessage.hasEligibleBodyHeaders(head.headers, maxBody: limits.bodyBytes)
        {
            collectedResponse = CollectedResponse(head: head, promises: [promise], exchange: exchange)
            responseStage = .collecting
        } else if processor != nil, !outboundBypass, let exchange, exchange.request != nil, !exchange.isHead,
                  code != 204, code != 304,
                  HTTPHookMessage.hasEligibleGzipBodyHeaders(head.headers, maxBody: limits.bodyBytes)
        {
            collectedResponse = CollectedResponse(head: head, promises: [promise], isGzip: true, exchange: exchange)
            responseStage = .collecting
        } else {
            observeResponse(.head(head))
            forwardResponsePart(.head(head), promise: promise, context: context)
            responseStage = .streamingFinal
        }
    }

    func collectResponsePart(_ part: HTTPClientResponsePart, promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        guard var collected = collectedResponse else {
            responseStage = .idle
            forwardResponsePart(part, promise: promise, context: context)
            return
        }
        switch part {
            case .head:
                abandonCollectedResponse(context: context)
                responseStage = .idle
                handleResponsePart(part, promise: promise, context: context)
            case let .body(buffer):
                collected.bytes += buffer.readableBytes
                collected.bodies.append((buffer, promise))
                collectedResponse = collected
                if collected.bytes > limits.bodyBytes || bufferedTotal > limits.bufferedBytes {
                    abandonCollectedResponse(context: context)
                }
            case let .end(trailers):
                collectedResponse = nil
                responseStage = .idle
                let original = HTTPHookMessage.data(of: collected.bodies.map(\.buffer))
                var lengthMatches = true
                if case let .contentLength(length) = HTTPHookMessage.framing(collected.head.headers) {
                    lengthMatches = length == original.count
                }
                if collected.isGzip {
                    // The collected wire bytes are no longer counted; the decoded copy must fit what is left.
                    let cap = min(limits.bodyBytes, limits.bufferedBytes - bufferedTotal - original.count)
                    guard trailers == nil, lengthMatches,
                          let decoded = HTTPHookGzip.decode(original, maxOutput: cap), HTTPHookJSON.isEligible(decoded)
                    else {
                        replayResponse(collected, end: (trailers, promise), context: context)
                        return
                    }
                    collected.promises.append(promise)
                    let observed = HTTPPluginResponse(
                        status: Int(collected.head.status.code), headers: HTTPHookMessage.decodedHeaders(collected.head.headers), body: decoded,
                    )
                    forwardCollectedResponse(collected, original: original, replacement: nil, observationalResponse: observed, context: context)
                    return
                }
                guard trailers == nil, lengthMatches, HTTPHookJSON.isEligible(original) else {
                    replayResponse(collected, end: (trailers, promise), context: context)
                    return
                }
                collected.promises.append(promise)
                startResponseEnter(collected, original: original, context: context)
        }
    }

    func replayResponse(
        _ collected: CollectedResponse, end: (trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?)?,
        context: ChannelHandlerContext,
    ) {
        observeResponse(.head(collected.head))
        forwardResponsePart(.head(collected.head), promise: collected.promises.first ?? nil, context: context)
        for body in collected.bodies {
            observeResponse(.body(body.buffer))
            forwardResponsePart(.body(body.buffer), promise: body.promise, context: context)
        }
        if let end {
            retireExchange()
            forwardResponseEnd(end.trailers, promise: end.promise, context: context)
        } else {
            responseStage = .streamingFinal
        }
    }

    func abandonCollectedResponse(context: ChannelHandlerContext) {
        guard let collected = collectedResponse else { return }
        collectedResponse = nil
        replayResponse(collected, end: nil, context: context)
    }

    func startResponseEnter(_ collected: CollectedResponse, original: Data, context: ChannelHandlerContext) {
        guard let processor, let request = collected.exchange.request else { return }
        let response = HTTPPluginResponse(
            status: Int(collected.head.status.code), headers: HTTPHookMessage.lowercasedHeaders(collected.head.headers), body: original,
        )
        pendingResponse = (collected, original)
        responseBusy = true
        // The upstream peer must not be read while the phase runs; the glue holds its own channel.
        context.fireUserInboundEventTriggered(HTTPHookReadHold.hold)
        let token = responsePhase.begin()
        let loop = context.eventLoop
        let handler = NIOLoopBound(self, eventLoop: loop)
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        responsePhase.task = Task {
            var authorized = await processor.isAuthorized()
            var replacement: Data?
            if authorized {
                replacement = try? await processor.process(.responseEnter, request: request, response: response)
                authorized = await processor.isAuthorized()
            }
            let outcome = Outcome(authorized: authorized, replacement: replacement)
            loop.execute { handler.value.responseEnterFinished(token: token, outcome: outcome, context: boundContext.value) }
        }
        responsePhase.deadline = loop.scheduleTask(in: limits.phaseDeadline) {
            handler.value.responseDeadlineHit(token: token, context: boundContext.value)
        }
    }

    /// See `requestDeadlineHit`.
    func responseDeadlineHit(token: UInt64, context: ChannelHandlerContext) {
        recheckAuthorization(request: false, token: token, context: context)
    }

    func responseEnterFinished(token: UInt64, outcome: Outcome, context: ChannelHandlerContext) {
        guard !closed, token == responsePhase.token, let pending = pendingResponse else { return }
        responsePhase.invalidate()
        responseAuthorizationRecheck = false
        pendingResponse = nil
        guard isConsentGranted(), outcome.authorized, context.channel.isActive else {
            closeConnection(context)
            return
        }
        forwardCollectedResponse(pending.collected, original: pending.original, replacement: outcome.replacement, context: context)
        responseBusy = false
        context.fireUserInboundEventTriggered(HTTPHookReadHold.release)
        drainOutbound(context)
    }

    /// A non-nil `observationalResponse` (decoded gzip) is only reported to leave: the wire bytes are forwarded
    /// unchanged and `replacement` is ignored, so mutation is impossible on that path.
    func forwardCollectedResponse(
        _ collected: CollectedResponse, original: Data, replacement: Data?,
        observationalResponse: HTTPPluginResponse? = nil, context: ChannelHandlerContext,
    ) {
        var head = collected.head
        var bodies = collected.bodies.map(\.buffer)
        var forwarded = original
        if observationalResponse == nil, let replacement, replacement != original, HTTPHookJSON.isEligible(replacement),
           original.count <= limits.bufferedBytes - bufferedTotal,
           replacement.count <= limits.bufferedBytes - bufferedTotal - original.count
        {
            head.headers = HTTPHookMessage.repairedFraming(head.headers, bodyLength: replacement.count)
            bodies = [ByteBuffer(bytes: replacement)]
            forwarded = replacement
        }
        let response = observationalResponse ?? HTTPPluginResponse(
            status: Int(head.status.code), headers: HTTPHookMessage.lowercasedHeaders(head.headers), body: forwarded,
        )
        let originals = collected.promises + collected.bodies.map(\.promise)
        let writeID = reserveWriteBodies(request: collected.exchange.request, response: response)

        observeResponse(.head(head))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        for body in bodies {
            observeResponse(.body(body))
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }
        let endPromise = context.eventLoop.makePromise(of: Void.self)
        responseEndsPending += 1
        observer?.responseEnd(written: endPromise.futureResult)
        lastResponseEnd = endPromise.futureResult
        context.write(wrapOutboundOut(.end(nil)), promise: endPromise)
        context.flush()
        retireExchange()
        endPromise.futureResult.whenComplete { [self] result in
            for original in originals {
                original?.completeWith(result)
            }
            guard !closed else { return }
            responseEndsPending -= 1
            let retained = pendingWrites.removeValue(forKey: writeID)
            switch result {
                case .success:
                    if let retained {
                        startLeave(.responseLeave, request: retained.request, response: retained.response, context: context)
                    }
                    if !responseBusy {
                        drainOutbound(context)
                    }
                case .failure:
                    closeConnection(context)
            }
        }
    }
}

// MARK: - Leave

@available(macOS 14, iOS 17, *)
private extension HTTPHookHandler {
    /// Keep write callbacks body-free so abort can release storage before a write resolves.
    func reserveWriteBodies(request: HTTPPluginRequest?, response: HTTPPluginResponse?) -> UInt64 {
        let id = nextWriteID
        nextWriteID &+= 1
        if let request {
            pendingWrites[id] = PendingWriteBodies(request: request, response: response)
            if bufferedTotal > limits.bufferedBytes || pendingWrites.count > limits.outstandingExchanges {
                // Leave is observational. Skip it instead of retaining bodies beyond either bound.
                pendingWrites[id] = nil
            }
        }
        return id
    }

    /// Read-only: runs after local forwarding succeeded, never blocks traffic and its result is ignored.
    func startLeave(_ phase: HTTPPluginPhase, request: HTTPPluginRequest, response: HTTPPluginResponse?, context: ChannelHandlerContext) {
        // Bounded: a slow callback cannot accumulate tasks (and the bodies they retain); excess leaves are dropped.
        guard let processor, !closed, leaveTasks.count < Self.maxLeaves else { return }
        let id = nextLeaveID
        nextLeaveID &+= 1
        leaveBodies[id] = (request.id, request.body.count, response?.body.count ?? 0)
        guard bufferedTotal <= limits.bufferedBytes else {
            leaveBodies[id] = nil
            return
        }
        let loop = context.eventLoop
        let handler = NIOLoopBound(self, eventLoop: loop)
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        leaveTasks[id] = Task {
            if await processor.isAuthorized() {
                _ = try? await processor.process(phase, request: request, response: response)
            } else {
                loop.execute {
                    if !handler.value.closed {
                        handler.value.closeConnection(boundContext.value)
                    }
                }
            }
            loop.execute {
                handler.value.leaveTasks[id] = nil
                handler.value.leaveBodies[id] = nil
            }
        }
    }
}
