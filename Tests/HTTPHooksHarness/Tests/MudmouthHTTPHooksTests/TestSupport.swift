//
//  TestSupport.swift
//  MudmouthHTTPHooksTests
//
//  Fakes and a two-channel rig for the transport tests. Everything is driven through NIOAsyncTestingChannel
//  because the processor is genuinely async and completes off the event loop.
//

import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

enum TestError: Error, Equatable { case boom }

// MARK: - Small thread-safe helpers

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func add(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var all: [String] {
        lock.withLock { events }
    }

    func matching(prefix: String) -> [String] {
        all.filter { $0.hasPrefix(prefix) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    var get: Bool {
        lock.withLock { value }
    }

    func set(_ new: Bool) {
        lock.withLock { value = new }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

// MARK: - Wire view of HTTP parts

/// Equatable summary of a part, so tests compare bytes and framing rather than NIO enums.
enum Wire: Equatable {
    case requestHead(method: String, uri: String, headers: [String: String])
    case responseHead(status: Int, headers: [String: String])
    case body(String)
    case end
    case endWithTrailers

    init(_ part: HTTPClientRequestPart) {
        switch part {
            case let .head(head): self = .requestHead(method: head.method.rawValue, uri: head.uri, headers: Wire.dictionary(head.headers))
            case let .body(data): self = .body(Wire.string(data))
            case let .end(trailers): self = trailers == nil ? .end : .endWithTrailers
        }
    }

    init(_ part: HTTPServerResponsePart) {
        switch part {
            case let .head(head): self = .responseHead(status: Int(head.status.code), headers: Wire.dictionary(head.headers))
            case let .body(data): self = .body(Wire.string(data))
            case let .end(trailers): self = trailers == nil ? .end : .endWithTrailers
        }
    }

    var headers: [String: String] {
        switch self {
            case let .requestHead(_, _, headers), let .responseHead(_, headers): headers
            default: [:]
        }
    }

    private static func dictionary(_ headers: HTTPHeaders) -> [String: String] {
        Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func string(_ data: IOData) -> String {
        guard case let .byteBuffer(buffer) = data else { return "<file region>" }
        return String(buffer: buffer)
    }
}

// MARK: - Fake processor

@available(macOS 14, iOS 17, *)
final class FakeProcessor: HTTPPluginProcessing, @unchecked Sendable {
    struct Call: Sendable {
        var phase: HTTPPluginPhase
        var request: HTTPPluginRequest
        var response: HTTPPluginResponse?
    }

    private let lock = NSLock()
    private var authorized = true
    private var recordedCalls: [Call] = []
    private var results: [HTTPPluginPhase: Result<Data?, Error>] = [:]
    private var gated: Set<HTTPPluginPhase> = []
    private var waiters: [HTTPPluginPhase: [CheckedContinuation<Void, Never>]] = [:]
    private var authorizationChecks = 0
    private var authorizationGated = false
    private var authorizationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var matchedRequests: [HTTPPluginRequest] = []

    let recorder: Recorder
    var matcher: @Sendable (HTTPPluginRequest) -> Bool = { $0.host == "api.example.com" }
    /// Runs after a phase decided its result and before it returns (used to revoke mid-flight).
    var afterProcess: (@Sendable (HTTPPluginPhase) -> Void)?

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func calls(_ phase: HTTPPluginPhase) -> [Call] {
        calls.filter { $0.phase == phase }
    }

    var matchedHeads: [HTTPPluginRequest] {
        lock.withLock { matchedRequests }
    }

    var authorizationCheckCount: Int {
        lock.withLock { authorizationChecks }
    }

    var authorizationWaiterCount: Int {
        lock.withLock { authorizationWaiters.count }
    }

    func gateAuthorization() {
        lock.withLock { authorizationGated = true }
    }

    func releaseAuthorization() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            authorizationGated = false
            let pending = Array(authorizationWaiters.values)
            authorizationWaiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }

    func setResult(_ phase: HTTPPluginPhase, _ result: Result<Data?, Error>) {
        lock.withLock { results[phase] = result }
    }

    func setAuthorized(_ value: Bool) {
        lock.withLock { authorized = value }
    }

    func gate(_ phase: HTTPPluginPhase) {
        lock.withLock { _ = gated.insert(phase) }
    }

    func releaseGate(_ phase: HTTPPluginPhase) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gated.remove(phase)
            return waiters.removeValue(forKey: phase) ?? []
        }
        pending.forEach { $0.resume() }
    }

    func matches(_ request: HTTPPluginRequest) -> Bool {
        lock.withLock { matchedRequests.append(request) }
        return matcher(request)
    }

    func isAuthorized() async -> Bool {
        let gated = lock.withLock {
            authorizationChecks += 1
            return authorizationGated
        }
        if gated {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resume = lock.withLock { () -> Bool in
                        if !authorizationGated || Task.isCancelled {
                            return true
                        }
                        authorizationWaiters[id] = continuation
                        return false
                    }
                    if resume {
                        continuation.resume()
                    }
                }
            } onCancel: {
                let pending = self.lock.withLock { self.authorizationWaiters.removeValue(forKey: id) }
                pending?.resume()
            }
        }
        return lock.withLock { authorized && !Task.isCancelled }
    }

    func process(_ phase: HTTPPluginPhase, request: HTTPPluginRequest, response: HTTPPluginResponse?) async throws -> Data? {
        recorder.add(phase.rawValue)
        lock.withLock { recordedCalls.append(.init(phase: phase, request: request, response: response)) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if gated.contains(phase) {
                        waiters[phase, default: []].append(continuation)
                        return false
                    }
                    return true
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            recorder.add("cancel \(phase.rawValue)")
            releaseGate(phase)
        }
        let result = lock.withLock { results[phase] } ?? .success(nil)
        afterProcess?(phase)
        return try result.get()
    }
}

// MARK: - Observer

final class RecordingObserver: HTTPExchangeObserving {
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func requestHead(_ head: HTTPRequestHead) {
        recorder.add("obs:req-head \(head.method.rawValue) \(head.uri) cl=\(head.headers.first(name: "content-length") ?? "-")")
    }

    func requestBody(_ buffer: ByteBuffer) {
        recorder.add("obs:req-body \(String(buffer: buffer))")
    }

    func responseHead(_ head: HTTPResponseHead) {
        recorder.add("obs:res-head \(head.status.code) cl=\(head.headers.first(name: "content-length") ?? "-")")
    }

    func responseBody(_ buffer: ByteBuffer) {
        recorder.add("obs:res-body \(String(buffer: buffer))")
    }

    func responseEnd() {
        recorder.add("obs:res-end")
    }
}

// MARK: - Channel handlers

/// Counts reads that reach the head of a pipeline; this is how tests observe read holds.
final class ReadProbe: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny
    private let counter: Counter
    private let flushes: Counter?

    init(counter: Counter, flushes: Counter? = nil) {
        self.counter = counter
        self.flushes = flushes
    }

    func flush(context: ChannelHandlerContext) {
        flushes?.increment()
        context.flush()
    }

    func read(context: ChannelHandlerContext) {
        counter.increment()
        context.read()
    }
}

/// Sits at the head side of a pipeline and decides what happens to the write of a message end:
/// pass, hold its promise until the test completes it, or fail it.
final class ControlledWriteHandler<Part>: ChannelOutboundHandler {
    typealias OutboundIn = Part
    typealias OutboundOut = Part

    var holdEnd = false
    var completeEndInline = false
    var failEnd: Error?
    private var heldPromises: [EventLoopPromise<Void>] = []
    var heldPromise: EventLoopPromise<Void>? {
        heldPromises.first
    }

    private let isEnd: (Part) -> Bool
    private let label: String
    private let recorder: Recorder

    init(label: String, recorder: Recorder, isEnd: @escaping (Part) -> Bool) {
        self.label = label
        self.recorder = recorder
        self.isEnd = isEnd
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard isEnd(unwrapOutboundIn(data)) else {
            context.write(data, promise: promise)
            return
        }
        recorder.add("\(label)-end-write")
        if let failEnd {
            promise?.fail(failEnd)
            return
        }
        if holdEnd {
            if let promise {
                heldPromises.append(promise)
            }
            context.write(data, promise: nil)
            return
        }
        if completeEndInline {
            context.write(data, promise: nil)
            promise?.succeed(())
            return
        }
        context.write(data, promise: promise)
    }

    func completeHeld(on loop: EventLoop, with error: Error? = nil) async throws {
        let done = loop.submit {
            let promises = self.heldPromises
            self.heldPromises.removeAll()
            for promise in promises {
                if let error {
                    promise.fail(error)
                } else {
                    promise.succeed(())
                }
            }
        }
        await (loop as? NIOAsyncTestingEventLoop)?.run()
        try await done.get()
    }
}

// MARK: - Rig

/// downstream: [ReadProbe, ControlledWrite, HTTPHookHandler, Glue]   (the client-facing, TLS-terminated leg)
/// upstream:   [ReadProbe, ControlledWrite, Glue]                    (the connection to the real server)
@available(macOS 14, iOS 17, *)
final class Rig {
    let loop: NIOAsyncTestingEventLoop
    let downstream: NIOAsyncTestingChannel
    let upstream: NIOAsyncTestingChannel
    let recorder: Recorder
    let processor: FakeProcessor
    let consent = Flag(true)
    let downstreamReads = Counter()
    let upstreamReads = Counter()
    let downstreamFlushes = Counter()
    let upstreamFlushes = Counter()
    let upstreamControl: ControlledWriteHandler<HTTPClientRequestPart>
    let downstreamControl: ControlledWriteHandler<HTTPServerResponsePart>
    private(set) var sentUpstream: [Wire] = []
    private(set) var sentDownstream: [Wire] = []

    private init(
        loop: NIOAsyncTestingEventLoop, downstream: NIOAsyncTestingChannel, upstream: NIOAsyncTestingChannel,
        recorder: Recorder, processor: FakeProcessor,
        upstreamControl: ControlledWriteHandler<HTTPClientRequestPart>,
        downstreamControl: ControlledWriteHandler<HTTPServerResponsePart>,
    ) {
        self.loop = loop
        self.downstream = downstream
        self.upstream = upstream
        self.recorder = recorder
        self.processor = processor
        self.upstreamControl = upstreamControl
        self.downstreamControl = downstreamControl
    }

    static func make(
        installProcessor: Bool = true,
        authority: String? = "api.example.com",
        limits: HTTPHookLimits = .init(),
        configure: (FakeProcessor) -> Void = { _ in },
    ) async throws -> Rig {
        let loop = NIOAsyncTestingEventLoop()
        let downstream = NIOAsyncTestingChannel(loop: loop)
        let upstream = NIOAsyncTestingChannel(loop: loop)
        let recorder = Recorder()
        let processor = FakeProcessor(recorder: recorder)
        configure(processor)
        let upstreamControl = ControlledWriteHandler<HTTPClientRequestPart>(label: "upstream", recorder: recorder) {
            if case .end = $0 {
                return true
            }
            return false
        }
        let downstreamControl = ControlledWriteHandler<HTTPServerResponsePart>(label: "downstream", recorder: recorder) {
            if case .end = $0 {
                return true
            }
            return false
        }
        let rig = Rig(
            loop: loop, downstream: downstream, upstream: upstream, recorder: recorder, processor: processor,
            upstreamControl: upstreamControl, downstreamControl: downstreamControl,
        )
        let consent = rig.consent
        let hook = HTTPHookHandler(
            authority: HTTPHookAuthority(host: authority),
            processor: installProcessor ? processor : nil,
            observer: RecordingObserver(recorder: recorder),
            isConsentGranted: { consent.get },
            limits: limits,
        )
        let (localGlue, remoteGlue) = GlueHandler.matchedPair()
        try await downstream.pipeline.addHandlers([
            ReadProbe(counter: rig.downstreamReads, flushes: rig.downstreamFlushes), downstreamControl, hook, localGlue,
        ]).get()
        try await upstream.pipeline.addHandlers([
            ReadProbe(counter: rig.upstreamReads, flushes: rig.upstreamFlushes), upstreamControl, remoteGlue,
        ]).get()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        try await downstream.connect(to: address).get()
        try await upstream.connect(to: address).get()
        return rig
    }

    // MARK: Driving

    func sendRequest(_ parts: HTTPServerRequestPart...) async throws {
        for part in parts {
            try await downstream.writeInbound(part)
        }
    }

    func sendResponse(_ parts: HTTPClientResponsePart...) async throws {
        for part in parts {
            try await upstream.writeInbound(part)
        }
    }

    // MARK: Observing

    @discardableResult
    func collectUpstream() async throws -> [Wire] {
        while let part = try await upstream.readOutbound(as: HTTPClientRequestPart.self) {
            sentUpstream.append(Wire(part))
        }
        return sentUpstream
    }

    @discardableResult
    func collectDownstream() async throws -> [Wire] {
        while let part = try await downstream.readOutbound(as: HTTPServerResponsePart.self) {
            sentDownstream.append(Wire(part))
        }
        return sentDownstream
    }

    /// Polls (bounded, wall-clock) while letting the testing loop run its queued tasks.
    func eventually(timeoutMilliseconds: Int = 3000, _ condition: () async throws -> Bool) async throws -> Bool {
        var waited = 0
        while waited < timeoutMilliseconds {
            await loop.run()
            if try await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 2_000_000)
            waited += 2
        }
        return false
    }

    func waitUpstream(_ count: Int) async throws -> [Wire] {
        _ = try await eventually { try await self.collectUpstream().count >= count }
        return sentUpstream
    }

    func waitDownstream(_ count: Int) async throws -> [Wire] {
        _ = try await eventually { try await self.collectDownstream().count >= count }
        return sentDownstream
    }

    func waitForPhase(_ phase: HTTPPluginPhase, count: Int = 1) async throws -> Bool {
        try await eventually { self.processor.calls(phase).count >= count }
    }

    func waitForClose() async throws -> Bool {
        try await eventually { !self.downstream.isActive }
    }

    /// Lets in-flight async work finish, then collects. Use before asserting that something did NOT happen.
    func quiet() async throws {
        await loop.run()
        try await Task.sleep(nanoseconds: 40_000_000)
        await loop.run()
        try await collectUpstream()
        try await collectDownstream()
    }
}

// MARK: - Message builders

enum Fixture {
    static let json = #"{"limit":10}"#
    static let mutated = #"{"limit":5}"#

    static func requestHead(
        _ method: HTTPMethod = .POST, uri: String = "/search?q=1", hostHeader: String = "api.example.com",
        contentType: String? = "application/json", contentLength: Int?, extra: [(String, String)] = [],
    ) -> HTTPRequestHead {
        var headers = HTTPHeaders([("Host", hostHeader)])
        if let contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        if let contentLength {
            headers.add(name: "Content-Length", value: "\(contentLength)")
        }
        for (name, value) in extra {
            headers.add(name: name, value: value)
        }
        return HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: headers)
    }

    static func chunkedRequestHead(uri: String = "/search?q=1") -> HTTPRequestHead {
        requestHead(uri: uri, contentLength: nil, extra: [("Transfer-Encoding", "chunked")])
    }

    static func responseHead(
        _ status: HTTPResponseStatus = .ok, contentType: String? = "application/json", contentLength: Int?,
        extra: [(String, String)] = [],
    ) -> HTTPResponseHead {
        var headers = HTTPHeaders()
        if let contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        if let contentLength {
            headers.add(name: "Content-Length", value: "\(contentLength)")
        }
        for (name, value) in extra {
            headers.add(name: name, value: value)
        }
        return HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    }

    static func buffer(_ string: String) -> ByteBuffer {
        ByteBuffer(string: string)
    }

    /// A complete JSON POST request: head, one body part, end.
    static func postParts(_ body: String = json, uri: String = "/search?q=1") -> [HTTPServerRequestPart] {
        [
            .head(requestHead(uri: uri, contentLength: body.utf8.count)),
            .body(buffer(body)),
            .end(nil),
        ]
    }
}

@available(macOS 14, iOS 17, *)
extension Rig {
    func sendPost(_ body: String = Fixture.json, uri: String = "/search?q=1") async throws {
        for part in Fixture.postParts(body, uri: uri) {
            try await downstream.writeInbound(part)
        }
    }

    func sendJSONResponse(_ body: String, status: HTTPResponseStatus = .ok) async throws {
        try await sendResponse(
            .head(Fixture.responseHead(status, contentLength: body.utf8.count)),
            .body(Fixture.buffer(body)),
            .end(nil),
        )
    }
}

@available(macOS 14, iOS 17, *)
extension Rig {
    /// Builds a rig, runs the body and always finishes both channels (embedded channels assert if dropped open).
    static func run(
        installProcessor: Bool = true,
        authority: String? = "api.example.com",
        limits: HTTPHookLimits = .init(),
        configure: (FakeProcessor) -> Void = { _ in },
        _ body: (Rig) async throws -> Void,
    ) async throws {
        let rig = try await make(installProcessor: installProcessor, authority: authority, limits: limits, configure: configure)
        do {
            try await body(rig)
        } catch {
            await rig.shutdown()
            throw error
        }
        await rig.shutdown()
    }

    func shutdown() async {
        // Release any gated phases so no continuation leaks.
        processor.releaseAuthorization()
        for phase in HTTPPluginPhase.allCases {
            processor.releaseGate(phase)
        }
        try? await upstreamControl.completeHeld(on: loop, with: ChannelError.ioOnClosedChannel)
        try? await downstreamControl.completeHeld(on: loop, with: ChannelError.ioOnClosedChannel)
        _ = try? await downstream.finish(acceptAlreadyClosed: true)
        _ = try? await upstream.finish(acceptAlreadyClosed: true)
        // Fire any leftover phase-deadline timers so the testing loop is not freed with scheduled tasks.
        await loop.run()
        await loop.advanceTime(by: .hours(1))
    }
}

/// Non-autoclosure assertions so `try await` expressions can be passed directly.
func expectTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, message, file: file, line: line)
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs, rhs, message, file: file, line: line)
}

@available(macOS 14, iOS 17, *)
extension Rig {
    /// Issues `pipeline.read()` from the tail, the way a downstream consumer (glue / auto-read) would, and lets the loop run it.
    func pipelineRead(_ channel: NIOAsyncTestingChannel) async throws {
        let done = channel.eventLoop.submit { channel.pipeline.read() }
        await loop.run()
        try await done.get()
    }
}

/// Records head-side write/flush/output-close order. The output close is swallowed (embedded channels cannot half-close).
final class OrderProbe: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny
    private let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        recorder.add("order:write")
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        recorder.add("order:flush")
        context.flush()
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard mode == .output else {
            context.close(mode: mode, promise: promise)
            return
        }
        recorder.add("order:close-output")
        promise?.succeed(())
    }
}
