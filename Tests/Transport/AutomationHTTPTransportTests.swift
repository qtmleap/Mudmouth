import XCTest
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
@testable import Mudmouth

final class AutomationHTTPTransportTests: XCTestCase, @unchecked Sendable {
    func testOrderedDuplicateHeadersAndExactExternalPayload() async throws {
        let fixture = try await TLSFixture.start(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nSet-Cookie: session=server-only\r\nConnection: close\r\n\r\nok")
        let transport = try makeTransport()
        defer { fixture.stop(); transport.shutdown() }
        let origin = try AutomationHTTPTransport.Origin(host: "localhost", port: fixture.port)
        let request = AutomationHTTPTransport.Request(origin: origin, method: "POST", encodedTarget: "/api?q=1", headers: [.init(name:"X-Order",value:"one"), .init(name:"Accept-Encoding",value:"gzip, deflate, br"), .init(name:"Cookie",value:"secret"), .init(name:"X-Order",value:"two")], body: Data("hello".utf8), contentType:"text/plain")
        let response = try await transport.executeSameOrigin(request)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
        let captured = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(captured.headers.filter { $0.name.lowercased() == "x-order" }.map(\.value), ["one", "two"])
        XCTAssertEqual(captured.body, Data("hello".utf8))
        XCTAssertEqual(captured.headers.filter { $0.name.lowercased() == "accept-encoding" }.map(\.value),["identity"])
        let id = UUID()
        let payload = Data("{\"literal\":  1}".utf8)
        _ = try await transport.deliver(endpoint: URL(string: "https://localhost:\(fixture.port)/deliver")!, payload: payload, deliveryID: id, credentials: .bearer("own-token"))
        let delivery = try XCTUnwrap(fixture.requests.last)
        XCTAssertNil(delivery.headers.first { $0.name.lowercased() == "cookie" })
        XCTAssertEqual(delivery.headers.first { $0.name.lowercased() == "authorization" }?.value, "Bearer own-token")
        XCTAssertEqual(delivery.headers.first { $0.name.lowercased() == "idempotency-key" }?.value, id.uuidString)
        XCTAssertEqual(delivery.body, payload)
        XCTAssertEqual(delivery.headers.filter { $0.name.lowercased() == "accept-encoding" }.map(\.value),["identity"])
        XCTAssertEqual(Set(delivery.headers.map { $0.name.lowercased() }),Set(["host","authorization","idempotency-key","content-type","content-length","accept-encoding","connection"]))
        _ = try await transport.deliver(endpoint: URL(string:"https://localhost:\(fixture.port)/deliver")!,payload:payload,deliveryID:id,credentials:.bearer("own-token"))
        let repeated = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(repeated.body,payload)
        XCTAssertEqual(repeated.headers,delivery.headers)
        XCTAssertEqual(fixture.requests.count,3)
    }
    func testStatusesAndHTTPBodySemantics() async throws {
        for (method, raw, status, body) in [
            ("GET", "HTTP/1.1 100 Continue\r\nX-Info: yes\r\n\r\nHTTP/1.1 401 Unauthorized\r\nContent-Length: 3\r\n\r\nbad", 401, Data("bad".utf8)),
            ("GET", "HTTP/1.1 500 Error\r\nContent-Length: 0\r\n\r\n", 500, Data()),
            ("HEAD", "HTTP/1.1 200 OK\r\nContent-Length: 99999\r\n\r\n", 200, nil),
            ("GET", "HTTP/1.1 204 No Content\r\n\r\n", 204, nil),
            ("GET", "HTTP/1.1 304 Not Modified\r\nContent-Length: 99999\r\n\r\n", 304, nil)
        ] as [(String,String,Int,Data?)] {
            let fixture = try await TLSFixture.start(response:raw)
            let transport = try makeTransport()
            defer { fixture.stop(); transport.shutdown() }
            let result = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:fixture.port),method:method,encodedTarget:"/",headers:[]))
            XCTAssertEqual(result.status,status)
            XCTAssertEqual(result.body,body)
        }
    }

    func testRedirectUpgradeFramingLimitsAndEncodingFailClosed() async throws {
        for (raw, expected) in [
            ("HTTP/1.1 302 Found\r\nLocation: https://example.invalid\r\nContent-Length: 0\r\n\r\n", .redirect),
            ("HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n", .upgrade),
            ("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\ncut", .earlyEOF),
            ("HTTP/1.1 200 OK\r\nContent-Length: 32769\r\n\r\n", .bodyLimit),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8001\r\n" + String(repeating:"b",count:32769) + "\r\n0\r\n\r\n", .bodyLimit),
            ("HTTP/1.1 200 OK\r\nX-Huge: " + String(repeating:"a",count:8200) + "\r\nContent-Length: 0\r\n\r\n", .headerLimit),
            ("HTTP/1.1 200 OK\r\nX-Incomplete: " + String(repeating:"a",count:8200), .headerLimit),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\n", .framing),
            ("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 1\r\n\r\nx", .unsupportedEncoding)
        ] as [(String,AutomationHTTPTransport.Failure)] {
            let fixture = try await TLSFixture.start(response:raw,close:true)
            let transport = try makeTransport()
            defer { fixture.stop(); transport.shutdown() }
            do { _ = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:fixture.port),method:"GET",encodedTarget:"/",headers:[])); XCTFail("Expected \(expected)") }
            catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,expected) }
        }
    }

    func testFragmentedIncompleteTrailersShareTheHeaderBudget() async throws {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        for trailers in ["X: " + String(repeating:"a",count:8300), String(repeating:"X: a\r\n",count:1400)] {
            let bytes = Array((head + "0\r\n" + trailers).utf8)
            let fragments = stride(from:0,to:bytes.count,by:511).map { String(decoding:bytes[$0..<min($0+511,bytes.count)],as:UTF8.self) }
            let fixture = try await TLSFixture.start(response:nil,fragments:fragments)
            let transport = try makeTransport(timeout:.milliseconds(300))
            defer { fixture.stop(); transport.shutdown() }
            do { _ = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:fixture.port),method:"GET",encodedTarget:"/",headers:[])); XCTFail("Oversize incomplete trailers accepted") }
            catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.headerLimit) }
        }
    }

    func testTransferCodingChainsAndDuplicatesAreRejected() async throws {
        for (coding, expected) in [("gzip, chunked",AutomationHTTPTransport.Failure.unsupportedEncoding),("gzip",.unsupportedEncoding),("chunked, chunked",.framing),("gzip,,chunked",.framing)] {
            let fixture = try await TLSFixture.start(response:"HTTP/1.1 200 OK\r\nTransfer-Encoding: \(coding)\r\n\r\n3\r\nzip\r\n0\r\n\r\n",close:true)
            let transport = try makeTransport()
            defer { fixture.stop(); transport.shutdown() }
            do { _ = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:fixture.port),method:"GET",encodedTarget:"/",headers:[])); XCTFail("Unsupported transfer coding accepted: \(coding)") }
            catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,expected) }
        }
    }

    func testChunkLengthsSkipBodyDelimitersAndExactAggregateTrailerLimit() async throws {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: ChUnKeD\r\n\r\n"
        let payload = "0\r\n\r\nnot-a-trailer"
        for extra in [0,1] {
            let padding = String(repeating:"a",count:8192-head.utf8.count-7+extra)
            let raw = head + String(payload.utf8.count,radix:16) + ";fixture=yes\r\n" + payload + "\r\n0\r\nX: " + padding + "\r\n\r\n"
            let bytes = Array(raw.utf8)
            let fragments = stride(from:0,to:bytes.count,by:127).map { String(decoding:bytes[$0..<min($0+127,bytes.count)],as:UTF8.self) }
            let fixture = try await TLSFixture.start(response:nil,fragments:fragments)
            let transport = try makeTransport()
            defer { fixture.stop(); transport.shutdown() }
            do {
                let result = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:fixture.port),method:"GET",encodedTarget:"/",headers:[]))
                XCTAssertEqual(extra,0,"Combined header/trailer budget exceeded")
                XCTAssertEqual(result.body,Data(payload.utf8))
            } catch {
                XCTAssertEqual(extra,1,"Exact combined limit should succeed")
                XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.headerLimit)
            }
        }
    }

    func testAtLimitBodiesAndDuplicateResponseHeadersArePreserved() async throws {
        let bytes = String(repeating:"a",count:32768)
        let fixture = try await TLSFixture.start(response:"HTTP/1.1 200 OK\r\nX-Duplicate: one\r\nX-Duplicate: two\r\nContent-Length: 32768\r\n\r\n" + bytes)
        let transport = try makeTransport()
        defer { fixture.stop(); transport.shutdown() }
        let result = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:fixture.port),method:"POST",encodedTarget:"/",headers:[],body:Data(bytes.utf8),contentType:"application/octet-stream"))
        XCTAssertEqual(result.body,Data(bytes.utf8))
        XCTAssertEqual(fixture.requests.first?.body,Data(bytes.utf8))
        XCTAssertEqual(result.headers.filter { $0.name.lowercased() == "x-duplicate" }.map(\.value),["one","two"])
    }

    func testTLSAndHostnameVerification() async throws {
        let fixture = try await TLSFixture.start(response:"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let system = try AutomationHTTPTransport()
        let rooted = try makeTransport()
        defer { fixture.stop(); system.shutdown(); rooted.shutdown() }
        for (transport, host) in [(system,"localhost"),(rooted,"127.0.0.1")] {
            do { _ = try await transport.executeSameOrigin(.init(origin:try .init(host:host,port:fixture.port),method:"GET",encodedTarget:"/",headers:[])); XCTFail("Untrusted TLS accepted") }
            catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.tls) }
        }
    }

    func testCancellationDuringTLSHandshakeClosesOnlyOwnedChannel() async throws {
        let fixture = try await TLSFixture.start(response:nil,stallTLS:true)
        let transport = try makeTransport(timeout:.seconds(2))
        let token = AutomationHTTPTransport.Cancellation()
        let request = AutomationHTTPTransport.Request(origin:try .init(host:"localhost",port:fixture.port),method:"GET",encodedTarget:"/",headers:[])
        let task = Task { try await transport.executeSameOrigin(request,cancellation:token) }
        defer { task.cancel(); fixture.stop(); transport.shutdown() }
        for _ in 0..<200 where fixture.activeConnections == 0 { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(fixture.activeConnections,1)
        token.cancel()
        do { _ = try await task.value; XCTFail("Handshake cancellation ignored") }
        catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.cancelled) }
        for _ in 0..<200 where fixture.activeConnections > 0 { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(fixture.activeConnections,0)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testDeadlineCancellationAndCapacityAreOperationSpecific() async throws {
        let hanging = try await TLSFixture.start(response:nil)
        let responding = try await TLSFixture.start(response:"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        let transport = try makeTransport(timeout:.seconds(2))
        let tokenA = AutomationHTTPTransport.Cancellation()
        let tokenB = AutomationHTTPTransport.Cancellation()
        let request = AutomationHTTPTransport.Request(origin:try .init(host:"localhost",port:hanging.port),method:"GET",encodedTarget:"/",headers:[])
        let a = Task { try await transport.executeSameOrigin(request,cancellation:tokenA) }
        let b = Task { try await transport.executeSameOrigin(request,cancellation:tokenB) }
        defer { a.cancel(); b.cancel(); hanging.stop(); responding.stop(); transport.shutdown() }
        for _ in 0..<200 where hanging.requests.count < 2 { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(hanging.requests.count,2)
        do { _ = try await transport.executeSameOrigin(request); XCTFail("Capacity exceeded") }
        catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.saturated) }
        tokenA.cancel()
        do { _ = try await a.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.cancelled) }
        // The second request still owns its channel and reaches its own deadline.
        let good = try await transport.executeSameOrigin(.init(origin:try .init(host:"localhost",port:responding.port),method:"GET",encodedTarget:"/",headers:[]))
        XCTAssertEqual(good.body,Data("ok".utf8))
        do { _ = try await b.value; XCTFail("Deadline ignored") }
        catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.deadline) }
        let preCancelled = AutomationHTTPTransport.Cancellation()
        preCancelled.cancel()
        do { _ = try await transport.executeSameOrigin(request,cancellation:preCancelled); XCTFail("Precancel ignored") }
        catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.cancelled) }
        XCTAssertEqual(hanging.requests.count,2)
    }

    func testRequestSafetyAndBoundsBeforeNetwork() async throws {
        let transport = try makeTransport()
        defer { transport.shutdown() }
        let origin = try AutomationHTTPTransport.Origin(host:"localhost",port:1)
        for header in [AutomationHTTPTransport.Header(name:"Host",value:"attacker"), .init(name:"Transfer-Encoding",value:"chunked"), .init(name:"Connection",value:"X-Foo"), .init(name:"X-Test",value:"hello\r\nCookie: secret")] {
            do { _ = try await transport.executeSameOrigin(.init(origin:origin,method:"GET",encodedTarget:"/",headers:[header])); XCTFail("Unsafe header accepted") }
            catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.invalidRequest) }
        }
        do { _ = try await transport.executeSameOrigin(.init(origin:origin,method:"POST",encodedTarget:"/",headers:[],body:Data(repeating:1,count:32769))); XCTFail("Oversize body accepted") }
        catch { XCTAssertEqual(error as? AutomationHTTPTransport.Failure,.bodyLimit) }
    }

}

private func makeTransport(timeout: TimeAmount = .seconds(10)) throws -> AutomationHTTPTransport {
    try AutomationHTTPTransport(testRoot: fixturePath("ca.pem"), timeout: timeout)
}
private func fixturePath(_ file: String) -> String { ProcessInfo.processInfo.environment["TRANSPORT_FIXTURES"]! + "/" + file }

private final class TLSFixture: @unchecked Sendable {
    struct Captured: Sendable { let headers: [AutomationHTTPTransport.Header]; let body: Data }
    private let lock = NSLock()
    private var stored: [Captured] = []
    private var children: [Channel] = []
    let group: MultiThreadedEventLoopGroup
    var server: Channel!
    var port: Int { server.localAddress!.port! }
    var requests: [Captured] { lock.withLock { stored } }
    var activeConnections: Int { lock.withLock { children.filter(\.isActive).count } }
    init() { group = MultiThreadedEventLoopGroup(numberOfThreads: 1) }
    func append(_ value: Captured) { lock.withLock { stored.append(value) } }
    static func start(response: String?, close: Bool = false, stallTLS: Bool = false, fragments: [String]? = nil) async throws -> TLSFixture {
        let f = TLSFixture()
        let certificates = try NIOSSLCertificate.fromPEMFile(fixturePath("server.pem"))
        let key = try NIOSSLPrivateKey(file: fixturePath("server.key"), format: .pem)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(key)))
        do {
            f.server = try await ServerBootstrap(group:f.group).childChannelInitializer { channel in
                f.lock.withLock { f.children.append(channel) }
                if stallTLS { return channel.eventLoop.makeSucceededVoidFuture() }
                do {
                    try channel.pipeline.syncOperations.addHandlers([NIOSSLServerHandler(context:context), ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy:.dropBytes)), FixtureHandler(fixture:f,response:response,close:close,fragments:fragments)])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.bind(host:"127.0.0.1",port:0).get()
            return f
        } catch { f.stop(); throw error }
    }
    func stop() {
        for channel in lock.withLock({ children }) { try? channel.close().wait() }
        if let server { try? server.close().wait() }
        try? group.syncShutdownGracefully()
    }
}
private final class FixtureHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer
    let fixture: TLSFixture
    let response: String?
    let close: Bool
    let fragments: [String]?
    var headers: [AutomationHTTPTransport.Header] = []
    var body = Data()
    init(fixture:TLSFixture,response:String?,close:Bool,fragments:[String]?) { self.fixture=fixture;self.response=response;self.close=close;self.fragments=fragments }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): headers = head.headers.map { .init(name:$0.name,value:$0.value) }
        case .body(var bytes): body.append(contentsOf: bytes.readBytes(length:bytes.readableBytes)!)
        case .end:
            fixture.append(.init(headers:headers,body:body))
            if let fragments { Self.send(channel:context.channel,fragments:fragments,index:0) }
            else if let response {
                let buffer = context.channel.allocator.buffer(string:response)
                let channel = context.channel
                let shouldClose = close
                context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in if shouldClose { channel.close(promise:nil) } }
            }
        }
    }
    private static func send(channel:Channel,fragments:[String],index:Int) {
        guard channel.isActive, index < fragments.count else { return }
        channel.writeAndFlush(channel.allocator.buffer(string:fragments[index])).whenSuccess { _ in
            channel.eventLoop.scheduleTask(in:.milliseconds(2)) { send(channel:channel,fragments:fragments,index:index+1) }
        }
    }
    func errorCaught(context:ChannelHandlerContext,error:Error) { context.close(promise:nil) }
}
