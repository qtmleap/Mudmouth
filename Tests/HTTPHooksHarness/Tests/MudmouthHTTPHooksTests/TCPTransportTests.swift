import Foundation
import MudmouthHTTPHooks
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

private enum SocketTestFailure: Error { case timeout, prematureClose }

private struct SocketMessage {
    var uri: String
    var status: Int
    var headers: HTTPHeaders
    var body: String
}

/// Every listener and accepted/connected socket belongs to this test and is closed before group shutdown.
private final class SocketResources: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []

    func add(_ channel: Channel) {
        lock.withLock { channels.append(channel) }
    }

    func closeAll() async {
        let owned = lock.withLock { channels.reversed() }
        for channel in owned {
            try? await channel.close().get()
        }
    }
}

private final class SocketOrigin: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let received: EventLoopPromise<SocketMessage>
    private let response: String
    private var head: HTTPRequestHead?
    private var body = ""

    init(received: EventLoopPromise<SocketMessage>, response: String) {
        self.received = received
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head): self.head = head
            case let .body(buffer): body += String(buffer: buffer)
            case .end:
                guard let head else { return }
                self.head = nil
                received.succeed(SocketMessage(uri: head.uri, status: 0, headers: head.headers, body: body))
                let headers = HTTPHeaders([("Content-Type", "application/json"), ("Content-Length", "\(response.utf8.count)"), ("Connection", "close")])
                context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .created, headers: headers))), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: response)))), promise: nil)
                let channel = context.channel
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}

private final class SocketResponse: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private let completed: EventLoopPromise<SocketMessage>
    private var head: HTTPResponseHead?
    private var body = ""
    private var finished = false
    private var deadline: Scheduled<Void>?

    init(completed: EventLoopPromise<SocketMessage>) {
        self.completed = completed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(5)) {
            self.finish(.failure(SocketTestFailure.timeout))
            context.close(promise: nil)
        }
    }

    private func finish(_ result: Result<SocketMessage, Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        completed.completeWith(result)
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head): self.head = head
            case let .body(buffer): body += String(buffer: buffer)
            case .end:
                guard let head else { return }
                finish(.success(SocketMessage(uri: "", status: Int(head.status.code), headers: head.headers, body: body)))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(SocketTestFailure.prematureClose))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }
}

@available(macOS 14, iOS 17, *)
final class TCPTransportTests: XCTestCase {
    /// Actual TCP + HTTP codecs + paired glue. No CONNECT/TLS claim is made by this plaintext test.
    func testRealTCPMutatesBothWireBodiesRepairsChunkedFramingAndSurvivesOriginClose() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = SocketResources()
        do {
            let originReceived = group.next().makePromise(of: SocketMessage.self)
            let responseReceived = group.next().makePromise(of: SocketMessage.self)
            let originBody = #"{"ok":true}"#
            let replacement = #"{"maintenance":true}"#
            let processor = FakeProcessor(recorder: Recorder())
            processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            processor.setResult(.responseEnter, .success(Data(replacement.utf8)))
            let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                resources.add(channel)
                return channel.pipeline.addHandlers([
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)), HTTPResponseEncoder(),
                    SocketOrigin(received: originReceived, response: originBody),
                ])
            }.bind(host: "127.0.0.1", port: 0).get()
            resources.add(origin)
            let originAddress = try XCTUnwrap(origin.localAddress)
            let proxy = try await ServerBootstrap(group: group).childChannelInitializer { downstream in
                resources.add(downstream)
                let (local, remote) = GlueHandler.matchedPair()
                return ClientBootstrap(group: downstream.eventLoop).channelInitializer { upstream in
                    resources.add(upstream)
                    return upstream.pipeline.addHandlers([
                        HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)), remote,
                    ])
                }.connect(to: originAddress).flatMap { _ in
                    downstream.pipeline.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)), HTTPResponseEncoder(),
                        HTTPHookHandler(authority: HTTPHookAuthority(host: "api.example.com"), processor: processor), local,
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            resources.add(proxy)
            let proxyAddress = try XCTUnwrap(proxy.localAddress)
            let client = try await ClientBootstrap(group: group).channelInitializer { channel in
                resources.add(channel)
                return channel.pipeline.addHandlers([
                    HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)),
                    SocketResponse(completed: responseReceived),
                ])
            }.connect(to: proxyAddress).get()
            var head = Fixture.chunkedRequestHead(uri: "/search?q=hello")
            head.headers.replaceOrAdd(name: "Host", value: "spoof.example.net")
            client.write(HTTPClientRequestPart.head(head), promise: nil)
            client.write(HTTPClientRequestPart.body(.byteBuffer(Fixture.buffer(Fixture.json))), promise: nil)
            try await client.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            let downstream = try await responseReceived.futureResult.get()
            let upstream = try await originReceived.futureResult.get()
            XCTAssertEqual(upstream.uri, "/search?q=hello")
            XCTAssertEqual(upstream.body, Fixture.mutated)
            XCTAssertEqual(upstream.headers.first(name: "content-length"), "\(Fixture.mutated.utf8.count)")
            XCTAssertFalse(upstream.headers.contains(name: "transfer-encoding"))
            XCTAssertEqual(downstream.status, 201)
            XCTAssertEqual(downstream.body, replacement)
            XCTAssertEqual(downstream.headers.first(name: "content-length"), "\(replacement.utf8.count)")
            XCTAssertFalse(downstream.headers.contains(name: "transfer-encoding"))
            XCTAssertEqual(processor.calls(.requestEnter).first?.request.host, "api.example.com")
            XCTAssertEqual(processor.calls(.requestEnter).first?.request.query, ["q": "hello"])
        } catch {
            await resources.closeAll()
            await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
            throw error
        }
        await resources.closeAll()
        await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
    }
}

private final class SocketRawReply: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let completed: EventLoopPromise<Data>
    private var bytes = Data()
    private var finished = false
    private var deadline: Scheduled<Void>?

    init(completed: EventLoopPromise<Data>) {
        self.completed = completed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(2)) {
            guard !self.finished else { return }
            self.finished = true
            self.completed.fail(SocketTestFailure.timeout)
            context.close(promise: nil)
        }
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            deadline?.cancel()
            completed.succeed(bytes)
        }
        context.fireChannelInactive()
    }
}

private final class UnsupportedForwardProbe: ChannelInboundHandler {
    typealias InboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientResponsePart
    let recorder: Recorder
    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        recorder.add("forwarded")
        if case .end = part {
            // Let the decoder reach the pipelined unsupported head before the earlier response arrives.
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.eventLoop.scheduleTask(in: .milliseconds(20)) {
                let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("Content-Length", "0")]))
                bound.value.write(self.wrapOutboundOut(.head(head)), promise: nil)
                bound.value.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

@available(macOS 14, iOS 17, *)
extension TCPTransportTests {
    func testRawTCPUpgradeAndNestedConnectReturn501WithoutForwardingBinarySuffix() async throws {
        let requests = [
            "GET / HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
            "CONNECT nested.example.com:443 HTTP/1.1\r\nHost: nested.example.com\r\n\r\n",
        ]
        for (request, prior) in requests.flatMap({ request in [false, true].map { (request, $0) } }) {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let resources = SocketResources()
            do {
                let received = group.next().makePromise(of: Data.self)
                let recorder = Recorder()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    resources.add(channel)
                    return channel.pipeline.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), HTTPResponseEncoder(),
                        HTTPHookHandler(authority: HTTPHookAuthority(host: "api.example.com"), processor: nil), UnsupportedForwardProbe(recorder: recorder),
                    ])
                }.bind(host: "127.0.0.1", port: 0).get()
                resources.add(server)
                let address = try XCTUnwrap(server.localAddress)
                let client = try await ClientBootstrap(group: group).channelInitializer { channel in
                    resources.add(channel)
                    return channel.pipeline.addHandler(SocketRawReply(completed: received))
                }.connect(to: address).get()
                let first = prior ? "GET /first HTTP/1.1\r\nHost: api.example.com\r\n\r\n" : ""
                var bytes = ByteBuffer(string: first + request)
                bytes.writeBytes([UInt8](repeating: 0xFF, count: 1024))
                try await client.writeAndFlush(bytes).get()
                do {
                    let reply = try await received.futureResult.get()
                    let text = String(decoding: reply, as: UTF8.self).lowercased()
                    let statusLines = text.components(separatedBy: "\r\n").filter { $0.hasPrefix("http/1.1 ") }
                    XCTAssertEqual(statusLines, prior ? ["http/1.1 200 ok", "http/1.1 501 not implemented"] : ["http/1.1 501 not implemented"],
                                   "refusal must follow earlier responses on the actual socket")
                    XCTAssertTrue(text.contains("content-length: 0\r\n"))
                    XCTAssertTrue(text.contains("connection: close\r\n"))
                    XCTAssertEqual(reply.count, text.utf8.count)
                } catch {
                    XCTFail("unsupported protocol did not receive a bounded 501 refusal: \(error)")
                }
                XCTAssertEqual(recorder.all, prior ? ["forwarded", "forwarded"] : [], "neither unsupported HTTP parts nor raw bytes may reach upstream glue")
            } catch {
                await resources.closeAll()
                await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
                throw error
            }
            await resources.closeAll()
            await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
        }
    }
}

private final class ContinueOrigin: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let recorder: Recorder
    private var uri = ""
    private var body = ""

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head):
                uri = head.uri
                body = ""
                if head.headers.first(name: "expect") == "100-continue" {
                    context.writeAndFlush(wrapOutboundOut(.head(.init(version: .http1_1, status: .continue))), promise: nil)
                }
            case let .body(buffer): body += String(buffer: buffer)
            case .end:
                recorder.add("\(uri) \(body)")
                if uri == "/continue" {
                    context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .init(statusCode: 103)))), promise: nil)
                }
                let head = Fixture.responseHead(contentLength: Fixture.json.utf8.count)
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(Fixture.buffer(Fixture.json)))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private final class ContinueClient: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let completed: EventLoopPromise<[String]>
    let recorder: Recorder
    private var bodies: [String] = []
    private var body = ""
    private var finished = false
    private var deadline: Scheduled<Void>?

    init(completed: EventLoopPromise<[String]>, recorder: Recorder) {
        self.completed = completed
        self.recorder = recorder
    }

    func channelActive(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(3)) {
            self.finish(.failure(SocketTestFailure.timeout))
            context.close(promise: nil)
        }
        let head = Fixture.requestHead(uri: "/continue", contentLength: Fixture.json.utf8.count, extra: [("Expect", "100-continue")])
        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
            case let .head(head):
                recorder.add("status \(head.status.code)")
                if head.status == .continue {
                    recorder.add("sending body after100")
                    context.write(wrapOutboundOut(.body(.byteBuffer(Fixture.buffer(Fixture.json)))), promise: nil)
                    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                } else if head.status.code >= 200 {
                    body = ""
                }
            case let .body(buffer): body += String(buffer: buffer)
            case .end:
                bodies.append(body)
                if bodies.count == 1 {
                    context.write(wrapOutboundOut(.head(Fixture.requestHead(uri: "/next", contentLength: Fixture.json.utf8.count))), promise: nil)
                    context.write(wrapOutboundOut(.body(.byteBuffer(Fixture.buffer(Fixture.json)))), promise: nil)
                    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                } else {
                    finish(.success(bodies))
                }
        }
    }

    private func finish(_ result: Result<[String], Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        completed.completeWith(result)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(SocketTestFailure.prematureClose))
        context.fireChannelInactive()
    }
}

@available(macOS 14, iOS 17, *)
extension TCPTransportTests {
    func testRealTCPClientWaitsFor100ThenReceives103FinalAndNextHookedExchange() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = SocketResources()
        do {
            let completed = group.next().makePromise(of: [String].self)
            let originLog = Recorder()
            let clientLog = Recorder()
            let processor = FakeProcessor(recorder: Recorder())
            processor.setResult(.requestEnter, .success(Data(Fixture.mutated.utf8)))
            processor.setResult(.responseEnter, .success(Data(Fixture.mutated.utf8)))
            let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                resources.add(channel)
                return channel.pipeline.addHandlers([
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)), HTTPResponseEncoder(), ContinueOrigin(recorder: originLog),
                ])
            }.bind(host: "127.0.0.1", port: 0).get()
            resources.add(origin)
            let address = try XCTUnwrap(origin.localAddress)
            let proxy = try await ServerBootstrap(group: group).childChannelInitializer { downstream in
                resources.add(downstream)
                let (local, remote) = GlueHandler.matchedPair()
                return ClientBootstrap(group: downstream.eventLoop).channelInitializer { upstream in
                    resources.add(upstream)
                    return upstream.pipeline.addHandlers([
                        HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward)), remote,
                    ])
                }.connect(to: address).flatMap { _ in
                    downstream.pipeline.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), HTTPResponseEncoder(),
                        HTTPHookHandler(authority: HTTPHookAuthority(host: "api.example.com"), processor: processor), local,
                    ])
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            resources.add(proxy)
            let proxyAddress = try XCTUnwrap(proxy.localAddress)
            _ = try await ClientBootstrap(group: group).channelInitializer { channel in
                resources.add(channel)
                return channel.pipeline.addHandlers([
                    HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .forward)),
                    ContinueClient(completed: completed, recorder: clientLog),
                ])
            }.connect(to: proxyAddress).get()
            do {
                let bodies = try await completed.futureResult.get()
                XCTAssertEqual(bodies, [Fixture.json, Fixture.mutated])
                XCTAssertEqual(clientLog.all, ["status 100", "sending body after100", "status 103", "status 200", "status 200"])
                XCTAssertEqual(originLog.all, ["/continue \(Fixture.json)", "/next \(Fixture.mutated)"])
                XCTAssertEqual(processor.calls(.responseEnter).map(\.request.path), ["/next"])
            } catch { XCTFail("100-continue handshake did not complete: \(error)") }
        } catch {
            await resources.closeAll()
            await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
            throw error
        }
        await resources.closeAll()
        await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
    }
}
